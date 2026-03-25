#!/usr/bin/env bash
# =============================================================================
# Matrix Server — безопасное обновление
# =============================================================================
# Запуск из корня плейбука:
#   bash tools/update.sh                  # полное обновление
#   bash tools/update.sh --dry-run        # показать что будет сделано
#   bash tools/update.sh --skip-backup    # без бэкапа БД (не рекомендуется)
#   bash tools/update.sh --backup-only    # только бэкап, без обновления
#   bash tools/update.sh --reload-proxy   # перезагрузить nginx/Traefik после деплоя
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
warn()    { echo -e "${YELLOW}[!]${NC} $*" >&2; }
err()     { echo -e "${RED}[x]${NC} $*" >&2; }
info()    { echo -e "${BLUE}[i]${NC} $*"; }
step()    { echo ""; echo -e "${BOLD}${CYAN}--- $* ---${NC}"; echo ""; }

# --- Пути ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK_ROOT=""

# --- Параметры ---
DRY_RUN=false
SKIP_BACKUP=false
BACKUP_ONLY=false
FORCE=false
RELOAD_NGINX=false
SYNC_CERTS_ONLY=false
BACKUP_DIR=""
MATRIX_DATA_PATH="/matrix"
NGINX_CONF="/etc/nginx/sites-available/matrix.conf"

# --- Парсинг аргументов ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --playbook-dir|-p) PLAYBOOK_ROOT="$2"; shift 2 ;;
        --dry-run|-n)      DRY_RUN=true; shift ;;
        --skip-backup)     SKIP_BACKUP=true; shift ;;
        --backup-only)     BACKUP_ONLY=true; shift ;;
        --force|-f)        FORCE=true; shift ;;
        --reload-nginx|--reload-proxy) RELOAD_NGINX=true; shift ;;
        --sync-certs)      SYNC_CERTS_ONLY=true; shift ;;
        --backup-dir)      BACKUP_DIR="$2"; shift 2 ;;
        --data-path)       MATRIX_DATA_PATH="$2"; shift 2 ;;
        --nginx-conf)      NGINX_CONF="$2"; shift 2 ;;
        -h|--help)
            echo "Использование: update.sh [ОПЦИИ]"
            echo ""
            echo "Опции:"
            echo "  --playbook-dir, -p PATH  Путь к корню плейбука (обязательно или автоопределение)"
            echo "  --dry-run, -n            Показать план без выполнения"
            echo "  --skip-backup            Пропустить бэкап БД (не рекомендуется)"
            echo "  --backup-only            Только бэкап, без обновления"
            echo "  --sync-certs             Только синхронизация TLS-сертификатов (без обновления)"
            echo "  --backup-dir PATH        Путь для бэкапа (по умолчанию ${MATRIX_DATA_PATH}/backups/)"
            echo "  --data-path PATH         Путь к данным Matrix (по умолчанию /matrix)"
            echo "  --reload-proxy           Перезагрузить reverse proxy после деплоя (nginx или Traefik)"
            echo "  --nginx-conf PATH        Путь к nginx конфигу (по умолчанию /etc/nginx/sites-available/matrix.conf)"
            echo "  --force, -f              Не спрашивать подтверждение"
            echo "  -h, --help               Справка"
            echo ""
            echo "Примеры:"
            echo "  bash update.sh -p /opt/matrix-docker-ansible-deploy"
            echo "  bash update.sh -p /opt/matrix-docker-ansible-deploy --dry-run"
            exit 0
            ;;
        *) err "Неизвестный параметр: $1"; exit 1 ;;
    esac
done

# --- Автоопределение пути к плейбуку ---
if [[ -z "$PLAYBOOK_ROOT" ]]; then
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

# --- Определяем путь бэкапа ---
if [[ -z "$BACKUP_DIR" ]]; then
    BACKUP_DIR="${MATRIX_DATA_PATH}/backups"
fi

TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
BACKUP_FILE="${BACKUP_DIR}/postgres-${TIMESTAMP}.sql.gz"


# =============================================================================
# Проверки
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Скрипт должен запускаться от root (или через sudo)"
        exit 1
    fi
}

