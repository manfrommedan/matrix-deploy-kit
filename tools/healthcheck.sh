#!/usr/bin/env bash
# =============================================================================
# Matrix-deploy-kit - healthcheck
# =============================================================================
# Проверяет состояние запущенного Matrix-сервера одной командой.
#
# Проверки:
#   1. Docker и compose-стек (matrix-postgres, matrix-synapse, ...)
#   2. Homeserver: /_matrix/federation/v1/version и /_matrix/client/versions
#   3. PostgreSQL - контейнер жив и принимает соединения
#   4. Reverse proxy (nginx или Traefik) - порт 443 и ACME
#   5. Свежесть последнего бэкапа (если есть)
#   6. Место на диске
#
# Использование:
#   bash tools/healthcheck.sh                # все проверки
#   bash tools/healthcheck.sh --no-backup    # пропустить проверку бэкапа
#   bash tools/healthcheck.sh --domain X     # ожидаемый домен
#   bash tools/healthcheck.sh --json         # вывод в JSON для мониторинга
#
# Коды возврата:
#   0  всё OK (или только warnings)
#   1  ошибка использования
#   2  есть failed checks
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

# --- дефолты ---
DOMAIN=""
SKIP_BACKUP=false
JSON_OUT=false
BACKUP_DIR="/var/matrix/backup"
DISK_MIN_FREE_MB=2048
COMPOSE_DIR="/matrix"
COMPOSE_TIMEOUT=5

# Маппинг "ожидаемое имя → состояние"
declare -a CHECKS=()
declare -a CHECK_RESULTS=() # "ok" | "warn" | "fail"

usage() {
    cat <<EOF
$(header_text "healthcheck" 2>&1 || true)

Использование:
  bash $(basename "$0") [опции]

Опции:
  --domain, -d DOMAIN       Домен (для проверки homeserver URL)
  --compose-dir PATH        Корень docker-compose (по умолчанию: /matrix)
  --backup-dir PATH         Где искать бэкапы (по умолчанию: /var/matrix/backup)
  --disk-min-free-mb N      Минимум свободного места в МБ (по умолчанию: 2048)
  --no-backup               Пропустить проверку свежести бэкапа
  --json                    Вывести результат в JSON (для мониторинга)
  -h, --help                Эта справка

Коды возврата: 0 OK, 1 usage, 2 failed checks.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain | -d)
            DOMAIN="$2"
            shift 2
            ;;
        --compose-dir)
            COMPOSE_DIR="$2"
            shift 2
            ;;
        --backup-dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --disk-min-free-mb)
            DISK_MIN_FREE_MB="$2"
            shift 2
            ;;
        --no-backup)
            SKIP_BACKUP=true
            shift
            ;;
        --json)
            JSON_OUT=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            err "Неизвестный аргумент: $1"
            usage
            exit 1
            ;;
    esac
done

# Запись результата проверки
record() {
    local status="$1" name="$2" detail="${3:-}"
    CHECKS+=("$name")
    CHECK_RESULTS+=("$status")
    if [[ "$JSON_OUT" == true ]]; then
        return
    fi
    case "$status" in
        ok) ok "  ✓ $name${detail:+ - $detail}" ;;
        warn) warn "  ! $name${detail:+ - $detail}" ;;
        fail) err "  ✗ $name${detail:+ - $detail}" ;;
    esac
}

# --- 1. Docker + compose ---
check_docker() {
    if ! command -v docker &>/dev/null; then
        record fail "docker" "не установлен"
        return
    fi
    if ! docker info >/dev/null 2>&1; then
        record fail "docker daemon" "не отвечает"
        return
    fi
    record ok "docker" "$(docker --version 2>/dev/null | head -1)"

    if [[ -d "$COMPOSE_DIR" ]] && [[ -f "${COMPOSE_DIR}/docker-compose.yml" ]]; then
        local running=0
        local total=0
        while read -r svc; do
            total=$((total + 1))
            if docker inspect --format '{{.State.Running}}' "$svc" 2>/dev/null |
                grep -qx true; then
                running=$((running + 1))
            fi
        done < <(docker compose -f "${COMPOSE_DIR}/docker-compose.yml" \
            config --services 2>/dev/null)
        if ((total == 0)); then
            record warn "compose services" "docker compose config не вернул сервисов"
        elif ((running == total)); then
            record ok "compose" "$running/$total сервисов запущено"
        elif ((running >= total - 1)); then
            record warn "compose" "$running/$total сервисов запущено (допустимо)"
        else
            record fail "compose" "только $running/$total сервисов запущено"
        fi
    else
        record warn "compose" "${COMPOSE_DIR}/docker-compose.yml не найден (не развёрнуто?)"
    fi
}

# --- 2. Homeserver federation / client APIs ---
check_homeserver() {
    if [[ -z "$DOMAIN" ]]; then
        record warn "homeserver" "домен не указан (передай --domain)"
        return
    fi
    local base="https://matrix.${DOMAIN}"
    # Federation version endpoint (публичный, без auth)
    local fed
    fed=$(curl -fsS --max-time "$COMPOSE_TIMEOUT" \
        "${base}/_matrix/federation/v1/version" 2>/dev/null || true)
    if [[ -n "$fed" ]] && echo "$fed" | grep -q '"server"'; then
        local server ver
        server=$(echo "$fed" | jq -r '.server.server' 2>/dev/null || echo "?")
        ver=$(echo "$fed" | jq -r '.server.version' 2>/dev/null || echo "?")
        record ok "federation v1/version" "${server} ${ver}"
    else
        record fail "federation v1/version" "endpoint не отвечает (${base})"
    fi
    # Client versions endpoint (публичный)
    local cli
    cli=$(curl -fsS --max-time "$COMPOSE_TIMEOUT" \
        "${base}/_matrix/client/versions" 2>/dev/null || true)
    if [[ -n "$cli" ]] && echo "$cli" | grep -q '"versions"'; then
        record ok "client/versions" "доступен"
    else
        record fail "client/versions" "endpoint не отвечает"
    fi
}

