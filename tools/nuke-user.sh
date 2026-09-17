#!/usr/bin/env bash
# =============================================================================
# Matrix Server — полное удаление пользователя
# =============================================================================
# Удаляет пользователя ПОЛНОСТЬЮ: сообщения, медиа, аккаунт, сессии, и затем
# hard-purge: строку в users + все его события из БД + рестарт Synapse
# (внутренние кеши). После этого юзер не отображается нигде.
#
# Запуск:
#   bash tools/nuke-user.sh username
#   bash tools/nuke-user.sh @username:domain.com
#   bash tools/nuke-user.sh '@whatsapp*'            # маска (glob) — всех подходящих
#   bash tools/nuke-user.sh '@user*' --dry-run
#   bash tools/nuke-user.sh username --force        # без подтверждения
#   bash tools/nuke-user.sh username --keep-messages # не редактить сообщения
#   bash tools/nuke-user.sh username --no-purge     # без hard-purge БД (старое поведение)
#
# Маска: символы * и ? как в shell (обязательно в кавычках, иначе shell
# раскроет glob сам). Пример: nuke-user.sh '@whatsapp*' --force
#
# Hard-purge идёт прямым SQL к локальной Synapse БД (postgres контейнер
# matrix-postgres), имена таблиц ориентированы на Synapse 1.15x+.
# Это удаляет локальные копии событий/строки; федеративные копии не трогает.
#
# Требования:
#   - root доступ на сервере
#   - запущенные matrix-synapse и matrix-postgres
#   - curl, jq
# =============================================================================

set -euo pipefail

# --- Цвета ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --- Вывод ---
log() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err() { echo -e "${RED}[x]${NC} $*" >&2; }
info() { echo -e "${BLUE}[i]${NC} $*"; }
step() {
    echo ""
    echo -e "${BOLD}${CYAN}--- $* ---${NC}"
    echo ""
}

# --- Параметры ---
DRY_RUN=false
FORCE=false
KEEP_MESSAGES=false
PURGE=true # hard-purge строк/событий из БД + рестарт Synapse
USERNAME=""
MATRIX_DATA_PATH="/matrix"
IS_MASK=false
NUKE_USERS=()
MASK_TOKEN_REVOKED=false # токен выдан маской, нужно отозвать в конце
MASK_ADMIN_USER=""       # для кого выдан масочный токен
UUID=""                  # uuid compat-сессии выданного токена
DID_PURGE=false          # был ли hard-purge хотя бы на одном юзере

# --- Парсинг аргументов ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run | -n)
            DRY_RUN=true
            shift
            ;;
        --force | -f)
            FORCE=true
            shift
            ;;
        --keep-messages)
            KEEP_MESSAGES=true
            shift
            ;;
        --no-purge)
            PURGE=false
            shift
            ;;
        --data-path)
            MATRIX_DATA_PATH="$2"
            shift 2
            ;;
        -h | --help)
            echo "Использование: nuke-user.sh <username|mask> [ОПЦИИ]"
            echo ""
            echo "Полностью удаляет пользователя с сервера."
            echo ""
            echo "Аргументы:"
            echo "  username               Имя пользователя (legion или @legion:domain.com)"
            echo "  mask                   Маска с * и ? — удалить всех подходящих"
            echo "                         (обязательно в кавычках): nuke-user.sh '@whatsapp*'"
            echo ""
            echo "Опции:"
            echo "  --dry-run, -n          Показать план без выполнения"
            echo "  --force, -f            Без подтверждения"
            echo "  --keep-messages        Не редактить сообщения (purge тогда тоже не трогает их)"
            echo "  --no-purge             Не делать hard-purge БД (только deactivate/erase + MAS)"
            echo "  --data-path PATH       Путь к данным Matrix (по умолчанию /matrix)"
            echo "  -h, --help             Справка"
            echo ""
            echo "Что удаляется:"
            echo "  1. Все сообщения пользователя (redact) во всех комнатах"
            echo "  2. Все медиафайлы пользователя"
            echo "  3. Кик из всех комнат"
            echo "  4. Аккаунт в Synapse (deactivate + erase)"
            echo "  5. Аккаунт в MAS (если включён)"
            echo "  6. Hard-purge: строка в users + все события юзера в Synapse БД"
            echo ""
            echo "Чего нельзя удалить:"
            echo "  - Копии сообщений на чужих федеративных серверах"
            echo "  - Кешированные медиа на чужих серверах"
            exit 0
            ;;
        -*)
            err "Неизвестный параметр: $1"
            exit 1
            ;;
        *)
            if [[ -z "$USERNAME" ]]; then
                USERNAME="$1"
            else
                err "Лишний аргумент: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$USERNAME" ]]; then
    err "Укажи имя пользователя: nuke-user.sh <username>"
    exit 1
