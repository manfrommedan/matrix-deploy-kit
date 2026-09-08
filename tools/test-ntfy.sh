#!/usr/bin/env bash
# =============================================================================
# Matrix-deploy-kit - ntfy smoke test
# =============================================================================
# Проверяет, что ntfy-сервер:
#   1. Доступен снаружи по HTTPS
#   2. /v1/health отвечает healthy
#   3. Анонимная подписка работает (если auth-default-access ≥ read)
#   4. Анонимная публикация работает (если auth-default-access ≥ write)
#   5. homeserver-объявление в .well-known указывает на ntfy
#
# Использование:
#   bash tools/test-ntfy.sh --domain example.com
#   bash tools/test-ntfy.sh --domain example.com --topic test-$(date +%s)
#   bash tools/test-ntfy.sh --domain example.com --no-publish
#
# Коды возврата: 0 OK, 1 usage, 2 found issues, 3 network error.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

# --- дефолты ---
DOMAIN=""
TOPIC="" # будет сгенерирован, если не задан
TIMEOUT=5
DO_PUBLISH=true

usage() {
    cat <<EOF
$(header_text "test-ntfy" 2>&1 || true)

Использование:
  bash $(basename "$0") --domain DOMAIN [опции]

Опции:
  --domain, -d DOMAIN       Bare-домен (например example.com)
  --topic TOPIC             Топик для теста (по умолчанию: test-UNIX_TS)
  --timeout SECONDS         Таймаут curl (по умолчанию: 5)
  --no-publish              Только проверка чтения, без публикации
  -h, --help                Эта справка

Коды возврата: 0 OK, 1 usage, 2 issues, 3 network error.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain | -d)
            DOMAIN="$2"
            shift 2
            ;;
        --topic)
            TOPIC="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --no-publish)
            DO_PUBLISH=false
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

if [[ -z "$DOMAIN" ]]; then
    err "Не указан --domain"
    usage
    exit 1
fi

if [[ -z "$TOPIC" ]]; then
    TOPIC="test-$(date +%s)"
fi

NTFY_BASE="https://ntfy.${DOMAIN}"
HS_BASE="https://matrix.${DOMAIN}"
ERRORS=0
WARNS=0

# Помощник записи результата
record() {
    local status="$1"
    local name="$2"
    local detail="${3:-}"
    case "$status" in
        ok) ok "  ✓ $name${detail:+ - $detail}" ;;
        warn)
            warn "  ! $name${detail:+ - $detail}"
            ((WARNS++))
            ;;
        fail)
            err "  ✗ $name${detail:+ - $detail}"
            ((ERRORS++))
            ;;
    esac
}

header_text "ntfy smoke test: ${DOMAIN}"
info "ntfy URL: ${NTFY_BASE}"
info "homeserver: ${HS_BASE}"
info "тестовый топик: ${TOPIC}"
echo ""

# 1. Health endpoint
health=$(curl -fsS --max-time "$TIMEOUT" "${NTFY_BASE}/v1/health" 2>/dev/null || echo "")
if [[ -z "$health" ]]; then
    record fail "health endpoint" "${NTFY_BASE}/v1/health не отвечает"
else
    if echo "$health" | grep -q '"healthy":true'; then
        record ok "health endpoint" "healthy"
    else
        record warn "health endpoint" "ответ: $health"
    fi
fi

# 2. Well-known: homeserver должен объявить ntfy
wk=$(curl -fsS --max-time "$TIMEOUT" "${HS_BASE}/.well-known/matrix/client" 2>/dev/null || echo "")
if [[ -z "$wk" ]]; then
    record warn "well-known" "${HS_BASE}/.well-known/matrix/client недоступен"
else
    ntfy_url_in_wk=$(echo "$wk" | jq -r '.["m.push"].url // empty' 2>/dev/null || echo "")
    if [[ -n "$ntfy_url_in_wk" ]]; then
        if [[ "$ntfy_url_in_wk" == "${NTFY_BASE}" ]]; then
            record ok "well-known m.push" "объявляет ${ntfy_url_in_wk}"
        else
            record warn "well-known m.push" "объявляет '${ntfy_url_in_wk}', ожидался '${NTFY_BASE}'"
        fi
    else
        record warn "well-known m.push" "не объявляет ntfy - клиенты не найдут дистрибьютора автоматически"
    fi
