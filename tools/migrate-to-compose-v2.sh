#!/usr/bin/env bash
# =============================================================================
# Migrate docker-compose v1 (Python) → v2 (Go plugin standalone)
# =============================================================================
# Известная проблема: на новом Docker Engine (25+) старый docker-compose v1
# падает с `KeyError: 'ContainerConfig'` при пересоздании контейнеров.
# Решение — установить standalone v2 binary в cli-plugins.
#
# Usage: bash migrate-to-compose-v2.sh
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }

[[ "$EUID" -eq 0 ]] || { warn "Запуск от root"; exit 1; }

# Уже установлен?
if docker compose version &>/dev/null; then
    log "docker compose v2 уже установлен:"
    docker compose version
    exit 0
fi

# 1) Попробуем через apt — на свежих Debian/Ubuntu есть docker-compose-plugin в Docker repo
if apt-cache show docker-compose-plugin &>/dev/null; then
    log "Установка через apt: docker-compose-plugin"
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
    docker compose version
    exit 0
fi

# 2) Иначе standalone binary напрямую от Docker
log "apt-package недоступен — ставим standalone binary"

PLUGIN_DIR=/usr/local/lib/docker/cli-plugins
mkdir -p "$PLUGIN_DIR"

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  COMPOSE_ARCH=linux-x86_64 ;;
    aarch64) COMPOSE_ARCH=linux-aarch64 ;;
    armv7l)  COMPOSE_ARCH=linux-armv7 ;;
    *) warn "Unknown arch $ARCH — попробуем x86_64"; COMPOSE_ARCH=linux-x86_64 ;;
esac

URL="https://github.com/docker/compose/releases/latest/download/docker-compose-${COMPOSE_ARCH}"
log "Download: $URL"
curl -sSL "$URL" -o "$PLUGIN_DIR/docker-compose"
chmod +x "$PLUGIN_DIR/docker-compose"

# user-level fallback too
mkdir -p "$HOME/.docker/cli-plugins"
cp "$PLUGIN_DIR/docker-compose" "$HOME/.docker/cli-plugins/"

log "Установлено:"
docker compose version

log ""
log "Старый docker-compose (v1 Python) больше не нужен:"
log "  apt remove docker-compose       # если ставился через apt"
log "  pip uninstall docker-compose    # если ставился через pip"
log ""
log "Использовать v2 синтаксис (с пробелом, не дефисом):"
log "  docker compose ps"
log "  docker compose up -d"
log "  docker compose pull"
log "  docker compose restart <svc>"