fi

# =============================================================================
# Подготовка
# =============================================================================

check_deps() {
    local missing=()
    for cmd in curl jq docker; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if ((${#missing[@]} > 0)); then
        err "Не найдены зависимости: ${missing[*]}"
        exit 1
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Скрипт должен запускаться от root"
        exit 1
    fi
}

get_server_name() {
    # Получаем server_name из конфига Synapse
    local config="${MATRIX_DATA_PATH}/synapse/config/homeserver.yaml"
    if [[ ! -f "$config" ]]; then
        err "Не найден конфиг Synapse: $config"
        exit 1
    fi
    grep '^server_name:' "$config" | awk '{print $2}' | tr -d "\"'"
}

get_admin_token() {
    # Получаем access_token существующего admin напрямую из базы данных
    # Это самый надёжный способ — работает и с MAS, и без

    info "Получение admin-токена из базы данных..."

    # Находим admin-пользователя и его токен
    ADMIN_TOKEN=$(docker exec --env-file="${MATRIX_DATA_PATH}/postgres/env-postgres-psql" \
        matrix-postgres \
        psql -h matrix-postgres synapse -t -A \
        -c "SELECT t.token FROM access_tokens t
            JOIN users u ON t.user_id = u.name
            WHERE u.admin = 1
            ORDER BY t.id DESC LIMIT 1;" 2>/dev/null) || true

    # Убираем пробелы
    ADMIN_TOKEN=$(echo "$ADMIN_TOKEN" | tr -d '[:space:]')

    if [[ -z "$ADMIN_TOKEN" ]]; then
        info "Нет активных admin-токенов в Synapse — попробуем выдать через MAS"
        return 1
    fi

    ADMIN_USER=$(docker exec --env-file="${MATRIX_DATA_PATH}/postgres/env-postgres-psql" \
        matrix-postgres \
        psql -h matrix-postgres synapse -t -A \
        -c "SELECT t.user_id FROM access_tokens t
            JOIN users u ON t.user_id = u.name
            WHERE u.admin = 1
            ORDER BY t.id DESC LIMIT 1;" 2>/dev/null | tr -d '[:space:]') || true

    info "Используем admin: ${ADMIN_USER}"
}

cleanup_admin() {
    # Ничего не нужно — мы используем существующий токен, не создаём временного пользователя
    :
}

# --- Токен через MAS (fallback, если в Synapse нет активных admin-сессий) ---
get_mas_admin_token() {
    local mas_cli="${MATRIX_DATA_PATH}/matrix-authentication-service/bin/mas-cli"
    if [[ ! -x "$mas_cli" ]]; then
        info "mas-cli не найден (${mas_cli})"
        return 1
    fi

    info "Нет активных admin-сессий в Synabase — выдаю compat-токен через mas-cli..."

    # Админов берём из Synapse БД (там источник правды по ур. правам)
    MASK_ADMIN_USER=$(docker exec --env-file="${MATRIX_DATA_PATH}/postgres/env-postgres-psql" \
        matrix-postgres \
        psql -h matrix-postgres synapse -t -A \
        -c "SELECT name FROM users WHERE admin = 1 AND name LIKE '@%' LIMIT 1;" 2>/dev/null) || true
    MASK_ADMIN_USER=$(echo "$MASK_ADMIN_USER" | tr -d '[:space:]')

    local localpart="${MASK_ADMIN_USER#@}"
    localpart="${localpart%%:*}"
    if [[ -z "$localpart" ]]; then
        info "Не найден ни один admin в Synapse БД"
        return 1
    fi

    local out
    if ! out=$("$mas_cli" manage issue-compatibility-token "$localpart" \
        --yes-i-want-to-grant-synapse-admin-privileges </dev/null 2>&1); then
        info "mas-cli выдача токена не удалась:"
        info "  $out"
        return 1
    fi

    ADMIN_TOKEN=$(echo "$out" | grep -oE 'mct_[A-Za-z0-9_-]+' | head -1)
    if [[ -z "$ADMIN_TOKEN" ]]; then
        info "Токен не распознан в ответе mas-cli:"
        info "  $out"
        return 1
    fi

    # UUID сессии — для точного отзыва токена после
    local uuid
    uuid=$(docker exec matrix-postgres psql -U matrix -d matrix_authentication_service -t -A \
        -c "SELECT compat_session_id FROM compat_access_tokens WHERE access_token = '${ADMIN_TOKEN}';" 2>/dev/null) || true
    UUID=$(echo "$uuid" | tail -1)

    MASK_TOKEN_REVOKED=true
    info "Выдан compat-токен admin (пользователь: ${localpart})"
    return 0
}

revoke_mask_token() {
    [[ "$MASK_TOKEN_REVOKED" == true && -n "${UUID:-}" ]] || return 0
    if docker exec matrix-postgres psql -U matrix -d matrix_authentication_service \
        -c "DELETE FROM compat_refresh_tokens WHERE compat_session_id = '${UUID}';" \
        -c "DELETE FROM compat_access_tokens WHERE compat_session_id = '${UUID}';" \
        -c "DELETE FROM compat_sessions WHERE compat_session_id = '${UUID}';" >/dev/null 2>&1; then
        info "Compat-токен масочной сессии отозван"
    else
        warn "Не отозван токен масочной сессии (uuid: ${UUID}) — убери вручную: DELETE FROM compat_sessions WHERE compat_session_id='${UUID}';"
    fi
}

# Synapse Admin API helper
SYNAPSE_BASE=""

synapse_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local url="${SYNAPSE_BASE}${endpoint}"

    if [[ "$method" == "GET" ]]; then
        curl -sf "$url" \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" \
            -H "Content-Type: application/json" 2>/dev/null
    elif [[ "$method" == "POST" ]]; then
        curl -sf "$url" \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$data" 2>/dev/null
    elif [[ "$method" == "PUT" ]]; then
        curl -sf "$url" \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$data" 2>/dev/null
    elif [[ "$method" == "DELETE" ]]; then
        curl -sf "$url" \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" \
            -H "Content-Type: application/json" 2>/dev/null
    fi
}

# =============================================================================
# Действия
# =============================================================================

resolve_user_id() {
    # Принимает username или @username:domain — возвращает полный MXID
    if [[ "$USERNAME" == @* ]]; then
        USER_ID="$USERNAME"
    else
        USER_ID="@${USERNAME}:${SERVER_NAME}"
    fi

    # Проверяем что пользователь существует
    local user_info
    user_info=$(synapse_api GET "/_synapse/admin/v2/users/${USER_ID}" 2>/dev/null) || true

    if [[ -z "$user_info" ]] || echo "$user_info" | jq -e '.errcode' >/dev/null 2>&1; then
        err "Пользователь ${USER_ID} не найден"
        exit 1
    fi

    USER_DISPLAYNAME=$(echo "$user_info" | jq -r '.displayname // "—"')
    USER_DEACTIVATED=$(echo "$user_info" | jq -r '.deactivated // false')
    USER_ADMIN=$(echo "$user_info" | jq -r '.admin // false')
    USER_CREATION_TS=$(echo "$user_info" | jq -r '.creation_ts // 0')

    if [[ "$USER_DEACTIVATED" == "true" ]]; then
        warn "Пользователь уже деактивирован"
    fi
}

get_user_rooms() {
    # Получаем список комнат пользователя
    local result
    result=$(synapse_api GET "/_synapse/admin/v1/users/${USER_ID}/joined_rooms" 2>/dev/null) || true

    if [[ -n "$result" ]]; then
        USER_ROOMS=$(echo "$result" | jq -r '.joined_rooms[]' 2>/dev/null) || USER_ROOMS=""
        USER_ROOM_COUNT=$(echo "$result" | jq -r '.total // 0')
    else
        USER_ROOMS=""
        USER_ROOM_COUNT=0
    fi
}

get_user_media() {
    # Получаем количество медиафайлов
    local result
    result=$(synapse_api GET "/_synapse/admin/v1/users/${USER_ID}/media" 2>/dev/null) || true

    if [[ -n "$result" ]]; then
        USER_MEDIA_COUNT=$(echo "$result" | jq -r '.total // 0')
    else
        USER_MEDIA_COUNT=0
    fi
}

get_user_devices() {
    local result
    result=$(synapse_api GET "/_synapse/admin/v2/users/${USER_ID}/devices" 2>/dev/null) || true

    if [[ -n "$result" ]]; then
        USER_DEVICE_COUNT=$(echo "$result" | jq -r '.total // 0')
    else
        USER_DEVICE_COUNT=0
    fi
}

redact_messages_in_room() {
    local room_id="$1"
    local room_name
    local redacted=0

    # Получаем имя комнаты
    local room_info
    room_info=$(synapse_api GET "/_synapse/admin/v1/rooms/${room_id}" 2>/dev/null) || true
    room_name=$(echo "$room_info" | jq -r '.name // "без имени"' 2>/dev/null)

    info "  Комната: ${room_name} (${room_id})"

    if [[ "$DRY_RUN" == true ]]; then
        log "  DRY-RUN: редактирование сообщений пропущено"
        return 0
    fi

    # Получаем события пользователя через messages API
    # Идём по страницам
    local from=""
    local batch=0

    while true; do
        local params="dir=b&limit=100&filter=%7B%22senders%22%3A%5B%22$(python3 -c "import urllib.parse; print(urllib.parse.quote('$USER_ID'))")%22%5D%2C%22types%22%3A%5B%22m.room.message%22%5D%7D"
        if [[ -n "$from" ]]; then
            params="${params}&from=${from}"
        fi

        local messages
        messages=$(synapse_api GET "/_matrix/client/v3/rooms/${room_id}/messages?${params}" 2>/dev/null) || break

        local events
        events=$(echo "$messages" | jq -r '.chunk[]?.event_id // empty' 2>/dev/null)

        if [[ -z "$events" ]]; then
            break
        fi

        while IFS= read -r event_id; do
            [[ -z "$event_id" ]] && continue

            # Admin redact — не требует быть в комнате
            synapse_api POST "/_synapse/admin/v1/rooms/${room_id}/redact/${event_id}" \
                '{"reason": "User account purged"}' >/dev/null 2>&1 || true

            ((redacted++)) || true

            # Прогресс каждые 50 сообщений
            if ((redacted % 50 == 0)); then
                echo -ne "\r    ${DIM}Удалено сообщений: ${redacted}...${NC}"
            fi
        done <<<"$events"

        # Следующая страница
        from=$(echo "$messages" | jq -r '.end // empty' 2>/dev/null)
        if [[ -z "$from" ]]; then
            break
        fi

        ((batch++))
        # Защита от бесконечного цикла
        if ((batch > 1000)); then
            warn "  Слишком много страниц, остановка"
            break
        fi
    done

    if ((redacted > 0)); then
        echo -ne "\r"
        log "  Удалено сообщений: ${redacted}"
    fi
}

redact_all_messages() {
    step "Удаление сообщений"

    if [[ "$KEEP_MESSAGES" == true ]]; then
        warn "Пропуск удаления сообщений (--keep-messages)"
        return 0
    fi

    if [[ -z "$USER_ROOMS" ]]; then
        info "Пользователь не состоит ни в одной комнате"
        return 0
    fi

    local room_num=0
    while IFS= read -r room_id; do
        [[ -z "$room_id" ]] && continue
        ((room_num++))
        info "[${room_num}/${USER_ROOM_COUNT}]"
        redact_messages_in_room "$room_id"
    done <<<"$USER_ROOMS"
}

delete_media() {
    step "Удаление медиафайлов"

    if ((USER_MEDIA_COUNT == 0)); then
        info "Медиафайлов нет"
        return 0
    fi

    info "Медиафайлов: ${USER_MEDIA_COUNT}"

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN: удаление медиа пропущено"
        return 0
    fi

    # Удаляем все медиа пользователя
    local result
    result=$(synapse_api DELETE "/_synapse/admin/v1/users/${USER_ID}/media" 2>/dev/null) || true

    local deleted
    deleted=$(echo "$result" | jq -r '.total // 0' 2>/dev/null)
    log "Удалено медиафайлов: ${deleted}"
}

kick_from_rooms() {
    step "Кик из комнат"

    if [[ -z "$USER_ROOMS" ]]; then
        info "Пользователь не состоит ни в одной комнате"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN: кик из ${USER_ROOM_COUNT} комнат пропущен"
        return 0
    fi

    local kicked=0
    while IFS= read -r room_id; do
        [[ -z "$room_id" ]] && continue

        # Используем admin API для удаления из комнаты
        synapse_api POST "/_synapse/admin/v1/rooms/${room_id}/kick" \
            "{\"user_id\": \"${USER_ID}\", \"reason\": \"Account purged\"}" >/dev/null 2>&1 || {
            # Fallback: через room membership API
            synapse_api POST "/_matrix/client/v3/rooms/${room_id}/kick" \
                "{\"user_id\": \"${USER_ID}\", \"reason\": \"Account purged\"}" >/dev/null 2>&1 || true
        }

        ((kicked++)) || true
    done <<<"$USER_ROOMS"

    log "Кикнут из ${kicked} комнат"
}

deactivate_account() {
    step "Деактивация аккаунта"

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN: деактивация пропущена"
        return 0
    fi

    info "Деактивация с erase=true (удаляет displayname, avatar, 3pid)..."

    local result
    result=$(synapse_api POST "/_synapse/admin/v1/deactivate/${USER_ID}" \
        '{"erase": true}' 2>/dev/null) || true

    if echo "$result" | jq -e '.id_server_unbind_result' >/dev/null 2>&1; then
        log "Аккаунт деактивирован и стёрт"
    else
        warn "Результат деактивации: ${result}"
    fi
}

remove_from_mas() {
    step "Удаление из MAS"

    # Проверяем есть ли MAS
    if ! docker ps --format '{{.Names}}' | grep -q '^matrix-authentication-service$'; then
        info "MAS не запущен — пропуск"
        return 0
    fi

    local localpart="${USER_ID#@}"
    localpart="${localpart%%:*}"

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN: удаление из MAS пропущено (localpart: ${localpart})"
        return 0
    fi

    info "Блокировка и удаление сессий ${localpart} в MAS..."

    local mas_cli="${MATRIX_DATA_PATH}/matrix-authentication-service/bin/mas-cli"

    if [[ -x "$mas_cli" ]]; then
        # Убиваем все сессии
        "$mas_cli" manage kill-sessions "${localpart}" 2>/dev/null &&
            log "Сессии MAS удалены" ||
            warn "Не удалось удалить сессии MAS"

        # Блокируем и деактивируем пользователя
        "$mas_cli" manage lock-user "${localpart}" --deactivate 2>/dev/null &&
            log "Пользователь заблокирован и деактивирован в MAS" ||
            warn "Не удалось заблокировать в MAS"
    else
        warn "mas-cli не найден: $mas_cli"
        info "Заблокируйте вручную:"
        echo "    mas-cli manage kill-sessions ${localpart}"
        echo "    mas-cli manage lock-user ${localpart}"
    fi
}

# =============================================================================
# Маска: glob -> список MXID
# =============================================================================

expand_user_mask() {
    # USERNAME содержит * или ? -> расширяем через LIKE в таблице users.
    # Запрос идёт через stdin (heredoc) — кавыки полностью под контролем bash,
    # без магии psql -v (её интерполяция в разных версиях нестабильная).
    local pat="$USERNAME"
    # Экранируем литеральные LIKE-специали. standard_conforming_strings=on
    # (дефолт PG 9.1+), поэтому '\' сам по себе не экранируется — достаточно
    # экранировать %, _ и одинарную кавычку в SQL-литерале.
    pat="${pat//\%/\\%}"
    pat="${pat//_/\\_}"
    pat="${pat//\'/\'\'}"
    # glob -> LIKE-паттерн
    pat="${pat//\*/%}"
    pat="${pat//\?/_}"

    NUKE_USERS=()
    while IFS= read -r mxid; do
        [[ -n "$mxid" ]] && NUKE_USERS+=("$mxid") || true
    done < <(
        docker exec -i --env-file="${MATRIX_DATA_PATH}/postgres/env-postgres-psql" \
            matrix-postgres \
            psql -h matrix-postgres synapse -t -A <<SQL
SELECT name FROM users WHERE name LIKE '${pat}' ORDER BY name;
SQL
    ) || true
}

# =============================================================================
# Hard-purge: вырезает строку пользователя и все его события из Synapse БД.
# Деактивации/erase по API оставляют строку в users (deactivated) и историю
# событий — именно это Кетеса/админ-панели потом показывают. Здесь — всё чисто.
#
# Делается в одной транзакции с ON_ERROR_STOP: если что-то пошло не так,
# ничего не удалится. Имена таблиц — под Synapse 1.15x+ (обернуто в проверки).
# =============================================================================

purge_user_full() {
    # $1 — полный MXID. Возвращает 0 при успехе, 1 при провале.
    local user_id="$1"

    if [[ "$PURGE" != true ]]; then
        info "Hard-purge отключён (--no-purge)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN: hard-purge ${user_id} пропущен"
        return 0
    fi

    info "Hard-purge БД: ${user_id} (users + events + связки)..."

    # Экранируем одинарные кавычки для SQL-литерала
    local esc="${user_id//\'/\'\'}"

    # Весь блок — одна транзакция (BEGIN/COMMIT + ON_ERROR_STOP): любая
    # ошибка откатит всё. docker exec -i пробрасывает heredoc в psql.
    echo "--- sql: BEGIN ---" >&2
    if ! docker exec -i --env-file="${MATRIX_DATA_PATH}/postgres/env-postgres-psql" \
        matrix-postgres \
        psql -h matrix-postgres synapse -v ON_ERROR_STOP=1 --no-psqlrc -X -q -t -A <<SQL; then
BEGIN;

-- 1) Собираем события юзера
CREATE TEMP TABLE _purge_ev AS
SELECT event_id, stream_ordering
FROM events
WHERE sender = '${esc}';

-- 2) Дочки без каскада
DELETE FROM event_edges e         USING _purge_ev g WHERE e.event_id = g.event_id OR e.prev_event_id = g.event_id;
DELETE FROM event_forward_extremities f USING _purge_ev g WHERE f.event_id = g.event_id;
DELETE FROM partial_state_events p       USING _purge_ev g WHERE p.event_id = g.event_id;
DELETE FROM partial_state_rooms p        USING _purge_ev g WHERE p.join_event_id = g.event_id;
DELETE FROM un_partial_stated_event_stream u USING _purge_ev g WHERE u.event_id = g.event_id;
DELETE FROM current_state_events c       USING _purge_ev g WHERE c.event_id = g.event_id;
DELETE FROM event_txn_id_device_id t     USING _purge_ev g WHERE t.event_id = g.event_id;
DELETE FROM sliding_sync_joined_rooms s  USING _purge_ev g WHERE s.event_stream_ordering = g.stream_ordering;
DELETE FROM sliding_sync_membership_snapshots s USING _purge_ev g
    WHERE s.event_stream_ordering = g.stream_ordering OR s.membership_event_id = g.event_id;
DELETE FROM thread_subscriptions t
    USING _purge_ev g
    WHERE t.event_id = g.event_id;
DELETE FROM msc4242_state_dag_forward_extremities m USING _purge_ev g WHERE m.event_id = g.event_id;
DELETE FROM msc4242_state_dag_edges m
    USING _purge_ev g
    WHERE m.event_id = g.event_id OR m.prev_state_event_id = g.event_id;
DELETE FROM local_current_membership l   USING _purge_ev g WHERE l.event_stream_ordering = g.stream_ordering;
DELETE FROM room_memberships r           USING _purge_ev g WHERE r.event_stream_ordering = g.stream_ordering;

-- 3) Сами события и их JSON
DELETE FROM event_json x
    WHERE x.event_id IN (SELECT event_id FROM _purge_ev);
DELETE FROM events e
    WHERE e.event_id IN (SELECT event_id FROM _purge_ev);

-- 4) Юзер-таблицы (FK из users здесь — точечные таблицы)
DELETE FROM users_to_send_full_presence_to WHERE user_id = '${esc}';
DELETE FROM per_user_experimental_features WHERE user_id = '${esc}';
DELETE FROM thread_subscriptions WHERE user_id = '${esc}';

-- 5) Аккаунт
DELETE FROM users WHERE name = '${esc}';

