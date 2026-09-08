#!/usr/bin/env bash
# =============================================================================
# Matrix-deploy-kit - logrotate для Matrix и nginx логов
# =============================================================================
# Без ротации /var/log/matrix/* и /var/log/nginx/* могут съесть диск.
# Этот скрипт ставит logrotate-конфиг, который:
#   - ротирует логи при достижении 100 МБ
#   - хранит 10 сжатых архивов (gzip)
#   - ротирует ежедневно (если файл существует)
#   - применяется сразу через logrotate -f
#
# Использование:
#   bash tools/logrotate-matrix.sh              # установить конфиг
#   bash tools/logrotate-matrix.sh --uninstall  # убрать конфиг
#   bash tools/logrotate-matrix.sh --force      # применить ротацию сразу
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

LOGROTATE_CONF="/etc/logrotate.d/matrix-deploy-kit"
LOGROTATE_USER_CONF_DIR="/etc/logrotate.d"

usage() {
    cat <<EOF
$(header_text "logrotate-matrix" 2>&1 || true)

Использование:
  bash $(basename "$0") [опции]

Опции:
  --uninstall     Удалить конфиг /etc/logrotate.d/matrix-deploy-kit
  --force         Применить ротацию сразу (logrotate -f)
  -h, --help      Эта справка

После установки cron / logrotate.timer будет ротировать логи автоматически
раз в день. Чтобы запустить ротацию вручную:

  logrotate -f /etc/logrotate.d/matrix-deploy-kit
EOF
}

UNINSTALL=false
FORCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        --force)
            FORCE=true
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

require_root
require_cmd logrotate "apt-get install -y logrotate"

if [[ "$UNINSTALL" == true ]]; then
    if [[ -f "$LOGROTATE_CONF" ]]; then
        rm -f "$LOGROTATE_CONF"
        ok "Удалён: $LOGROTATE_CONF"
    else
        info "Конфиг $LOGROTATE_CONF не найден - нечего удалять"
    fi
    exit 0
fi

cat >"$LOGROTATE_CONF" <<'EOF'
# Matrix-deploy-kit - ротация логов
#
# Создано tools/logrotate-matrix.sh. Управляй через этот скрипт, не правь руками
# (иначе при следующем запуске перезапишется).

# --- Synapse + matrix-* (если логи пишутся на хост) ---
/var/log/matrix/*.log {
    size 100M
    rotate 10
    compress
    delaycompress
    missingok
    notifempty
    create 0640 matrix matrix
    sharedscripts
    postrotate
        # Если используется docker-compose - перезапусти Synapse
        # systemctl restart matrix-synapse.service 2>/dev/null || true
    endscript
}

/var/log/matrix/**/*.log {
    size 100M
    rotate 10
    compress
    delaycompress
    missingok
    notifempty
}

/matrix/synapse/storage/logs/*.log {
    size 100M
    rotate 10
    compress
    delaycompress
    missingok
    notifempty
    create 0640 matrix matrix
}

/matrix/ntfy/*.log {
    size 50M
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
}

# --- nginx (если не используешь docker-nginx и логи на хосте) ---
/var/log/nginx/*.log {
    size 100M
    rotate 10
    compress
    delaycompress
    missingok
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 $(cat /var/run/nginx.pid) 2>/dev/null || true
    endscript
}

# --- certbot ---
/var/log/letsencrypt/*.log {
    size 10M
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

ok "Установлен: $LOGROTATE_CONF"

# Проверим синтаксис
if logrotate -d "$LOGROTATE_CONF" >/dev/null 2>&1; then
    ok "Синтаксис logrotate: OK"
else
    err "Синтаксис logrotate: ошибка. Проверь: logrotate -d $LOGROTATE_CONF"
    exit 1
fi

# Если попросили - применим сразу
if [[ "$FORCE" == true ]]; then
    log "Принудительная ротация (logrotate -f)..."
    logrotate -f "$LOGROTATE_CONF"
    ok "Ротация применена"
fi

echo ""
info "Текущая конфигурация:"
echo "  Конфиг:       $LOGROTATE_CONF"
echo "  Лимит:        100M на файл (nginx, synapse), 50M (ntfy), 10M (certbot)"
echo "  Хранение:     10 архивов (gzip), delaycompress для свежести"
echo ""
info "Автоматическая ротация: раз в день через /etc/cron.daily/logrotate"
info "или systemd timer (logrotate.timer, если включён)."
echo ""
info "Проверить состояние:"
echo "  ls -lh /var/log/matrix/ /var/log/nginx/"
echo "  logrotate -d $LOGROTATE_CONF   # dry-run"
echo "  logrotate -f $LOGROTATE_CONF   # force-rotate"
