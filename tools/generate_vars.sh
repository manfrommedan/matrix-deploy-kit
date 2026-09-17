#!/usr/bin/env bash
# =============================================================================
# Matrix Server - интерактивный генератор vars.yml
# =============================================================================
# Запуск из корня плейбука:
#   bash tools/generate-vars.sh
#   bash tools/generate-vars.sh --output /path/to/vars.yml
#   bash tools/generate-vars.sh --dry-run
# =============================================================================

set -euo pipefail

# --- Подключаем общую библиотеку (gen_dynamic_port и пр.) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

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
header() {
    echo ""
    echo -e "${BOLD}${CYAN}=== $* ===${NC}"
    echo ""
}
divider() { echo -e "${DIM}$(printf '%.0s─' {1..60})${NC}"; }

# --- Определяем путь к корню плейбука ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK_ROOT=""
OUTPUT_FILE=""
DRY_RUN=false
ENV_FILE=""

# --- Парсинг аргументов ---
RANDOM_PORTS=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --playbook-dir | -p)
            PLAYBOOK_ROOT="$2"
            shift 2
            ;;
        --output | -o)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --dry-run | -n)
            DRY_RUN=true
            shift
            ;;
        --random-ports)
            RANDOM_PORTS=true
            shift
            ;;
        -h | --help)
            echo "Использование: generate-vars.sh [ОПЦИИ]"
            echo ""
            echo "Опции:"
            echo "  --playbook-dir, -p PATH  Путь к корню плейбука (обязательно или автоопределение)"
            echo "  --output, -o PATH        Путь для сохранения vars.yml"
            echo "                           По умолчанию: <playbook>/inventory/host_vars/matrix.<domain>/vars.yml"
            echo "  --dry-run, -n            Показать результат без записи файлов"
            echo "  --random-ports           В секции LiveKit автоматически сгенерировать"
            echo "                           случайные порты (49152-65535) без интерактивного"
            echo "                           вопроса. Соответствует --random-ports в"
            echo "                           prepare_server.sh."
            echo "  -h, --help               Показать эту справку"
            echo ""
            echo "Примеры:"
            echo "  bash generate-vars.sh -p /opt/matrix-docker-ansible-deploy"
            echo "  bash generate-vars.sh --dry-run -p /opt/matrix-docker-ansible-deploy"
            echo "  bash generate-vars.sh --random-ports -p /opt/matrix-docker-ansible-deploy"
            echo "  bash generate-vars.sh --env-file answers.env -p /opt/matrix-docker-ansible-deploy"
            echo ""
            echo "Формат --env-file (одна KEY=VALUE на строку, KEY - переменная wizard'а):"
            echo "  DOMAIN=example.com"
            echo "  SERVER_IP=1.2.3.4"
            echo "  HOMESERVER=synapse"
            echo "  ELEMENT_BRAND=\"My Chat\""
            echo "  ELEMENT_THEME=dark"
            echo "  ELEMENT_REG_ENABLED=true"
            echo "  ELEMENT_COUNTRY=RU"
            echo "  LOG_LEVEL=WARNING"
            echo "  (полный список см. в комментариях скрипта)"
            exit 0
            ;;
        --env-file)
            ENV_FILE="$2"
            if [[ ! -f "$ENV_FILE" ]]; then
                err "Файл $ENV_FILE не найден"
                exit 1
            fi
            # shellcheck disable=SC1090
            set -a
            source "$ENV_FILE"
            set +a
            shift 2
            ;;
        *)
            err "Неизвестный параметр: $1"
            exit 1
            ;;
    esac
done

# --- Автоопределение пути к плейбуку ---
if [[ -z "$PLAYBOOK_ROOT" ]]; then
    # Пробуем: рядом со скриптом (tools/), уровень выше, текущая директория
    for candidate in "$SCRIPT_DIR/.." "$SCRIPT_DIR/../.." "$PWD"; do
        if [[ -f "$candidate/setup.yml" ]]; then
            PLAYBOOK_ROOT="$(cd "$candidate" && pwd)"
            break
        fi
    done
fi

if [[ -z "$PLAYBOOK_ROOT" || ! -f "$PLAYBOOK_ROOT/setup.yml" ]]; then
    err "Не найден плейбук (setup.yml). Укажи путь: --playbook-dir /path/to/playbook"
    exit 1
fi

# =============================================================================
# Функции ввода
# =============================================================================

# Ввод текста с дефолтом
ask() {
    local prompt="$1"
    local default="${2:-}"
    local result

    if [[ -n "$default" ]]; then
        echo -en "  ${prompt} ${DIM}[${default}]${NC}: " >&2
    else
        echo -en "  ${prompt}: " >&2
    fi

    read -r result
    echo "${result:-$default}"
}

# Ввод пароля (скрытый)
ask_secret() {
    local prompt="$1"
    local default="${2:-}"
    local result

    if [[ -n "$default" ]]; then
        echo -en "  ${prompt} ${DIM}[авто]${NC}: " >&2
    else
        echo -en "  ${prompt}: " >&2
    fi

    read -rs result
    echo "" >&2
    echo "${result:-$default}"
}

# Да/нет вопрос
ask_yn() {
    local prompt="$1"
    local default="${2:-y}"
    local yn_hint answer

    if [[ "$default" == "y" ]]; then
        yn_hint="Y/n"
    else
        yn_hint="y/N"
    fi

    while true; do
        echo -en "  ${prompt} ${DIM}[${yn_hint}]${NC}: " >&2
        read -r answer
        answer="${answer:-$default}"
        # Принимаем: y, yes, n, no (регистронезависимо) или пустой ввод
        if [[ "$answer" =~ ^[YyNn]([EeOoSs])?$ ]] || [[ -z "$answer" ]]; then
            break
        fi
        warn "Введи y (да) или n (нет)"
    done

    [[ "$answer" =~ ^[Yy] ]]
}

# Ввод порта с валидацией
ask_port() {
    local prompt="$1"
    local default="${2:-}"
    local result

    while true; do
        if [[ -n "$default" ]]; then
            echo -en "  ${prompt} ${DIM}[${default}]${NC}: " >&2
        else
            echo -en "  ${prompt}: " >&2
        fi
        read -r result
        result="${result:-$default}"

        if [[ "$result" =~ ^[0-9]+$ ]] && ((result >= 1 && result <= 65535)); then
            echo "$result"
            return
        fi
        warn "Порт должен быть числом от 1 до 65535"
    done
}