COMMIT;
SQL
        err "Hard-purge ${user_id} сломался (всё в транзакции — откачено)"
        return 1
    fi

    log "Hard-purge ${user_id} завершён"
    DID_PURGE=true
    return 0
}

# Перезапуск Synapse если был хоть один hard-purge — иначе API-кеши
# (list/detail) продолжают отдавать вырезанных юзеров/события.
restart_synapse_if_needed() {
    if [[ "$PURGE" != true || "$DRY_RUN" == true || "$DID_PURGE" != true ]]; then
        return 0
    fi
    if ! docker ps --format '{{.Names}}' | grep -q '^matrix-synapse$'; then
        warn "Контейнер matrix-synapse не найден — перезапусти вручную (иначе кеши)."
        return 0
    fi
    info "Перезапуск matrix-synapse (сброс API-кешей после hard-purge)..."
    if docker restart matrix-synapse >/dev/null 2>&1; then
        log "matrix-synapse перезапущен"
    else
        warn "Не удалось перезапустить matrix-synapse — сделай вручную!"
    fi
}

# =============================================================================
# Пайплайн удаления ОДНОГО пользователя
# =============================================================================

nuke_single() {
    # $1 — полный MXID. Возвращает 0 при успехе, 1 при провале.
    local user_id="$1"
    USER_ID="$user_id"

    # Проверяем что пользователь существует
    local user_info
    user_info=$(synapse_api GET "/_synapse/admin/v2/users/${USER_ID}" 2>/dev/null) || true

    if [[ -z "$user_info" ]] || echo "$user_info" | jq -e '.errcode' >/dev/null 2>&1; then
        warn "Пользователь ${USER_ID} не найден (пропущен)"
        return 1
    fi

    USER_DISPLAYNAME=$(echo "$user_info" | jq -r '.displayname // "—"')
    USER_DEACTIVATED=$(echo "$user_info" | jq -r '.deactivated // false')
    USER_ADMIN=$(echo "$user_info" | jq -r '.admin // false')

    if [[ "$USER_DEACTIVATED" == "true" ]]; then
        warn "Пользователь уже деактивирован"
    fi

    get_user_rooms
    get_user_media
    get_user_devices

    info "Target: ${USER_ID} (displayname: ${USER_DISPLAYNAME}, rooms: ${USER_ROOM_COUNT})"

    redact_all_messages
    delete_media
    kick_from_rooms
    deactivate_account
    remove_from_mas
    purge_user_full "$USER_ID"
}