check_playbook() {
    if [[ ! -f "${PLAYBOOK_ROOT}/setup.yml" ]]; then
        err "Не найден setup.yml в ${PLAYBOOK_ROOT}"
        err "Убедитесь что скрипт находится в tools/ плейбука"
        exit 1
    fi
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        err "Docker не установлен"
        exit 1
    fi
}

check_inventory() {
    if [[ ! -f "${PLAYBOOK_ROOT}/inventory/hosts" ]]; then
        err "Не найден inventory/hosts"
        err "Сначала запустите generate_vars.sh"
        exit 1
    fi
}

postgres_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^matrix-postgres$"
}


# =============================================================================
# Бэкап PostgreSQL
# =============================================================================

do_backup() {
    step "Бэкап PostgreSQL"

    if ! postgres_running; then
        warn "Контейнер matrix-postgres не запущен — бэкап невозможен"
        if [[ "$BACKUP_ONLY" == true ]]; then
            err "Нечего бэкапить. Выход."
            exit 1
        fi
        return 0
    fi

    mkdir -p "$BACKUP_DIR"

    info "Создание дампа базы данных..."
    info "Файл: ${BACKUP_FILE}"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN: docker exec matrix-postgres pg_dumpall | gzip > ${BACKUP_FILE}"
        return 0
    fi

    # Создаём дамп
    if /usr/bin/docker exec \
        --env-file="${MATRIX_DATA_PATH}/postgres/env-postgres-psql" \
        matrix-postgres \
        /usr/local/bin/pg_dumpall -h matrix-postgres \
        | gzip -c > "$BACKUP_FILE"; then

        BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
        log "Бэкап создан: ${BACKUP_FILE} (${BACKUP_SIZE})"
    else
        err "Ошибка создания бэкапа!"
        if [[ "$FORCE" != true ]]; then
            err "Обновление прервано. Используйте --skip-backup чтобы пропустить."
            exit 1
        fi
        warn "Продолжаем без бэкапа (--force)"
    fi

    # Ротация: оставляем 5 последних бэкапов
    local backup_count
    backup_count=$(find "$BACKUP_DIR" -name "postgres-*.sql.gz" -type f 2>/dev/null | wc -l)

    if (( backup_count > 5 )); then
        info "Ротация бэкапов: удаляем старые (оставляем 5 последних)"
        find "$BACKUP_DIR" -name "postgres-*.sql.gz" -type f \
            | sort | head -n -5 \
            | while read -r old_backup; do
                rm -f "$old_backup"
                info "  Удалён: $(basename "$old_backup")"
            done
    fi
}


# =============================================================================
# Проверка обновлений (changelog)
# =============================================================================

check_changelog() {
    step "Проверка обновлений"

    local changelog="${PLAYBOOK_ROOT}/CHANGELOG.md"

    if [[ -f "$changelog" ]]; then
        # Показываем первые строки (последние изменения)
        info "Последние изменения в плейбуке:"
        echo ""
        head -50 "$changelog" | while IFS= read -r line; do
            echo -e "  ${DIM}${line}${NC}"
        done
        echo -e "  ${DIM}...${NC}"
        echo ""
        info "Полный changelog: ${changelog}"
    else
        warn "CHANGELOG.md не найден"
    fi
}


# =============================================================================
# Обновление плейбука
# =============================================================================

update_playbook() {
    step "Обновление плейбука"

    cd "$PLAYBOOK_ROOT"

    # Проверяем есть ли git
    if [[ ! -d .git ]]; then
        warn "Плейбук не является git-репозиторием"
        warn "Обновление исходников пропущено"
        return 0
    fi

    # Проверяем наличие локальных изменений
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        warn "Обнаружены локальные изменения в плейбуке!"
        echo ""
        git status --short
        echo ""

        if [[ "$FORCE" != true && "$DRY_RUN" != true ]]; then
            echo -en "  Продолжить обновление? ${DIM}[y/N]${NC}: "
            read -r answer
            if [[ ! "$answer" =~ ^[Yy] ]]; then
                info "Обновление отменено"
                exit 0
            fi
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN: git pull"
        return 0
    fi

    info "Получение обновлений..."
    if git pull; then
        log "Плейбук обновлён"
    else
        err "Ошибка git pull"
        err "Попробуйте вручную: cd ${PLAYBOOK_ROOT} && git pull"
        exit 1
    fi
}


