#!/usr/bin/env bash
# =============================================================================
# Install LiveKit JWT Service AS-mode (MSC4512, MSC4502) — ЭКСПЕРИМЕНТАЛЬНАЯ ФИЧА
# =============================================================================
#
# Ставит lk-as.yaml в ${DATA_PATH}/synapse/config/, выравнивает права,
# валидирует vars.yml/nginx, затем перезапускает synapse + jwt-service.
#
# Запускать ПОСЛЕ `just install-all` с vars.yml от wizard'а c LIVEKIT_AS_MODE=true.
#
# Использование:
#   bash tools/install-livekit-as.sh [--vars PATH] [--domain EXAMPLE.COM] \
#       [--data-path /matrix] [--skip-restart] [-y]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

VARS_FILE=""
DOMAIN=""
DATA_PATH_LK=""
SKIP_RESTART=false
ASSUME_YES=false

usage() {
    cat <<EOF
$(header_text "install-livekit-as.sh" 2>&1 || true)

Ставит Application Service режим lk-jwt-service (MSC4512/MSC4502).
⚠️  ЭКСПЕРИМЕНТАЛЬНАЯ ФИЧА - используй осторожно. legacy-путь не трогает.

Опции:
  --vars PATH        путь к vars.yml (по умолчанию inventory/host_vars/matrix.<domain>)
  --domain DOMAIN    bare-домен matrix_domain
  --data-path PATH   путь хранения данных (по умолчанию из vars.yml: matrix_base_data_path, иначе /matrix)
  --skip-restart     не перезапускать matrix-сервисы в конце
  -y                 не переспрашивать перед рестартом
  -h, --help         эта справка
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vars)
            VARS_FILE="$2"
            shift 2
            ;;
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --data-path)
            DATA_PATH_LK="$2"
            shift 2
            ;;
        --skip-restart)
            SKIP_RESTART=true
            shift
            ;;
        -y)
            ASSUME_YES=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            err "Неизвестный параметр: $1"
            usage
            exit 1
            ;;
    esac
done

require_root

PLAYBOOK_ROOT="${TEMPLATE_SCRIPT_DIR:-${SCRIPT_DIR}/..}"
[[ ! -f "${PLAYBOOK_ROOT}/setup.yml" ]] && PLAYBOOK_ROOT="/root/matrix-docker-ansible-deploy"
[[ ! -f "${PLAYBOOK_ROOT}/setup.yml" ]] && PLAYBOOK_ROOT="/opt/matrix-docker-ansible-deploy"

# --- найти vars.yml ---
if [[ -z "$VARS_FILE" ]]; then
    if [[ -n "$DOMAIN" ]]; then
        VARS_FILE="${PLAYBOOK_ROOT}/inventory/host_vars/matrix.${DOMAIN}/vars.yml"
    else
        for candidate in "${PLAYBOOK_ROOT}"/inventory/host_vars/matrix.*; do
            [[ -d "$candidate" ]] || continue
            if [[ -f "${candidate}/vars.yml" ]]; then
                VARS_FILE="${candidate}/vars.yml"
                break
            fi
        done
    fi
fi
[[ -n "$VARS_FILE" && -f "$VARS_FILE" ]] || die "vars.yml не найден. Укажи --vars PATH"

AS_FILE="$(dirname "$VARS_FILE")/lk-as.yaml"
[[ -f "$AS_FILE" ]] || die "lk-as.yaml не найден рядом с vars.yml (${AS_FILE}). Ответь на вопрос про AS-режим в wizard'е."

echo ""
echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${YELLOW}  ЭКСПЕРИМЕНТАЛЬНАЯ ФИЧА - lk-jwt-service AS-mode (MSC4512)${NC}"
echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "vars.yml: ${VARS_FILE}"
info "AS file:  ${AS_FILE}"
echo ""

# --- 1) валидация vars.yml ---
header_text "1/5  Валидация vars.yml"
MISSING=0
_check_var() {
    if grep -q "^$1:" "$VARS_FILE"; then
        ok "  присутствует: $1"
    else
        err "  ОТСУТСТВУЕТ: $1"
        MISSING=$((MISSING + 1))
    fi
}
_check_var "matrix_synapse_experimental_features_custom"
_check_var "matrix_synapse_app_service_config_files"
_check_var "matrix_synapse_matrix_rtc_transports"
_check_var "matrix_livekit_jwt_service_environment_variables_extension"
_check_var "livekit_server_path_prefix"
[[ "$MISSING" -eq 0 ]] || die "В vars.yml не хватает блоков (см. выше). Ответь 'y' на вопрос AS-режима в wizard'е и перегенерируй vars."

