#!/usr/bin/env bash
# =============================================================================
# Matrix Server — полное удаление пользователя
# =============================================================================
# Удаляет пользователя ПОЛНОСТЬЮ: сообщения, медиа, аккаунт, сессии.
#
# Запуск:
#   bash tools/nuke-user.sh username
#   bash tools/nuke-user.sh @username:domain.com
#   bash tools/nuke-user.sh username --dry-run
#   bash tools/nuke-user.sh username --force        # без подтверждения
#   bash tools/nuke-user.sh username --keep-messages # не редактить сообщения
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
log()     { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
err()     { echo -e "${RED}[x]${NC} $*" >&2; }
info()    { echo -e "${BLUE}[i]${NC} $*"; }
step()    { echo ""; echo -e "${BOLD}${CYAN}--- $* ---${NC}"; echo ""; }

# --- Параметры ---
DRY_RUN=false
FORCE=false
KEEP_MESSAGES=false
USERNAME=""
MATRIX_DATA_PATH="/matrix"

# --- Парсинг аргументов ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|-n)        DRY_RUN=true; shift ;;
        --force|-f)          FORCE=true; shift ;;
        --keep-messages)     KEEP_MESSAGES=true; shift ;;
        --data-path)         MATRIX_DATA_PATH="$2"; shift 2 ;;
        -h|--help)
            echo "Использование: nuke-user.sh <username> [ОПЦИИ]"
            echo ""
            echo "Полностью удаляет пользователя с сервера."
            echo ""
            echo "Аргументы:"
            echo "  username               Имя пользователя (legion или @legion:domain.com)"
            echo ""
            echo "Опции:"
            echo "  --dry-run, -n          Показать план без выполнения"
            echo "  --force, -f            Без подтверждения"
            echo "  --keep-messages        Не редактить сообщения (только удалить аккаунт)"
            echo "  --data-path PATH       Путь к данным Matrix (по умолчанию /matrix)"
            echo "  -h, --help             Справка"
            echo ""
            echo "Что удаляется:"
            echo "  1. Все сообщения пользователя (redact) во всех комнатах"
            echo "  2. Все медиафайлы пользователя"
            echo "  3. Кик из всех комнат"
            echo "  4. Аккаунт в Synapse (deactivate + erase)"
            echo "  5. Аккаунт в MAS (если включён)"
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
    if (( ${#missing[@]} > 0 )); then
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

detect_synapse_url() {
    # Получаем IP контейнера из Docker-сети — самый надёжный способ
    SYNAPSE_URL=""
    SYNAPSE_HOST=""

    local synapse_ip
    synapse_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
        matrix-synapse 2>/dev/null | awk '{print $1}')

    if [[ -n "$synapse_ip" ]] && curl -sf -o /dev/null -m 3 \
        "http://${synapse_ip}:8008/_matrix/client/versions" 2>/dev/null; then
        SYNAPSE_URL="http://${synapse_ip}:8008"
        info "Synapse: ${synapse_ip}:8008"
        return 0
    fi

    # Fallback: Traefik
    if curl -sf -o /dev/null -m 3 "http://127.0.0.1:81/_matrix/client/versions" \
        -H "Host: matrix.${SERVER_NAME}" 2>/dev/null; then
        SYNAPSE_URL="http://127.0.0.1:81"
        SYNAPSE_HOST="matrix.${SERVER_NAME}"
        info "Synapse: Traefik (127.0.0.1:81)"
        return 0
    fi

    err "Контейнер matrix-synapse не найден или не отвечает"
    err "Проверьте: docker ps | grep synapse"
    exit 1
}

get_admin_token() {
    # Стратегия 1: access_token из БД (быстро, если admin залогинен)
    info "Получение admin-токена из базы данных..."

    ADMIN_TOKEN=$(docker exec --env-file="${MATRIX_DATA_PATH}/postgres/env-postgres-psql" \
        matrix-postgres \
        psql -h matrix-postgres synapse -t -A \
        -c "SELECT t.token FROM access_tokens t
            JOIN users u ON t.user_id = u.name
            WHERE u.admin = 1
            ORDER BY t.id DESC LIMIT 1;" 2>/dev/null) || true

    ADMIN_TOKEN=$(echo "$ADMIN_TOKEN" | tr -d '[:space:]')

    if [[ -n "$ADMIN_TOKEN" ]]; then
        ADMIN_USER=$(docker exec --env-file="${MATRIX_DATA_PATH}/postgres/env-postgres-psql" \
            matrix-postgres \
            psql -h matrix-postgres synapse -t -A \
            -c "SELECT t.user_id FROM access_tokens t
                JOIN users u ON t.user_id = u.name
                WHERE u.admin = 1
                ORDER BY t.id DESC LIMIT 1;" 2>/dev/null | tr -d '[:space:]') || true
        info "Используем admin: ${ADMIN_USER}"
        TEMP_ADMIN=false
        return 0
    fi

    # Стратегия 2: MAS — issue-compatibility-token через mas-cli
    local mas_container
    mas_container=$(docker ps --format '{{.Names}}' | grep -m1 'authentication-service') || true

    if [[ -n "$mas_container" ]]; then
        warn "Токен не найден в БД — пробую через MAS..."

        # Находим admin в MAS (can_request_admin = true)
        local mas_admin
        mas_admin=$(docker exec --env-file="${MATRIX_DATA_PATH}/postgres/env-postgres-psql" \
            matrix-postgres \
            psql -h matrix-postgres matrix_authentication_service -t -A \
            -c "SELECT username FROM users WHERE can_request_admin = true LIMIT 1;" 2>/dev/null | tr -d '[:space:]') || true

        if [[ -n "$mas_admin" ]]; then
            info "MAS admin: ${mas_admin}"

            # issue-compatibility-token выводит токен в stderr (лог)
            local mas_output
            mas_output=$(docker exec "$mas_container" \
                mas-cli manage issue-compatibility-token \
                --yes-i-want-to-grant-synapse-admin-privileges \
                "$mas_admin" 2>&1) || true

            # Токен: mct_... в строке "token issued: mct_xxx"
            ADMIN_TOKEN=$(echo "$mas_output" | grep -oP 'mct_\S+' | head -1) || true

            if [[ -n "$ADMIN_TOKEN" ]]; then
                ADMIN_USER="@${mas_admin}:${SERVER_NAME}"
                TEMP_ADMIN=false
                log "Токен получен через MAS для ${ADMIN_USER}"
                return 0
            fi
            warn "mas-cli не дал токен: ${mas_output}"
        else
            warn "Нет admin-пользователей в MAS"
        fi
    fi

    # Стратегия 3: registration_shared_secret (без MAS)
    warn "Пробую registration_shared_secret..."

    local config="${MATRIX_DATA_PATH}/synapse/config/homeserver.yaml"
    local shared_secret
    shared_secret=$(grep '^registration_shared_secret:' "$config" 2>/dev/null \
        | head -1 | sed 's/^registration_shared_secret:[[:space:]]*//' | tr -d "\"'") || true

    if [[ -n "$shared_secret" ]]; then
        local tmp_user="_nuke_admin_${RANDOM}"
        local tmp_pass
        tmp_pass=$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p | head -c 32)

        local nonce_resp
        nonce_resp=$(curl -s -m 5 "${SYNAPSE_URL}/_synapse/admin/v1/register") || true
        local nonce
        nonce=$(echo "$nonce_resp" | jq -r '.nonce // empty' 2>/dev/null)

        if [[ -n "$nonce" ]]; then
            local mac
            mac=$(printf '%s\0%s\0%s\0%s' "$nonce" "$tmp_user" "$tmp_pass" "admin" \
                | openssl dgst -sha1 -hmac "$shared_secret" | awk '{print $NF}')

            local reg_result
            reg_result=$(curl -s -m 5 "${SYNAPSE_URL}/_synapse/admin/v1/register" \
                -H "Content-Type: application/json" \
                -d "{\"nonce\":\"${nonce}\",\"username\":\"${tmp_user}\",\"password\":\"${tmp_pass}\",\"mac\":\"${mac}\",\"admin\":true}") || true

            ADMIN_TOKEN=$(echo "$reg_result" | jq -r '.access_token // empty' 2>/dev/null)

            if [[ -n "$ADMIN_TOKEN" ]]; then
                ADMIN_USER="@${tmp_user}:${SERVER_NAME}"
                TEMP_ADMIN=true
                TEMP_ADMIN_USER="$ADMIN_USER"
                log "Создан временный admin: ${ADMIN_USER}"
                return 0
            fi
        fi
    fi

    # Все стратегии исчерпаны
    err "Не удалось получить admin-токен"
    err "Стратегия 1 (БД): нет токенов в access_tokens"
    [[ -n "$mas_container" ]] && err "Стратегия 2 (MAS): mas-cli issue-compatibility-token не дал результат"
    err "Стратегия 3 (register API): endpoint отключён или недоступен"
    err ""
    err "Решение: залогиньтесь в Element Web как admin, затем попробуйте снова"
    exit 1

    ADMIN_USER="@${tmp_user}:${SERVER_NAME}"
    TEMP_ADMIN=true
    TEMP_ADMIN_USER="$ADMIN_USER"
    log "Создан временный admin: ${ADMIN_USER}"
}

cleanup_admin() {
    if [[ "${TEMP_ADMIN:-false}" == true && -n "${TEMP_ADMIN_USER:-}" && -n "${ADMIN_TOKEN:-}" ]]; then
        info "Удаление временного admin ${TEMP_ADMIN_USER}..."
        synapse_api POST "/_synapse/admin/v1/deactivate/${TEMP_ADMIN_USER}" \
            '{"erase": true}' >/dev/null 2>&1 || true
        log "Временный admin удалён"
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
    # USER_CREATION_TS используется в расширенном выводе (при отладке)
    # shellcheck disable=SC2034
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
        local params
        params="dir=b&limit=100&filter=%7B%22senders%22%3A%5B%22$(python3 -c "import urllib.parse; print(urllib.parse.quote('$USER_ID'))")%22%5D%2C%22types%22%3A%5B%22m.room.message%22%5D%7D"
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
            if (( redacted % 50 == 0 )); then
                echo -ne "\r    ${DIM}Удалено сообщений: ${redacted}...${NC}"
            fi
        done <<< "$events"

        # Следующая страница
        from=$(echo "$messages" | jq -r '.end // empty' 2>/dev/null)
        if [[ -z "$from" ]]; then
            break
        fi

        ((batch++))
        # Защита от бесконечного цикла
        if (( batch > 1000 )); then
            warn "  Слишком много страниц, остановка"
            break
        fi
    done

    if (( redacted > 0 )); then
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
    done <<< "$USER_ROOMS"
}

delete_media() {
    step "Удаление медиафайлов"

    if (( USER_MEDIA_COUNT == 0 )); then
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
    done <<< "$USER_ROOMS"

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
        "$mas_cli" manage kill-sessions "${localpart}" 2>/dev/null && \
            log "Сессии MAS удалены" || \
            warn "Не удалось удалить сессии MAS"

        "$mas_cli" manage lock-user "${localpart}" --deactivate 2>/dev/null && \
            log "Пользователь заблокирован и деактивирован в MAS" || \
            warn "Не удалось заблокировать в MAS"
    else
        warn "mas-cli не найден: $mas_cli"
        info "Заблокируйте вручную:"
        echo "    mas-cli manage kill-sessions ${localpart}"
        echo "    mas-cli manage lock-user ${localpart}"
    fi
}

purge_from_db() {
    step "Удаление из баз данных"

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN: purge пропущен"
        return 0
    fi

    local pg_env="--env-file=${MATRIX_DATA_PATH}/postgres/env-postgres-psql"
    local pg_cmd="docker exec ${pg_env} matrix-postgres psql -h matrix-postgres"

    # --- MAS ---
    if docker ps --format '{{.Names}}' | grep -q 'authentication-service'; then
        local mas_uid
        local localpart="${USER_ID#@}"
        localpart="${localpart%%:*}"
        mas_uid=$($pg_cmd matrix_authentication_service -t -A \
            -c "SELECT user_id FROM users WHERE username = '${localpart}';" 2>/dev/null | tr -d '[:space:]') || true

        if [[ -n "$mas_uid" ]]; then
            info "Purge MAS: ${localpart} (${mas_uid})"

            # Удаляем снизу вверх по FK-зависимостям:
            # oauth2_access_tokens → oauth2_sessions → user_sessions → users
            $pg_cmd matrix_authentication_service -q -c "
                -- Уровень 3: листья oauth2
                DELETE FROM oauth2_access_tokens WHERE oauth2_session_id IN (
                    SELECT oauth2_session_id FROM oauth2_sessions WHERE user_session_id IN (
                        SELECT user_session_id FROM user_sessions WHERE user_id = '${mas_uid}'));
                DELETE FROM oauth2_refresh_tokens WHERE oauth2_session_id IN (
                    SELECT oauth2_session_id FROM oauth2_sessions WHERE user_session_id IN (
                        SELECT user_session_id FROM user_sessions WHERE user_id = '${mas_uid}'));
                DELETE FROM oauth2_authorization_grants WHERE oauth2_session_id IN (
                    SELECT oauth2_session_id FROM oauth2_sessions WHERE user_session_id IN (
                        SELECT user_session_id FROM user_sessions WHERE user_id = '${mas_uid}'));
                -- Уровень 2: сессии
                DELETE FROM oauth2_sessions WHERE user_session_id IN (
                    SELECT user_session_id FROM user_sessions WHERE user_id = '${mas_uid}');
                DELETE FROM compat_sessions WHERE user_session_id IN (
                    SELECT user_session_id FROM user_sessions WHERE user_id = '${mas_uid}');
                DELETE FROM user_session_authentications WHERE user_session_id IN (
                    SELECT user_session_id FROM user_sessions WHERE user_id = '${mas_uid}');
                -- Уровень 1: прямые зависимости users
                DELETE FROM user_sessions WHERE user_id = '${mas_uid}';
                DELETE FROM user_passwords WHERE user_id = '${mas_uid}';
                DELETE FROM upstream_oauth_links WHERE user_id = '${mas_uid}';
                DELETE FROM personal_sessions WHERE owner_user_id = '${mas_uid}' OR actor_user_id = '${mas_uid}';
                DELETE FROM compat_sessions WHERE user_id = '${mas_uid}';
                -- Пользователь (CASCADE: user_emails, user_terms, user_unsupported_third_party_ids)
                DELETE FROM users WHERE user_id = '${mas_uid}';
            " 2>/dev/null && \
                log "MAS: запись удалена" || \
                warn "MAS: не удалось удалить (возможно уже удалена)"
        else
            info "MAS: пользователь не найден в БД"
        fi
    fi

    # --- Synapse ---
    local syn_localpart="${USER_ID#@}"
    syn_localpart="${syn_localpart%%:*}"
    info "Purge Synapse: ${USER_ID} (localpart: ${syn_localpart})"

    # Некоторые таблицы хранят MXID, некоторые — localpart
    $pg_cmd synapse -q -c "
        DELETE FROM erased_users WHERE user_id = '${USER_ID}';
        DELETE FROM devices WHERE user_id = '${USER_ID}';
        DELETE FROM device_lists_stream WHERE user_id = '${USER_ID}';
        DELETE FROM device_lists_changes_in_room WHERE user_id = '${USER_ID}';
        DELETE FROM e2e_cross_signing_keys WHERE user_id = '${USER_ID}';
        DELETE FROM open_id_tokens WHERE user_id = '${USER_ID}';
        DELETE FROM user_directory WHERE user_id = '${USER_ID}';
        DELETE FROM user_directory_search WHERE user_id = '${USER_ID}';
        DELETE FROM user_ips WHERE user_id = '${USER_ID}';
        DELETE FROM user_daily_visits WHERE user_id = '${USER_ID}';
        DELETE FROM user_stats_current WHERE user_id = '${USER_ID}';
        DELETE FROM presence_stream WHERE user_id = '${USER_ID}';
        DELETE FROM current_state_delta_stream WHERE state_key = '${USER_ID}';
        DELETE FROM per_user_experimental_features WHERE user_id = '${USER_ID}';
        DELETE FROM thread_subscriptions WHERE user_id = '${USER_ID}';
        DELETE FROM users_to_send_full_presence_to WHERE user_id = '${USER_ID}';
        DELETE FROM user_signature_stream WHERE from_user_id = '${USER_ID}';
        DELETE FROM access_tokens WHERE user_id = '${USER_ID}';
        -- Таблицы с localpart вместо MXID
        DELETE FROM profiles WHERE user_id = '${syn_localpart}';
        DELETE FROM user_filters WHERE user_id = '${syn_localpart}';
        -- Запись пользователя
        DELETE FROM users WHERE name = '${USER_ID}';
    " 2>/dev/null && \
        log "Synapse: запись удалена" || \
        warn "Synapse: не удалось удалить (возможно уже удалена)"
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

    SERVER_NAME=$(get_server_name)
    info "Server name: ${SERVER_NAME}"

    # Автоопределение URL Synapse API
    detect_synapse_url

    # Переопределяем synapse_api с найденным URL
    synapse_api() {
        local method="$1"
        local endpoint="$2"
        local data="${3:-}"
        local url="${SYNAPSE_URL}${endpoint}"

        local args=(-sf "$url"
            -H "Authorization: Bearer ${ADMIN_TOKEN}"
            -H "Content-Type: application/json")

        # Host header нужен только при работе через Traefik
        [[ -n "${SYNAPSE_HOST}" ]] && args+=(-H "Host: ${SYNAPSE_HOST}")

        case "$method" in
            GET)    curl "${args[@]}" 2>/dev/null ;;
            POST)   curl "${args[@]}" -d "$data" 2>/dev/null ;;
            PUT)    curl "${args[@]}" -X PUT -d "$data" 2>/dev/null ;;
            DELETE) curl "${args[@]}" -X DELETE 2>/dev/null ;;
        esac
    }

    # Получаем admin-токен
    get_admin_token
    trap cleanup_admin EXIT

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
    echo -e "    ${RED}✗${NC} Purge из баз данных (MAS + Synapse)"
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
    purge_from_db

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