# =============================================================================
# Обновление ролей (Galaxy)
# =============================================================================

update_roles() {
    step "Обновление ролей Ansible"

    cd "$PLAYBOOK_ROOT"

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN: just roles (или ansible-galaxy install -r requirements.yml)"
        return 0
    fi

    # Пробуем just, потом make, потом напрямую
    if command -v just &>/dev/null && [[ -f justfile ]]; then
        info "Обновление через: just roles"
        just roles
    elif [[ -f Makefile ]] && grep -q "^roles:" Makefile; then
        info "Обновление через: make roles"
        make roles
    else
        info "Обновление через: ansible-galaxy install"
        rm -rf roles/galaxy
        ansible-galaxy install -r requirements.yml -p roles/galaxy/ --force
    fi

    log "Роли обновлены"
}


# =============================================================================
# Применение обновлений
# =============================================================================

apply_update() {
    step "Применение обновлений (install-all)"

    cd "$PLAYBOOK_ROOT"

    info "Это обновит Docker-образы и перезапустит изменённые сервисы"
    info "Команда: ansible-playbook setup.yml --tags=install-all,ensure-matrix-users-created,start"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN: ansible-playbook запущен не будет"
        return 0
    fi

    if [[ "$FORCE" != true ]]; then
        echo -en "  Применить обновления? ${DIM}[Y/n]${NC}: "
        read -r answer
        answer="${answer:-y}"
        if [[ ! "$answer" =~ ^[Yy] ]]; then
            info "Применение отменено. Обновления скачаны, но не применены."
            info "Для применения вручную:"
            echo "    cd ${PLAYBOOK_ROOT}"
            echo "    just install-all"
            return 0
        fi
    fi

    info "Запуск ansible-playbook (это может занять несколько минут)..."
    echo ""

    # Фикс локали — предотвращает ошибки Python/Ansible на серверах без настроенной локали
    export LC_ALL="${LC_ALL:-C.UTF-8}" LANG="${LANG:-C.UTF-8}"

    ansible-playbook \
        -i "${PLAYBOOK_ROOT}/inventory/hosts" \
        "${PLAYBOOK_ROOT}/setup.yml" \
        --tags=install-all,ensure-matrix-users-created,start

    log "Обновления применены"
}


# =============================================================================
# Определение режима прокси и домена
# =============================================================================

# Режим: "nginx" (nginx → Traefik) или "traefik" (Traefik-only)
PROXY_MODE=""
MATRIX_DOMAIN=""
MATRIX_HOSTNAME=""

# Admin-панели (заполняются detect_admin_endpoints)
SYNAPSE_ADMIN_URL=""
ELEMENT_ADMIN_URL=""