# Ввод URL с валидацией
ask_url() {
    local prompt="$1"
    local default="${2:-}"
    local result

    while true; do
        if [[ -n "$default" ]]; then
            echo -en "  ${prompt} ${DIM}[${default}]${NC}: " >&2
        else
            echo -en "  ${prompt}: " >&2
        fi
        read -r result
        result="${result:-$default}"

        if [[ "$result" =~ ^https?:// ]]; then
            echo "$result"
            return
        fi
        warn "URL должен начинаться с https:// или http://"
    done
}

# Выбор из списка (множественный)
ask_multi() {
    local prompt="$1"
    shift
    local -a options=("$@")
    local -a selected=()

    echo -e "  ${prompt}" >&2
    echo -e "  ${DIM}Введи номера через пробел или пустую строку чтобы пропустить${NC}" >&2
    echo "" >&2

    local i=1
    for opt in "${options[@]}"; do
        echo -e "    ${BOLD}${i})${NC} ${opt}" >&2
        ((i++))
    done

    echo "" >&2
    echo -en "  Выбор: " >&2
    read -r choices

    if [[ -n "$choices" ]]; then
        for num in $choices; do
            if [[ "$num" =~ ^[0-9]+$ ]] && ((num >= 1 && num <= ${#options[@]})); then
                selected+=("${options[$((num - 1))]}")
            fi
        done
    fi

    if [[ ${#selected[@]} -gt 0 ]]; then
        printf '%s\n' "${selected[@]}"
    fi
}

# Генерация секрета
gen_secret() {
    local len="${1:-64}"
    if command -v pwgen &>/dev/null; then
        pwgen -s "$len" 1
    elif command -v openssl &>/dev/null; then
        openssl rand -base64 "$len" | tr -dc 'a-zA-Z0-9' | head -c "$len"
    else
        head -c 256 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$len"
    fi
}

# =============================================================================
# Начало
# =============================================================================
clear 2>/dev/null || true

cat <<'BANNER'

  ╔══════════════════════════════════════════════════╗
  ║   Matrix Server - генератор конфигурации        ║
  ║   vars.yml для matrix-docker-ansible-deploy     ║
  ╚══════════════════════════════════════════════════╝

BANNER

if [[ "$DRY_RUN" == true ]]; then
    warn "Режим DRY-RUN: файлы не будут записаны, результат покажем в конце"
    echo ""
fi

info "Нажимай Enter чтобы принять значение по умолчанию ${DIM}[в скобках]${NC}"
echo ""

# --- Non-interactive режим (--env-file) ---
# Если передан --env-file, источник уже загружен, переменные экспортированы.
# Пропускаем все интерактивные блоки wizard'а и идём прямо к heredoc-генерации.
if [[ -n "${WIZARD_NONINTERACTIVE:-}" || -n "${ENV_FILE:-}" ]]; then
    info "Non-interactive режим (--env-file или WIZARD_NONINTERACTIVE=1)"
    info "  Все значения берутся из env-переменных с fallback на дефолты"
    if [[ -z "${DOMAIN:-}" ]]; then
        die "Non-interactive режим требует DOMAIN в env (например, --env-file с DOMAIN=example.com)"
    fi
    # Минимально-необходимые дефолты (если не заданы в env)
    : "${SERVER_IP:=}"
    : "${HOMESERVER:=synapse}"
    : "${ELEMENT_BRAND:=""}"
    : "${ELEMENT_THEME:=light}"
    : "${ELEMENT_REG_ENABLED:=false}"
    : "${ELEMENT_COUNTRY:=GB}"
    : "${ELEMENT_DISABLE_GUESTS:=true}"
    : "${ELEMENT_LAB_SETTINGS:=true}"
    : "${ELEMENT_LOGO_URL:=}"
    : "${ELEMENT_BG_URL:=}"
    : "${ELEMENT_BUG_URL:=}"
    : "${ELEMENT_FOOTER_LINKS:=[]}"
    : "${SUBDOMAIN_MATRIX:=matrix.${DOMAIN}}"
    : "${SUBDOMAIN_ELEMENT:=element.${DOMAIN}}"
    : "${SUBDOMAIN_NTFY:=ntfy.${DOMAIN}}"
    : "${WITH_LANDING_PAGE:=true}"
    : "${WITH_NTFY:=true}"
    : "${NTFY:=false}" # будет выставлен в true ниже если WITH_NTFY
    [[ "${WITH_NTFY}" == "true" ]] && NTFY=true
    : "${NTFY_AUTH:=read-write}"
    : "${NTFY_CACHE:=24h}"
    : "${NTFY_MGR_INTERVAL:=2s}"
    : "${NTFY_KEEPALIVE:=20s}"
    : "${NTFY_VISITOR_MSG_LIMIT:=5000}"
    : "${NTFY_VISITOR_TOPIC_LIMIT:=30}"
    : "${NTFY_UPSTREAM:=}"
    : "${NTFY_WEB_ROOT:=app}"
    : "${LOG_LEVEL:=WARNING}"
    : "${SECRET_KEY:=$(openssl rand -hex 32)}"
    : "${DATA_PATH:=/matrix}"
    : "${MAX_UPLOAD_SIZE:=100}"
    : "${URL_PREVIEW:=false}"
    : "${WELCOME_ROOM_ENABLED:=false}"
    : "${SYNAPSE_AUTO_COMPRESSOR:=false}"
    : "${PRESENCE_ENABLED:=true}"
    : "${BACKUP_ENABLED:=true}"
    : "${BACKUP_INTERVAL_DAYS:=1}"
    : "${BACKUP_KEEP_DAYS:=7}"
    : "${BACKUP_ENCRYPT:=false}"
    : "${USE_NGINX:=true}"
    : "${PROXY_MODE:=nginx}"
    : "${FEDERATION_ENABLED:=true}"
    : "${GUEST_ACCESS:=false}"
    : "${HSTS_PRELOAD:=false}"
    : "${CLOUDFLARE_ENABLED:=false}"
    : "${MAX_UPLOAD_SIZE:=100}"
    : "${POSTGRES_PASS:=$(openssl rand -hex 16)}"
    : "${POSTGRES_BACKUP:=true}"
    : "${MAS_ENABLED:=true}"
    : "${COTURN:=true}"
    : "${COTURN_STUN_PORT:=3478}"
    : "${COTURN_TURNS_PORT:=5349}"
    : "${COTURN_RELAY_MIN:=49152}"
    : "${COTURN_RELAY_MAX:=49172}"
    : "${LIVEKIT_RTC_TCP:=}"
    : "${LIVEKIT_RTC_UDP:=}"
    : "${LIVEKIT_TURN_TLS:=}"
    : "${LIVEKIT_TURN_UDP:=}"
    : "${BOT_NAMES:=}"
    : "${BRIDGE_NAMES:=}"
    : "${CALLS_ENABLED:=true}"
    : "${ELEMENT_ADMIN_ENABLED:=false}"
    : "${FEDERATION_WHITELIST:=}"
    : "${FEDERATION_BLACKLIST:=}"
    : "${MATRIX_ROOT_REDIRECT:=true}"
    : "${TLS13_ONLY:=false}"
    : "${TLS13:=false}"
    : "${CF_DNS_TOKEN:=}"
    : "${CF_EMAIL:=}"
    : "${CF_ZONE_TOKEN:=}"
    : "${SMARTHOST:=}"
    : "${SMTP_LOGIN:=}"
    : "${SMTP_PASSWORD:=}"
    : "${SMTP_RELAY_HOST:=}"
    : "${SMTP_RELAY_PORT:=587}"
    : "${HOMESERVER_URL:=}"
    : "${BACKUP_TIME_OF_DAY:=04:00}"
    : "${BACKUP_RETAIN_DAYS:=7}"
    : "${SMTP_USE_TLS:=true}"
    : "${MATRIX_RTC_TRANSPORT_TIMEOUT:=}"
    : "${LIVEKIT_TURNS_PORT:=5349}"
    : "${ENABLED_SERVICES:=}"
    : "${LOCALE:=ru}"
    : "${MAS_ADMIN_API:=}"
    : "${MAS_EMAIL_REQUIRED:=false}"
    : "${MAS_REGISTRATION_ENABLED:=true}"
    : "${MAS_TOKEN_REQUIRED:=false}"
    : "${MAS_ENCRYPTION_SECRET:=$(openssl rand -hex 32)}"
    : "${WELCOME_ROOM_ALIAS:=welcome}"
    : "${WELCOME_ROOM_CREATOR:=welcome-bot}"
    : "${SECRET_KEY:=$(openssl rand -hex 32)}"
    : "${SECRET_KEY_HELM:=$(openssl rand -hex 32)}"
    # LiveKit не использует отдельный поддомен (path-routing через matrix.DOMAIN)
    : "${LIVEKIT_RTC_TCP:=}"
    : "${LIVEKIT_RTC_UDP:=}"
    : "${LIVEKIT_TURN_TLS:=}"
    : "${LIVEKIT_TURN_UDP:=}"
    info "  DOMAIN=${DOMAIN}"
    info "  HOMESERVER=${HOMESERVER}"
    info "  LOG_LEVEL=${LOG_LEVEL}"
    info "  ELEMENT_BRAND='${ELEMENT_BRAND}' (theme=${ELEMENT_THEME})"
    info "  NTFY=${WITH_NTFY}, LIVEKIT_RTC_TCP=${LIVEKIT_RTC_TCP:-<случайный>}"
    echo ""
    # Перепрыгиваем wizard (до heredoc-блока основной генерации)
    SKIP_WIZARD=true
fi

# =============================================================================
# 1. Домен и сервер
# =============================================================================
if [[ "${SKIP_WIZARD:-false}" != "true" ]]; then
    header "1/12  Домен и сервер"

    info "Домен определяет адреса пользователей: ${BOLD}@user:example.com${NC}"
    info "Указывай ${BOLD}bare-домен${NC} (example.com), ${RED}не${NC} поддомен (matrix.example.com)"
    info "Плейбук сам создаст поддомены: matrix.*, element.* и другие"
    info "После первого запуска домен менять ${RED}нельзя${NC}!"
    echo ""

    DOMAIN=$(ask "Домен Matrix-сервера" "example.com")

    # Валидация: ловим частую ошибку - ввод поддомена вместо bare-домена
    if [[ "$DOMAIN" == matrix.* ]]; then
        BARE_DOMAIN="${DOMAIN#matrix.}"
        warn "Похоже ты ввёл поддомен ${BOLD}${DOMAIN}${NC}"
        warn "matrix_domain должен быть bare-доменом: ${BOLD}${BARE_DOMAIN}${NC}"
        warn "Плейбук сам создаст matrix.${BARE_DOMAIN} для Synapse"
        echo ""
        if ask_yn "Использовать ${BARE_DOMAIN} вместо ${DOMAIN}?" "y"; then
            DOMAIN="$BARE_DOMAIN"
            log "Домен: ${DOMAIN}"
        fi
    fi

    # --- Кастомные поддомены (override matrix_server_fqn_*) ---
    # По умолчанию плейбук создаёт matrix.${DOMAIN}, element.${DOMAIN} и т.д.
    # Здесь можно переопределить любой из них на свой домен (в т.ч. на другом apex-домене).
    # LiveKit НЕ требует отдельного поддомена - он path-routed через matrix.${DOMAIN}
    divider
    info "Каждый сервис по умолчанию доступен на ${BOLD}сервис.${DOMAIN}${NC}:"
    info "  matrix.${DOMAIN}  - Synapse (homeserver)"
    info "  element.${DOMAIN} - Element Web (клиент)"
    info "  ntfy.${DOMAIN}    - ntfy (push-уведомления)"
    info "  LiveKit (звонки) - path-routed через matrix.${DOMAIN}, отдельный поддомен не нужен"
    echo ""
    info "Если хочешь нестандартные имена (например, ${BOLD}chat.${DOMAIN}${NC} вместо element.*),"
    info "укажи их здесь. Пустая строка = оставить дефолт."
    echo ""

    # Дефолтные имена
    SUBDOMAIN_MATRIX="matrix.${DOMAIN}"
    SUBDOMAIN_ELEMENT="element.${DOMAIN}"
    SUBDOMAIN_NTFY="ntfy.${DOMAIN}"

    # Helper: спросить кастомный subdomain, опционально оставляя дефолт
    ask_subdomain() {
        local prompt="$1"
        local default="$2"
        local val
        val=$(ask "$prompt" "")
        if [[ -z "$val" ]]; then
            echo "$default"
        elif [[ "$val" == *.*.* || "$val" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
            echo "$val"
        else
            warn "'${val}' не похоже на FQDN - использую дефолт ${default}"
            echo "$default"
        fi
    }

    if ask_yn "Переопределить какие-то поддомены (нестандартные имена)?" "n"; then
        SUBDOMAIN_MATRIX=$(ask_subdomain "Synapse (matrix.${DOMAIN})" "$SUBDOMAIN_MATRIX")
        SUBDOMAIN_ELEMENT=$(ask_subdomain "Element Web (element.${DOMAIN})" "$SUBDOMAIN_ELEMENT")
        SUBDOMAIN_NTFY=$(ask_subdomain "ntfy (ntfy.${DOMAIN})" "$SUBDOMAIN_NTFY")
        log "Кастомные поддомены: matrix=${SUBDOMAIN_MATRIX}, element=${SUBDOMAIN_ELEMENT}, ntfy=${SUBDOMAIN_NTFY}"
    fi

    SERVER_IP=$(ask "Публичный IP сервера" "")
    HOMESERVER=$(ask "Реализация homeserver" "synapse")

    # Путь хранения данных
    divider
    info "Все данные (БД, медиафайлы, конфиги) хранятся на хосте"
    info "По умолчанию: ${BOLD}/matrix${NC} - можно указать отдельный диск/раздел"
    echo ""

    DATA_PATH="/matrix"
    if ask_yn "Изменить путь хранения данных?" "n"; then
        DATA_PATH=$(ask "Абсолютный путь (например /mnt/data/matrix)" "/matrix")
        DATA_PATH="${DATA_PATH%/}"
        if [[ -z "$DATA_PATH" || "$DATA_PATH" != /* ]]; then
            warn "Путь должен быть абсолютным. Используется /matrix"
            DATA_PATH="/matrix"
        fi
    fi

    # Генерируем секреты
    divider
    info "Генерация секретов..."
    SECRET_KEY=$(gen_secret 64)
    POSTGRES_PASS=$(gen_secret 48)

    echo -e "  Секретный ключ:    ${DIM}${SECRET_KEY:0:16}...${NC} (сгенерирован)"
    echo -e "  Пароль PostgreSQL: ${DIM}${POSTGRES_PASS:0:16}...${NC} (сгенерирован)"

    if ask_yn "Задать секреты вручную?" "n"; then
        custom_secret=$(ask_secret "Секретный ключ (matrix_homeserver_generic_secret_key)" "")
        [[ -n "$custom_secret" ]] && SECRET_KEY="$custom_secret"

        custom_pg=$(ask_secret "Пароль PostgreSQL" "")
        [[ -n "$custom_pg" ]] && POSTGRES_PASS="$custom_pg"
    fi

    # =============================================================================
    # 2. Reverse Proxy
    # =============================================================================
    header "2/12  Reverse Proxy"

    info "Два режима работы:"
    info ""
    info "  ${BOLD}1) nginx → Traefik${NC} ${GREEN}(рекомендуется)${NC}"
    info "     nginx терминирует SSL (certbot), Traefik - внутренний роутер"
    info "     Admin-панели на скрытых портах, кастомные страницы ошибок,"
    info "     landing page, полный контроль над конфигом"
    info ""
    info "  ${BOLD}2) Traefik-only${NC}"
    info "     Traefik сам управляет SSL (ACME). Минимум настроек,"
    info "     но admin-панели только через пути/поддомены"
    echo ""

    USE_NGINX=true
    if ! ask_yn "Использовать nginx + Traefik?" "y"; then
        USE_NGINX=false
    fi

    # =============================================================================
    # 3. Сеть и доступ
    # =============================================================================
    header "3/12  Сеть и доступ"

    # --- Федерация ---
    info "Федерация - связь с пользователями на ${BOLD}других${NC} Matrix-серверах"
    info "Без неё сервер работает как закрытый корпоративный мессенджер"
    echo ""

    FEDERATION_ENABLED=true
    FEDERATION_WHITELIST=""
    FEDERATION_BLACKLIST=""

    if ! ask_yn "Включить федерацию?" "y"; then
        FEDERATION_ENABLED=false
    else
        # Whitelist / Blacklist
        divider
        info "${BOLD}Фильтрация федерации${NC} - ограничение связи с другими серверами"
        info ""
        info "  ${BOLD}Whitelist${NC} - разрешить федерацию ${GREEN}только${NC} с указанными серверами"
        info "  ${BOLD}Blacklist${NC} - заблокировать конкретные серверы (остальные разрешены)"
        info "  Оба пустые - федерация со всеми (по умолчанию)"
        echo ""

        if ask_yn "Настроить фильтрацию федерации?" "n"; then
            info "Whitelist - ${BOLD}только эти${NC} серверы смогут взаимодействовать"
            info "Введи домены через пробел (или пусто чтобы пропустить)"
            info "Пример: ${DIM}matrix.org mozilla.org gitter.im${NC}"
            FEDERATION_WHITELIST=$(ask "Whitelist" "")

            if [[ -z "$FEDERATION_WHITELIST" ]]; then
                echo ""
                info "Blacklist - эти серверы будут ${RED}заблокированы${NC}"
                info "Введи домены через пробел (или пусто чтобы пропустить)"
                info "Пример: ${DIM}evil.server.com spam.domain.net${NC}"
                FEDERATION_BLACKLIST=$(ask "Blacklist" "")
            else
                info "${DIM}Blacklist пропущен (whitelist уже задан)${NC}"
            fi
        fi
    fi

    divider

    # --- Гостевой доступ ---
    info "Гостевой доступ позволяет участвовать в звонках без аккаунта"
    info "Гости ${BOLD}не могут${NC} писать сообщения - только звонки"
    echo ""

    GUEST_ACCESS=false
    if ask_yn "Разрешить гостевой доступ?" "n"; then
        GUEST_ACCESS=true
    fi

    divider

    # --- Редирект matrix.domain → element.domain ---
    info "По умолчанию ${BOLD}matrix.${DOMAIN}${NC} перенаправляет на ${BOLD}element.${DOMAIN}${NC}"
    info "Корень Synapse - JSON API, бесполезен в браузере"
    echo ""

    MATRIX_ROOT_REDIRECT=true
    if ! ask_yn "Редирект matrix.${DOMAIN} → element.${DOMAIN}?" "y"; then
        MATRIX_ROOT_REDIRECT=false
    fi

    # =============================================================================
    # 4. Аутентификация
    # =============================================================================
    header "4/12  Аутентификация"

    MAS_ENABLED=false
    MAS_ENCRYPTION_SECRET=""
    MAS_REGISTRATION_ENABLED=false
    MAS_EMAIL_REQUIRED=false
    MAS_TOKEN_REQUIRED=false
    MAS_TOS_URI=""
    MAS_ADMIN_API=false
    REGISTRATION=false
    OPEN_REGISTRATION=false
    ELEMENT_ADMIN_ENABLED=false
    ELEMENT_ADMIN_PORT=""
    WELCOME_ROOM_ENABLED=false
    WELCOME_ROOM_ALIAS=""
    WELCOME_ROOM_CREATOR=""

    # --- MAS ---
    info "Matrix Authentication Service (MAS) - OIDC-провайдер"
    info "Необходим для ${BOLD}Element X${NC} (новый клиент)"
    info "Заменяет встроенную аутентификацию Synapse на OIDC"
    info "Регистрация и логин управляются через MAS"
    echo ""

    if ask_yn "Включить MAS (обязательно для Element X)?" "y"; then
        MAS_ENABLED=true
        MAS_ENCRYPTION_SECRET=$(openssl rand -hex 32 2>/dev/null || gen_secret 64)

        divider

        # --- Регистрация через MAS ---
        info "Регистрация новых пользователей через MAS"
        info "По умолчанию регистрация ${BOLD}закрыта${NC} - аккаунты создаёт администратор через CLI:"
        info "  ${DIM}mas-cli manage register-user USERNAME -p PASSWORD${NC}"
        echo ""

        if ask_yn "Разрешить самостоятельную регистрацию?" "n"; then
            MAS_REGISTRATION_ENABLED=true

            echo ""
            info "Email при регистрации:"
            info "  ${BOLD}Да${NC}  - пользователь должен подтвердить email (нужен SMTP)"
            info "  ${BOLD}Нет${NC} - регистрация без email"
            echo ""

            if ask_yn "Требовать email при регистрации?" "n"; then
                MAS_EMAIL_REQUIRED=true
            fi

            echo ""
            info "Пригласительный токен при регистрации:"
            info "  Создание: ${BOLD}mas-cli manage issue-user-registration-token${NC}"
            echo ""

            if ask_yn "Требовать пригласительный токен?" "y"; then
                MAS_TOKEN_REQUIRED=true
            fi
        fi

        divider

        # --- ToS ---
        info "Terms of Service - чекбокс на странице регистрации MAS"
        info "Пользователь должен принять условия для создания аккаунта"
        echo ""

        if ask_yn "Включить ToS при регистрации?" "n"; then
            MAS_TOS_URI=$(ask_url "URL страницы Terms of Service" "https://matrix.${DOMAIN}/tos")
        fi

        # MAS Admin API (auto-enable)
        MAS_ADMIN_API=true

    else
        divider

        # --- Регистрация через Synapse (без MAS) ---
        info "Регистрация без MAS управляется через Synapse напрямую"
        info "По умолчанию регистрация ${BOLD}закрыта${NC} - аккаунты создаёт администратор через CLI"
        echo ""

        if ask_yn "Включить регистрацию по пригласительным токенам?" "n"; then
            REGISTRATION=true
        else
            echo ""
            warn "${RED}⚠ ВНИМАНИЕ:${NC} открытая регистрация без верификации - ${RED}магнит для спама!${NC}"
            warn "Любой сможет создать аккаунт без ограничений."
            warn "Рекомендуется только для закрытых/тестовых серверов."
            echo ""
            if ask_yn "Открытая регистрация БЕЗ верификации?" "n"; then
                OPEN_REGISTRATION=true
            fi
        fi
    fi

    divider

    # --- Welcome Room ---
    info "Автоматическое приглашение в welcome-комнату при регистрации"
    info "Новые пользователи получат инвайт с правилами и инструкциями"
    echo ""

    if ask_yn "Включить welcome-комнату?" "n"; then
        WELCOME_ROOM_ENABLED=true
        WELCOME_ROOM_ALIAS=$(ask "Alias комнаты" "#welcome:${DOMAIN}")
        WELCOME_ROOM_CREATOR=$(ask "Localpart создателя комнаты (например: admin)" "admin")
    fi

    # =============================================================================
    # 5. Сервисы
    # =============================================================================
    header "5/12  Сервисы"

    CALLS_ENABLED=false
    LIVEKIT_RTC_TCP=""
    LIVEKIT_RTC_UDP=""
    LIVEKIT_TURN_TLS=""
    LIVEKIT_TURN_UDP=""
    SYNAPSE_ADMIN=false
    SYNAPSE_ADMIN_PATH=""
    SYNAPSE_ADMIN_PORT=""
    SYNAPSE_ADMIN_ON_PORT=false
    COTURN=false
    RANDOMIZE_COTURN_PORTS=false
    COTURN_STUN_PORT=""
    COTURN_TURNS_PORT=""
    COTURN_RELAY_MIN=""
    COTURN_RELAY_MAX=""
    NTFY=false
    SYNAPSE_AUTO_COMPRESSOR=false
    MEDIA_REPO=false

    # --- Звонки (LiveKit) ---
    info "Звонки через ${BOLD}LiveKit${NC} - аудио/видео прямо из Element Web"
    info "LiveKit SFU (медиа-сервер) запускается на: ${BOLD}matrix.${DOMAIN}${NC}"
    echo ""

    if ask_yn "Включить аудио/видео звонки?" "y"; then
        CALLS_ENABLED=true

        divider

        # --- Настройка портов LiveKit ---
        info "По умолчанию LiveKit использует стандартные порты:"
        info "  ICE/TCP: ${BOLD}7881${NC}, ICE/UDP: ${BOLD}7882${NC}, TURN/TLS: ${BOLD}5349${NC}, TURN/UDP: ${BOLD}3478${NC}"
        echo ""
        info "Рандомизация портов затрудняет обнаружение сервиса при сканировании"
        warn "От DPI это ${RED}не защищает${NC} - DPI анализирует содержимое, а не номер порта"
        echo ""

        if [[ "$RANDOM_PORTS" == true ]]; then
            # Неинтерактивный режим: генерируем уникальные порты в dynamic-диапазоне
            # через общий хелпер. Те же порты будут в prepare_server.sh --random-ports.
            _used=""
            for _var in LIVEKIT_RTC_TCP LIVEKIT_RTC_UDP LIVEKIT_TURN_TLS LIVEKIT_TURN_UDP; do
                port=$(gen_dynamic_port "" "" "$_used") || {
                    err "Не удалось сгенерировать уникальный $_var (диапазон слишком узкий?)"
                    exit 1
                }
                printf -v "$_var" '%s' "$port"
                _used+=" $port"
            done
            info "--random-ports: сгенерированы уникальные порты в dynamic-диапазоне"
        elif ask_yn "Рандомизировать порты LiveKit?" "y"; then
            # Генерируем 4 уникальных случайных порта (10000-49999)
            LIVEKIT_RTC_TCP=$((RANDOM % 40000 + 10000))
            LIVEKIT_RTC_UDP=$((RANDOM % 40000 + 10000))
            while [[ "$LIVEKIT_RTC_UDP" == "$LIVEKIT_RTC_TCP" ]]; do
                LIVEKIT_RTC_UDP=$((RANDOM % 40000 + 10000))
            done
            LIVEKIT_TURN_TLS=$((RANDOM % 40000 + 10000))
            while [[ "$LIVEKIT_TURN_TLS" == "$LIVEKIT_RTC_TCP" || "$LIVEKIT_TURN_TLS" == "$LIVEKIT_RTC_UDP" ]]; do
                LIVEKIT_TURN_TLS=$((RANDOM % 40000 + 10000))
            done
            LIVEKIT_TURN_UDP=$((RANDOM % 40000 + 10000))
            while [[ "$LIVEKIT_TURN_UDP" == "$LIVEKIT_RTC_TCP" || "$LIVEKIT_TURN_UDP" == "$LIVEKIT_RTC_UDP" || "$LIVEKIT_TURN_UDP" == "$LIVEKIT_TURN_TLS" ]]; do
                LIVEKIT_TURN_UDP=$((RANDOM % 40000 + 10000))
            done

            info "Сгенерированы порты (можно изменить):"
            LIVEKIT_RTC_TCP=$(ask_port "ICE/TCP порт" "$LIVEKIT_RTC_TCP")
            LIVEKIT_RTC_UDP=$(ask_port "ICE/UDP порт" "$LIVEKIT_RTC_UDP")
            LIVEKIT_TURN_TLS=$(ask_port "TURN/TLS порт" "$LIVEKIT_TURN_TLS")
            LIVEKIT_TURN_UDP=$(ask_port "TURN/UDP порт" "$LIVEKIT_TURN_UDP")
        else
            LIVEKIT_RTC_TCP=$(ask_port "ICE/TCP порт" "7881")
            LIVEKIT_RTC_UDP=$(ask_port "ICE/UDP порт" "7882")
            LIVEKIT_TURN_TLS=$(ask_port "TURN/TLS порт" "5349")
            LIVEKIT_TURN_UDP=$(ask_port "TURN/UDP порт" "3478")
        fi

        echo ""
        info "Порты LiveKit:"
        echo -e "    ICE/TCP:  ${BOLD}${LIVEKIT_RTC_TCP}${NC}"
        echo -e "    ICE/UDP:  ${BOLD}${LIVEKIT_RTC_UDP}${NC}"
        echo -e "    TURN/TLS: ${BOLD}${LIVEKIT_TURN_TLS}${NC}"
        echo -e "    TURN/UDP: ${BOLD}${LIVEKIT_TURN_UDP}${NC}"
    fi

    divider

    # --- Ketesa (Admin Panel) ---
    info "Ketesa - ${BOLD}веб-панель управления${NC} сервером"
    info "Пользователи, комнаты, медиа, статистика"
    echo ""

    if ask_yn "Включить Ketesa (admin panel)?" "y"; then
        SYNAPSE_ADMIN=true

        if [[ "$USE_NGINX" == true ]]; then
            divider
            info "Варианты доступа к Ketesa:"
            info "  ${BOLD}1)${NC} По пути: matrix.${DOMAIN}${BOLD}/admin${NC}"
            info "  ${BOLD}2)${NC} На отдельном порту: matrix.${DOMAIN}${BOLD}:PORT${NC} (скрыт от сканеров)"
            echo ""

            if ask_yn "Вынести на отдельный порт (рекомендуется)?" "y"; then
                SYNAPSE_ADMIN_ON_PORT=true
                SYNAPSE_ADMIN_PORT=$((RANDOM % 40000 + 10000))
                SYNAPSE_ADMIN_PORT=$(ask_port "Порт для Ketesa (через nginx)" "$SYNAPSE_ADMIN_PORT")

                info "Ketesa: ${BOLD}https://matrix.${DOMAIN}:${SYNAPSE_ADMIN_PORT}/${NC}"
                info "Потребуется настройка nginx (см. prepare-server.sh)"
            else
                info "Путь по умолчанию: ${BOLD}/admin${NC}"
                info "Можно изменить для безопасности (например: /my-secret-admin)"
                SYNAPSE_ADMIN_PATH=$(ask "Путь Ketesa" "/admin")
            fi
        else
            # Traefik-only: только путь (без порта)
            info "Путь по умолчанию: ${BOLD}matrix.${DOMAIN}/admin${NC}"
            info "Можно изменить для безопасности (например: /my-secret-admin)"
            SYNAPSE_ADMIN_PATH=$(ask "Путь Ketesa" "/admin")

            info "Ketesa: ${BOLD}https://matrix.${DOMAIN}${SYNAPSE_ADMIN_PATH}${NC}"
        fi
    fi

    divider

    # --- Element Admin ---
    info "Element Admin - ${BOLD}современная панель управления${NC} сервером"
    info "Работает через MAS Admin API (требует MAS)"
    echo ""

    if [[ "$MAS_ENABLED" == true ]]; then
        if ask_yn "Включить Element Admin?" "n"; then
            ELEMENT_ADMIN_ENABLED=true
            MAS_ADMIN_API=true

            if [[ "$USE_NGINX" == true ]]; then
                # nginx режим: порт через nginx
                ELEMENT_ADMIN_PORT=$((RANDOM % 40000 + 10000))
                ELEMENT_ADMIN_PORT=$(ask_port "Порт для Element Admin (через nginx)" "$ELEMENT_ADMIN_PORT")

                info "Element Admin: ${BOLD}https://matrix.${DOMAIN}:${ELEMENT_ADMIN_PORT}/${NC}"
                info "Потребуется настройка nginx (см. prepare-server.sh)"
            else
                # Traefik-only: поддомен (по умолчанию admin.element.DOMAIN)
                info "По умолчанию: ${BOLD}admin.element.${DOMAIN}${NC}"
                info "Element Admin: ${BOLD}https://admin.element.${DOMAIN}/${NC}"
            fi
        fi
    else
        info "${DIM}Element Admin требует MAS - пропущено${NC}"
    fi

    divider

    # --- Coturn ---
    info "Coturn (TURN/STUN) - помогает установить звонки через NAT и файрвол"
    info "Без него звонки могут ${RED}не работать${NC} у части пользователей"
    echo ""

    if ask_yn "Включить Coturn?" "y"; then
        COTURN=true

        divider

        info "Coturn по умолчанию использует стандартные порты:"
        info "  STUN/TURN: ${BOLD}3478${NC} (TCP+UDP), TURNS: ${BOLD}5349${NC} (TCP+UDP)"
        info "  Relay UDP: ${BOLD}49152-49172${NC}"
        info "Рандомизация затрудняет обнаружение при сканировании портов"
        echo ""

        if ask_yn "Рандомизировать порты Coturn?" "n"; then
            RANDOMIZE_COTURN_PORTS=true
            COTURN_STUN_PORT=$((RANDOM % 50000 + 10000))
            COTURN_TURNS_PORT=$((RANDOM % 50000 + 10000))
            # Relay range - 20 последовательных портов из случайного начала
            COTURN_RELAY_MIN=$((RANDOM % 40000 + 10000))
            COTURN_RELAY_MAX=$((COTURN_RELAY_MIN + 20))

            # Уникальность stun vs turns
            while [[ "$COTURN_TURNS_PORT" == "$COTURN_STUN_PORT" ]]; do
                COTURN_TURNS_PORT=$((RANDOM % 50000 + 10000))
            done

            info "Порты Coturn:"
            echo -e "    STUN/TURN: ${BOLD}${COTURN_STUN_PORT}${NC} (TCP+UDP)"
            echo -e "    TURNS:     ${BOLD}${COTURN_TURNS_PORT}${NC} (TCP+UDP)"
            echo -e "    Relay UDP: ${BOLD}${COTURN_RELAY_MIN}-${COTURN_RELAY_MAX}${NC}"
        fi
    fi

    divider

    # --- ntfy ---
    info "ntfy - ${BOLD}push-уведомления${NC} для Android через UnifiedPush"
    info "Заменяет Google FCM для приватных push-уведомлений: ${BOLD}${SUBDOMAIN_NTFY}${NC}"
    echo ""

    if ask_yn "Включить ntfy?" "y"; then
        NTFY=true

        # --- Тюнинг доставки push-уведомлений ---
        divider
        info "Тюнинг доставки (если не уверен - оставь дефолты):"
        echo ""

        # auth_default_access: для UnifiedPush нужно разрешить анонимным клиентам
        # подписываться (read). Self-hosted обычно ставят read-write или write-only.
        # deny-all сломает UnifiedPush на Android.
        info "Политика доступа по умолчанию (для анонимных UnifiedPush-клиентов):"
        info "  ${DIM}read-write${NC}  - любой может читать И публиковать (нужно для UP-дистрибутора)"
        info "  ${DIM}write-only${NC} - только публиковать (только push-доставка, не подходит для UP-чтения)"
        info "  ${DIM}read-only${NC}  - только читать (нельзя слать уведомления с сервера)"
        info "  ${DIM}deny-all${NC}   - никому (сломает UnifiedPush, только для приватных инсталлов)"
        echo ""
        NTFY_AUTH=$(ask "  auth-default-access" "read-write")
        case "$NTFY_AUTH" in
            read-write | write-only | read-only | deny-all) ;;
            *)
                warn "Неизвестное значение '$NTFY_AUTH', использую read-write"
                NTFY_AUTH="read-write"
                ;;
        esac

        # cache_duration: сколько держать сообщения для оффлайн-подписчиков
        info "Как долго хранить сообщения для оффлайн-клиентов (повышает шанс доставки):"
        info "  ${DIM}12h${NC} (дефолт ntfy) / ${DIM}24h${NC} (рекомендую) / ${DIM}48h${NC} (WiFi-only сети)"
        NTFY_CACHE=$(ask "  cache-duration" "24h")

        # manager_interval: как часто проверять новые сообщения
        info "Интервал опроса новых сообщений (меньше = быстрее доставка, больше CPU):"
        info "  ${DIM}5s${NC} (дефолт) / ${DIM}2s${NC} (быстрее) / ${DIM}10s${NC} (экономичнее)"
        NTFY_MGR_INTERVAL=$(ask "  manager-interval" "2s")

        # keepalive_interval: для long-polling (по умолчанию 30s, снижаем для мобильных)
        NTFY_KEEPALIVE=$(ask "  keepalive-interval (long-poll)" "20s")

        # visitor_message_daily_limit: лимит на кол-во сообщений/день с анонимного IP
        # Дефолт ntfy = 100, для push-шлюза это мало, рекомендую 5000
        NTFY_VISITOR_MSG_LIMIT=$(ask "  visitor-message-daily-limit" "5000")

        # visitor_topics_limit: макс. число топиков на посетителя
        NTFY_VISITOR_TOPIC_LIMIT=$(ask "  visitor-topics-limit" "30")

        # upstream_base_url: если хочешь, чтобы твой ntfy мог fallback-ить на ntfy.sh
        # для глобальных топиков. Имеет смысл если хочешь доставлять пользователям
        # других ntfy-инстансов, но замедляет локальные сообщения.
        NTFY_UPSTREAM=$(ask "  upstream-base-url (пусто = без upstream)" "")

        # web app: удобный UI на ntfy.<domain>/app для тестирования
        if ask_yn "Включить веб-интерфейс ntfy (${SUBDOMAIN_NTFY}/app)?" "y"; then
            NTFY_WEB_ROOT="app"
        else
            NTFY_WEB_ROOT=""
        fi

        # --- Клиентская настройка (шпаргалка) ---
        echo ""
        info "Чтобы ${BOLD}Element Android/iOS${NC} начал получать push через ntfy:"
        echo -e "  ${DIM}1.${NC} Element Android → Settings → Notifications → ${BOLD}UnifiedPush: Force custom push gateway${NC}"
        echo -e "     URL: ${BOLD}https://${SUBDOMAIN_NTFY}${NC}"
        echo -e "  ${DIM}2.${NC} Element Android → Settings → Troubleshoot → ${BOLD}Troubleshoot notifications${NC}"
        echo -e "     Должен показать 'distributor: ntfy'"
        echo -e "  ${DIM}3.${NC} Проверить доставку: ${BOLD}https://${SUBDOMAIN_NTFY}/app${NC} (веб-интерфейс)"
        echo ""
        info "Подробнее: docs/TROUBLESHOOTING.md (раздел ntfy)"
    fi

    divider

    # --- Auto-Compressor ---
    info "Auto-Compressor - ${BOLD}сжимает историю${NC} состояний комнат в БД"
    info "Ускоряет работу сервера и уменьшает объём базы (рекомендуется)"
    echo ""

    if ask_yn "Включить Synapse Auto-Compressor?" "y"; then
        SYNAPSE_AUTO_COMPRESSOR=true
    fi

    # --- Media Repo ---
    if ask_yn "Matrix Media Repo (расширенное хранилище медиа, дедупликация)?" "n"; then
        MEDIA_REPO=true
    fi

    # =============================================================================
    # 6. Веб-клиент (Element Web)
    # =============================================================================
    header "6/12  Веб-клиент (Element Web)"

    info "Element Web - основной клиент, доступен на ${BOLD}element.${DOMAIN}${NC}"
    info "Задаём брендинг: название, тему, логотип, фоновую картинку, а также"
    info "политики регистрации и гостевого доступа."
    echo ""

    # Дефолт названия - capitalized первая метка домена + " Chat".
    # Для matrix.example.com → "Matrix Chat", для m.example.com → "M Chat".
    ELEMENT_BRAND_DEFAULT="$(awk -F. 'NF>=2 {print toupper(substr($1,1,1)) tolower(substr($1,2))} NF<2 {print toupper(substr($0,1,1)) tolower(substr($0,2))}' <<<"${DOMAIN%%.*}") Chat"
    ELEMENT_BRAND=$(ask "Название бренда (видно в заголовке вкладки и на странице входа)" "$ELEMENT_BRAND_DEFAULT")

    # Тема по умолчанию
    if ask_yn "Тёмная тема по умолчанию?" "n"; then
        ELEMENT_THEME="dark"
    else
        ELEMENT_THEME="light"
    fi

    # Регистрация
    if ask_yn "Показывать кнопку «Создать аккаунт» на странице входа?" "n"; then
        ELEMENT_REG_ENABLED=true
    else
        ELEMENT_REG_ENABLED=false
    fi

    # Логотип - пустая строка = стандартный Element
    ELEMENT_LOGO_URL=$(ask "URL своего логотипа для страницы входа (пусто - стандартный)" "")
    if [[ -n "$ELEMENT_LOGO_URL" && ! "$ELEMENT_LOGO_URL" =~ ^https?:// ]]; then
        warn "URL должен начинаться с http(s):// - оставляю стандартный логотип"
        ELEMENT_LOGO_URL=""
    fi

    # Фоновая картинка
    ELEMENT_BG_URL=$(ask "URL фоновой картинки (пусто - стандартная)" "")
    if [[ -n "$ELEMENT_BG_URL" && ! "$ELEMENT_BG_URL" =~ ^https?:// ]]; then
        warn "URL должен начинаться с http(s):// - оставляю стандартный фон"
        ELEMENT_BG_URL=""
    fi

    # Страна для телефонов (влияет только на маску ввода)
    ELEMENT_COUNTRY=$(ask "Код страны для телефонов (ISO 3166-1 alpha-2: RU, DE, GB...)" "GB")
    ELEMENT_COUNTRY="${ELEMENT_COUNTRY^^}" # в верхний регистр
    if [[ ! "$ELEMENT_COUNTRY" =~ ^[A-Z]{2}$ ]]; then
        warn "Код страны должен быть 2 буквы (ISO 3166-1) - ставлю GB"
        ELEMENT_COUNTRY="GB"
    fi

    # Гости
    if ask_yn "Разрешить гостевой доступ (вход без аккаунта)?" "n"; then
        ELEMENT_DISABLE_GUESTS=false
    else
        ELEMENT_DISABLE_GUESTS=true
    fi

    # Lab settings (экспериментальные фичи)
    if ask_yn "Показывать раздел Lab Settings (экспериментальные функции)?" "y"; then
        ELEMENT_LAB_SETTINGS=true
    else
        ELEMENT_LAB_SETTINGS=false
    fi

    # Bug report endpoint
    ELEMENT_BUG_URL=$(ask "URL для баг-репортов (пусто - element.io по умолчанию)" "")
    if [[ -n "$ELEMENT_BUG_URL" && ! "$ELEMENT_BUG_URL" =~ ^https?:// ]]; then
        warn "URL должен начинаться с http(s):// - оставляю дефолт"
        ELEMENT_BUG_URL=""
    fi

    # Footer links - обычно проставляют ссылки на ToS, который kit раздаёт
    # через шаблон templates/tos.html. Ссылка на /tos работает в любом режиме
    # (nginx, Traefik-only, playbook-managed).
    ELEMENT_FOOTER_LINKS="[]"
    if ask_yn "Добавить ссылки в подвал страницы входа (Условия использования, Приватность)?" "n"; then
        ELEMENT_FOOTER_LINKS=$(
            cat <<JSON
[
  {"text": "Условия использования", "url": "https://${DOMAIN}/tos"},
  {"text": "Политика конфиденциальности", "url": "https://${DOMAIN}/tos#privacy"},
  {"text": "Домой", "url": "https://${DOMAIN}/"}
]
JSON
        )
    fi

    log "Element Web: brand='${ELEMENT_BRAND}', theme=${ELEMENT_THEME}, registration=${ELEMENT_REG_ENABLED}"

    # =============================================================================
    # 7. Мосты (Bridges)
    # =============================================================================
    header "7/12  Мосты (Bridges)"

    info "Мосты связывают Matrix с другими мессенджерами"
    info "Пользователи смогут писать в Telegram, Discord и т.д. прямо из Matrix"
    echo ""

    declare -A BRIDGE_MAP=(
        ["Telegram (mautrix)"]="matrix_bridge_mautrix_telegram_enabled"
        ["Discord (mautrix)"]="matrix_bridge_mautrix_discord_enabled"
        ["WhatsApp (mautrix)"]="matrix_bridge_mautrix_whatsapp_enabled"
        ["Signal (mautrix)"]="matrix_bridge_mautrix_signal_enabled"
        ["Slack (mautrix)"]="matrix_bridge_mautrix_slack_enabled"
        ["Instagram (mautrix-meta)"]="matrix_bridge_mautrix_meta_instagram_enabled"
        ["Messenger (mautrix-meta)"]="matrix_bridge_mautrix_meta_messenger_enabled"
        ["Twitter (mautrix)"]="matrix_bridge_mautrix_twitter_enabled"
        ["Google Chat (mautrix)"]="matrix_bridge_mautrix_googlechat_enabled"
        ["Google Messages (mautrix)"]="matrix_bridge_mautrix_gmessages_enabled"
        ["Bluesky (mautrix)"]="matrix_bridge_mautrix_bluesky_enabled"
        ["LinkedIn (beeper)"]="matrix_bridge_beeper_linkedin_enabled"
        ["IRC (heisenbridge)"]="matrix_bridge_heisenbridge_enabled"
        ["IRC (appservice)"]="matrix_bridge_appservice_irc_enabled"
        ["Discord (appservice)"]="matrix_bridge_appservice_discord_enabled"
        ["Email (postmoogle)"]="matrix_bridge_postmoogle_enabled"
        ["Hookshot (GitHub/GitLab/JIRA)"]="matrix_bridge_hookshot_enabled"
        ["Steam"]="matrix_bridge_steam_enabled"
        ["WeChat"]="matrix_bridge_wechat_enabled"
        ["SMS"]="matrix_bridge_sms_enabled"
    )

    BRIDGE_NAMES=(
        "Telegram (mautrix)"
        "Discord (mautrix)"
        "WhatsApp (mautrix)"
        "Signal (mautrix)"
        "Slack (mautrix)"
        "Instagram (mautrix-meta)"
        "Messenger (mautrix-meta)"
        "Twitter (mautrix)"
        "Google Chat (mautrix)"
        "Google Messages (mautrix)"
        "Bluesky (mautrix)"
        "LinkedIn (beeper)"
        "IRC (heisenbridge)"
        "IRC (appservice)"
        "Discord (appservice)"
        "Email (postmoogle)"
        "Hookshot (GitHub/GitLab/JIRA)"
        "Steam"
        "WeChat"
        "SMS"
    )

    mapfile -t SELECTED_BRIDGES < <(ask_multi "Какие мосты включить?" "${BRIDGE_NAMES[@]}")

    if [[ ${#SELECTED_BRIDGES[@]} -gt 0 && "${SELECTED_BRIDGES[0]}" != "" ]]; then
        warn "ВАЖНО - компромисс безопасности: любой мост видит переписку в открытом виде"
        warn "  Бридж расшифровывает Matrix и шифрует в протокол мессенджера (и обратно) -"
        warn "  plaintext живёт в процессе бриджа на этом сервере. E2EE покрывает только"
        warn "  сегменты, 'сквозного' шифрования через мост не существует."
        warn "  Не бриджь чувствительные переписки (пиши их напрямую из приложения)"
        warn "  или выноси бридж на железо, которому доверяешь полностью (не VPS)."
    fi

    # =============================================================================
    # 8. Боты
    # =============================================================================
    header "8/12  Боты"

    info "Боты добавляют автоматизацию: модерация, напоминания, AI и т.д."
    echo ""

    declare -A BOT_MAP=(
        ["Draupnir (модерация)"]="matrix_bot_draupnir_enabled"
        ["Mjolnir (модерация)"]="matrix_bot_mjolnir_enabled"
        ["Maubot (фреймворк плагинов)"]="matrix_bot_maubot_enabled"
        ["Reminder Bot (напоминания)"]="matrix_bot_matrix_reminder_bot_enabled"
        ["Registration Bot (токены регистрации)"]="matrix_bot_matrix_registration_bot_enabled"
        ["BaiBot (LLM / AI)"]="matrix_bot_baibot_enabled"
        ["Honoroit (helpdesk)"]="matrix_bot_honoroit_enabled"
        ["Buscarron (веб-формы в Matrix)"]="matrix_bot_buscarron_enabled"
        ["Go-NEB (универсальный бот)"]="matrix_bot_go_neb_enabled"
    )

    BOT_NAMES=(
        "Draupnir (модерация)"
        "Mjolnir (модерация)"
        "Maubot (фреймворк плагинов)"
        "Reminder Bot (напоминания)"
        "Registration Bot (токены регистрации)"
        "BaiBot (LLM / AI)"
        "Honoroit (helpdesk)"
        "Buscarron (веб-формы в Matrix)"
        "Go-NEB (универсальный бот)"
    )

    mapfile -t SELECTED_BOTS < <(ask_multi "Какие боты включить?" "${BOT_NAMES[@]}")

    # =============================================================================
    # 9. Email / SMTP
    # =============================================================================
    header "9/12  Email (SMTP)"

    info "Email нужен для ${BOLD}уведомлений${NC} о пропущенных сообщениях"
    info "и для ${BOLD}сброса паролей${NC} пользователей"
    echo ""

    SMTP_ENABLED=false
    SMTP_HOST=""
    SMTP_PORT=""
    SMTP_USER=""
    SMTP_PASS=""
    SMTP_FROM=""

    if ask_yn "Настроить отправку email?" "n"; then
        SMTP_ENABLED=true
        SMTP_HOST=$(ask "SMTP хост" "smtp.example.com")
        SMTP_PORT=$(ask_port "SMTP порт" "587")
        SMTP_USER=$(ask "SMTP пользователь" "")
        SMTP_PASS=$(ask_secret "SMTP пароль" "")
        SMTP_FROM=$(ask "Email отправителя" "matrix@${DOMAIN}")
    fi

    # =============================================================================
    # 10. Производительность и хранение
    # =============================================================================
    header "10/12  Производительность и хранение"

    # --- Размер загрузки ---
    info "Максимальный размер файла, который можно отправить в чат"
    echo ""
    MAX_UPLOAD=$(ask "Лимит загрузки файлов (МБ)" "100")

    divider

    # --- URL preview ---
    info "Предпросмотр ссылок - при отправке URL показывается заголовок и картинка"
    echo ""

    URL_PREVIEW=false
    if ask_yn "Включить предпросмотр ссылок?" "y"; then
        URL_PREVIEW=true
    fi

    divider

    # --- Retention: сообщения ---
    info "Retention - ${BOLD}автоматическое удаление${NC} старых сообщений"
    info "Экономит место на диске и соответствует политикам хранения данных"
    info "Рекомендуется 90 дней для большинства серверов"
    echo ""

    RETENTION_ENABLED=true
    RETENTION_DAYS="90"
    RETENTION_PURGE_INTERVAL="3h"

    if ask_yn "Включить retention (автоудаление сообщений)?" "y"; then
        RETENTION_DAYS=$(ask "Хранить сообщения (дней)" "90")
        RETENTION_PURGE_INTERVAL=$(ask "Интервал очистки (например 3h, 12h, 1d)" "3h")
    else
        RETENTION_ENABLED=false
    fi

    divider

    # --- Retention: медиа ---
    info "Отдельно можно удалять старые медиафайлы (фото, видео, документы)"
    info "  ${BOLD}Локальные${NC}  - загруженные вашими пользователями"
    info "  ${BOLD}Удалённые${NC}  - кешированные файлы с других серверов"
    echo ""

    MEDIA_RETENTION_LOCAL=""
    MEDIA_RETENTION_REMOTE=""

    if ask_yn "Автоудаление старых медиафайлов?" "n"; then
        MEDIA_RETENTION_LOCAL=$(ask "Хранить локальные медиа (например 180d, пусто = вечно)" "")
        MEDIA_RETENTION_REMOTE=$(ask "Хранить удалённые медиа (например 30d)" "30d")
    fi

    divider

    # --- Тонкая настройка ---
    info "Дополнительные параметры для опытных администраторов"
    echo ""

    WORKERS_ENABLED=false
    WORKERS_PRESET="little-federation-helper"
    PRESENCE_ENABLED=true
    LOG_LEVEL="WARNING"

    if ask_yn "Тонкая настройка производительности?" "n"; then

        divider
        info "${BOLD}Workers${NC} - распределение нагрузки по нескольким процессам"
        info "Рекомендуется для серверов с ${BOLD}50+ активных пользователей${NC}"
        echo ""

        if ask_yn "Включить Workers?" "n"; then
            WORKERS_ENABLED=true

            info "Пресеты:"
            info "  ${BOLD}1)${NC} little-federation-helper - ${GREEN}1 воркер${NC}, только федерация (для слабых VPS)"
            info "  ${BOLD}2)${NC} one-of-each             - ${YELLOW}12 воркеров${NC}, по одному каждого типа (4+ GB RAM)"
            info "  ${BOLD}3)${NC} specialized-workers      - ${RED}14 воркеров${NC}, максимум (8+ GB RAM)"
            echo ""

            while true; do
                _wp_choice=$(ask "Пресет [1/2/3]" "1")
                case "$_wp_choice" in
                    1 | little-federation-helper)
                        WORKERS_PRESET="little-federation-helper"
                        break
                        ;;
                    2 | one-of-each)
                        WORKERS_PRESET="one-of-each"
                        break
                        ;;
                    3 | specialized-workers)
                        WORKERS_PRESET="specialized-workers"
                        break
                        ;;
                    *) warn "Введи 1, 2 или 3" ;;
                esac
            done

            info "Выбран пресет: ${BOLD}${WORKERS_PRESET}${NC}"
        fi

        divider
        info "${BOLD}Presence${NC} - статусы «онлайн/оффлайн» пользователей"
        info "Отключение снижает нагрузку на сервер"
        echo ""

        if ! ask_yn "Показывать статус онлайн/оффлайн?" "y"; then
            PRESENCE_ENABLED=false
        fi

        divider
        info "Уровни логирования: ${BOLD}DEBUG${NC}, ${BOLD}INFO${NC}, ${BOLD}WARNING${NC}, ${BOLD}ERROR${NC}"
        echo ""
        info "Влияние на диск (примерно для 100 активных юзеров, в сутки):"
        info "  ${DIM}DEBUG${NC}     - 5-10 ГБ       (только для активной отладки)"
        info "  ${DIM}INFO${NC}      - 500 МБ - 1 ГБ (по умолчанию в upstream Synapse)"
        info "  ${BOLD}WARNING${NC}   - 50-100 МБ     (рекомендуется для прода)"
        info "  ${DIM}ERROR${NC}     - 5-20 МБ       (только ошибки)"
        echo ""
        info "WARNING - оптимально для продакшна, DEBUG - для отладки на 1-2 часа"
        echo ""
        info "После деплоя рекомендую поставить ${BOLD}bash tools/logrotate-matrix.sh${NC}"
        info "  - это настроит ротацию для /var/log/matrix/* и /var/log/nginx/*"
        echo ""

        LOG_LEVEL=$(ask "Уровень логирования Synapse" "WARNING")
        LOG_LEVEL="${LOG_LEVEL^^}" # принудительно UPPERCASE (Python 3.13+)

        # =============================================================================
        # 11. Безопасность и защита от DPI
        # =============================================================================
        header "11/12  Безопасность и защита от цензуры"

        info "В некоторых странах DPI (Deep Packet Inspection) блокирует"
        info "нестандартный трафик. Эти настройки помогут защитить сервер."
        echo ""

        # --- TLS 1.3 ---
        TLS13_ONLY=false
        info "${BOLD}TLS 1.3${NC} - минимум метаданных, устойчивость к перехвату"
        info "Отключает устаревшие TLS 1.0/1.1/1.2 для всех веб-сервисов"
        info "Безопасно для ${BOLD}современных клиентов${NC}, может сломать старые браузеры"
        echo ""

        if ask_yn "Принудительно TLS 1.3 (рекомендуется для безопасности)?" "y"; then
            TLS13_ONLY=true
        fi

        divider

        # --- HSTS Preload ---
        HSTS_PRELOAD=false
        info "${BOLD}HSTS Preload${NC} - запрещает браузерам обращаться по HTTP"
        info "Домен попадает в список предзагрузки Chrome/Firefox/Safari"
        info "После включения ${RED}сложно отключить${NC} - домен закрепляется как HTTPS-only"
        echo ""

        if ask_yn "Включить HSTS Preload?" "n"; then
            HSTS_PRELOAD=true
        fi

        divider

        # --- Federation на порт 443 ---
        FED_ON_443=false
        info "${BOLD}Federation на порт 443${NC} - маскирует federation под обычный HTTPS"
        info "По умолчанию federation использует порт 8448, который легко обнаружить"
        info "Перенос на 443 позволяет пропускать трафик через ${BOLD}Cloudflare CDN${NC}"
        echo ""

        if ask_yn "Перенести federation на порт 443?" "n"; then
            FED_ON_443=true
        fi

        divider

        # --- Cloudflare ---
        CLOUDFLARE_ENABLED=false
        CF_EMAIL=""
        CF_ZONE_TOKEN=""
        CF_DNS_TOKEN=""

        info "${BOLD}Cloudflare proxy${NC} - скрывает реальный IP сервера"
        info "Защита от DDoS, кеширование, маскировка от сканеров"
        info "Требует: домен на Cloudflare, API-токены для DNS challenge"
        echo ""

        if ask_yn "Настроить Cloudflare DNS challenge (для SSL-сертификатов)?" "n"; then
            CLOUDFLARE_ENABLED=true
            CF_EMAIL=$(ask "Cloudflare email" "")
            CF_ZONE_TOKEN=$(ask_secret "CF_ZONE_API_TOKEN" "")
            CF_DNS_TOKEN=$(ask_secret "CF_DNS_API_TOKEN" "")
        fi

        # =============================================================================
        # 12. Бэкап и обслуживание
        # =============================================================================
        header "12/12  Бэкап"

        info "Встроенный сервис автоматического бэкапа PostgreSQL"
        info "Создаёт ежедневные дампы БД в ${BOLD}${DATA_PATH}/postgres-backup/${NC}"
        info "Без бэкапа потеря данных при сбое ${RED}невосстановима${NC}"
        echo ""

        POSTGRES_BACKUP=false
        if ask_yn "Включить автоматический бэкап PostgreSQL?" "y"; then
            POSTGRES_BACKUP=true
        fi

    fi # закрытие if "Тонкая настройка производительности?" (line 1240)

fi # закрытие if SKIP_WIZARD (line 372)

# =============================================================================
# Генерация vars.yml
# =============================================================================

# Определяем путь вывода (нужен в обоих режимах - интерактивном и env-file)
if [[ -z "$OUTPUT_FILE" ]]; then
    HOST_DIR="${PLAYBOOK_ROOT}/inventory/host_vars/matrix.${DOMAIN}"
    mkdir -p "$HOST_DIR"
    OUTPUT_FILE="${HOST_DIR}/vars.yml"
fi

# Для dry-run пишем во временный файл
if [[ "$DRY_RUN" == true ]]; then
    OUTPUT_FILE=$(mktemp /tmp/matrix-vars-XXXXXX.yml)
    trap 'rm -f "${OUTPUT_FILE:-}"' EXIT
fi

# Убеждаемся что директория существует
mkdir -p "$(dirname "$OUTPUT_FILE")"

if [[ "${SKIP_WIZARD:-false}" != "true" ]]; then
    header "Генерация vars.yml"
fi

# --- Основной блок ---
# В non-interactive режиме часть переменных может быть не задана - выключаем
# проверку unbound variables на время генерации. В интерактивном режиме все
# они определены (wizard отработал), set -u остаётся как был.
if [[ "${SKIP_WIZARD:-false}" == "true" ]]; then
    set +u
fi
cat >"$OUTPUT_FILE" <<VARSEOF
# Matrix Server - ${DOMAIN}
---
# =============================================================================
# Matrix Server - ${DOMAIN}
# Сгенерировано: $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================


# -----------------------------------------------------------------------------
# Playbook migration validation
# -----------------------------------------------------------------------------
# Авто-подвязка validated к expected: playbook не падает на pre-flight при
# breaking change'ах. Если хочешь читать CHANGELOG при каждом апдейте -
# замени на конкретную версию (например: v2026.05.18.0).
matrix_playbook_migration_validated_version: "{{ matrix_playbook_migration_expected_version }}"


# -----------------------------------------------------------------------------
# Домен и homeserver
# -----------------------------------------------------------------------------

matrix_domain: ${DOMAIN}
matrix_homeserver_implementation: ${HOMESERVER}

# Кастомные поддомены (если переопределялись в секции 1/12 wizard'а).
# По умолчанию плейбук ставит matrix.${DOMAIN}, element.${DOMAIN} и т.д.
# Эти переменные переопределяют их, если задано явно.
# LiveKit не использует отдельный поддомен - path-routing через matrix.DOMAIN
# (см. README раздел "Структура" и комментарии в generate_vars.sh)
matrix_server_fqn_matrix: ${SUBDOMAIN_MATRIX}
matrix_server_fqn_element: ${SUBDOMAIN_ELEMENT}
matrix_server_fqn_ntfy: ${SUBDOMAIN_NTFY}

# Секрет для генерации остальных секретов (НЕЛЬЗЯ менять после деплоя!)
matrix_homeserver_generic_secret_key: '${SECRET_KEY}'


# -----------------------------------------------------------------------------
# Element Web - брендинг (из секции 6/12 wizard'а)
# -----------------------------------------------------------------------------
matrix_client_element_brand: "${ELEMENT_BRAND}"
matrix_client_element_default_theme: "${ELEMENT_THEME}"
matrix_client_element_registration_enabled: ${ELEMENT_REG_ENABLED}
matrix_client_element_default_country_code: "${ELEMENT_COUNTRY}"
matrix_client_element_disable_guests: ${ELEMENT_DISABLE_GUESTS}
matrix_client_element_show_lab_settings: ${ELEMENT_LAB_SETTINGS}
VARSEOF

# Условные блоки Element Web (выходим из heredoc, пишем cat >>)
if [[ -n "$ELEMENT_LOGO_URL" ]]; then
    cat >>"$OUTPUT_FILE" <<EOF
matrix_client_element_welcome_logo: "${ELEMENT_LOGO_URL}"
matrix_client_element_branding_auth_header_logo_url: "${ELEMENT_LOGO_URL}"

EOF
fi

if [[ -n "$ELEMENT_BG_URL" ]]; then
    cat >>"$OUTPUT_FILE" <<EOF
matrix_client_element_branding_welcome_background_url: "${ELEMENT_BG_URL}"

EOF
else
    # Фикс null welcome background из upstream'а: дефолт ~ → JSON null →
    # <img src="null"> → 404. Подкладываем валидный bundled URL.
    cat >>"$OUTPUT_FILE" <<EOF
matrix_client_element_branding_welcome_background_url: "themes/element/img/backgrounds/lake.jpg"

EOF
fi

if [[ -n "$ELEMENT_BUG_URL" ]]; then
    cat >>"$OUTPUT_FILE" <<EOF
matrix_client_element_bug_report_endpoint_url: "${ELEMENT_BUG_URL}"

EOF
fi

cat >>"$OUTPUT_FILE" <<EOF
matrix_client_element_branding_auth_footer_links: ${ELEMENT_FOOTER_LINKS}
EOF

# Возвращаемся в основной heredoc для остальных секций
cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# PostgreSQL
# -----------------------------------------------------------------------------

postgres_connection_password: '${POSTGRES_PASS}'


# -----------------------------------------------------------------------------
# Хранение данных
# -----------------------------------------------------------------------------
VARSEOF

if [[ "$DATA_PATH" != "/matrix" ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF

# Кастомный путь хранения данных (по умолчанию /matrix)
matrix_base_data_path: ${DATA_PATH}
VARSEOF
else
    cat >>"$OUTPUT_FILE" <<VARSEOF

# По умолчанию данные хранятся в /matrix (bind mounts на хосте)
# Для изменения раскомментируй:
# matrix_base_data_path: /matrix
VARSEOF
fi

cat >>"$OUTPUT_FILE" <<VARSEOF

# Структура каталогов (создаётся автоматически):
#   <base_path>/synapse/config     - конфиг Synapse
#   <base_path>/synapse/storage    - медиафайлы
#   <base_path>/postgres/data      - база данных PostgreSQL
#   <base_path>/coturn             - данные TURN сервера
#   <base_path>/traefik            - конфиг Traefik
#   <base_path>/static-files       - .well-known и т.д.


# -----------------------------------------------------------------------------
# Reverse Proxy
# -----------------------------------------------------------------------------
VARSEOF

if [[ "$USE_NGINX" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF

# nginx на хосте фронтит внутренний Traefik
matrix_playbook_reverse_proxy_type: playbook-managed-traefik
matrix_playbook_ssl_enabled: true

# Отключаем SSL в Traefik (nginx + certbot занимаются терминацией)
traefik_config_entrypoint_web_secure_enabled: false
traefik_certs_dumper_enabled: false

# Traefik слушает только на localhost
traefik_container_web_host_bind_port: '127.0.0.1:81'
traefik_config_entrypoint_web_forwardedHeaders_insecure: true

# Federation entrypoint
matrix_playbook_public_matrix_federation_api_traefik_entrypoint_host_bind_port: '127.0.0.1:8449'
matrix_playbook_public_matrix_federation_api_traefik_entrypoint_config_http3_enabled: false
matrix_playbook_public_matrix_federation_api_traefik_entrypoint_config_custom:
  forwardedHeaders:
    insecure: true
VARSEOF
else
    cat >>"$OUTPUT_FILE" <<VARSEOF

# Traefik управляется плейбуком (SSL через Let's Encrypt)
matrix_playbook_reverse_proxy_type: playbook-managed-traefik
VARSEOF
fi

cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# IPv6
# -----------------------------------------------------------------------------

devture_systemd_docker_base_ipv6_enabled: true


# -----------------------------------------------------------------------------
# Заглушка на bare domain (${DOMAIN})
# -----------------------------------------------------------------------------
# Показывает страницу-заглушку + раздаёт .well-known/matrix для делегации

matrix_static_files_container_labels_base_domain_enabled: true
matrix_static_files_container_labels_base_domain_traefik_hostname: "{{ matrix_domain }}"


# -----------------------------------------------------------------------------
# Сеть и доступ
# -----------------------------------------------------------------------------
VARSEOF

if [[ "$FEDERATION_ENABLED" == false ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF

# Федерация отключена - сервер работает как изолированный мессенджер
matrix_homeserver_federation_enabled: false
VARSEOF
else
    # Federation whitelist
    if [[ -n "$FEDERATION_WHITELIST" ]]; then
        {
            echo ""
            echo "# Федерация - whitelist (только эти серверы разрешены)"
            echo "matrix_synapse_federation_domain_whitelist:"
            for _domain in $FEDERATION_WHITELIST; do
                echo "  - '${_domain}'"
            done
        } >>"$OUTPUT_FILE"
    fi

fi

if [[ "$MAS_ENABLED" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF

# Регистрация управляется через MAS (matrix_authentication_service)
# matrix_synapse_enable_registration: true  # нельзя с MAS
VARSEOF
elif [[ "$REGISTRATION" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF

# Регистрация по пригласительным токенам (управление: Ketesa)
matrix_synapse_enable_registration: true
matrix_synapse_registration_requires_token: true
VARSEOF
elif [[ "$OPEN_REGISTRATION" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF

# ВНИМАНИЕ: открытая регистрация без верификации!
matrix_synapse_enable_registration: true
matrix_synapse_enable_registration_without_verification: true
VARSEOF
else
    cat >>"$OUTPUT_FILE" <<VARSEOF

# Регистрация закрыта - создавать пользователей через CLI
matrix_synapse_enable_registration: false
VARSEOF
fi

if [[ "$GUEST_ACCESS" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF

# Гостевой доступ (для Element Call без авторизации)
matrix_synapse_allow_guest_access: true
VARSEOF
fi

if [[ "$MATRIX_ROOT_REDIRECT" == false ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF

# Отключить редирект matrix.${DOMAIN} → element.${DOMAIN}
matrix_synapse_container_labels_public_client_root_redirection_enabled: false
VARSEOF
fi

# --- Synapse: производительность ---
cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Synapse - производительность
# -----------------------------------------------------------------------------

matrix_synapse_max_upload_size_mb: ${MAX_UPLOAD}
VARSEOF

if [[ "$URL_PREVIEW" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF
matrix_synapse_url_preview_enabled: true

# Поиск в справочнике пользователей по всем аккаунтам сервера
# (иначе находятся только те, с кем есть общие комнаты)
matrix_synapse_user_directory_search_all_users: true
VARSEOF
fi

# --- Auto-join welcome room ---
if [[ "$WELCOME_ROOM_ENABLED" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF

# Auto-join: новые пользователи автоматически попадают в welcome-комнату
matrix_synapse_auto_join_rooms:
  - "${WELCOME_ROOM_ALIAS}"
matrix_synapse_autocreate_auto_join_rooms: true
matrix_synapse_auto_join_mxid_localpart: "${WELCOME_ROOM_CREATOR}"
VARSEOF
fi

if [[ "$PRESENCE_ENABLED" == false ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF

# Статус онлайн/оффлайн отключён (снижает нагрузку)
matrix_synapse_presence_enabled: false
VARSEOF
fi

# Логирование Synapse. WARNING - рекомендуемый дефолт для прода
# (50-100 МБ/день на ~100 активных юзеров). DEBUG используй только
# на короткое время при отладке, иначе съест диск.
cat >>"$OUTPUT_FILE" <<VARSEOF

# -----------------------------------------------------------------------------
# Synapse - логирование (управляется секцией 10/12 wizard'а)
# -----------------------------------------------------------------------------
matrix_synapse_log_level: "${LOG_LEVEL}"
matrix_synapse_storage_sql_log_level: "${LOG_LEVEL}"
matrix_synapse_root_log_level: "${LOG_LEVEL}"
VARSEOF

# --- Workers ---
if [[ "$WORKERS_ENABLED" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Synapse Workers (распределение нагрузки)
# -----------------------------------------------------------------------------

matrix_synapse_workers_enabled: true
matrix_synapse_workers_preset: ${WORKERS_PRESET}
VARSEOF
fi

# --- Retention: сообщения ---
if [[ "$RETENTION_ENABLED" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Retention (автоудаление старых сообщений)
# -----------------------------------------------------------------------------

matrix_synapse_retention_enabled: true
matrix_synapse_retention_default_policy_min_lifetime: 1d
matrix_synapse_retention_default_policy_max_lifetime: ${RETENTION_DAYS}d
matrix_synapse_retention_allowed_lifetime_min: 1d
matrix_synapse_retention_allowed_lifetime_max: ${RETENTION_DAYS}d

# Очистка каждые ${RETENTION_PURGE_INTERVAL}
matrix_synapse_retention_purge_jobs:
  - longest_max_lifetime: ${RETENTION_DAYS}d
    interval: ${RETENTION_PURGE_INTERVAL}
VARSEOF
fi

# --- Retention: медиа ---
if [[ -n "$MEDIA_RETENTION_LOCAL" || -n "$MEDIA_RETENTION_REMOTE" ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Медиа retention (автоудаление старых файлов)
# -----------------------------------------------------------------------------
VARSEOF

    if [[ -n "$MEDIA_RETENTION_LOCAL" ]]; then
        cat >>"$OUTPUT_FILE" <<VARSEOF

# Локальные медиа (загруженные пользователями этого сервера)
matrix_synapse_media_retention_local_media_lifetime: ${MEDIA_RETENTION_LOCAL}
VARSEOF
    fi

    if [[ -n "$MEDIA_RETENTION_REMOTE" ]]; then
        cat >>"$OUTPUT_FILE" <<VARSEOF

# Удалённые медиа (кешированные файлы с других серверов)
matrix_synapse_media_retention_remote_media_lifetime: ${MEDIA_RETENTION_REMOTE}
VARSEOF
    fi
fi

# --- Звонки (LiveKit) ---
if [[ "$CALLS_ENABLED" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Звонки (аудио/видео через LiveKit)
# -----------------------------------------------------------------------------
VARSEOF

    cat >>"$OUTPUT_FILE" <<VARSEOF

# Отдельный Element Call web-клиент не ставим - Element Web сам умеет в LiveKit.
matrix_element_call_enabled: false

# Включаем RTC backbone: LiveKit-server + JWT service + rtc_foci в well-known.
# Без этого matrix_rtc_enabled дефолтит в matrix_element_call_enabled (false) -
# и весь LiveKit-стек остаётся выключен несмотря на порты ниже.
matrix_rtc_enabled: true
VARSEOF

    if [[ -n "$LIVEKIT_RTC_TCP" ]]; then
        cat >>"$OUTPUT_FILE" <<VARSEOF

# Порты LiveKit (рандомизированные - защита от сканеров)
livekit_server_config_rtc_tcp_port: ${LIVEKIT_RTC_TCP}
livekit_server_config_rtc_udp_port: ${LIVEKIT_RTC_UDP}
livekit_server_config_turn_tls_port: ${LIVEKIT_TURN_TLS}
livekit_server_config_turn_udp_port: ${LIVEKIT_TURN_UDP}
livekit_server_config_rtc_use_external_ip: true
VARSEOF

        if [[ -n "$SERVER_IP" ]]; then
            cat >>"$OUTPUT_FILE" <<VARSEOF
livekit_server_config_rtc_node_ip: '${SERVER_IP}'
VARSEOF
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Performance tuning (Matrix homeserver + Element X + LiveKit)
# -----------------------------------------------------------------------------
# Рекомендованные значения для small/medium homeserver (1-4 CPU, 2-8 GB RAM).
# Применяются всегда - безопасно для дефолтного workload.

# global_factor 1.5 = +50% к каждому in-memory кэшу synapse
{
    echo ""
    echo "# -----------------------------------------------------------------------------"
    echo "# Synapse tuning - sliding sync (Element X) + caches"
    echo "# -----------------------------------------------------------------------------"
    echo "matrix_synapse_caches_global_factor: 1.5"
    echo ""
    echo "# Объединённый extension yaml: perf tuning + federation blacklist (если задан)"
    echo "matrix_synapse_configuration_extension_yaml: |"
    echo "  caches:"
    echo "    sync_response_cache_duration: 2m"
    echo "  experimental_features:"
    echo "    faster_joins: true"
    if [[ -n "${FEDERATION_BLACKLIST:-}" ]]; then
        echo "  ip_range_blacklist: []"
        echo "  federation_domain_blacklist:"
        for _domain in $FEDERATION_BLACKLIST; do
            echo "    - '${_domain}'"
        done
    fi
} >>"$OUTPUT_FILE"

# --- enable_authenticated_media escape hatch ---
# Synapse 1.120+ требует auth для legacy media endpoints. Element Web 1.12.x
# имеет bug в feature detection - не использует authenticated path → картинки
# 404. Spantaleev CHANGELOG (2024-11-26) официально рекомендует workaround.
# По умолчанию НЕ ставим (security). Раскомментируй если столкнёшься с проблемой:
cat >>"$OUTPUT_FILE" <<'VARSEOF'

# Раскомментируй ЕСЛИ Element Web показывает 404 на картинки.
# Tradeoff: любой с mxc:// URI скачает media без auth.
# matrix_synapse_enable_authenticated_media: false
VARSEOF

# -----------------------------------------------------------------------------
# LiveKit tuning (Element Call performance)
# -----------------------------------------------------------------------------
if [[ "$CALLS_ENABLED" == true ]]; then
    cat >>"$OUTPUT_FILE" <<'VARSEOF'

# ICE Lite - faster ICE establishment на public-IP host (без NAT)
livekit_server_config_rtc_use_ice_lite: true

# Полный extension с performance + safety параметрами:
# - batch_io: merge UDP system calls → ~30% меньше CPU syscalls
# - packet_buffer_size: снижено (default video=500, audio=200) под small VPS
# - congestion_control.allow_pause: SFU паузит low-priority streams под нагрузкой
# - allow_tcp_fallback: клиент с UDP-block идёт через ICE TCP fallback
# - audio.active_red_encoding: Opus RED redundancy для lossy mobile networks
# - room.enabled_codecs: +H.264 для iOS Safari hw-acceleration
# - limit: защита от accidental overload (1 CPU реалистично ~400 tracks)
livekit_server_configuration_extension_yaml: |
  rtc:
    allow_tcp_fallback: true
    batch_io:
      batch_size: 128
      max_flush_interval: 2ms
    packet_buffer_size_video: 300
    packet_buffer_size_audio: 100
    congestion_control:
      enabled: true
      allow_pause: true
  audio:
    active_red_encoding: true
  room:
    enabled_codecs:
      - mime: audio/opus
      - mime: video/vp8
      - mime: video/h264
  limit:
    num_tracks: 800
    bytes_per_sec: 50000000
    subscription_limit_video: 30
    subscription_limit_audio: 50
  logging:
    level: info
VARSEOF
fi

# --- Ketesa (Admin Panel) ---
if [[ "$SYNAPSE_ADMIN" == true ]]; then
    if [[ "$SYNAPSE_ADMIN_ON_PORT" == true ]]; then
        cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Ketesa - Admin Panel (matrix.${DOMAIN}:${SYNAPSE_ADMIN_PORT})
# -----------------------------------------------------------------------------

matrix_ketesa_enabled: true
matrix_ketesa_hostname: "ketesa.internal"
matrix_ketesa_path_prefix: /
VARSEOF
    else
        cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Ketesa - Admin Panel (matrix.${DOMAIN}${SYNAPSE_ADMIN_PATH})
# -----------------------------------------------------------------------------

matrix_ketesa_enabled: true
VARSEOF

        if [[ "$SYNAPSE_ADMIN_PATH" != "/" ]]; then
            cat >>"$OUTPUT_FILE" <<VARSEOF
matrix_ketesa_path_prefix: ${SYNAPSE_ADMIN_PATH}
VARSEOF
        fi
    fi
fi

# --- MAS ---
if [[ "$MAS_ENABLED" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Matrix Authentication Service (MAS) - для Element X
# -----------------------------------------------------------------------------

matrix_authentication_service_enabled: true
matrix_authentication_service_config_secrets_encryption: '${MAS_ENCRYPTION_SECRET}'
VARSEOF

    if [[ "$MAS_REGISTRATION_ENABLED" == true ]]; then
        cat >>"$OUTPUT_FILE" <<VARSEOF

# Разрешить самостоятельную регистрацию через MAS
matrix_authentication_service_config_account_password_registration_enabled: true
VARSEOF

        if [[ "$MAS_EMAIL_REQUIRED" == true ]]; then
            cat >>"$OUTPUT_FILE" <<VARSEOF
matrix_authentication_service_config_account_password_registration_email_required: true
VARSEOF
        else
            cat >>"$OUTPUT_FILE" <<VARSEOF
matrix_authentication_service_config_account_password_registration_email_required: false
VARSEOF
        fi

        if [[ "$MAS_TOKEN_REQUIRED" == true ]]; then
            cat >>"$OUTPUT_FILE" <<VARSEOF
matrix_authentication_service_config_account_password_registration_token_required: true
VARSEOF
        fi
    fi

    if [[ -n "$MAS_TOS_URI" ]]; then
        cat >>"$OUTPUT_FILE" <<VARSEOF

# ToS - обязательный чекбокс при регистрации
matrix_authentication_service_configuration_extension_yaml: |
  branding:
    tos_uri: '${MAS_TOS_URI}'
VARSEOF
    fi

    if [[ "$MAS_ADMIN_API" == true ]]; then
        cat >>"$OUTPUT_FILE" <<VARSEOF

# MAS Admin API (нужен для Element Admin)
matrix_authentication_service_admin_api_enabled: true
VARSEOF
    fi
fi

# --- Element Admin ---
if [[ "$ELEMENT_ADMIN_ENABLED" == true ]]; then
    if [[ "$USE_NGINX" == true && -n "$ELEMENT_ADMIN_PORT" ]]; then
        cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Element Admin (matrix.${DOMAIN}:${ELEMENT_ADMIN_PORT})
# -----------------------------------------------------------------------------

matrix_element_admin_enabled: true
matrix_element_admin_hostname: "element-admin.internal"
matrix_element_admin_path_prefix: /
VARSEOF
    else
        cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Element Admin (admin.element.${DOMAIN})
# -----------------------------------------------------------------------------

matrix_element_admin_enabled: true
VARSEOF
    fi
fi

# --- Coturn ---
if [[ "$COTURN" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# TURN/STUN (coturn)
# -----------------------------------------------------------------------------

coturn_enabled: true
VARSEOF

    if [[ -n "$SERVER_IP" ]]; then
        cat >>"$OUTPUT_FILE" <<VARSEOF
coturn_turn_external_ip_addresses: ['${SERVER_IP}']
VARSEOF
    else
        cat >>"$OUTPUT_FILE" <<VARSEOF
# coturn_turn_external_ip_addresses: ['<SERVER_PUBLIC_IP>']
VARSEOF
    fi

    if [[ "$RANDOMIZE_COTURN_PORTS" == true ]]; then
        cat >>"$OUTPUT_FILE" <<VARSEOF

# Нестандартные порты Coturn (затрудняет обнаружение при сканировании)
coturn_container_stun_plain_host_bind_port_tcp: '${COTURN_STUN_PORT}'
coturn_container_stun_plain_host_bind_port_udp: '${COTURN_STUN_PORT}'
coturn_container_stun_tls_host_bind_port_tcp: '${COTURN_TURNS_PORT}'
coturn_container_stun_tls_host_bind_port_udp: '${COTURN_TURNS_PORT}'
coturn_turn_udp_min_port: ${COTURN_RELAY_MIN}
coturn_turn_udp_max_port: ${COTURN_RELAY_MAX}
VARSEOF
    fi
fi

# --- ntfy ---
if [[ "$NTFY" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# ntfy - push-уведомления (${SUBDOMAIN_NTFY})
# -----------------------------------------------------------------------------

ntfy_enabled: true
VARSEOF

    # Веб-интерфейс (опционально)
    if [[ -n "$NTFY_WEB_ROOT" ]]; then
        cat >>"$OUTPUT_FILE" <<EOF
ntfy_web_root: ${NTFY_WEB_ROOT}
EOF
    fi

    # Тюнинг доставки через configuration_extension_yaml.
    # Эти настройки критичны для доставки push-уведомлений на Android.
    cat >>"$OUTPUT_FILE" <<EOF
matrix_ntfy_configuration_extension_yaml: |
  # Политика доступа для анонимных UnifiedPush-клиентов
  auth-default-access: "${NTFY_AUTH}"
  # Как долго хранить сообщения для оффлайн-подписчиков
  cache-duration: "${NTFY_CACHE}"
  # Интервал опроса новых сообщений (меньше = быстрее доставка)
  manager-interval: "${NTFY_MGR_INTERVAL}"
  # Long-poll keepalive
  keepalive-interval: "${NTFY_KEEPALIVE}"
  # Лимиты на анонимных посетителей (защита от спама)
  visitor-message-daily-limit: ${NTFY_VISITOR_MSG_LIMIT}
  visitor-topics-limit: ${NTFY_VISITOR_TOPIC_LIMIT}
EOF

    # Upstream - опционально
    if [[ -n "$NTFY_UPSTREAM" ]]; then
        cat >>"$OUTPUT_FILE" <<EOF
  upstream-base-url: "${NTFY_UPSTREAM}"
EOF
    fi
fi

# --- Registration (без MAS) ---
# ВНИМАНИЕ: matrix-registration (приложение ZerataX) ПОЛНОСТЬЮ УДАЛЁН из плейбука
# (май 2026). Апстрим жёстко роняет pre-flight на ЛЮБОЙ matrix_registration_*
# переменной (validate_config.yml), независимо от migration_validated_version.
# Synapse-native токен-регистрация для не-MAS ветки уже включается выше:
#   matrix_synapse_enable_registration + matrix_synapse_registration_requires_token
# Поэтому отдельный matrix_registration_* блок здесь НЕ нужен и НЕ должен возвращаться.

# --- Synapse Auto-Compressor ---
if [[ "$SYNAPSE_AUTO_COMPRESSOR" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Synapse Auto-Compressor
# -----------------------------------------------------------------------------

matrix_synapse_auto_compressor_enabled: true
VARSEOF
fi

# --- Media Repo ---
if [[ "$MEDIA_REPO" == true ]]; then
    MEDIA_REPO_DATASTORE_ID=$(gen_secret 32)
    cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Matrix Media Repo
# -----------------------------------------------------------------------------

matrix_media_repo_enabled: true

# ID файлового хранилища (НЕЛЬЗЯ менять после сохранения медиа!)
matrix_media_repo_datastore_file_id: '${MEDIA_REPO_DATASTORE_ID}'

# Rate limit для media-repo (дефолт 1 req/s слишком жёсткий для клиентов)
matrix_media_repo_rate_limit_enabled: false
VARSEOF

    # Если companion имеет explicit priority (federation на 443 с nginx),
    # media-repo роутеры должны иметь priority выше, иначе companion перехватит media запросы
    if [[ "$FED_ON_443" == true && "$USE_NGINX" == true ]]; then
        cat >>"$OUTPUT_FILE" <<VARSEOF

# Приоритеты media-repo роутеров (должны быть выше companion priority=1000,
# иначе /_matrix/media уходит в Synapse, где media_repo отключён → 404)
matrix_media_repo_container_labels_traefik_media_priority: 2000
matrix_media_repo_container_labels_traefik_client_matrix_client_media_priority: 2000
matrix_media_repo_container_labels_traefik_media_federation_priority: 2000
matrix_media_repo_container_labels_traefik_federation_matrix_federation_media_priority: 2000
matrix_media_repo_container_labels_traefik_logout_priority: 2000
matrix_media_repo_container_labels_traefik_admin_priority: 2000
matrix_media_repo_container_labels_traefik_t2bot_priority: 2000
matrix_media_repo_container_labels_traefik_logout_federation_priority: 2000
matrix_media_repo_container_labels_traefik_admin_federation_priority: 2000
matrix_media_repo_container_labels_traefik_t2bot_federation_priority: 2000
VARSEOF
    fi
fi

# --- Мосты ---
# Мосты, требующие доп. конфигурации (пишутся закомментированными)
declare -A BRIDGE_REQUIRES_CONFIG=(
    ["Telegram (mautrix)"]="# Получи api_id и api_hash: https://my.telegram.org/apps
# matrix_bridge_mautrix_telegram_api_id: ''
# matrix_bridge_mautrix_telegram_api_hash: ''"
    ["IRC (appservice)"]="# Настрой IRC-серверы (см. docs/configuring-playbook-bridge-appservice-irc.md)
# matrix_bridge_appservice_irc_ircService_servers: {}"
    ["Discord (appservice)"]="# Получи client_id и bot_token: https://discord.com/developers/applications
# matrix_bridge_appservice_discord_client_id: ''
# matrix_bridge_appservice_discord_bot_token: ''"
)

if [[ ${#SELECTED_BRIDGES[@]} -gt 0 ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Мосты (Bridges)
# -----------------------------------------------------------------------------
VARSEOF

    # E2EE включён по умолчанию для выбранных мостов:
    # Matrix-часть переписки шифруется (end-to-bridge), расшифровка только в бридже
    cat >>"$OUTPUT_FILE" <<'VARSEOF'

# E2EE для бриджей (end-to-bridge)
# ВАЖНО: бридж — доверенная точка, видящая переписку в открытом виде.
# E2EE закрывает Matrix-сегмент (Synapse/федерация видят шифротекст), но сам
# бридж на этом сервере расшифровывает каждое сообщение. Сквозного шифрования
# через мост не бывает; sensitive переписку веди без бриджа.
matrix_bridges_encryption_enabled: true
matrix_bridges_encryption_default: true
VARSEOF

    for bridge_name in "${SELECTED_BRIDGES[@]}"; do
        if [[ -n "$bridge_name" ]]; then
            var_name="${BRIDGE_MAP[$bridge_name]:-}"
            if [[ -n "$var_name" ]]; then
                extra="${BRIDGE_REQUIRES_CONFIG[$bridge_name]:-}"
                if [[ -n "$extra" ]]; then
                    # Мост требует конфигурации - пишем закомментированным
                    {
                        echo ""
                        echo "# ${bridge_name} - ТРЕБУЕТ НАСТРОЙКИ, раскомментируй после заполнения:"
                        echo "# ${var_name}: true"
                        echo "$extra"
                    } >>"$OUTPUT_FILE"
                else
                    # Мост работает сразу
                    {
                        echo ""
                        echo "# ${bridge_name}"
                        echo "${var_name}: true"
                    } >>"$OUTPUT_FILE"
                fi
            fi
        fi
    done
fi

# --- Боты ---
# Боты, требующие доп. конфигурации (пишутся закомментированными)
declare -A BOT_REQUIRES_CONFIG=(
    ["Draupnir (модерация)"]="# Создай бота, получи access token и management room
# matrix_bot_draupnir_access_token: ''
# matrix_bot_draupnir_management_room: ''"
    ["Mjolnir (модерация)"]="# Создай бота, получи access token и management room
# matrix_bot_mjolnir_access_token: ''
# matrix_bot_mjolnir_management_room: ''"
    ["Maubot (фреймворк плагинов)"]="# Задай пароль для веб-интерфейса maubot
# matrix_bot_maubot_initial_password: ''"
    ["Reminder Bot (напоминания)"]="# Задай пароль бота
# matrix_bot_matrix_reminder_bot_matrix_user_password: ''"
    ["Registration Bot (токены регистрации)"]="# Задай пароль бота
# matrix_bot_matrix_registration_bot_bot_password: ''"
    ["BaiBot (LLM / AI)"]="# Задай пароль бота и ключи LLM-провайдера
# matrix_bot_baibot_config_user_password: ''
# matrix_bot_baibot_config_initial_global_config_provider_openai_api_key: ''"
    ["Honoroit (helpdesk)"]="# Задай пароль бота и ID комнаты
# matrix_bot_honoroit_password: ''
# matrix_bot_honoroit_roomid: '!roomid:example.com'"
    ["Buscarron (веб-формы в Matrix)"]="# Задай пароль бота и настрой формы
# matrix_bot_buscarron_password: ''
# matrix_bot_buscarron_forms: []"
    ["Go-NEB (универсальный бот)"]="# UNMAINTAINED - получи access token вручную
# (см. docs/configuring-playbook-bot-go-neb.md)"
)

if [[ ${#SELECTED_BOTS[@]} -gt 0 ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Боты
# -----------------------------------------------------------------------------
VARSEOF

    for bot_name in "${SELECTED_BOTS[@]}"; do
        if [[ -n "$bot_name" ]]; then
            var_name="${BOT_MAP[$bot_name]:-}"
            if [[ -n "$var_name" ]]; then
                extra="${BOT_REQUIRES_CONFIG[$bot_name]:-}"
                if [[ -n "$extra" ]]; then
                    # Бот требует конфигурации - пишем закомментированным
                    {
                        echo ""
                        echo "# ${bot_name} - ТРЕБУЕТ НАСТРОЙКИ, раскомментируй после заполнения:"
                        echo "# ${var_name}: true"
                        echo "$extra"
                    } >>"$OUTPUT_FILE"
                else
                    # Бот работает сразу
                    {
                        echo ""
                        echo "# ${bot_name}"
                        echo "${var_name}: true"
                    } >>"$OUTPUT_FILE"
                fi
            fi
        fi
    done
fi

# --- Email ---
if [[ "$SMTP_ENABLED" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Email / SMTP
# -----------------------------------------------------------------------------

exim_relay_sender_address: '${SMTP_FROM}'
exim_relay_relay_use: true
exim_relay_relay_host_name: '${SMTP_HOST}'
exim_relay_relay_host_port: ${SMTP_PORT}
VARSEOF

    if [[ -n "$SMTP_USER" ]]; then
        cat >>"$OUTPUT_FILE" <<VARSEOF
exim_relay_relay_auth: true
exim_relay_relay_auth_username: '${SMTP_USER}'
exim_relay_relay_auth_password: '${SMTP_PASS}'
VARSEOF
    fi
fi

# --- Backup ---
if [[ "$POSTGRES_BACKUP" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Бэкап PostgreSQL
# -----------------------------------------------------------------------------

postgres_backup_enabled: true
VARSEOF
fi

# --- Безопасность и DPI ---
SECURITY_BLOCK=false
if [[ "$TLS13_ONLY" == true || "$HSTS_PRELOAD" == true || "$FED_ON_443" == true || "$CLOUDFLARE_ENABLED" == true ]]; then
    SECURITY_BLOCK=true
fi

if [[ "$SECURITY_BLOCK" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF


# -----------------------------------------------------------------------------
# Безопасность и защита от DPI
# -----------------------------------------------------------------------------
VARSEOF
fi

# TLS 1.3
if [[ "$TLS13_ONLY" == true ]]; then
    cat >>"$OUTPUT_FILE" <<'VARSEOF'

# Принудительно TLS 1.3 для всех веб-сервисов
traefik_provider_configuration_extension_yaml: |
  tls:
    options:
      default:
        minVersion: VersionTLS13
VARSEOF
fi

# HSTS Preload
if [[ "$HSTS_PRELOAD" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF

# HSTS Preload - домен закрепляется как HTTPS-only в браузерах
matrix_client_element_hsts_preload_enabled: true
matrix_static_files_hsts_preload_enabled: true
VARSEOF
fi

# Federation на порт 443
if [[ "$FED_ON_443" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF

# Federation на порт 443 (маскировка под обычный HTTPS)
matrix_synapse_http_listener_resource_names: ["client","federation"]
matrix_federation_public_port: 443
matrix_synapse_federation_port_enabled: false
matrix_synapse_tls_federation_listener_enabled: false
VARSEOF

    # С nginx: federation идёт через тот же entrypoint (web), нужен explicit priority
    if [[ "$USE_NGINX" == true ]]; then
        cat >>"$OUTPUT_FILE" <<VARSEOF

# Federation через nginx → traefik web entrypoint (не отдельный порт 8449)
matrix_federation_traefik_entrypoint_name: web

# Companion priority: без него traefik не может определить куда слать /_matrix
# (federation и client API на одном entrypoint)
matrix_synapse_reverse_proxy_companion_container_labels_public_client_api_traefik_priority: 1000
VARSEOF
    fi
fi

# Cloudflare DNS challenge
if [[ "$CLOUDFLARE_ENABLED" == true ]]; then
    cat >>"$OUTPUT_FILE" <<VARSEOF

# Cloudflare DNS challenge для SSL-сертификатов
traefik_config_certificatesResolvers_acme_dnsChallenge_enabled: true
traefik_config_certificatesResolvers_acme_dnsChallenge_provider: "cloudflare"
traefik_config_certificatesResolvers_acme_dnsChallenge_delayBeforeCheck: 60
traefik_config_certificatesResolvers_acme_dnsChallenge_resolvers:
  - "1.1.1.1:53"

traefik_environment_variables: |
  CF_API_EMAIL=${CF_EMAIL}
  CF_ZONE_API_TOKEN=${CF_ZONE_TOKEN}
  CF_DNS_API_TOKEN=${CF_DNS_TOKEN}
  LEGO_DISABLE_CNAME_SUPPORT=true
VARSEOF
fi

# vars.yml содержит SECRET_KEY/POSTGRES_PASS/CF-токены — делаем его чужому нечитаемым
# (600), при этом сам каталог и inventory/hosts оставляем с дефолтными правами
chmod 600 "$OUTPUT_FILE"

# Самопроверка: не попали ли в сгенерированный файл переменные, уже переименованные апстримом
vars_check_naming "$OUTPUT_FILE"

# =============================================================================
# Генерация hosts (inventory)
# =============================================================================
HOSTS_FILE="${PLAYBOOK_ROOT}/inventory/hosts"
LOCAL_DEPLOY=false

if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN: hosts не записывается"
else
    if [[ ! -f "$HOSTS_FILE" ]] || ask_yn "Перезаписать inventory/hosts?" "y"; then

        if ask_yn "Локальный деплой (плейбук запускается на этом же сервере)?" "y"; then
            LOCAL_DEPLOY=true
        fi

        if [[ "$LOCAL_DEPLOY" == true ]]; then
            HOST_LINE="matrix.${DOMAIN} ansible_connection=local"
        else
            SSH_USER=$(ask "SSH пользователь для Ansible" "root")
            USE_SUDO=false
            if [[ "$SSH_USER" != "root" ]]; then
                USE_SUDO=true
            fi

            HOST_LINE="matrix.${DOMAIN} ansible_host=${SERVER_IP:-<SERVER_IP>} ansible_ssh_user=${SSH_USER}"
            if [[ "$USE_SUDO" == true ]]; then
                HOST_LINE="${HOST_LINE} ansible_become=true ansible_become_user=root"
            fi
        fi

        cat >"$HOSTS_FILE" <<HOSTSEOF
[matrix_servers]
${HOST_LINE}
HOSTSEOF

        log "inventory/hosts сохранён"
    fi
fi

# =============================================================================
# Итоги
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Конфигурация сгенерирована успешно${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${BOLD}Режим:${NC}     ${YELLOW}DRY-RUN (файлы не записаны)${NC}"
    echo -e "  ${BOLD}Данные:${NC}    ${DATA_PATH}/"
else
    echo -e "  ${BOLD}vars.yml:${NC}  ${OUTPUT_FILE}"
    echo -e "  ${BOLD}hosts:${NC}     ${HOSTS_FILE}"
    echo -e "  ${BOLD}Данные:${NC}    ${DATA_PATH}/"
fi
echo ""

# Подсчитываем что включено
ENABLED_COUNT=0
[[ "$CALLS_ENABLED" == true ]] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[[ "$SYNAPSE_ADMIN" == true ]] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[[ "$MAS_ENABLED" == true ]] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[[ "$ELEMENT_ADMIN_ENABLED" == true ]] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[[ "$COTURN" == true ]] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[[ "$NTFY" == true ]] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[[ "$REGISTRATION" == true || "$MAS_REGISTRATION_ENABLED" == true ]] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[[ "$SYNAPSE_AUTO_COMPRESSOR" == true ]] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[[ "$MEDIA_REPO" == true ]] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[[ "$RETENTION_ENABLED" == true ]] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[[ "$WORKERS_ENABLED" == true ]] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[[ "$POSTGRES_BACKUP" == true ]] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[[ "$WELCOME_ROOM_ENABLED" == true ]] && ENABLED_COUNT=$((ENABLED_COUNT + 1))

echo -e "  ${BOLD}Сервисы:${NC}   ${ENABLED_COUNT} включено"
echo -e "  ${BOLD}Мосты:${NC}     ${#SELECTED_BRIDGES[@]}"
echo -e "  ${BOLD}Боты:${NC}      ${#SELECTED_BOTS[@]}"
echo -e "  ${BOLD}Клиенты:${NC}   Element Web"
echo ""

# Ключевые параметры
echo -e "  ${BOLD}Параметры:${NC}"
if [[ "$USE_NGINX" == true ]]; then
    echo -e "    Прокси:      ${GREEN}nginx → Traefik${NC}"
else
    echo -e "    Прокси:      ${GREEN}Traefik-only${NC}"
fi
if [[ "$MAS_ENABLED" == true ]]; then
    echo -e "    MAS:         ${GREEN}включён${NC} (Element X поддержка)"
    if [[ "$MAS_REGISTRATION_ENABLED" == true ]]; then
        _reg_info="регистрация открыта"
        [[ "$MAS_TOKEN_REQUIRED" == true ]] && _reg_info="${_reg_info}, по токену"
        [[ "$MAS_EMAIL_REQUIRED" == true ]] && _reg_info="${_reg_info}, email обязателен"
        echo -e "    Регистрация: ${GREEN}${_reg_info}${NC}"
    else
        echo -e "    Регистрация: ${DIM}только через CLI${NC}"
    fi
    [[ -n "$MAS_TOS_URI" ]] && echo -e "    ToS:         ${GREEN}${MAS_TOS_URI}${NC}"
else
    echo -e "    MAS:         ${DIM}отключён${NC}"
    if [[ "$REGISTRATION" == true ]]; then
        echo -e "    Регистрация: ${GREEN}по токенам${NC}"
    elif [[ "$OPEN_REGISTRATION" == true ]]; then
        echo -e "    Регистрация: ${RED}открытая (без верификации!)${NC}"
    else
        echo -e "    Регистрация: ${DIM}закрыта${NC}"
    fi
fi
if [[ "$SYNAPSE_ADMIN" == true ]]; then
    if [[ "$SYNAPSE_ADMIN_ON_PORT" == true ]]; then
        echo -e "    Ketesa:   ${GREEN}matrix.${DOMAIN}:${SYNAPSE_ADMIN_PORT}${NC}"
    else
        echo -e "    Ketesa:   ${GREEN}matrix.${DOMAIN}${SYNAPSE_ADMIN_PATH}${NC}"
    fi
fi
if [[ "$ELEMENT_ADMIN_ENABLED" == true ]]; then
    if [[ -n "$ELEMENT_ADMIN_PORT" ]]; then
        echo -e "    Elem Admin:  ${GREEN}matrix.${DOMAIN}:${ELEMENT_ADMIN_PORT}${NC}"
    else
        echo -e "    Elem Admin:  ${GREEN}admin.element.${DOMAIN}${NC}"
    fi
fi
if [[ "$WELCOME_ROOM_ENABLED" == true ]]; then
    echo -e "    Welcome:     ${GREEN}${WELCOME_ROOM_ALIAS}${NC}"
fi
if [[ "$FEDERATION_ENABLED" == true ]]; then
    _fed_info="включена"
    [[ -n "$FEDERATION_WHITELIST" ]] && _fed_info="${_fed_info}, whitelist: ${FEDERATION_WHITELIST}"
    [[ -n "$FEDERATION_BLACKLIST" ]] && _fed_info="${_fed_info}, blacklist: ${FEDERATION_BLACKLIST}"
    echo -e "    Федерация:   ${GREEN}${_fed_info}${NC}"
else
    echo -e "    Федерация:   ${RED}отключена${NC} (изолированный сервер)"
fi
if [[ "$RETENTION_ENABLED" == true ]]; then
    echo -e "    Retention:   ${RETENTION_DAYS} дней, purge каждые ${RETENTION_PURGE_INTERVAL}"
else
    echo -e "    Retention:   ${DIM}отключён${NC}"
fi
if [[ "$WORKERS_ENABLED" == true ]]; then
    echo -e "    Workers:     ${GREEN}${WORKERS_PRESET}${NC}"
fi
if [[ "$POSTGRES_BACKUP" == true ]]; then
    echo -e "    Бэкап:       ${GREEN}PostgreSQL (ежедневный)${NC}"
fi
if [[ "$PRESENCE_ENABLED" == false ]]; then
    echo -e "    Presence:    ${DIM}отключён${NC}"
fi
if [[ "$TLS13_ONLY" == true ]]; then
    echo -e "    TLS:         ${GREEN}только 1.3${NC}"
fi
if [[ "$FED_ON_443" == true ]]; then
    echo -e "    Federation:  ${GREEN}порт 443 (скрыт от DPI)${NC}"
fi
if [[ "$HSTS_PRELOAD" == true ]]; then
    echo -e "    HSTS:        ${GREEN}Preload${NC}"
fi
if [[ "$CLOUDFLARE_ENABLED" == true ]]; then
    echo -e "    Cloudflare:  ${GREEN}DNS challenge${NC}"
fi
echo ""

# DNS записи
echo -e "  ${BOLD}Необходимые DNS записи (A-записи → ${SERVER_IP:-<IP>}):${NC}"
echo -e "    ${DOMAIN}                        - заглушка + .well-known"
echo -e "    matrix.${DOMAIN}                 - Synapse homeserver"
if [[ "$SYNAPSE_ADMIN" == true ]]; then
    if [[ "$SYNAPSE_ADMIN_ON_PORT" == true ]]; then
        echo -e "                                        + :${SYNAPSE_ADMIN_PORT} (Ketesa)"
    else
        echo -e "                                        + ${SYNAPSE_ADMIN_PATH:-/synapse-admin}"
    fi
fi
echo -e "    element.${DOMAIN}                - Element Web"
[[ "$NTFY" == true ]] &&
    echo -e "    ntfy.${DOMAIN}                   - ntfy push-уведомления"
echo ""

# Следующие шаги
if [[ "$DRY_RUN" != true ]]; then
    echo -e "  ${BOLD}Следующие шаги:${NC}"
    echo ""
    if [[ "$LOCAL_DEPLOY" == true ]]; then
        echo "    1. Настрой DNS записи (все поддомены → IP сервера)"
        if [[ "$USE_NGINX" == true ]]; then
            _prepare_cmd="bash tools/prepare-server.sh --domain ${DOMAIN}"
            [[ -n "$SYNAPSE_ADMIN_PORT" ]] && _prepare_cmd="${_prepare_cmd} --ketesa-port ${SYNAPSE_ADMIN_PORT}"
            [[ -n "$ELEMENT_ADMIN_PORT" ]] && _prepare_cmd="${_prepare_cmd} --element-admin-port ${ELEMENT_ADMIN_PORT}"
            [[ "$NTFY" == true ]] && _prepare_cmd="${_prepare_cmd} --with-ntfy"
            echo "    2. Подготовь сервер:"
            echo "         ${_prepare_cmd}"
            echo "    3. Запусти деплой:"
        else
            _prepare_cmd="bash tools/prepare-server.sh --domain ${DOMAIN} --traefik-only"
            [[ "$NTFY" == true ]] && _prepare_cmd="${_prepare_cmd} --with-ntfy"
            echo "    2. Подготовь сервер:"
            echo "         ${_prepare_cmd}"
            echo "    3. Запусти деплой:"
        fi
        echo "         cd ${PLAYBOOK_ROOT}"
        echo "         just roles"
        echo "         just install-all"
        echo ""
        if [[ "$MAS_ENABLED" == true ]]; then
            echo "    Создание администратора (через MAS):"
            echo "       docker exec -it matrix-authentication-service \\"
            echo "         mas-cli manage register-user admin -p ПАРОЛЬ --admin"
        else
            echo "    Создание администратора:"
            echo "       ansible-playbook -i inventory/hosts setup.yml \\"
            echo "         --extra-vars='username=admin password=ПАРОЛЬ admin=yes' \\"
            echo "         --tags=register-user"
        fi
    else
        echo "    1. Настрой DNS записи (все поддомены → IP сервера)"
        if [[ "$USE_NGINX" == true ]]; then
            _prepare_cmd_r="bash prepare-server.sh --domain ${DOMAIN}"
            [[ -n "$SYNAPSE_ADMIN_PORT" ]] && _prepare_cmd_r="${_prepare_cmd_r} --ketesa-port ${SYNAPSE_ADMIN_PORT}"
            [[ -n "$ELEMENT_ADMIN_PORT" ]] && _prepare_cmd_r="${_prepare_cmd_r} --element-admin-port ${ELEMENT_ADMIN_PORT}"
            echo "    2. На сервере: ${_prepare_cmd_r}"
        else
            echo "    2. На сервере: bash prepare-server.sh --domain ${DOMAIN} --traefik-only"
        fi
        echo "    3. На управляющей машине:"
        echo "         cd ${PLAYBOOK_ROOT}"
        echo "         just roles"
        echo "         just install-all"
        echo ""
        if [[ "$MAS_ENABLED" == true ]]; then
            echo "    4. Создание администратора (через MAS):"
            echo "         docker exec -it matrix-authentication-service \\"
            echo "           mas-cli manage register-user admin -p ПАРОЛЬ --admin"
        else
            echo "    4. Создание администратора:"
            echo "         ansible-playbook -i inventory/hosts setup.yml \\"
            echo "           --extra-vars='username=admin password=ПАРОЛЬ admin=yes' \\"
            echo "           --tags=register-user"
        fi
    fi
    echo ""
    echo -e "    ${BOLD}Обновление сервера:${NC}"
    echo "         bash tools/update.sh"
    echo ""
    echo -e "    ${BOLD}Утилиты:${NC}"
    echo "         bash tools/nuke-user.sh USERNAME   - полное удаление пользователя"
fi

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"

# --- DRY-RUN: показать результат и удалить временный файл ---
if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo -e "${BOLD}${CYAN}=== Содержимое vars.yml ===${NC}"
    echo ""
    cat "$OUTPUT_FILE"
    rm -f "$OUTPUT_FILE"
fi
