#!/usr/bin/env bash
#
# Bootstrap: клонирует matrix-docker-ansible-deploy, кладёт в него tools/ и
# templates/ из этого набора и запускает генератор vars.yml.
#
# Запуск от root на целевом сервере:
#   bash deploy.sh
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

DEPLOY_DIR="/root/matrix-docker-ansible-deploy"
PLAYBOOK_URL="https://github.com/spantaleev/matrix-docker-ansible-deploy.git"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ "$EUID" -eq 0 ]] || { err "Запусти от root"; exit 1; }
command -v git &>/dev/null || { err "Нет git: apt-get install -y git"; exit 1; }

# 1. Плейбук
if [[ -d "$DEPLOY_DIR" ]]; then
    warn "Директория ${DEPLOY_DIR} уже существует"
    read -rp "    Удалить и клонировать заново? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] && rm -rf "$DEPLOY_DIR"
fi
if [[ ! -d "$DEPLOY_DIR" ]]; then
    log "Клонирую плейбук"
    git clone "$PLAYBOOK_URL" "$DEPLOY_DIR" 2>&1 | tail -1
fi

# 2. tools/ и templates/ в плейбук.
#    templates/ обязательны: prepare_server.sh ищет их в ../templates от tools/.
log "Копирую tools/ и templates/ в плейбук"
mkdir -p "${DEPLOY_DIR}/tools" "${DEPLOY_DIR}/templates"
cp "${SCRIPT_DIR}/tools/"*.sh "${DEPLOY_DIR}/tools/"
chmod +x "${DEPLOY_DIR}/tools/"*.sh
cp "${SCRIPT_DIR}/templates/"* "${DEPLOY_DIR}/templates/" 2>/dev/null || true

# Чтобы наши файлы не светились в git status плейбука
for ex in "tools/" "templates/"; do
    grep -qx "$ex" "${DEPLOY_DIR}/.git/info/exclude" 2>/dev/null \
        || echo "$ex" >> "${DEPLOY_DIR}/.git/info/exclude"
done

# Landing page разворачивает prepare_server.sh --with-landing-page (с подстановкой
# домена). Здесь в /var/www ничего не кладём.

# 3. Генератор vars.yml
echo
cd "$DEPLOY_DIR"
bash tools/generate_vars.sh

# 4. Следующие шаги
cat <<EOF

Дальше:

  1. Подготовка сервера (если ещё не делалась):
       bash ${DEPLOY_DIR}/tools/prepare_server.sh --domain <DOMAIN> [опции]

  2. Деплой:
       cd ${DEPLOY_DIR}
       export LC_ALL=C.UTF-8
       just roles
       just install-all

  3. Администратор:
       docker exec matrix-authentication-service \\
         mas-cli manage register-user --yes admin --password <ПАРОЛЬ> --admin
EOF
