#!/usr/bin/env bash
# =============================================================================
# Matrix Server — скрипт первоначальной подготовки
# =============================================================================
# Запуск на целевом сервере от root:
#   curl -sL https://your-host/prepare_server.sh | bash -s -- --domain example.com
#   или:
#   bash prepare_server.sh --domain example.com
#
# Поддерживаемые ОС: Ubuntu 20.04+, Debian 11+
# =============================================================================

set -euo pipefail

# --- Цвета ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

# --- Значения по умолчанию ---
DOMAIN=""
DEPLOY_USER="matrix-admin"
SSH_PORT=22
SWAP_SIZE="2G"
SKIP_FIREWALL=true
SKIP_SWAP=false
SKIP_SSH_HARDENING=true
SKIP_DOCKER=false
SKIP_NGINX=false
SKIP_FAIL2BAN=true
CERTBOT_EMAIL=""
DRY_RUN=false
KETESA_PORT=""
ELEMENT_ADMIN_PORT=""
WITH_LANDING_PAGE=false
WITH_NTFY=false
DATA_PATH="/matrix"

# Режим прокси: "nginx" (nginx → Traefik) или "traefik" (Traefik-only)
PROXY_MODE="nginx"

# Порты для файрвола (пустые = дефолтные значения)
LK_RTC_TCP=""
LK_RTC_UDP=""
LK_TURN_TLS=""
LK_TURN_UDP=""
COTURN_STUN_PORT=""
COTURN_TURNS_PORT=""
COTURN_RELAY_RANGE=""
FEDERATION_ON_443=false
TLS13_ONLY=false
MAX_UPLOAD_SIZE="100"  # MB, должно совпадать с matrix_synapse_max_upload_size_mb

# --- Справка ---
usage() {
    cat <<'USAGE'
Использование:
  prepare_server.sh --domain DOMAIN [OPTIONS]

Обязательные параметры:
  --domain DOMAIN           Домен Matrix-сервера (example.com)

Reverse proxy (выбрать один):
  (по умолчанию)            nginx → Traefik (nginx терминирует SSL, certbot)
  --traefik-only            Traefik-only (Traefik сам управляет SSL через ACME)
  --skip-nginx              Алиас для --traefik-only

Опции (nginx режим):
  --email EMAIL             Email для certbot (по умолчанию admin@DOMAIN)
  --ketesa-port PORT Порт для Ketesa (nginx → Traefik)
  --element-admin-port PORT Порт для Element Admin (nginx → Traefik)
  --with-landing-page       Создать landing page и ToS на matrix.DOMAIN
  --with-ntfy               Включить поддомен ntfy.DOMAIN (push-уведомления)

Порты для файрвола (--with-firewall):
  --livekit-rtc-tcp PORT    LiveKit RTC TCP порт
  --livekit-rtc-udp PORT    LiveKit RTC UDP порт
  --livekit-turn-tls PORT   LiveKit TURN TLS порт
  --livekit-turn-udp PORT   LiveKit TURN UDP порт
  --coturn-stun PORT        Coturn STUN порт (по умолчанию: 3478)
  --coturn-turns PORT       Coturn TURNS порт (по умолчанию: 5349)
  --coturn-relay-range MIN:MAX  Coturn relay UDP диапазон (по умолчанию: 49152:49172)
  --federation-on-443       Федерация на 443 (не открывать 8448, не генерировать nginx-блок)
  --tls13-only              Принудительно TLS 1.3 (ssl_protocols TLSv1.3 во всех блоках)
  --max-upload SIZE_MB      Макс. размер загрузки в МБ (по умолчанию: 100, должно совпадать с Synapse)

Общие опции:
  --deploy-user USER        Имя deploy-пользователя (по умолчанию: matrix-admin)
  --ssh-port PORT           Порт SSH (по умолчанию: 22)
  --swap-size SIZE          Размер swap (по умолчанию: 2G, 0 — не создавать)
  --skip-swap               Не создавать swap
  --skip-docker             Не ставить Docker (плейбук поставит сам)
  --with-firewall           Настроить ufw (по умолчанию выключен)
  --with-ssh-hardening      Закрепить настройки SSH (по умолчанию выключен)
  --with-fail2ban           Установить fail2ban (по умолчанию выключен)
  --data-path PATH          Путь к данным Matrix (по умолчанию: /matrix)
  --dry-run                 Показать что будет сделано, без выполнения
  -h, --help                Показать справку

Примеры:
  # nginx режим (с admin-панелями на портах):
  prepare_server.sh --domain example.com --ketesa-port 35805 --with-landing-page

  # Traefik-only (SSL через Traefik ACME):
  prepare_server.sh --domain example.com --traefik-only
USAGE
    exit 0
}

# --- Парсинг аргументов ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)           DOMAIN="$2"; shift 2 ;;
        --email)            CERTBOT_EMAIL="$2"; shift 2 ;;
        --deploy-user)      DEPLOY_USER="$2"; shift 2 ;;
        --ssh-port)         SSH_PORT="$2"; shift 2 ;;
        --swap-size)        SWAP_SIZE="$2"; shift 2 ;;
        --skip-swap)        SKIP_SWAP=true; shift ;;
        --skip-docker)      SKIP_DOCKER=true; shift ;;
        --skip-nginx|--traefik-only) SKIP_NGINX=true; PROXY_MODE="traefik"; shift ;;
        --with-firewall)    SKIP_FIREWALL=false; shift ;;
        --with-ssh-hardening) SKIP_SSH_HARDENING=false; shift ;;
        --with-fail2ban)    SKIP_FAIL2BAN=false; shift ;;
        --ketesa-port) KETESA_PORT="$2"; shift 2 ;;
        --element-admin-port) ELEMENT_ADMIN_PORT="$2"; shift 2 ;;
        --with-landing-page)  WITH_LANDING_PAGE=true; shift ;;
        --with-ntfy)          WITH_NTFY=true; shift ;;
        --data-path)        DATA_PATH="$2"; shift 2 ;;
        --livekit-rtc-tcp)    LK_RTC_TCP="$2"; shift 2 ;;
        --livekit-rtc-udp)    LK_RTC_UDP="$2"; shift 2 ;;
        --livekit-turn-tls)   LK_TURN_TLS="$2"; shift 2 ;;
        --livekit-turn-udp)   LK_TURN_UDP="$2"; shift 2 ;;
        --coturn-stun)        COTURN_STUN_PORT="$2"; shift 2 ;;
        --coturn-turns)       COTURN_TURNS_PORT="$2"; shift 2 ;;
        --coturn-relay-range) COTURN_RELAY_RANGE="$2"; shift 2 ;;
        --federation-on-443)  FEDERATION_ON_443=true; shift ;;
        --tls13-only)         TLS13_ONLY=true; shift ;;
        --max-upload)         MAX_UPLOAD_SIZE="$2"; shift 2 ;;
        --dry-run)          DRY_RUN=true; shift ;;
        -h|--help)          usage ;;
        *)                  err "Неизвестный параметр: $1"; usage ;;
    esac
