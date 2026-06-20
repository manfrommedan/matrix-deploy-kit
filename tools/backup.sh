#!/usr/bin/env bash
# =============================================================================
# Matrix Server — backup
# =============================================================================
# pg_dumpall (synapse + MAS + все БД и роли) + signing keys / конфиги → BACKUP_DIR.
# Ротация: последние RETENTION_DAYS снимков.
#
# Использование:
#   bash backup.sh                  # ручной запуск
#   bash backup.sh --install-cron   # daily cron @ 03:00
#
# Переменные окружения:
#   BACKUP_DIR         куда складывать (по умолчанию /root/backups — намеренно
#                      ВНЕ тома данных, чтобы дамп пережил порчу /matrix)
#   MATRIX_DATA_PATH   путь к данным Matrix (по умолчанию /matrix)
#   RETENTION_DAYS     сколько снимков хранить (по умолчанию 7)
# =============================================================================

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/root/backups}"
MATRIX_DATA_PATH="${MATRIX_DATA_PATH:-/matrix}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
PG_CONTAINER="matrix-postgres"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }

# --- Установка cron ---
if [[ "${1:-}" == "--install-cron" ]]; then
    SCRIPT_PATH="$(readlink -f "$0")"
    CRON_LINE="0 3 * * * /usr/bin/env bash $SCRIPT_PATH >> /var/log/matrix-backup.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "$CRON_LINE") | crontab -
    log "Cron установлен: ежедневно в 03:00 (лог: /var/log/matrix-backup.log)"
    exit 0
fi

[[ "$EUID" -eq 0 ]] || { err "Запуск от root"; exit 1; }
command -v docker &>/dev/null || { err "Docker не установлен"; exit 1; }

TS=$(date +%Y%m%d-%H%M%S)
DEST="$BACKUP_DIR/$TS"
mkdir -p "$DEST"
log "Backup → $DEST"

# --- 1) PostgreSQL: один контейнер, все БД и роли (pg_dumpall) ---
# Учётка и пароль берутся из env-файла плейбука (как в update.sh).
PG_ENV="${MATRIX_DATA_PATH}/postgres/env-postgres-psql"
if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
    warn "Контейнер $PG_CONTAINER не запущен — postgres пропущен"
elif [[ ! -f "$PG_ENV" ]]; then
    warn "Не найден $PG_ENV — postgres пропущен (нестандартная установка?)"
else
    log "pg_dumpall ($PG_CONTAINER)"
    if docker exec --env-file="$PG_ENV" "$PG_CONTAINER" \
        pg_dumpall -h "$PG_CONTAINER" | gzip -9 > "$DEST/pgdumpall.sql.gz"; then
        log "  postgres: $(du -h "$DEST/pgdumpall.sql.gz" | cut -f1)"
    else
        err "  pg_dumpall failed"
        rm -f "$DEST/pgdumpall.sql.gz"
    fi
fi

# --- 2) Конфиги Synapse (вкл. signing.key) ---
snapshot_dir() {
    local src="$1" out="$2"
    [[ -d "$src" ]] || return 1
    log "$3: $src"
    tar czf "$DEST/$out" -C "$(dirname "$src")" "$(basename "$src")" 2>/dev/null \
        && log "  $(du -h "$DEST/$out" | cut -f1)"
}
snapshot_dir "${MATRIX_DATA_PATH}/synapse/config"                       synapse-config.tar.gz "Synapse config" || \
    warn "Synapse config не найден в ${MATRIX_DATA_PATH}/synapse/config"

# --- 3) Конфиг MAS ---
snapshot_dir "${MATRIX_DATA_PATH}/matrix-authentication-service/config" mas-config.tar.gz     "MAS config" || true

# --- 4) nginx vhosts (если nginx-режим) ---
if [[ -d /etc/nginx/sites-enabled ]]; then
    tar czf "$DEST/nginx-sites.tar.gz" -C /etc/nginx sites-enabled nginx.conf 2>/dev/null \
        && log "nginx configs: $(du -h "$DEST/nginx-sites.tar.gz" | cut -f1)"
fi

# --- 5) Manifest ---
cat > "$DEST/MANIFEST.txt" <<EOF
Matrix server backup
Timestamp: $TS
Host: $(hostname)
Synapse: $(docker exec matrix-synapse python -c "import synapse; print(synapse.__version__)" 2>/dev/null || echo "?")
Files:
$(cd "$DEST" && ls -la | tail -n +2)
EOF

# --- 6) Ротация: последние RETENTION_DAYS снимков ---
log "Rotate: оставляю последние $RETENTION_DAYS"
ls -dt "$BACKUP_DIR"/2* 2>/dev/null | tail -n +$((RETENTION_DAYS + 1)) | while read -r old; do
    log "  rm $old"
    rm -rf "$old"
done

log "Backup complete. Total: $(du -sh "$BACKUP_DIR" | cut -f1)"
log "Off-site sync (рекомендуется):"
log "  rsync -av $BACKUP_DIR/ remote:/path/"
log "  rclone sync $BACKUP_DIR/ s3:bucket/"