# --- 3. PostgreSQL ---
check_postgres() {
    local container="matrix-postgres"
    if ! command -v docker &>/dev/null; then
        return
    fi
    if ! docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null |
        grep -qx true; then
        record fail "postgres" "${container} не запущен"
        return
    fi
    if docker exec "$container" pg_isready -U matrix -d synapse \
        >/dev/null 2>&1; then
        record ok "postgres" "pg_isready OK"
    else
        record fail "postgres" "pg_isready не прошёл"
    fi
}

# --- 4. Reverse proxy ---
check_proxy() {
    # Проверяем, что 443 слушается, и ACME-челлендж не сломан
    if ! command -v ss &>/dev/null; then
        record warn "proxy" "ss не найден, пропускаю"
        return
    fi
    if ss -ltnH "sport = :443" 2>/dev/null | grep -q LISTEN; then
        local who
        who=$(ss -ltnpH "sport = :443" 2>/dev/null | head -1 |
            grep -oE 'users:\(\("([^"]+)"' | sed 's/users:(("//' || true)
        record ok "https :443" "LISTEN${who:+ ($who)}"
    else
        record fail "https :443" "не слушается"
    fi
    # ACME http-01 (порт 80)
    if ss -ltnH "sport = :80" 2>/dev/null | grep -q LISTEN; then
        record ok "http :80 (ACME)" "LISTEN"
    else
        record warn "http :80 (ACME)" "не слушается - обновление сертификатов может сломаться"
    fi
}

# --- 5. Свежесть бэкапа ---
check_backup_freshness() {
    if [[ "$SKIP_BACKUP" == true ]]; then
        return
    fi
    if [[ ! -d "$BACKUP_DIR" ]]; then
        record warn "backup dir" "${BACKUP_DIR} не существует (бэкап ещё не делался?)"
        return
    fi
    # Ищем самый свежий каталог с датой в имени (формат: 2* от pg_dumpall)
    local latest
    latest=$(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -name '2*' \
        -printf '%T@ %p\n' 2>/dev/null |
        sort -n | tail -1 | awk '{print $2}')
    if [[ -z "$latest" ]]; then
        record warn "backup" "не найдено каталогов с датой в ${BACKUP_DIR}"
        return
    fi
    # latest mtime
    local mtime
    mtime=$(stat -c '%Y' "$latest" 2>/dev/null || echo 0)
    local now
    now=$(date +%s)
    local age_h=$(((now - mtime) / 3600))
    if ((age_h <= 26)); then
        record ok "backup свежесть" "$(basename "$latest") (${age_h} ч. назад)"
    elif ((age_h <= 72)); then
        record warn "backup свежесть" "$(basename "$latest") (${age_h} ч. назад - рекомендуется ≤24ч)"
    else
        record fail "backup свежесть" "$(basename "$latest") (${age_h} ч. назад - слишком старый)"
    fi
}

# --- 6. Место на диске ---
check_disk() {
    local target="/matrix"
    [[ -d "$target" ]] || target="/"
    local free_kb
    free_kb=$(df -P "$target" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -z "$free_kb" || "$free_kb" -eq 0 ]]; then
        record warn "disk" "df не вернул результат"
        return
    fi
    local free_mb=$((free_kb / 1024))
    if ((free_mb >= DISK_MIN_FREE_MB)); then
        record ok "disk free" "${free_mb} МБ на ${target}"
    else
        record fail "disk free" "${free_mb} МБ < ${DISK_MIN_FREE_MB} МБ на ${target}"
    fi
}

# --- main ---
if [[ "$JSON_OUT" != true ]]; then
    header_text "Healthcheck"
    [[ -n "$DOMAIN" ]] && info "Домен: ${DOMAIN}"
    info "Compose dir: ${COMPOSE_DIR}"
    [[ "$SKIP_BACKUP" != true ]] && info "Backup dir: ${BACKUP_DIR}"
    echo ""
fi

check_docker
check_homeserver
check_postgres
check_proxy
check_backup_freshness
check_disk

# --- Итог ---
fails=0
warns=0
for s in "${CHECK_RESULTS[@]}"; do
    case "$s" in
        fail) fails=$((fails + 1)) ;;
        warn) warns=$((warns + 1)) ;;
    esac
done

if [[ "$JSON_OUT" == true ]]; then
    printf '{\n  "domain": "%s",\n  "checks": [\n' "${DOMAIN}"
    for i in "${!CHECKS[@]}"; do
        sep=$([ "$i" -lt "$((${#CHECKS[@]} - 1))" ] && echo "," || echo "")
        printf '    {"name": "%s", "status": "%s"}%s\n' \
            "${CHECKS[$i]}" "${CHECK_RESULTS[$i]}" "$sep"
    done
    printf '  ],\n  "fails": %d,\n  "warns": %d\n}\n' "$fails" "$warns"
else
    echo ""
    if ((fails == 0)); then
        if ((warns == 0)); then
            ok "Healthcheck: всё OK"
        else
            warn "Healthcheck: OK с ${warns} предупреждением(-ями)"
        fi
    else
        err "Healthcheck: ${fails} failed, ${warns} warnings"
    fi
fi

exit $((fails > 0 ? 2 : 0))