# AS-режим есть с 0.7; kit пинит latest, чтобы образ сам обновлялся
JWT_VER="$(awk '/^matrix_livekit_jwt_service_version:/ {sub(/^matrix_livekit_jwt_service_version:[[:space:]]*/,""); gsub(/^["'\'']|["'\'']$/,""); print; exit}' "$VARS_FILE")"
if [[ "$JWT_VER" == "latest" ]]; then
    ok "  jwt-service version: latest (образ сам обновляется)"
elif [[ -n "$JWT_VER" ]]; then
    warn "  jwt-service version: ${JWT_VER} (работает при >= 0.7; для авто-обновления лучше latest)"
else
    warn "  matrix_livekit_jwt_service_version не задан (mdad-default 0.7.0; лучше latest)"
fi

if grep -q "^matrix_synapse_matrix_rtc_transports_custom:" "$VARS_FILE"; then
    warn "найден matrix_synapse_matrix_rtc_transports_custom — хотя мы делаем ОДИН override из плейбука"
    warn "  возможно получится ДВЕ livekit-записи (default + custom). Тогда transports.url дублируется:"
    warn "  клиент возьмёт ту, которая первая. Проверь что custom не дублирует нашу структуру."
fi

# --- 2) сверка токенов lk-as.yaml vs env-extension in vars.yml ---
header_text "2/5  Сверка токенов"
AS_T_FILE="$(awk -F'"' '/^as_token:/ {print $2; exit}' "$AS_FILE")"
HS_T_FILE="$(awk -F'"' '/^hs_token:/ {print $2; exit}' "$AS_FILE")"
# Токены в vars.yml - в block-scalar env-расширения. PyYAML-перегенерация
# (livekit-as-setup.sh) перекраивает формат в single-line quoted c переносами,
# поэтому извлекаем значение, а не строку целиком.
_env_token() { grep -oE "$1=[A-Za-z0-9]+" "$VARS_FILE" | head -1 | cut -d'=' -f2; }
AS_T_VARS="$(_env_token LIVEKIT_AS_TOKEN)"
HS_T_VARS="$(_env_token LIVEKIT_HS_TOKEN)"
[[ -n "$AS_T_FILE" && -n "$HS_T_FILE" ]] || die "Не смог прочитать as_token/hs_token из $AS_FILE"
[[ "$AS_T_FILE" == "$AS_T_VARS" ]] || die "as_token в файле != LIVEKIT_AS_TOKEN в vars.yml"
[[ "$HS_T_FILE" == "$HS_T_VARS" ]] || die "hs_token в файле != LIVEKIT_HS_TOKEN в vars.yml"
ok "  токены совпадают"

# --- 3) валидация nginx ---
header_text "3/5  Валидация nginx"
if command -v nginx &>/dev/null; then
    if nginx -t >/dev/null 2>&1; then
        ok "  nginx -t: OK"
    else
        die "nginx -t ОШИБОК - конфиг невалиден. Почини его прежде чем продолжать."
    fi
    NGINX_MATRIX_CONF="/etc/nginx/sites-enabled/matrix.conf"
    [[ ! -f "$NGINX_MATRIX_CONF" ]] && NGINX_MATRIX_CONF="/etc/nginx/sites-available/matrix.conf"
    if [[ -f "$NGINX_MATRIX_CONF" ]]; then
        if grep -qE 'proxy_set_header\s+Upgrade' "$NGINX_MATRIX_CONF"; then
            ok "  Upgrade-хедеры в ${NGINX_MATRIX_CONF}: на месте"
        else
            warn "  ${NGINX_MATRIX_CONF}: нет proxy_set_header Upgrade — WS до SFU может не подняться"
            warn "  Если matrix.conf сгенерирован prepare_server.sh — хедер обычно уже есть (_proxy_block)."
        fi
    else
        warn "  matrix.conf не найден (норма если Traefik-only)"
    fi
else
    info "  nginx не установлен (Traefik-only?) — проверку пропускаем"
fi

# --- 4) установка lk-as.yaml ---
header_text "4/5  Установка lk-as.yaml"
# matrix_base_data_path может быть закомментирован дефолтом — берём только активную строку
SYNAPSE_CFG="${DATA_PATH_LK:-$(awk '/^matrix_base_data_path:/ {sub(/^matrix_base_data_path:[[:space:]]*/,""); gsub(/^["'\'']|["'\'']$/,""); print; exit}' "$VARS_FILE")}"
SYNAPSE_CFG="${SYNAPSE_CFG:-/matrix}"
SYNAPSE_CFG_DIR="${SYNAPSE_CFG}/synapse/config"
[[ -d "$SYNAPSE_CFG_DIR" ]] || die "Каталог ${SYNAPSE_CFG_DIR} не существует. Сначала just install-all."

DEST="${SYNAPSE_CFG_DIR}/lk-as.yaml"
# Владелец = host-юзер MDAD (matrix_user_name, дефолт "matrix")
install -m 640 -o "$(stat -c %U "${SYNAPSE_CFG_DIR}/homeserver.yaml" 2>/dev/null || echo matrix)" \
    -g "$(stat -c %G "${SYNAPSE_CFG_DIR}/homeserver.yaml" 2>/dev/null || echo matrix)" "$AS_FILE" "$DEST"
ok "  установлено: ${DEST} (mode 640, owner по аналогии с homeserver.yaml)"

if [[ "$SKIP_RESTART" != true ]]; then
    if [[ "$ASSUME_YES" != true ]]; then
        # || true: закрывшийся stdin (cron/pipe) даёт read=1 под set -e - а файл
        # уже на месте, глупо помирать до решения о рестарте
        read -r -p "Перезапустить matrix-synapse и matrix-livekit-jwt-service? [y/N] " answer || true
        [[ "$answer" =~ ^[Yy] ]] || { info "пропускаем рестарт (скрипт успешен, сервисы перестартует install-all/вручную)"; }
    else
        answer="y"
    fi
    if [[ "$answer" =~ ^[Yy] ]]; then
        systemctl restart matrix-synapse matrix-livekit-jwt-service
        sleep 5
        ok "  сервисы перезапущены"
    fi
else
    info "  restart пропущен (--skip-restart)"
fi

# --- 5) smoke-проверки ---
header_text "5/5  Smoke-проверки"
MATRIX_HOST="matrix.${DOMAIN:-$(awk -F': *' '/^matrix_domain:/ {gsub(/["'"'"']/,"",$2); print $2; exit}' "$VARS_FILE")}"
ok_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    "https://${MATRIX_HOST}/_matrix/client/unstable/org.matrix.msc4143/rtc/transports" || echo "000")
if [[ "$ok_code" == "401" || "$ok_code" == "200" ]]; then
    ok "  /rtc/transports жив (HTTP ${ok_code}; 401 = недостаток токена, что норма без AT)"