detect_domain() {
    local vars_dir="${PLAYBOOK_ROOT}/inventory/host_vars"
    if [[ -d "$vars_dir" ]]; then
        local host_dir
        host_dir=$(find "$vars_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
        if [[ -n "$host_dir" ]]; then
            # matrix.kremlin.ddnsgeek.com → kremlin.ddnsgeek.com
            MATRIX_HOSTNAME=$(basename "$host_dir")
            MATRIX_DOMAIN="${MATRIX_HOSTNAME#matrix.}"
        fi
    fi
}

detect_proxy_mode() {
    if [[ -f "$NGINX_CONF" ]] && command -v nginx &>/dev/null; then
        PROXY_MODE="nginx"
    else
        PROXY_MODE="traefik"
    fi
}

# Парсит vars.yml и возвращает значение переменной (или пустую строку)
_vars_yml() {
    local var_name="$1"
    local vars_file="${PLAYBOOK_ROOT}/inventory/host_vars/${MATRIX_HOSTNAME}/vars.yml"
    if [[ -f "$vars_file" ]]; then
        grep "^${var_name}:" "$vars_file" 2>/dev/null \
            | head -1 \
            | sed 's/^[^:]*:[[:space:]]*//' \
            | sed 's/^["'"'"']//' \
            | sed 's/["'"'"']$//'
    fi
}

detect_admin_endpoints() {
    SYNAPSE_ADMIN_URL=""
    ELEMENT_ADMIN_URL=""

    [[ -z "$MATRIX_HOSTNAME" ]] && return 0

    if [[ "$PROXY_MODE" == "nginx" ]]; then
        # --- nginx режим: ищем порты из nginx.conf ---
        local sa_port="" ea_port="" current_port=""
        while IFS= read -r line; do
            if [[ "$line" =~ listen[[:space:]]+([0-9]+)[[:space:]]+ssl ]]; then
                current_port="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ Host[[:space:]]+synapse-admin\.internal ]]; then
                sa_port="$current_port"
            fi
            if [[ "$line" =~ Host[[:space:]]+element-admin\.internal ]]; then
                ea_port="$current_port"
            fi
        done < "$NGINX_CONF"

        [[ -n "$sa_port" ]] && SYNAPSE_ADMIN_URL="https://${MATRIX_HOSTNAME}:${sa_port}/"
        [[ -n "$ea_port" ]] && ELEMENT_ADMIN_URL="https://${MATRIX_HOSTNAME}:${ea_port}/"

        # Если admin не на порту — проверяем path из vars.yml
        if [[ -z "$SYNAPSE_ADMIN_URL" ]]; then
            local sa_enabled
            sa_enabled=$(_vars_yml "matrix_synapse_admin_enabled")
            if [[ "$sa_enabled" == "true" ]]; then
                local sa_path
                sa_path=$(_vars_yml "matrix_synapse_admin_path_prefix")
                sa_path="${sa_path:-/synapse-admin}"
                SYNAPSE_ADMIN_URL="https://${MATRIX_HOSTNAME}${sa_path}"
            fi
        fi

        if [[ -z "$ELEMENT_ADMIN_URL" ]]; then
            local ea_enabled
            ea_enabled=$(_vars_yml "matrix_element_admin_enabled")
            if [[ "$ea_enabled" == "true" ]]; then
                local ea_host ea_path
                ea_host=$(_vars_yml "matrix_element_admin_hostname")
                ea_path=$(_vars_yml "matrix_element_admin_path_prefix")
                ea_host="${ea_host:-admin.element.${MATRIX_DOMAIN}}"
                ea_path="${ea_path:-/}"
                ELEMENT_ADMIN_URL="https://${ea_host}${ea_path}"
            fi
        fi
    else
        # --- Traefik-only режим: URL из vars.yml ---
        local sa_enabled
        sa_enabled=$(_vars_yml "matrix_synapse_admin_enabled")
        if [[ "$sa_enabled" == "true" ]]; then
            local sa_host sa_path
            sa_host=$(_vars_yml "matrix_synapse_admin_hostname")
            sa_path=$(_vars_yml "matrix_synapse_admin_path_prefix")
            sa_host="${sa_host:-${MATRIX_HOSTNAME}}"
            sa_path="${sa_path:-/synapse-admin}"
            SYNAPSE_ADMIN_URL="https://${sa_host}${sa_path}"
        fi

        local ea_enabled
        ea_enabled=$(_vars_yml "matrix_element_admin_enabled")
        if [[ "$ea_enabled" == "true" ]]; then
            local ea_host ea_path
            ea_host=$(_vars_yml "matrix_element_admin_hostname")
            ea_path=$(_vars_yml "matrix_element_admin_path_prefix")
            ea_host="${ea_host:-admin.element.${MATRIX_DOMAIN}}"
            ea_path="${ea_path:-/}"
            ELEMENT_ADMIN_URL="https://${ea_host}${ea_path}"
        fi
    fi
}


# =============================================================================
# nginx / Traefik — перезагрузка reverse proxy
# =============================================================================

reload_proxy() {
    if [[ "$PROXY_MODE" == "nginx" ]]; then
        step "Перезагрузка nginx"

        if [[ "$DRY_RUN" == true ]]; then
            log "DRY-RUN: nginx reload"
            return 0
        fi

        if nginx -t 2>/dev/null; then
            systemctl reload nginx
            log "nginx перезагружен"
        else
            err "Ошибка в конфигурации nginx!"
            nginx -t
            return 1
        fi
        
        step "Перезапуск Traefik"

        if [[ "$DRY_RUN" == true ]]; then
            log "DRY-RUN: docker restart matrix-traefik"
            return 0
        fi

        if docker ps --format '{{.Names}}' | grep -q "^matrix-traefik$"; then
            docker restart matrix-traefik
            log "Traefik перезапущен"
        else
            warn "Контейнер matrix-traefik не найден"
        fi
    fi
}


# =============================================================================
# Проверка здоровья
# =============================================================================

health_check() {
    step "Проверка сервисов"

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN: проверка сервисов пропущена"
        return 0
    fi

    local all_ok=true

    # --- Контейнеры ---
    info "Docker-контейнеры:"
    echo ""

    # Ключевые контейнеры (без них сервер не работает)
    local core_containers=("matrix-synapse" "matrix-postgres" "matrix-traefik")
    for container in "${core_containers[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            echo -e "    ${GREEN}●${NC} ${container}"
        else
            echo -e "    ${RED}●${NC} ${container} — НЕ ЗАПУЩЕН"
            all_ok=false
        fi
    done

    # Дополнительные сервисы — проверяем если запущены
    local extra_containers
    extra_containers=$(docker ps --format '{{.Names}}' | grep "^matrix-" | grep -v -E "^(matrix-synapse|matrix-postgres|matrix-traefik)$" | sort)
    if [[ -n "$extra_containers" ]]; then
        while IFS= read -r container; do
            echo -e "    ${GREEN}●${NC} ${container}"
        done <<< "$extra_containers"
    fi

    echo ""

    # --- systemd сервисы ---
    info "Статус systemd-сервисов:"
    echo ""
    local failed_services
    failed_services=$(systemctl list-units "matrix-*" --state=failed --no-legend --no-pager 2>/dev/null)
    if [[ -n "$failed_services" ]]; then
        all_ok=false
        echo "$failed_services" | while IFS= read -r line; do
            echo -e "    ${RED}●${NC} ${line}"
        done
    else
        local running_count
        running_count=$(systemctl list-units "matrix-*" --state=running --no-legend --no-pager 2>/dev/null | wc -l)
        log "${running_count} systemd-сервисов запущено"
    fi

    echo ""

    # --- Reverse proxy ---
    info "Reverse proxy (${PROXY_MODE}):"
    if [[ "$PROXY_MODE" == "nginx" ]]; then
        if systemctl is-active nginx &>/dev/null; then
            log "nginx — работает"
        else
            warn "nginx — не запущен"
            all_ok=false
        fi
    else
        if docker ps --format '{{.Names}}' | grep -q "^matrix-traefik$"; then
            log "Traefik — работает"
        else
            warn "Traefik — не запущен"
            all_ok=false
        fi
    fi

    echo ""

    # --- HTTP-эндпоинты ---
    if [[ -n "$MATRIX_HOSTNAME" ]]; then
        info "HTTP-проверки:"
        echo ""

        # Synapse API
        local synapse_url="https://${MATRIX_HOSTNAME}/_matrix/client/versions"
        local http_code
        http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "$synapse_url" 2>/dev/null || true)
        if [[ "$http_code" == "200" ]]; then
            echo -e "    ${GREEN}●${NC} Synapse API       → 200"
        else
            echo -e "    ${RED}●${NC} Synapse API       → ${http_code}"
            all_ok=false
        fi

        # Federation (порт 443 если federation_public_port=443, иначе 8448)
        local fed_port="8448"
        local fed_public_port
        fed_public_port=$(_vars_yml "matrix_federation_public_port")
        [[ "$fed_public_port" == "443" ]] && fed_port="443"
        local fed_url="https://${MATRIX_HOSTNAME}:${fed_port}/_matrix/federation/v1/version"
        http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "$fed_url" 2>/dev/null || true)
        if [[ "$http_code" == "200" ]]; then
            echo -e "    ${GREEN}●${NC} Federation API    → 200"
        else
            echo -e "    ${YELLOW}●${NC} Federation API    → ${http_code}"
        fi

        # .well-known
        local wk_url="https://${MATRIX_DOMAIN}/.well-known/matrix/server"
        http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "$wk_url" 2>/dev/null || true)
        if [[ "$http_code" == "200" ]]; then
            echo -e "    ${GREEN}●${NC} .well-known       → 200"
        else
            echo -e "    ${YELLOW}●${NC} .well-known       → ${http_code}"
        fi

        # Synapse Admin
        if [[ -n "$SYNAPSE_ADMIN_URL" ]]; then
            http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "$SYNAPSE_ADMIN_URL" 2>/dev/null || true)
            if [[ "$http_code" == "200" ]]; then
                echo -e "    ${GREEN}●${NC} Synapse Admin     → 200"
            else
                echo -e "    ${RED}●${NC} Synapse Admin     → ${http_code}"
                all_ok=false
            fi
        fi

        # Element Admin
        if [[ -n "$ELEMENT_ADMIN_URL" ]]; then
            http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "$ELEMENT_ADMIN_URL" 2>/dev/null || true)
            if [[ "$http_code" == "200" ]]; then
                echo -e "    ${GREEN}●${NC} Element Admin     → 200"
            else
                echo -e "    ${RED}●${NC} Element Admin     → ${http_code}"
                all_ok=false
            fi
        fi

        echo ""
    fi

    # --- Итог ---
    if [[ "$all_ok" == true ]]; then
        log "Все сервисы в порядке"
    else
        warn "Некоторые сервисы не работают"
        info "Проверьте логи: journalctl -fu <имя-сервиса>"
    fi

    # Self-check через ansible (опционально)
    info "Для полной проверки запустите:"
    echo "    cd ${PLAYBOOK_ROOT} && just run-tags self-check"
}