# =============================================================================
# Главная логика
# =============================================================================

main() {
    echo ""
    echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Matrix Server — ПОЛНОЕ УДАЛЕНИЕ ПОЛЬЗОВАТЕЛЯ${NC}"
    echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        warn "Режим DRY-RUN: ничего не будет выполнено"
        echo ""
    fi

    # --- Проверки ---
    check_root
    check_deps

    # Определяем режим: одиночный MXID или маска
    if [[ "$USERNAME" == *\** || "$USERNAME" == *\?* ]]; then
        IS_MASK=true
    fi

    # Определяем base URL для API
    # Пробуем через docker exec напрямую
    if docker exec matrix-synapse curl -sf http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; then
        SYNAPSE_BASE="http://localhost:8008"
        # Все API вызовы пойдут через docker exec? Нет, через docker exec неудобно.
        # Пробуем через 127.0.0.1:81 (Traefik)
        :
    fi

    SERVER_NAME=$(get_server_name)
    info "Server name: ${SERVER_NAME}"

    SYNAPSE_BASE="http://127.0.0.1:81"

    # Переопределяем synapse_api для добавления Host header
    synapse_api() {
        local method="$1"
        local endpoint="$2"
        local data="${3:-}"
        local url="http://127.0.0.1:81${endpoint}"

        local args=(-sf "$url"
            -H "Authorization: Bearer ${ADMIN_TOKEN}"
            -H "Content-Type: application/json"
            -H "Host: matrix.${SERVER_NAME}")

        case "$method" in
            GET) curl "${args[@]}" 2>/dev/null ;;
            POST) curl "${args[@]}" -d "$data" 2>/dev/null ;;
            PUT) curl "${args[@]}" -X PUT -d "$data" 2>/dev/null ;;
            DELETE) curl "${args[@]}" -X DELETE 2>/dev/null ;;
        esac
    }

    # Получаем admin-токен: сначала из живых сессий Synapse, при их
    # отсутствии — выдаём compat-токен через mas-cli (отзываем в конце)
    if ! get_admin_token; then
        if ! get_mas_admin_token; then
            err "Не найден admin access_token в базе данных"
            err "Убедитесь что есть хотя бы один admin и (при MAS) запущен контейнер matrix-authentication-service"
            exit 1
        fi
    fi
    trap 'cleanup_admin; revoke_mask_token' EXIT

    # --- Режим маски ---
    if [[ "$IS_MASK" == true ]]; then
        step "Развёртка маски: ${USERNAME}"
        expand_user_mask

        if ((${#NUKE_USERS[@]} == 0)); then
            info "Маске никто не соответствует (и активные, и деактивные проверены)"
            exit 0
        fi

        info "Найдено пользователей: ${#NUKE_USERS[@]}"
        for u in "${NUKE_USERS[@]}"; do
            echo -e "    ${DIM}${u}${NC}"
        done
        if ((${#NUKE_USERS[@]} > 30)); then
            echo -e "    ${DIM}… (список усечён, всего ${#NUKE_USERS[@]})${NC}"
        fi
        echo ""
        echo -e "  ${BOLD}${RED}Будет выполнено для каждого:${NC}"
        if [[ "$KEEP_MESSAGES" != true ]]; then
            echo -e "    ${RED}✗${NC} Redact всех сообщений"
        fi
        echo -e "    ${RED}✗${NC} Удаление медиафайлов"
        echo -e "    ${RED}✗${NC} Кик из комнат"
        echo -e "    ${RED}✗${NC} Деактивация аккаунта (erase: true)"
        echo -e "    ${RED}✗${NC} Удаление из MAS"
        if [[ "$PURGE" == true ]]; then
            echo -e "    ${RED}✗${NC} Hard-purge БД (users + events) + рестарт Synapse"
        else
            echo -e "    ${DIM}— Hard-purge отключён (--no-purge)${NC}"
        fi
        echo ""

        if [[ "$DRY_RUN" != true && "$FORCE" != true ]]; then
            echo -e "  ${BOLD}${RED}ЭТО ДЕЙСТВИЕ НЕОБРАТИМО (для всех ${#NUKE_USERS[@]})!${NC}"
            echo ""
            echo -en "  Удалить всех? Введи '${BOLD}DELETE${NC}' для подтверждения: "
            read -r answer
            if [[ "$answer" != "DELETE" ]]; then
                info "Отменено"
                exit 0
            fi
            echo ""
        fi

        local total=${#NUKE_USERS[@]}
        local i=0
        local ok_count=0
        local fail_count=0
        for u in "${NUKE_USERS[@]}"; do
            i=$((i + 1))
            echo ""
            step "[${i}/${total}] ${u}"
            if nuke_single "$u"; then
                ok_count=$((ok_count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
        done

        restart_synapse_if_needed

        echo ""
        echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════${NC}"
        if [[ "$DRY_RUN" == true ]]; then
            echo -e "${BOLD}${YELLOW}  DRY-RUN завершён (ничего не выполнено)${NC}"
        else
            echo -e "${BOLD}${GREEN}  Обработано: ${total}, успешно: ${ok_count}, ошибок: ${fail_count}${NC}"
        fi
        echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════${NC}"
        exit 0
    fi

    # --- Одиночный режим (как раньше) ---
    # Определяем пользователя
    resolve_user_id

    # Собираем информацию
    get_user_rooms
    get_user_media
    get_user_devices

    # --- Показываем план ---
    step "Информация о пользователе"

    echo -e "  ${BOLD}User ID:${NC}      ${USER_ID}"
    echo -e "  ${BOLD}Имя:${NC}          ${USER_DISPLAYNAME}"
    echo -e "  ${BOLD}Admin:${NC}        ${USER_ADMIN}"
    echo -e "  ${BOLD}Деактивирован:${NC} ${USER_DEACTIVATED}"
    echo -e "  ${BOLD}Комнат:${NC}       ${USER_ROOM_COUNT}"
    echo -e "  ${BOLD}Медиафайлов:${NC}  ${USER_MEDIA_COUNT}"
    echo -e "  ${BOLD}Устройств:${NC}    ${USER_DEVICE_COUNT}"
    echo ""

    if [[ "$USER_ADMIN" == "true" ]]; then
        warn "ВНИМАНИЕ: это admin-пользователь!"
    fi

    echo -e "  ${BOLD}${RED}Будет выполнено:${NC}"
    if [[ "$KEEP_MESSAGES" != true ]]; then
        echo -e "    ${RED}✗${NC} Redact всех сообщений в ${USER_ROOM_COUNT} комнатах"
    else
        echo -e "    ${DIM}— Сообщения сохранены (--keep-messages)${NC}"
    fi
    echo -e "    ${RED}✗${NC} Удаление ${USER_MEDIA_COUNT} медиафайлов"
    echo -e "    ${RED}✗${NC} Кик из ${USER_ROOM_COUNT} комнат"
    echo -e "    ${RED}✗${NC} Деактивация аккаунта (erase: true)"
    echo -e "    ${RED}✗${NC} Удаление из MAS"
    if [[ "$PURGE" == true ]]; then
        echo -e "    ${RED}✗${NC} Hard-purge БД (users + events) + рестарт Synapse"
    else
        echo -e "    ${DIM}— Hard-purge отключён (--no-purge)${NC}"
    fi
    echo ""

    # --- Подтверждение ---
    if [[ "$DRY_RUN" != true && "$FORCE" != true ]]; then
        echo -e "  ${BOLD}${RED}ЭТО ДЕЙСТВИЕ НЕОБРАТИМО!${NC}"
        echo ""
        echo -en "  Удалить пользователя ${BOLD}${USER_ID}${NC}? Введи '${BOLD}DELETE${NC}' для подтверждения: "
        read -r answer
        if [[ "$answer" != "DELETE" ]]; then
            info "Отменено"
            exit 0
        fi
        echo ""
    fi

    # --- Выполнение ---
    redact_all_messages
    delete_media
    kick_from_rooms
    deactivate_account
    remove_from_mas
    purge_user_full "$USER_ID"
    restart_synapse_if_needed

    # --- Итог ---
    echo ""
    echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════${NC}"
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${BOLD}${YELLOW}  DRY-RUN завершён (ничего не выполнено)${NC}"
    else
        echo -e "${BOLD}${GREEN}  Пользователь ${USER_ID} полностью удалён${NC}"
    fi
    echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    if [[ "$DRY_RUN" != true ]]; then
        info "Напоминание:"
        echo "    - Копии сообщений на чужих серверах удалить невозможно"
        echo "    - Для полной очистки медиа-кеша: just run-tags purge-media-cache"
        echo ""
    fi
}

main "$@"
