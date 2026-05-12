#!/usr/bin/env bash
# =============================================================================
# Matrix Server — daily backup script
# =============================================================================
# pg_dump synapse + mas + signing keys + critical configs → /root/backups/
# Rotation: keep last 7 daily, last 4 weekly.
#
# Использование:
#   bash backup.sh                  # ручной запуск
#   bash backup.sh --install-cron   # установить daily cron @ 03:00
#
# Critical: bind-volume ≠ backup. При crash диска / rm -rf / pg corruption
# единственное что спасёт — независимый dump в другое место.
# =============================================================================

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/root/backups}"
RETENTION_DAYS=7

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }

# --- Install как cron ---
if [[ "${1:-}" == "--install-cron" ]]; then
    SCRIPT_PATH="$(readlink -f "$0")"
    CRON_LINE="0 3 * * * /usr/bin/env bash $SCRIPT_PATH >> /var/log/matrix-backup.log 2>&1"
    # idempotent
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "$CRON_LINE") | crontab -
    log "Cron установлен: ежедневно в 03:00"
    log "Логи: /var/log/matrix-backup.log"
    exit 0
fi

[[ "$EUID" -eq 0 ]] || { err "Запуск от root"; exit 1; }

mkdir -p "$BACKUP_DIR"
TS=$(date +%Y%m%d-%H%M%S)
DEST="$BACKUP_DIR/$TS"
mkdir -p "$DEST"

log "Backup → $DEST"

# =============================================================================
# 1) PostgreSQL (synapse + mas)
# =============================================================================
# Поддерживаем оба варианта: matrix-docker-ansible-deploy и docker-compose кастом
# Ищем postgres container по имени или по labels.

find_pg_container() {
    local db="$1"
    # 1) compose service name синапса по convention: matrix-postgres / postgres
    for c in "matrix-postgres" "postgres" "postgres-${db}" "${db}_postgres"; do
        if docker ps --format '{{.Names}}' | grep -qx "$c"; then
            echo "$c"; return 0
        fi
    done
    return 1
}

for db_label in "synapse:synapse" "mas:mas"; do
    db="${db_label%%:*}"
    user="${db_label##*:}"

    cont=$(find_pg_container "$db") || { warn "postgres контейнер для $db не найден — пропускаю"; continue; }

    log "pg_dump $db (контейнер: $cont)"
    if docker exec "$cont" pg_dump -U "$user" -d "$db" --clean --if-exists 2>/dev/null \
        | gzip -9 > "$DEST/pgdump-${db}.sql.gz"; then
        size=$(du -h "$DEST/pgdump-${db}.sql.gz" | cut -f1)
        log "  $db: $size"
    else
        err "  $db dump failed"
    fi
done

# =============================================================================
# 2) Synapse signing keys + homeserver.yaml (если найдём)
# =============================================================================
for path in \
    "/matrix/synapse/config" \
    "/root/next/synapse" \
    "/etc/matrix-synapse"; do
    if [[ -d "$path" ]]; then
        log "Synapse config snapshot: $path"
        tar czf "$DEST/synapse-config.tar.gz" -C "$(dirname "$path")" "$(basename "$path")" 2>/dev/null \
            && log "  $(du -h "$DEST/synapse-config.tar.gz" | cut -f1)"
        break
    fi
done

# =============================================================================
# 3) MAS config
# =============================================================================
for path in \
    "/matrix/matrix-authentication-service/config" \
    "/root/next/mas" \
    "/etc/mas"; do
    if [[ -d "$path" ]]; then
        log "MAS config: $path"
        tar czf "$DEST/mas-config.tar.gz" -C "$(dirname "$path")" "$(basename "$path")" 2>/dev/null
        break
    fi
done

# =============================================================================
# 4) nginx configs (vhosts) — необязательно, но полезно
# =============================================================================
if [[ -d /etc/nginx/sites-enabled ]]; then
    tar czf "$DEST/nginx-sites.tar.gz" -C /etc/nginx sites-enabled nginx.conf 2>/dev/null \
        && log "nginx configs: $(du -h "$DEST/nginx-sites.tar.gz" | cut -f1)"
fi

# =============================================================================
# 5) Manifest
# =============================================================================
cat > "$DEST/MANIFEST.txt" <<EOF
Matrix server backup
Timestamp: $TS
Host: $(hostname)
Synapse version: $(docker exec synapse python -c "import synapse; print(synapse.__version__)" 2>/dev/null || echo "?")
Files:
$(cd "$DEST" && ls -la | tail -n +2)
EOF

# =============================================================================
# 6) Rotate
# =============================================================================
log "Rotate: keep last $RETENTION_DAYS daily"
ls -dt "$BACKUP_DIR"/2* 2>/dev/null | tail -n +$((RETENTION_DAYS + 1)) | while read -r old; do
    log "  rm $old"
    rm -rf "$old"
done

# Total size
TOTAL=$(du -sh "$BACKUP_DIR" | cut -f1)
log "Backup complete. Total: $TOTAL"
log ""
log "RECOMMENDED: настрой off-site sync:"
log "  rsync -av $BACKUP_DIR/ remote:/path/   (другой сервер)"
log "  rclone sync $BACKUP_DIR/ s3:bucket/    (S3-compatible)"