done

# --- Валидация ---
if [[ -z "$DOMAIN" ]]; then
    err "Домен обязателен. Используй: --domain example.com"
    exit 1
fi

# Проверка: nginx-only опции не совместимы с --traefik-only
if [[ "$PROXY_MODE" == "traefik" ]]; then
    if [[ -n "$KETESA_PORT" || -n "$ELEMENT_ADMIN_PORT" ]]; then
        warn "Опции --ketesa-port / --element-admin-port работают только в nginx режиме."
        warn "В Traefik-only admin-панели доступны через пути/поддомены (настраивается в vars.yml)."
        KETESA_PORT=""
        ELEMENT_ADMIN_PORT=""
    fi
    if [[ "$WITH_LANDING_PAGE" == true ]]; then
        warn "Опция --with-landing-page работает только в nginx режиме."
        warn "В Traefik-only landing page нужно настраивать отдельно."
        WITH_LANDING_PAGE=false
    fi
fi

# Проверка: matrix_domain должен быть bare-доменом, не поддоменом matrix.*
if [[ "$DOMAIN" == matrix.* ]]; then
    BARE="${DOMAIN#matrix.}"
    warn "Ты ввёл поддомен ${DOMAIN}, но matrix_domain должен быть bare-доменом."
    warn "Правильно: ${BARE} (поддомены matrix.${BARE}, element.${BARE} создаются автоматически)"
    echo ""
    read -rp "Использовать ${BARE} вместо ${DOMAIN}? [Y/n] " fix_domain
    fix_domain="${fix_domain:-y}"
    if [[ "$fix_domain" =~ ^[Yy] ]]; then
        DOMAIN="$BARE"
        info "Домен изменён на: ${DOMAIN}"
    fi
fi

if [[ "$EUID" -ne 0 ]]; then
    err "Скрипт нужно запускать от root"
    exit 1
fi

if [[ -z "$CERTBOT_EMAIL" ]]; then
    CERTBOT_EMAIL="admin@${DOMAIN}"
fi

# Проверка ОС
if ! command -v apt-get &>/dev/null; then
    err "Поддерживаются только apt-based дистрибутивы (Ubuntu/Debian)"
    exit 1
fi

# Определяем ОС
OS_ID=$(. /etc/os-release && echo "$ID")
OS_VERSION=$(. /etc/os-release && echo "$VERSION_ID")
OS_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

info "ОС: ${OS_ID} ${OS_VERSION} (${OS_CODENAME})"
info "Домен: ${DOMAIN}"
_subdomains="matrix.${DOMAIN}, element.${DOMAIN}"
[[ "$WITH_NTFY" == true ]] && _subdomains="${_subdomains}, ntfy.${DOMAIN}"
info "Поддомены: ${_subdomains}"
info "Deploy-пользователь: ${DEPLOY_USER}"
info "SSH порт: ${SSH_PORT}"
if [[ "$PROXY_MODE" == "nginx" ]]; then
    info "Reverse proxy: nginx → Traefik (nginx терминирует SSL)"
    info "Certbot email: ${CERTBOT_EMAIL}"
    [[ -n "$KETESA_PORT" ]] && info "Ketesa порт: ${KETESA_PORT}"
    [[ -n "$ELEMENT_ADMIN_PORT" ]] && info "Element Admin порт: ${ELEMENT_ADMIN_PORT}"
    [[ "$WITH_LANDING_PAGE" == true ]] && info "Landing page: включена"
else
    info "Reverse proxy: Traefik-only (SSL через ACME)"
fi

if [[ "$DRY_RUN" == true ]]; then
    warn "DRY RUN — ничего не будет выполнено"
    exit 0
fi

echo ""
read -rp "Продолжить? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { info "Отменено."; exit 0; }
echo ""


# =============================================================================
# 1. Обновление системы
# =============================================================================
log "Обновление системы..."

export DEBIAN_FRONTEND=noninteractive
export LC_ALL="${LC_ALL:-C.UTF-8}" LANG="${LANG:-C.UTF-8}"

apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    sudo \
    wget \
    unzip \
    htop \
    iotop \
    net-tools \
    jq \
    logrotate \
    pwgen \
    pipx

log "Система обновлена"


# =============================================================================
# 2. Deploy-пользователь
# =============================================================================
log "Создание пользователя ${DEPLOY_USER}..."

if id "${DEPLOY_USER}" &>/dev/null; then
    warn "Пользователь ${DEPLOY_USER} уже существует, пропускаю"
else
    useradd -m -s /bin/bash -G sudo "${DEPLOY_USER}"

    # Sudo без пароля для deploy-пользователя
    cat > "/etc/sudoers.d/${DEPLOY_USER}" <<EOF