else
    warn "  /rtc/transports: HTTP ${ok_code} (ожидалось 200/401. 404 → msc4143 не включён,"
    warn "     в MDAD включается автоматически при ненулевых transports)"
fi

SMOKE_BAD=false
PROXY_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST \
    -H 'Content-Type: application/json' -d '{}' \
    "https://${MATRIX_HOST}/_matrix/client/unstable/io.element.msc4195/rtc/livekit/get_token" || echo "000")
if [[ "$PROXY_CODE" == "404" ]]; then
    SMOKE_BAD=true
    err "  прокси отдаёт 404 M_UNRECOGNIZED - НЕ работает AS-проксирование"
    err "  причины: нет msc4512_enabled, lk-as.yaml не подключён и т.п. См. docs/LIVEKIT-AS-MODE-MSC4512.md"
else
    ok "  MSC4512-прокси жив (HTTP ${PROXY_CODE}; сервис отвечает своей ошибкой - что и надо)"
fi

echo ""
if [[ "$SMOKE_BAD" == true ]]; then
    warn "Файл на месте, но smoke не пройден - допроверяй до реального звонка."
else
    log "AS-режим установлен. Проверь реальный звонок в свежем Element Call/Web."
fi
info "Логи: journalctl -fu matrix-livekit-jwt-service"
info "Откат:  rm ${DEST} + убрать блок из vars.yml + just install-all"