fi

# 3. Анонимная подписка: попробуем подключиться long-poll
# Делаем короткий poll (3 сек), если что-то придёт - супер, если нет - это ОК (никто не публиковал)
echo ""
info "Тест подписки (long-poll 3 сек на ${TOPIC}):"
sub_resp=$(timeout 3 curl -fsS --max-time "$TIMEOUT" -H "Accept: application/x-ndjson" \
    "${NTFY_BASE}/${TOPIC}/json?poll=1" 2>/dev/null || true)
# Успех подписки - это то, что мы получили HTTP-ответ без ошибки.
# Нам не нужно получать сообщение - это проверка, что endpoint не отвечает 401/403.
# Отдельно проверим 401/403 через явный запрос без sub.
auth_check=$(curl -sS --max-time "$TIMEOUT" -o /dev/null -w "%{http_code}" \
    "${NTFY_BASE}/${TOPIC}/info" 2>/dev/null || echo "000")
case "$auth_check" in
    200) record ok "anonymous subscribe" "endpoint /<topic>/info отвечает 200" ;;
    401 | 403)
        record fail "anonymous subscribe" "endpoint отвечает ${auth_check} - auth-default-access не разрешает анонимное чтение (нужно read-write/write-only или read-only с publish-permission)"
        ;;
    404)
        record warn "anonymous subscribe" "endpoint /<topic>/info отвечает 404 (странно, должно быть 200/401/403)"
        ;;
    000) record fail "network" "не удалось подключиться к ${NTFY_BASE}" ;;
    *) record warn "anonymous subscribe" "HTTP ${auth_check}" ;;
esac

# 4. Анонимная публикация
if [[ "$DO_PUBLISH" == true ]]; then
    echo ""
    info "Тест публикации: 'smoke-test-from-kit' в ${TOPIC}"
    pub_http=$(curl -sS --max-time "$TIMEOUT" -o /tmp/ntfy-pub.out -w "%{http_code}" \
        -d "smoke-test-from-kit at $(date '+%Y-%m-%d %H:%M:%S')" \
        "${NTFY_BASE}/${TOPIC}" 2>/dev/null || echo "000")
    case "$pub_http" in
        200) record ok "anonymous publish" "опубликовано (HTTP 200)" ;;
        401 | 403)
            record fail "anonymous publish" "HTTP ${pub_http} - auth-default-access запрещает анонимную запись. Если хочешь разрешить (нужно для UnifiedPush), выстави read-write"
            ;;
        429) record warn "anonymous publish" "rate-limited (HTTP 429) - попробуй позже или увеличь visitor-message-daily-limit" ;;
        000) record fail "network" "не удалось подключиться" ;;
        *) record warn "anonymous publish" "HTTP ${pub_http}: $(cat /tmp/ntfy-pub.out 2>/dev/null | head -c 100)" ;;
    esac
    rm -f /tmp/ntfy-pub.out
fi

# 5. Локальный healthcheck контейнера
if command -v docker &>/dev/null; then
    echo ""
    if docker inspect --format '{{.State.Running}}' matrix-ntfy 2>/dev/null | grep -qx true; then
        record ok "container" "matrix-ntfy running"
    else
        record warn "container" "matrix-ntfy не запущен (или не на этом хосте)"
    fi
fi

# --- Итог ---
echo ""
if ((ERRORS == 0)); then
    if ((WARNS == 0)); then
        ok "ntfy: всё OK"
    else
        warn "ntfy: OK с ${WARNS} предупреждением(-ями)"
    fi
    echo ""
    echo "Проверь доставку вручную:"
    echo "  1. Element Android → Settings → Troubleshoot → Troubleshoot notifications"
    echo "  2. Должен показать distributor: ntfy"
    echo "  3. Открой https://${NTFY_BASE}/app и подпишись на нужный топик"
    exit 0
else
    err "ntfy: ${ERRORS} ошибок, ${WARNS} предупреждений"
    echo ""
    echo "См. docs/TROUBLESHOOTING.md раздел 10 (ntfy push)."
    exit 2
fi