# =============================================================================
# Синхронизация TLS-сертификатов (nginx режим)
# =============================================================================

sync_tls_certs() {
    step "Синхронизация TLS-сертификатов"

    # Определяем домен из inventory
    [[ -z "$MATRIX_DOMAIN" ]] && detect_domain

    local cert_dir="/etc/letsencrypt/live/${MATRIX_DOMAIN}"
    if [[ ! -f "${cert_dir}/fullchain.pem" ]]; then
        info "Certbot-серты не найдены (Traefik-only режим?) — пропуск"
        return 0
    fi

    local _matrix_uid _matrix_gid
    _matrix_uid=$(id -u matrix 2>/dev/null || echo 0)
    _matrix_gid=$(id -g matrix 2>/dev/null || echo 0)

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN: синхронизация сертов из ${cert_dir}/"
        return 0
    fi

    local updated=false

    # LiveKit серты
    local lk_dir="${MATRIX_DATA_PATH}/livekit-server/certs"
    if [[ -d "${MATRIX_DATA_PATH}/livekit-server" ]]; then
        mkdir -p "$lk_dir"
        if ! diff -q "${cert_dir}/fullchain.pem" "${lk_dir}/fullchain.pem" &>/dev/null; then
            cp -L "${cert_dir}/fullchain.pem" "${lk_dir}/fullchain.pem"
            cp -L "${cert_dir}/privkey.pem" "${lk_dir}/privkey.pem"
            chown "${_matrix_uid}:${_matrix_gid}" "${lk_dir}"/*.pem 2>/dev/null || true
            chmod 640 "${lk_dir}"/*.pem
            log "LiveKit серты: обновлены"
            updated=true
        else
            info "LiveKit серты: актуальны"
        fi
    fi

    # Coturn серты
    local ct_dir="${MATRIX_DATA_PATH}/coturn/certs"
    if [[ -d "${MATRIX_DATA_PATH}/coturn" ]]; then
        mkdir -p "$ct_dir"
        if ! diff -q "${cert_dir}/fullchain.pem" "${ct_dir}/fullchain.pem" &>/dev/null; then
            cp -L "${cert_dir}/fullchain.pem" "${ct_dir}/fullchain.pem"
            cp -L "${cert_dir}/privkey.pem" "${ct_dir}/privkey.pem"
            chown "${_matrix_uid}:${_matrix_gid}" "${ct_dir}"/*.pem 2>/dev/null || true
            chmod 640 "${ct_dir}"/*.pem
            log "Coturn серты: обновлены"
            updated=true
        else
            info "Coturn серты: актуальны"
        fi
    fi

    # Перезапуск сервисов если серты обновились
    if [[ "$updated" == true ]]; then
        systemctl restart matrix-livekit-server 2>/dev/null || true
        systemctl restart matrix-coturn 2>/dev/null || true
        log "Сервисы перезапущены после обновления сертов"
    fi
}


# =============================================================================
# Главная логика
# =============================================================================

main() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Matrix Server — обновление${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        warn "Режим DRY-RUN: ничего не будет выполнено"
        echo ""
    fi

    # --- Предварительные проверки ---
    step "Предварительные проверки"

    check_root
    log "Запущен от root"

    check_playbook
    log "Плейбук: ${PLAYBOOK_ROOT}"

    check_docker
    log "Docker доступен"

    check_inventory
    log "Inventory найден"

    if postgres_running; then
        log "PostgreSQL работает"
    else
        warn "PostgreSQL не запущен (первый деплой?)"
    fi

    # --- Бэкап ---
    if [[ "$SKIP_BACKUP" != true ]]; then
        do_backup
    else
        warn "Бэкап пропущен (--skip-backup)"
    fi

    # Если только бэкап — выходим
    if [[ "$BACKUP_ONLY" == true ]]; then
        echo ""
        log "Бэкап завершён"
        exit 0
    fi

    # Если только синхронизация сертов — делаем и выходим
    if [[ "$SYNC_CERTS_ONLY" == true ]]; then
        detect_domain
        detect_proxy_mode
        if [[ "$PROXY_MODE" == "nginx" ]]; then
            sync_tls_certs
        else
            info "Traefik-only режим — синхронизация сертов не нужна"
        fi
        exit 0
    fi

    # --- Changelog ---
    check_changelog

    # --- Обновление ---
    update_playbook
    update_roles
    apply_update

    # --- Определяем домен, режим и эндпоинты ---
    detect_domain
    detect_proxy_mode
    detect_admin_endpoints

    # --- TLS серты ---
    if [[ "$PROXY_MODE" == "nginx" ]]; then
        sync_tls_certs
    fi

    # --- Reverse proxy ---
    if [[ "$RELOAD_NGINX" == true ]]; then
        reload_proxy
    fi

    # --- Проверка ---
    health_check

    # --- Итог ---
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${BOLD}${YELLOW}  DRY-RUN завершён (ничего не выполнено)${NC}"
    else
        echo -e "${BOLD}${GREEN}  Обновление завершено${NC}"
        echo ""
        echo -e "  ${BOLD}Бэкап:${NC}     ${BACKUP_FILE:-пропущен}"
        echo -e "  ${BOLD}Плейбук:${NC}   ${PLAYBOOK_ROOT}"
        echo -e "  ${BOLD}Прокси:${NC}    ${PROXY_MODE}"

        if [[ -n "${MATRIX_HOSTNAME:-}" ]]; then
            echo ""
            echo -e "  ${BOLD}Сервисы:${NC}"
            echo -e "    Element Web:    https://element.${MATRIX_DOMAIN}/"
            echo -e "    Synapse API:    https://${MATRIX_HOSTNAME}/_matrix/client/versions"
            [[ -n "$SYNAPSE_ADMIN_URL" ]] && \
                echo -e "    Synapse Admin:  ${SYNAPSE_ADMIN_URL}"
            [[ -n "$ELEMENT_ADMIN_URL" ]] && \
                echo -e "    Element Admin:  ${ELEMENT_ADMIN_URL}"
        fi
    fi
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    if [[ "$DRY_RUN" != true ]]; then
        info "Если что-то пошло не так:"
        echo "    1. Проверь логи: journalctl -fu matrix-synapse"
        echo "    2. Восстанови БД из бэкапа:"
        echo "       gunzip < ${BACKUP_FILE} | docker exec -i matrix-postgres psql -h matrix-postgres"
        echo "    3. Перезапусти сервисы: just start-all"
        echo ""
    fi
}

main "$@"
