#!/usr/bin/env bash
# =============================================================================
# Matrix Server — быстрый деплой с нуля
# =============================================================================
# Запуск на целевом сервере от root:
#   bash deploy.sh
#
# Что делает:
#   1. Клонирует matrix-docker-ansible-deploy
#   2. Копирует tools/ в плейбук
#   3. Запускает интерактивный генератор vars.yml
#   4. Показывает следующие шаги
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

DEPLOY_DIR="/root/matrix-docker-ansible-deploy"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   Matrix Server — быстрый деплой                ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# --- Проверки ---
if [[ "$EUID" -ne 0 ]]; then
    err "Запусти от root"
    exit 1
fi

if ! command -v git &>/dev/null; then
    err "git не установлен. Запусти: apt-get install -y git"
    exit 1
fi

# --- Шаг 1: Клонирование плейбука ---
if [[ -d "$DEPLOY_DIR" ]]; then
    warn "Директория ${DEPLOY_DIR} уже существует"
    read -rp "  Удалить и клонировать заново? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$DEPLOY_DIR"
        log "Старая директория удалена"
    else
        info "Используем существующую"
    fi
fi

if [[ ! -d "$DEPLOY_DIR" ]]; then
    log "Клонирую matrix-docker-ansible-deploy..."
    git clone https://github.com/spantaleev/matrix-docker-ansible-deploy.git "$DEPLOY_DIR" 2>&1 | tail -1
    log "Плейбук клонирован"
fi

# --- Шаг 2: Копирование tools ---
log "Копирую tools/..."
mkdir -p "${DEPLOY_DIR}/tools"
cp "${SCRIPT_DIR}/tools/"*.sh "${DEPLOY_DIR}/tools/"
chmod +x "${DEPLOY_DIR}/tools/"*.sh

# Скрываем tools/ от git status
if ! grep -q "^tools/" "${DEPLOY_DIR}/.git/info/exclude" 2>/dev/null; then
    echo "tools/" >> "${DEPLOY_DIR}/.git/info/exclude"
fi
log "tools/ скопированы (4 скрипта)"

# --- Шаг 3: Landing page шаблоны ---
if [[ -d "${SCRIPT_DIR}/templates" ]]; then
    mkdir -p /var/www/matrix-landing
    if [[ ! -f /var/www/matrix-landing/index.html ]]; then
        cp "${SCRIPT_DIR}/templates/index.html" /var/www/matrix-landing/index.html
        cp "${SCRIPT_DIR}/templates/tos.html" /var/www/matrix-landing/tos.html
        log "Landing page шаблоны скопированы в /var/www/matrix-landing/"
        warn "Отредактируй index.html — замени SERVER_NAME на название сервера"
    else
        info "Landing page уже существует, пропускаю"
    fi
fi

# --- Шаг 4: Генерация vars.yml ---
echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════${NC}"
echo ""
log "Всё готово. Запускаю генератор конфигурации..."
echo ""

cd "$DEPLOY_DIR"
bash tools/generate_vars.sh

# --- Шаг 5: Итоги ---
echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════${NC}"
echo ""
log "Генерация завершена."
echo ""
info "Дальнейшие шаги:"
echo ""
echo "  1. Подготовь сервер (если ещё не сделано):"
echo "     bash ${DEPLOY_DIR}/tools/prepare_server.sh --domain <DOMAIN> [опции]"
echo ""
echo "  2. Загрузи роли и деплой:"
echo "     cd ${DEPLOY_DIR}"
echo "     export LC_ALL=C.UTF-8"
echo "     just roles"
echo "     just install-all"
echo ""
echo "  3. Создай администратора:"
echo "     docker exec matrix-authentication-service \\"
echo "       mas-cli manage register-user --yes admin --password <ПАРОЛЬ> --admin"
echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════${NC}"