${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL
EOF
    chmod 440 "/etc/sudoers.d/${DEPLOY_USER}"

    # Копируем SSH-ключи root → deploy user
    if [[ -d /root/.ssh ]]; then
        mkdir -p "/home/${DEPLOY_USER}/.ssh"
        cp /root/.ssh/authorized_keys "/home/${DEPLOY_USER}/.ssh/authorized_keys" 2>/dev/null || true
        chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
        chmod 700 "/home/${DEPLOY_USER}/.ssh"
        chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys" 2>/dev/null || true
    fi

    log "Пользователь ${DEPLOY_USER} создан"
fi


# =============================================================================
# 3. SSH Hardening
# =============================================================================
if [[ "$SKIP_SSH_HARDENING" == false ]]; then
    log "Настройка SSH..."

    SSHD_CONFIG="/etc/ssh/sshd_config"
    SSHD_BACKUP="/etc/ssh/sshd_config.bak.$(date +%s)"
    cp "$SSHD_CONFIG" "$SSHD_BACKUP"
    info "Бэкап sshd_config: ${SSHD_BACKUP}"

    # Функция для установки параметра в sshd_config
    set_sshd_param() {
        local key="$1" value="$2"
        if grep -qE "^\s*#?\s*${key}\b" "$SSHD_CONFIG"; then
            sed -i "s/^\s*#\?\s*${key}\b.*/${key} ${value}/" "$SSHD_CONFIG"
        else
            echo "${key} ${value}" >> "$SSHD_CONFIG"
        fi
    }

    set_sshd_param "Port"                  "$SSH_PORT"
    set_sshd_param "PermitRootLogin"       "prohibit-password"
    set_sshd_param "PasswordAuthentication" "no"
    set_sshd_param "PubkeyAuthentication"  "yes"
    set_sshd_param "X11Forwarding"         "no"
    set_sshd_param "MaxAuthTries"          "3"
    set_sshd_param "ClientAliveInterval"   "300"
    set_sshd_param "ClientAliveCountMax"   "2"

    # Валидация конфига перед перезапуском
    if sshd -t -f "$SSHD_CONFIG" 2>/dev/null; then
        systemctl restart sshd
        log "SSH настроен (порт ${SSH_PORT})"
    else
        err "Ошибка в sshd_config, откатываю"
        cp "$SSHD_BACKUP" "$SSHD_CONFIG"
        systemctl restart sshd
    fi
else
    info "SSH hardening пропущен (включить: --with-ssh-hardening)"
fi


# =============================================================================
# 4. Firewall (ufw)
# =============================================================================
if [[ "$SKIP_FIREWALL" == false ]]; then
    log "Настройка файрвола (ufw)..."

    apt-get install -y -qq ufw

    # Сброс правил
    ufw --force reset >/dev/null 2>&1

    # Политика по умолчанию
    ufw default deny incoming
    ufw default allow outgoing

    # SSH
    ufw allow "${SSH_PORT}/tcp" comment "SSH"

    # HTTP/HTTPS
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"

    # Matrix Federation (пропускаем если федерация на 443)
    if [[ "$FEDERATION_ON_443" != true ]]; then
        ufw allow 8448/tcp comment "Matrix Federation"
    fi

    # TURN/STUN (Coturn) — кастомные порты если указаны, иначе дефолтные
    ufw allow "${COTURN_STUN_PORT:-3478}/tcp" comment "STUN/TURN TCP"
    ufw allow "${COTURN_STUN_PORT:-3478}/udp" comment "STUN/TURN UDP"
    ufw allow "${COTURN_TURNS_PORT:-5349}/tcp" comment "TURNS TCP"
    ufw allow "${COTURN_TURNS_PORT:-5349}/udp" comment "TURNS UDP"
    ufw allow "${COTURN_RELAY_RANGE:-49152:49172}/udp" comment "TURN relay UDP"

    # LiveKit порты (если указаны)
    [[ -n "$LK_RTC_TCP" ]] && ufw allow "${LK_RTC_TCP}/tcp" comment "LiveKit RTC TCP"
    [[ -n "$LK_RTC_UDP" ]] && ufw allow "${LK_RTC_UDP}/udp" comment "LiveKit RTC UDP"
    [[ -n "$LK_TURN_TLS" ]] && ufw allow "${LK_TURN_TLS}/tcp" comment "LiveKit TURN TLS"
    [[ -n "$LK_TURN_TLS" ]] && ufw allow "${LK_TURN_TLS}/udp" comment "LiveKit TURN TLS UDP"
    [[ -n "$LK_TURN_UDP" ]] && ufw allow "${LK_TURN_UDP}/udp" comment "LiveKit TURN UDP"

    # Admin-панели на отдельных портах
    [[ -n "$KETESA_PORT" ]] && ufw allow "${KETESA_PORT}/tcp" comment "Ketesa"
    [[ -n "$ELEMENT_ADMIN_PORT" ]] && ufw allow "${ELEMENT_ADMIN_PORT}/tcp" comment "Element Admin"

    # Включаем
    ufw --force enable
    log "Файрвол настроен"
    ufw status numbered
else
    info "Файрвол пропущен (включить: --with-firewall)"
fi


# =============================================================================
# 5. Swap
# =============================================================================
if [[ "$SKIP_SWAP" == false && "$SWAP_SIZE" != "0" ]]; then
    log "Настройка swap (${SWAP_SIZE})..."

    if swapon --show | grep -q "/swapfile"; then
        warn "Swap уже существует, пропускаю"
    else
        fallocate -l "${SWAP_SIZE}" /swapfile
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile

        # Добавляем в fstab если ещё нет
        if ! grep -q "/swapfile" /etc/fstab; then
            echo "/swapfile none swap sw 0 0" >> /etc/fstab
        fi

        # Оптимальные параметры для сервера
        sysctl -w vm.swappiness=10 >/dev/null
        sysctl -w vm.vfs_cache_pressure=50 >/dev/null

        if ! grep -q "vm.swappiness" /etc/sysctl.d/99-matrix.conf 2>/dev/null; then
            cat > /etc/sysctl.d/99-matrix.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
        fi

        log "Swap ${SWAP_SIZE} создан"
    fi
else
    info "Swap пропущен"
fi


# =============================================================================
# 6. Docker
# =============================================================================
if [[ "$SKIP_DOCKER" == false ]]; then
    log "Установка Docker..."

    # Удаляем ВСЕ старые пакеты Docker (docker*, containerd, runc, podman)
    INSTALLED_DOCKER=$(dpkg --get-selections 2>/dev/null | grep -E '^(docker|containerd|runc|podman)' | grep -v deinstall | cut -f1 || true)
    if [[ -n "$INSTALLED_DOCKER" ]]; then
        warn "Удаляю старые пакеты Docker: ${INSTALLED_DOCKER//$'\n'/, }"
        # shellcheck disable=SC2086
        apt-get remove -y -qq --purge $INSTALLED_DOCKER
        apt-get autoremove -y -qq
    fi

    if command -v docker &>/dev/null && docker version --format '{{.Server.Version}}' &>/dev/null; then
        DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        info "Docker уже установлен: ${DOCKER_VER}"
    else
        # Официальный apt-репозиторий Docker
        install -m 0755 -d /etc/apt/keyrings

        if [[ "$OS_ID" == "ubuntu" ]]; then
            DOCKER_URL="https://download.docker.com/linux/ubuntu"
            DOCKER_CODENAME="${UBUNTU_CODENAME:-$OS_CODENAME}"
        else
            DOCKER_URL="https://download.docker.com/linux/debian"
            DOCKER_CODENAME="$OS_CODENAME"
        fi

        curl -fsSL "${DOCKER_URL}/gpg" -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: ${DOCKER_URL}
Suites: ${DOCKER_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        log "Docker установлен: $(docker --version)"
    fi

    # Добавляем deploy-пользователя в группу docker
    usermod -aG docker "${DEPLOY_USER}" 2>/dev/null || true

    # Остановить контейнеры от предыдущего деплоя (restart policy поднимет их при старте демона)
    if docker ps -q --filter name=matrix- 2>/dev/null | grep -q .; then
        warn "Обнаружены контейнеры от предыдущего деплоя — останавливаю..."
        docker ps -q --filter name=matrix- | xargs -r docker stop 2>/dev/null || true
        log "Старые контейнеры остановлены"
    fi

    # Автозапуск
    systemctl enable docker
    systemctl start docker
else
    info "Docker пропущен (--skip-docker, плейбук поставит сам)"
fi


# =============================================================================
# 6a. Ansible
# =============================================================================
log "Проверка Ansible..."

if command -v ansible &>/dev/null; then
    info "Ansible уже установлен: $(ansible --version | head -1)"
else
    log "Установка Ansible..."
    apt-get install -y -qq ansible
    log "Ansible установлен: $(ansible --version 2>/dev/null | head -1)"
fi


# =============================================================================
# 6b. just (command runner)
# =============================================================================
log "Проверка just..."

if command -v just &>/dev/null; then
    info "just уже установлен: $(just --version)"
else
    log "Установка just..."
    apt-get install -y -qq just 2>/dev/null || {
        # Если нет в репозиториях — ставим через prebuilt binary
        JUST_VERSION=$(curl -fsSL https://api.github.com/repos/casey/just/releases/latest | jq -r .tag_name)
        curl -fsSL "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz" | tar xz -C /usr/local/bin just
        chmod +x /usr/local/bin/just
    }
    log "just установлен: $(just --version)"
fi


if [[ "$SKIP_NGINX" == false ]]; then

# =============================================================================
# 7. nginx
# =============================================================================
log "Установка nginx..."

if command -v nginx &>/dev/null; then
    warn "nginx уже установлен: $(nginx -v 2>&1)"
else
    apt-get install -y -qq nginx
    systemctl enable nginx
    log "nginx установлен: $(nginx -v 2>&1)"
fi

# Создаём директорию для certbot webroot
mkdir -p /var/www/certbot

# Удаляем дефолтный конфиг
rm -f /etc/nginx/sites-enabled/default


# =============================================================================
# 8. Certbot
# =============================================================================
log "Установка certbot..."

if command -v certbot &>/dev/null; then
    warn "certbot уже установлен: $(certbot --version 2>&1)"
else
    apt-get install -y -qq certbot python3-certbot-nginx
    log "certbot установлен: $(certbot --version 2>&1)"
fi

# Файлы SSL-конфигурации nginx (certbot не всегда их создаёт)
mkdir -p /etc/letsencrypt
if [[ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]]; then
    curl -fsSL https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf \
        -o /etc/letsencrypt/options-ssl-nginx.conf
    log "options-ssl-nginx.conf скачан"
fi
if [[ ! -f /etc/letsencrypt/ssl-dhparams.pem ]]; then
    curl -fsSL https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem \
        -o /etc/letsencrypt/ssl-dhparams.pem
    log "ssl-dhparams.pem скачан"
fi


# =============================================================================
# 9. Получение SSL-сертификатов
# =============================================================================
log "Получение SSL-сертификатов..."

# Формируем список доменов для сертификата
CERT_DOMAINS=("${DOMAIN}" "matrix.${DOMAIN}" "element.${DOMAIN}")
[[ "$WITH_NTFY" == true ]] && CERT_DOMAINS+=("ntfy.${DOMAIN}")

# --- Проверка DNS перед запросом сертификата ---
MY_IP=$(curl -s --max-time 5 ifconfig.me || echo "")

info "Проверка DNS записей (должны указывать на ${MY_IP:-<этот сервер>}):"
echo ""

DNS_OK=true
for d in "${CERT_DOMAINS[@]}"; do
    RESOLVED_IP=$(dig +short "$d" A 2>/dev/null | tail -1)
    if [[ -z "$RESOLVED_IP" ]]; then
        echo -e "    ${RED}✗${NC} ${d} — ${RED}не резолвится${NC}"
        DNS_OK=false
    elif [[ -n "$MY_IP" && "$RESOLVED_IP" != "$MY_IP" ]]; then
        echo -e "    ${YELLOW}!${NC} ${d} → ${RESOLVED_IP} (ожидается ${MY_IP})"
        DNS_OK=false
    else
        echo -e "    ${GREEN}✓${NC} ${d} → ${RESOLVED_IP}"
    fi
done
echo ""

if [[ "$DNS_OK" == false ]]; then
    warn "Некоторые DNS записи не настроены или указывают на другой IP!"
    warn "Certbot не сможет получить сертификат без корректных DNS записей."
    echo ""
    echo -e "  Необходимые A-записи (все → ${MY_IP:-<IP сервера>}):"
    for d in "${CERT_DOMAINS[@]}"; do
        echo -e "    A  ${d}  →  ${MY_IP:-<IP>}"
    done
    echo ""
    read -rp "  Продолжить попытку получения сертификата? [y/N] " dns_continue
    if [[ ! "$dns_continue" =~ ^[Yy] ]]; then
        warn "Пропускаем получение сертификата."
        warn "После настройки DNS запусти вручную:"
        _certbot_cmd="certbot certonly --standalone"
        for d in "${CERT_DOMAINS[@]}"; do
            _certbot_cmd="${_certbot_cmd} -d ${d}"
        done
        warn "  ${_certbot_cmd}"
        # Продолжаем с настройкой nginx (без сертификата — nginx не запустится)
        CERT_PATH=""
    fi
fi

# --- Запрос сертификата ---
CERT_PATH="${CERT_PATH:-/etc/letsencrypt/live/${DOMAIN}/fullchain.pem}"

if [[ -n "$CERT_PATH" && -f "$CERT_PATH" ]]; then
    warn "Сертификат для ${DOMAIN} уже существует"
elif [[ -n "$CERT_PATH" ]]; then
    # Останавливаем nginx чтобы certbot мог использовать порт 80 (standalone)
    systemctl stop nginx 2>/dev/null || true

    # Собираем аргументы -d для certbot
    CERTBOT_DOMAIN_ARGS=()
    for d in "${CERT_DOMAINS[@]}"; do
        CERTBOT_DOMAIN_ARGS+=(-d "$d")
    done

    if certbot certonly --standalone --non-interactive --agree-tos \
        --email "${CERTBOT_EMAIL}" \
        "${CERTBOT_DOMAIN_ARGS[@]}"; then
        log "Сертификаты получены"
        # Переключаем renewal на webroot (standalone не работает пока nginx запущен)
        _renewal_conf="/etc/letsencrypt/renewal/${DOMAIN}.conf"
        if [[ -f "$_renewal_conf" ]]; then
            sed -i 's/^authenticator = standalone$/authenticator = webroot/' "$_renewal_conf"
            if ! grep -q '^\[\[webroot\]\]' "$_renewal_conf"; then
                {
                    echo "[[webroot]]"
                    for d in "${CERT_DOMAINS[@]}"; do
                        echo "${d} = /var/www/certbot"
                    done
                } >> "$_renewal_conf"
            fi
            log "Certbot renewal переключен на webroot"
        fi
    else
        err "Не удалось получить сертификаты."
        err "После настройки DNS запусти вручную:"
        _certbot_cmd="certbot certonly --standalone"
        for d in "${CERT_DOMAINS[@]}"; do
            _certbot_cmd="${_certbot_cmd} -d ${d}"
        done
        err "  ${_certbot_cmd}"
    fi
fi

# Автопродление (таймер certbot обычно ставится с пакетом, проверяем)
if systemctl list-timers | grep -q certbot; then
    info "Автопродление сертификатов: активно (certbot.timer)"
else
    # Добавляем cron как fallback
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
        info "Автопродление: добавлено в cron (03:00 ежедневно)"
    fi
fi

# Серты для LiveKit и Coturn (nginx+Traefik: Traefik без ACME → нужны свои серты)
if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    # Определяем UID/GID пользователя matrix (может отличаться на разных системах)
    _matrix_uid=$(id -u matrix 2>/dev/null || echo 0)
    _matrix_gid=$(id -g matrix 2>/dev/null || echo 0)
    if [[ "$_matrix_uid" == "0" ]]; then
        warn "Пользователь matrix ещё не создан — серты будут root:root (Ansible исправит владельца)"
    fi

    # LiveKit
    _lk_cert_dir="${DATA_PATH}/livekit-server/certs"
    mkdir -p "$_lk_cert_dir"
    cp -L "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${_lk_cert_dir}/fullchain.pem"
    cp -L "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" "${_lk_cert_dir}/privkey.pem"
    chown "${_matrix_uid}:${_matrix_gid}" "${_lk_cert_dir}"/*.pem 2>/dev/null || true
    chmod 640 "${_lk_cert_dir}"/*.pem
    log "LiveKit серты: скопированы в ${_lk_cert_dir}/"

    # Coturn
    _ct_cert_dir="${DATA_PATH}/coturn/certs"
    mkdir -p "$_ct_cert_dir"
    cp -L "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${_ct_cert_dir}/fullchain.pem"
    cp -L "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" "${_ct_cert_dir}/privkey.pem"
    chown "${_matrix_uid}:${_matrix_gid}" "${_ct_cert_dir}"/*.pem 2>/dev/null || true
    chmod 640 "${_ct_cert_dir}"/*.pem
    log "Coturn серты: скопированы в ${_ct_cert_dir}/"

    # Хук обновления сертов: копировать + рестартовать LiveKit, Coturn, nginx
    # UID/GID вписываются в хук как литералы (определены сейчас, не меняются)
    cat > /etc/letsencrypt/renewal-hooks/post/restart-matrix-tls.sh <<RLHOOK
#!/bin/bash
DOMAIN="${DOMAIN}"
LK_DIR="${_lk_cert_dir}"
CT_DIR="${_ct_cert_dir}"
MATRIX_UID="${_matrix_uid}"
MATRIX_GID="${_matrix_gid}"
for DIR in "\${LK_DIR}" "\${CT_DIR}"; do
    cp -L "/etc/letsencrypt/live/\${DOMAIN}/fullchain.pem" "\${DIR}/fullchain.pem"
    cp -L "/etc/letsencrypt/live/\${DOMAIN}/privkey.pem" "\${DIR}/privkey.pem"
    chown \${MATRIX_UID}:\${MATRIX_GID} "\${DIR}"/*.pem 2>/dev/null || true
    chmod 640 "\${DIR}"/*.pem
done
systemctl restart matrix-livekit-server 2>/dev/null || true
systemctl restart matrix-coturn 2>/dev/null || true
systemctl restart nginx 2>/dev/null || true
RLHOOK
    chmod +x /etc/letsencrypt/renewal-hooks/post/restart-matrix-tls.sh
    log "Certbot хук: restart-matrix-tls.sh создан"
fi


# =============================================================================
# 10. Конфигурация nginx для Matrix
# =============================================================================
log "Настройка nginx для Matrix..."

NGINX_CONF="/etc/nginx/sites-available/matrix.conf"

# Общий блок проксирования в Traefik
# shellcheck disable=SC2120
# Вставка ssl_protocols TLSv1.3 если --tls13-only
_ssl_extra() {
    if [[ "$TLS13_ONLY" == true ]]; then
        echo "    ssl_protocols TLSv1.3;"
    fi
}

_proxy_block() {
    local host_header="${1:-\$host}"
    cat <<PROXYBLOCK
        proxy_pass http://127.0.0.1:81;
        proxy_set_header Host ${host_header};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_hide_header X-Powered-By;
        proxy_hide_header Server;
        proxy_hide_header X-Frame-Options;
        proxy_hide_header X-Content-Type-Options;
        proxy_hide_header X-XSS-Protection;
        proxy_hide_header Content-Security-Policy;
        proxy_hide_header Referrer-Policy;
        proxy_hide_header Strict-Transport-Security;

        client_max_body_size ${MAX_UPLOAD_SIZE}M;

        proxy_connect_timeout 60s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
PROXYBLOCK
}

# Блок для media upload — ограничение скорости, чтобы не забивать канал
_media_location() {
    cat <<MEDIABLOCK
    # Media upload — троттлинг, чтобы большие файлы не блокировали сообщения
    location /_matrix/media/ {
        proxy_pass http://127.0.0.1:81;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;

        proxy_http_version 1.1;

        proxy_hide_header X-Powered-By;
        proxy_hide_header Server;
        proxy_hide_header X-Frame-Options;
        proxy_hide_header X-Content-Type-Options;
        proxy_hide_header X-XSS-Protection;
        proxy_hide_header Content-Security-Policy;
        proxy_hide_header Referrer-Policy;
        proxy_hide_header Strict-Transport-Security;

        client_max_body_size ${MAX_UPLOAD_SIZE}M;
        proxy_request_buffering off;
        limit_rate 2m;

        proxy_connect_timeout 60s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
    }
MEDIABLOCK
}

# Страница ошибок и landing page
mkdir -p /var/www/matrix-landing

# Копируем error.html из шаблонов
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../templates/error.html" ]]; then
    cp "${SCRIPT_DIR}/../templates/error.html" /var/www/matrix-landing/error.html
    log "Страница ошибок скопирована"
elif [[ -f "${SCRIPT_DIR}/templates/error.html" ]]; then
    cp "${SCRIPT_DIR}/templates/error.html" /var/www/matrix-landing/error.html
    log "Страница ошибок скопирована"
else
    # Fallback: генерируем минимальную страницу
    cat > /var/www/matrix-landing/error.html <<'ERROREOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>503</title>
<style>body{background:#0a0a0a;color:#00ff41;font-family:monospace;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
.c{text-align:center}.code{font-size:6rem;font-weight:900;text-shadow:0 0 20px #00ff41}.msg{margin-top:1rem;color:#00ff4180}</style>
</head><body><div class="c"><div class="code">502</div><div class="msg">The machine sleeps. It will rise again.</div></div></body></html>
ERROREOF
    log "Страница ошибок сгенерирована (fallback)"
fi

# Landing page шаблоны
if [[ "$WITH_LANDING_PAGE" == true ]]; then
    if [[ -f "${SCRIPT_DIR}/../templates/index.html" ]]; then
        cp "${SCRIPT_DIR}/../templates/index.html" /var/www/matrix-landing/index.html
        log "Landing page скопирована"
    fi
    if [[ -f "${SCRIPT_DIR}/../templates/tos.html" ]]; then
        cp "${SCRIPT_DIR}/../templates/tos.html" /var/www/matrix-landing/tos.html
        log "ToS page скопирована"
    fi
fi

# Branding assets (логотип, фон Element Web)
mkdir -p /var/www/matrix-landing/branding
_branding_src=""
if [[ -d "${SCRIPT_DIR}/../templates" ]]; then
    _branding_src="${SCRIPT_DIR}/../templates"
elif [[ -d "${SCRIPT_DIR}/templates" ]]; then
    _branding_src="${SCRIPT_DIR}/templates"
fi
if [[ -n "$_branding_src" ]]; then
    _branding_count=0
    for _bf in "$_branding_src"/element-*.svg "$_branding_src"/element-*.png; do
        [[ -f "$_bf" ]] || continue
        cp "$_bf" /var/www/matrix-landing/branding/
        _branding_count=$((_branding_count + 1))
    done
    if (( _branding_count > 0 )); then
        log "Branding: скопировано ${_branding_count} файл(ов) в /var/www/matrix-landing/branding/"
    fi
fi

# Формируем списки server_name для nginx блоков
_SN_EXTRA=""
[[ "$WITH_NTFY" == true ]] && _SN_EXTRA="${_SN_EXTRA}
        ntfy.${DOMAIN}"

# "сервисные домены" (без base domain — он в отдельном блоке)
_SN_SERVICES="    server_name
        matrix.${DOMAIN}
        element.${DOMAIN}${_SN_EXTRA};"

# HTTP redirect (все домены)
_SN_REDIRECT="    server_name
        ${DOMAIN}
        matrix.${DOMAIN}
        element.${DOMAIN}${_SN_EXTRA};"

{
cat <<NGINXEOF
# Matrix server — nginx reverse-proxy
# Автоматически сгенерировано prepare_server.sh

# Безопасность: скрываем версию nginx
server_tokens off;

# Логи отключены
access_log off;
error_log /dev/null;

NGINXEOF

# --- Base domain: DOMAIN ---
cat <<NGINXEOF
# --- HTTPS: ${DOMAIN} (base domain) ---
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;

    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
$(_ssl_extra)

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Content-Security-Policy "frame-ancestors 'none'" always;
    add_header Referrer-Policy no-referrer always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    root /var/www/html;
    index index.html index.nginx-debian.html;

    # .well-known — делегация Matrix → Traefik
    location /.well-known {
        proxy_pass http://127.0.0.1:81;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;

        proxy_http_version 1.1;

        proxy_hide_header X-Powered-By;
        proxy_hide_header Server;
        proxy_hide_header X-Frame-Options;
        proxy_hide_header X-Content-Type-Options;
        proxy_hide_header X-XSS-Protection;
        proxy_hide_header Content-Security-Policy;
        proxy_hide_header Referrer-Policy;
        proxy_hide_header Strict-Transport-Security;
    }

    error_page 502 503 504 /error.html;
    location = /error.html {
        internal;
        root /var/www/matrix-landing;
    }
}

NGINXEOF

# --- matrix.DOMAIN: с landing page или без ---
if [[ "$WITH_LANDING_PAGE" == true ]]; then
cat <<NGINXEOF
# --- HTTPS: matrix.${DOMAIN} — с landing page ---
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;

    server_name matrix.${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
$(_ssl_extra)

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Content-Security-Policy "frame-ancestors 'self'" always;
    add_header Referrer-Policy no-referrer always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    # Landing page на корне
    location = / {
        root /var/www/matrix-landing;
        try_files /index.html =404;
        add_header Cache-Control "no-cache, no-store";
        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options SAMEORIGIN always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Content-Security-Policy "frame-ancestors 'self'" always;
        add_header Referrer-Policy no-referrer always;
        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    }

    # Terms of Service
    location = /tos {
        root /var/www/matrix-landing;
        try_files /tos.html =404;
        add_header Cache-Control "no-cache, no-store";
        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options SAMEORIGIN always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Content-Security-Policy "frame-ancestors 'self'" always;
        add_header Referrer-Policy no-referrer always;
        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    }

    # Branding assets (логотип, фон)
    location /branding/ {
        root /var/www/matrix-landing;
        expires 1h;
        add_header Cache-Control "public, no-transform";
        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options SAMEORIGIN always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Content-Security-Policy "frame-ancestors 'self'" always;
        add_header Referrer-Policy no-referrer always;
        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    }

$(_media_location)

    # Всё остальное — в Traefik
    location / {
$(_proxy_block)
    }

    error_page 502 503 504 /error.html;
    location = /error.html {
        internal;
        root /var/www/matrix-landing;
    }
}

# --- HTTPS: остальные сервисы ---
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;

    server_name
        element.${DOMAIN}${_SN_EXTRA};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
$(_ssl_extra)

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Content-Security-Policy "frame-ancestors 'self'" always;
    add_header Referrer-Policy no-referrer always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    location / {
$(_proxy_block)
    }

    error_page 502 503 504 /error.html;
    location = /error.html {
        internal;
        root /var/www/matrix-landing;
    }
}
NGINXEOF
else
cat <<NGINXEOF
# --- HTTPS: все сервисы Matrix ---
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;

${_SN_SERVICES}

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
$(_ssl_extra)

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Content-Security-Policy "frame-ancestors 'self'" always;
    add_header Referrer-Policy no-referrer always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    # Branding assets (логотип, фон)
    location /branding/ {
        root /var/www/matrix-landing;
        expires 1h;
        add_header Cache-Control "public, no-transform";
        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options SAMEORIGIN always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Content-Security-Policy "frame-ancestors 'self'" always;
        add_header Referrer-Policy no-referrer always;
        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    }

$(_media_location)

    location / {
$(_proxy_block)
    }

    error_page 502 503 504 /error.html;
    location = /error.html {
        internal;
        root /var/www/matrix-landing;
    }
}
NGINXEOF
fi

if [[ "$FEDERATION_ON_443" != true ]]; then
cat <<NGINXEOF

# --- HTTPS: Matrix Federation (порт 8448) ---
server {
    listen 8448 ssl http2 default_server;
    listen [::]:8448 ssl http2 default_server;

    server_name matrix.${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
$(_ssl_extra)

    location / {
        proxy_pass http://127.0.0.1:8449;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;

        proxy_hide_header X-Powered-By;
        proxy_hide_header Server;
        proxy_hide_header X-Frame-Options;
        proxy_hide_header X-Content-Type-Options;
        proxy_hide_header X-XSS-Protection;
        proxy_hide_header Content-Security-Policy;
        proxy_hide_header Referrer-Policy;
        proxy_hide_header Strict-Transport-Security;

        client_max_body_size ${MAX_UPLOAD_SIZE}M;
    }

    error_page 502 503 504 /error.html;
    location = /error.html {
        internal;
        root /var/www/matrix-landing;
    }
}
NGINXEOF
fi

cat <<NGINXEOF

# --- HTTP → HTTPS redirect ---
server {
    listen 80;
    listen [::]:80;

${_SN_REDIRECT}

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGINXEOF

# --- Ketesa на отдельном порту ---
if [[ -n "$KETESA_PORT" ]]; then
cat <<NGINXEOF

# --- HTTPS: Ketesa (порт ${KETESA_PORT}) ---
server {
    listen ${KETESA_PORT} ssl http2;
    listen [::]:${KETESA_PORT} ssl http2;

    server_name matrix.${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
$(_ssl_extra)

    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;
    proxy_hide_header X-Frame-Options;
    proxy_hide_header X-Content-Type-Options;
    proxy_hide_header X-XSS-Protection;
    proxy_hide_header Content-Security-Policy;
    proxy_hide_header Referrer-Policy;
    proxy_hide_header Strict-Transport-Security;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Content-Security-Policy "frame-ancestors 'self'" always;
    add_header Referrer-Policy no-referrer always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    location / {
        proxy_pass http://127.0.0.1:81;
        proxy_set_header Host ketesa.internal;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;

        proxy_http_version 1.1;
    }

    error_page 502 503 504 /error.html;
    location = /error.html {
        internal;
        root /var/www/matrix-landing;
    }
}
NGINXEOF
fi

# --- Element Admin на отдельном порту ---
if [[ -n "$ELEMENT_ADMIN_PORT" ]]; then
cat <<NGINXEOF

# --- HTTPS: Element Admin (порт ${ELEMENT_ADMIN_PORT}) ---
server {
    listen ${ELEMENT_ADMIN_PORT} ssl http2;
    listen [::]:${ELEMENT_ADMIN_PORT} ssl http2;

    server_name matrix.${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
$(_ssl_extra)

    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;
    proxy_hide_header X-Frame-Options;
    proxy_hide_header X-Content-Type-Options;
    proxy_hide_header X-XSS-Protection;
    proxy_hide_header Content-Security-Policy;
    proxy_hide_header Referrer-Policy;
    proxy_hide_header Strict-Transport-Security;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Content-Security-Policy "frame-ancestors 'self'" always;
    add_header Referrer-Policy no-referrer always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    location / {
        proxy_pass http://127.0.0.1:81;
        proxy_set_header Host element-admin.internal;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;

        proxy_http_version 1.1;
    }

    error_page 502 503 504 /error.html;
    location = /error.html {
        internal;
        root /var/www/matrix-landing;
    }
}
NGINXEOF
fi

} > "$NGINX_CONF"

# Включаем конфиг
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/matrix.conf

# Проверяем и перезапускаем
if nginx -t 2>/dev/null; then
    systemctl restart nginx
    log "nginx перезапущен (новый конфиг активен)"
else
    warn "nginx конфиг невалиден (возможно сертификаты ещё не получены)"
    warn "После получения сертификатов: nginx -t && systemctl restart nginx"
fi

else
    info "Режим Traefik-only: nginx и certbot не устанавливаются"
    info "Traefik сам управляет SSL через Let's Encrypt ACME"
    info "Admin-панели доступны через пути/поддомены (настраивается в vars.yml):"
    info "  Ketesa: matrix.${DOMAIN}/ketesa (по умолчанию)"
    info "  Element Admin: admin.element.${DOMAIN}/ (по умолчанию)"
fi  # SKIP_NGINX


# =============================================================================
# 11. fail2ban (опционально, включается через --with-fail2ban)
# =============================================================================
if [[ "$SKIP_FAIL2BAN" == false ]]; then
    log "Настройка fail2ban..."

    apt-get install -y -qq fail2ban

    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 3
EOF

    if [[ "$SKIP_NGINX" == false ]]; then
        cat >> /etc/fail2ban/jail.local <<EOF

[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled = true
EOF
    fi

    systemctl enable fail2ban
    systemctl restart fail2ban
    log "fail2ban настроен"
else
    info "fail2ban пропущен (включить: --with-fail2ban)"
fi


# =============================================================================
# 12. Kernel tuning (сетевой стек)
# =============================================================================
log "Оптимизация сетевого стека..."

cat > /etc/sysctl.d/99-matrix-network.conf <<'EOF'
# TCP tuning
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Connection tracking
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535

# Security
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Keepalive
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5

# File descriptors
fs.file-max = 1048576
EOF

sysctl --system >/dev/null 2>&1
log "Сетевой стек оптимизирован"


# =============================================================================
# Итоги
# =============================================================================
SERVER_IP=$(curl -s --max-time 5 ifconfig.me || echo "<не удалось определить>")

echo ""
echo "============================================================================="
echo -e "${GREEN}  Сервер подготовлен для развёртывания Matrix${NC}"
echo "============================================================================="
echo ""
echo "  Домен:            ${DOMAIN}"
echo "  IP сервера:       ${SERVER_IP}"
echo "  Deploy user:      ${DEPLOY_USER}"
echo "  SSH порт:         ${SSH_PORT}"
echo ""
echo "  Установлено:"
command -v docker &>/dev/null && echo "    Docker:   $(docker --version 2>/dev/null)"
command -v ansible &>/dev/null && echo "    Ansible:  $(ansible --version 2>/dev/null | head -1)"
command -v just &>/dev/null && echo "    just:     $(just --version 2>/dev/null)"
if [[ "$PROXY_MODE" == "nginx" ]]; then
echo "    nginx:    $(nginx -v 2>&1 | head -1)"
echo "    certbot:  $(certbot --version 2>&1 | head -1)"
fi
if [[ "$SKIP_FAIL2BAN" == false ]]; then
echo "    fail2ban: $(fail2ban-client --version 2>&1 | head -1)"
fi
echo ""
if [[ "$PROXY_MODE" == "nginx" ]]; then
echo "  Reverse proxy:    nginx → Traefik"
echo "  SSL сертификат:   ${CERT_PATH}"
echo "  nginx конфиг:     /etc/nginx/sites-available/matrix.conf"
else
echo "  Reverse proxy:    Traefik-only (SSL через Let's Encrypt ACME)"
fi
echo ""
if [[ "$PROXY_MODE" == "nginx" ]]; then
    if [[ -n "$KETESA_PORT" || -n "$ELEMENT_ADMIN_PORT" ]]; then
echo "  Admin-панели (nginx → Traefik):"
[[ -n "$KETESA_PORT" ]] && echo "    Ketesa:  https://matrix.${DOMAIN}:${KETESA_PORT}/"
[[ -n "$ELEMENT_ADMIN_PORT" ]] && echo "    Element Admin:  https://matrix.${DOMAIN}:${ELEMENT_ADMIN_PORT}/"
echo ""
    fi
    if [[ "$WITH_LANDING_PAGE" == true ]]; then
echo "  Landing page:     /var/www/matrix-landing/index.html"
echo "  Terms of Service: /var/www/matrix-landing/tos.html"
echo ""
    fi
else
echo "  Admin-панели (Traefik):"
echo "    Ketesa:  https://matrix.${DOMAIN}/ketesa (по умолчанию)"
echo "    Element Admin:  https://admin.element.${DOMAIN}/ (по умолчанию)"
echo "    (настраивается через hostname/path_prefix в vars.yml)"
echo ""
fi
echo "  DNS записи (должны указывать на ${SERVER_IP}):"
echo "    A  ${DOMAIN}                -> ${SERVER_IP}  (stub + .well-known)"
echo "    A  matrix.${DOMAIN}         -> ${SERVER_IP}  (Synapse homeserver)"
echo "    A  element.${DOMAIN}        -> ${SERVER_IP}  (Element Web)"
[[ "$WITH_NTFY" == true ]] && \
echo "    A  ntfy.${DOMAIN}            -> ${SERVER_IP}  (ntfy push-уведомления)"
echo ""
echo "  Следующий шаг — запуск плейбука:"
echo "    cd matrix-docker-ansible-deploy"
echo "    just roles"
echo "    just install-all"
echo ""
echo "============================================================================="
