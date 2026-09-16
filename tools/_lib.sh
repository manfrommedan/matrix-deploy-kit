#!/usr/bin/env bash
# =============================================================================
# Matrix-deploy-kit - общая библиотека для скриптов
# =============================================================================
# Подключать так:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=tools/_lib.sh
#   source "${SCRIPT_DIR}/_lib.sh"
#
# После source доступны функции:
#   log, info, warn, err, ok
#   header_text, divider
#   die <msg>          - err + exit 1
#   yes_no <prompt> [default] - да/нет с дефолтом (возвращает 0/1)
#   require_root       - die если не root
#   require_cmd <cmd>  - die если команда отсутствует
#   gen_dynamic_port [min] [max] [used] - случайный свободный порт
#   vars_check_naming <vars.yml> [--strict] - отлов переменных,
#       переименованных апстримом плейбука (и опечаток во флагах бриджей)
# =============================================================================

# Не делать set -u здесь, чтобы скрипт мог подключаться с ужесточённым режимом.
# Просто объявляем переменные, если их ещё нет.

: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[1;33m}"
: "${BLUE:=\033[0;34m}"
: "${CYAN:=\033[0;36m}"
: "${BOLD:=\033[1m}"
: "${DIM:=\033[2m}"
: "${NC:=\033[0m}"

log() { echo -e "${GREEN}[+]${NC} $*"; }
ok() { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err() { echo -e "${RED}[x]${NC} $*" >&2; }
header_text() { echo -e "${BOLD}${CYAN}=== $* ===${NC}"; }
divider() { echo -e "${DIM}$(printf '%.0s─' {1..60})${NC}"; }

die() {
    err "$*"
    # Возвращаем код, а не выходим - это позволяет тестам перехватить rc.
    # Скрипты с `set -e` (а они все) выйдут так же, как если бы die() звал exit.
    return 1
}

yes_no() {
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
        if [[ "$answer" =~ ^[YyNn]([EeOoSs])?$ ]]; then
            [[ "$answer" =~ ^[Yy] ]] && return 0 || return 1
        fi
        warn "Введи y (да) или n (нет)"
    done
}

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Запусти от root"
}

require_cmd() {
    local cmd="$1"
    local hint="${2:-}"
    command -v "$cmd" &>/dev/null ||
        die "Команда '$cmd' не найдена${hint:+ - $hint}"
}

# Генерирует уникальный случайный порт в заданном диапазоне.
# По умолчанию - динамический/private диапазон IANA (49152-65535).
# Использование:
#   port=$(gen_dynamic_port)                  # 49152-65535
#   port=$(gen_dynamic_port 10000 60000)      # кастомный диапазон
#   port=$(gen_dynamic_port "" "" "$used")    # избегать уже занятых (через пробел)
gen_dynamic_port() {
    local min="${1:-49152}"
    local max="${2:-65535}"
    local used="${3:-}"
    local range=$((max - min + 1))
    local port attempts=0
    while ((attempts < 100)); do
        # bash $RANDOM = 0..32767; два дают 30-битное число - хватает.
        port=$(((RANDOM * 32768 + RANDOM) % range + min))
        # Проверяем уникальность
        if [[ -n "$used" ]]; then
            local collision=0
            for u in $used; do
                if [[ "$u" == "$port" ]]; then
                    collision=1
                    break
                fi
            done
            if ((collision)); then
                attempts=$((attempts + 1))
                continue
            fi
        fi
        echo "$port"
        return 0
    done
    # Если не смогли сгенерировать уникальный (очень маловероятно) -
    # возвращаем хоть какой-то, но это сигнал что диапазон слишком узкий.
    echo "$port"
    return 1
}

# vars_check_naming <vars.yml> [--strict]
#
# Ловит переменные, переименованные апстримом плейбука (иначе: ansible
# падает на validate_config или - хуже - молча игнорирует переменную,
# и бридж просто не включается):
#   matrix_mautrix_*        -> matrix_bridge_mautrix_*          (и остальные бриджи)
#   ..._account_registration_token_required
#                           -> ..._account_password_registration_token_required
# А также предупреждает о неизвестных флагах matrix_bridge_*_enabled
# (типичная опечатка вроде matrix_bridge_whatsapp_enabled без "mautrix").
# С --strict старые имена завершают скрипт ошибкой (для pre-deploy проверок).
vars_check_naming() {
    local file="$1" strict="${2:-}"
    [[ -f "$file" ]] || return 0

    local old_prefix_re='^matrix_(mautrix|hookshot|heisenbridge|appservice_(irc|discord)|beeper_linkedin|wechat|sms_bridge|steam_bridge|rustpush_bridge|postmoogle|mx_puppet_(groupme|steam)|meshtastic_relay)_[a-z0-9_]*:'
    local mas_old_re='^matrix_authentication_service_config_account_registration_token_required:'
    local -a bad=()
    local hit
    while IFS= read -r hit; do bad+=("$hit"); done \
        < <(grep -nE "$old_prefix_re" "$file" || true)
    while IFS= read -r hit; do bad+=("$hit"); done \
        < <(grep -nE "$mas_old_re" "$file" || true)

    if ((${#bad[@]} > 0)); then
        err "В ${file} найдены переменные со старыми именами:"
        printf '    %s\n' "${bad[@]}" >&2
        info "Замена: matrix_<имя>_* -> matrix_bridge_<имя>_*,"
        info "        ..._account_registration_token_required -> ..._account_password_registration_token_required"
        if [[ "$strict" == "--strict" ]]; then
            die "Переименуй переменные в ${file} и повтори"
        fi
        warn "Плейбук их проигнорирует или остановится на validate_config"
    fi

    local known_flag_re='^matrix_bridge_(mautrix_(telegram|discord|whatsapp|signal|slack|meta_instagram|meta_messenger|twitter|googlechat|gmessages|bluesky)|beeper_linkedin|heisenbridge|appservice_(irc|discord)|postmoogle|hookshot|steam|wechat|sms)_enabled$'
    local flag
    while IFS= read -r flag; do
        [[ -z "$flag" ]] && continue
        # shellcheck disable=SC2076
        if ! [[ "$flag" =~ $known_flag_re ]]; then
            warn "'${flag}' в ${file}: неизвестный флаг, похоже на опечатку - ansible его проигнорирует, бридж НЕ включится"
        fi
    done < <(sed -n 's/^\(matrix_bridge_[a-z0-9_]*_enabled\):.*/\1/p' "$file")

    return 0
}
