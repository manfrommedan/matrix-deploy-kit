#!/usr/bin/env bash
# =============================================================================
# Matrix Server — восстановление из бэкапа (создан backup.sh)
# =============================================================================
# Заливает pg_dumpall (все БД + роли) обратно в matrix-postgres и по флагу
# возвращает конфиги Synapse/MAS (вкл. signing.key).
#
# Использование:
#   bash restore.sh --latest                 # последний снимок из BACKUP_DIR
#   bash restore.sh /root/backups/20260620-030000
#   bash restore.sh --latest --config        # + восстановить конфиги
#   bash restore.sh --latest --dry-run
#
# Опции:
#   --latest            взять самый свежий снимок из BACKUP_DIR
#   --config            также восстановить конфиги Synapse/MAS из tar.gz
#   --clean             дропнуть целевые БД перед заливкой (чистая замена, если
#                       postgres уже с данными — иначе будет merge с конфликтами)
#   --playbook-dir P    путь к плейбуку (для just stop-all/start-all)
#   --data-path P       путь к данным Matrix (по умолчанию /matrix)
#   --yes, -y           без подтверждения
#   --dry-run, -n       показать план, ничего не делать
#
# ВАЖНО: чистое восстановление — на СВЕЖЕ развёрнутый сервер (БД ещё без данных).
# При заливке поверх существующих БД psql выдаст «… already exists» — это ожидаемо
# для ролей/баз; данные грузятся в рамках дампа.
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

BACKUP_DIR="${BACKUP_DIR:-/root/backups}"
MATRIX_DATA_PATH="${MATRIX_DATA_PATH:-/matrix}"
PG_CONTAINER="matrix-postgres"
PLAYBOOK_ROOT=""
SNAPSHOT=""
USE_LATEST=false
RESTORE_CONFIG=false
CLEAN=false
ASSUME_YES=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --latest)         USE_LATEST=true; shift ;;
        --config)         RESTORE_CONFIG=true; shift ;;
        --clean)          CLEAN=true; shift ;;
        --playbook-dir|-p) PLAYBOOK_ROOT="$2"; shift 2 ;;
        --data-path)      MATRIX_DATA_PATH="$2"; shift 2 ;;
        --yes|-y)         ASSUME_YES=true; shift ;;
        --dry-run|-n)     DRY_RUN=true; shift ;;
        -h|--help)        sed -n '2,30p' "$0"; exit 0 ;;
        -*)               err "Неизвестный параметр: $1"; exit 1 ;;
        *)                SNAPSHOT="$1"; shift ;;
    esac
done

[[ "$EUID" -eq 0 ]] || { err "Запуск от root"; exit 1; }
command -v docker &>/dev/null || { err "Docker не установлен"; exit 1; }

# --- Выбор снимка ---
if [[ "$USE_LATEST" == true ]]; then
    SNAPSHOT=$(ls -dt "$BACKUP_DIR"/2* 2>/dev/null | head -1 || true)
    [[ -n "$SNAPSHOT" ]] || { err "В $BACKUP_DIR нет снимков"; exit 1; }
fi
[[ -n "$SNAPSHOT" ]] || { err "Укажи снимок или --latest"; exit 1; }
[[ -d "$SNAPSHOT" ]] || { err "Каталог снимка не найден: $SNAPSHOT"; exit 1; }

DUMP="$SNAPSHOT/pgdumpall.sql.gz"
[[ -f "$DUMP" ]] || { err "Нет дампа БД в снимке: $DUMP"; exit 1; }
if ! gzip -t "$DUMP" 2>/dev/null; then
    err "Дамп повреждён (gzip -t): $DUMP"; exit 1
fi

# --- env-файл postgres ---
PG_ENV="${MATRIX_DATA_PATH}/postgres/env-postgres-psql"
[[ -f "$PG_ENV" ]] || { err "Не найден $PG_ENV — postgres не развёрнут?"; exit 1; }

# --- Автоопределение плейбука (для just stop-all/start-all) ---
if [[ -z "$PLAYBOOK_ROOT" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for c in "$SCRIPT_DIR/.." "$PWD" "/root/matrix-docker-ansible-deploy"; do
        [[ -f "$c/setup.yml" ]] && { PLAYBOOK_ROOT="$(cd "$c" && pwd)"; break; }
    done
fi

echo ""
info "Снимок:    $SNAPSHOT"
info "БД-дамп:   $DUMP ($(du -h "$DUMP" | cut -f1))"
info "Конфиги:   $([[ "$RESTORE_CONFIG" == true ]] && echo "будут восстановлены" || echo "пропустить (--config чтобы вернуть)")"
info "Режим БД:  $([[ "$CLEAN" == true ]] && echo "CLEAN — целевые БД будут пересозданы" || echo "merge в существующие (--clean для чистой замены)")"
info "Плейбук:   ${PLAYBOOK_ROOT:-<не найден, just не используется>}"
[[ -f "$SNAPSHOT/MANIFEST.txt" ]] && { echo ""; sed 's/^/    /' "$SNAPSHOT/MANIFEST.txt"; echo ""; }

if [[ "$DRY_RUN" == true ]]; then
    warn "DRY-RUN: ничего не выполнено"
    exit 0
fi

warn "ВНИМАНИЕ: восстановление перезапишет данные Matrix на этом сервере."
if [[ "$ASSUME_YES" != true ]]; then
    read -rp "  Продолжить? Напиши 'restore': " ans
    [[ "$ans" == "restore" ]] || { info "Отменено."; exit 0; }
fi

# --- Останавливаем сервисы (кроме postgres) ---
run_just() { [[ -n "$PLAYBOOK_ROOT" ]] && command -v just &>/dev/null && (cd "$PLAYBOOK_ROOT" && just "$@"); }

if [[ -n "$PLAYBOOK_ROOT" ]] && command -v just &>/dev/null; then
    log "Останавливаю сервисы (just stop-all)..."
    run_just stop-all || warn "just stop-all завершился с ошибкой — продолжаю"
else
    warn "Плейбук/just не найдены — останавливаю app-контейнеры вручную"
    docker ps -q --filter name=matrix- | while read -r cid; do
        name=$(docker inspect -f '{{.Name}}' "$cid" | sed 's#^/##')
        [[ "$name" == "$PG_CONTAINER" ]] && continue
        systemctl stop "${name}.service" 2>/dev/null || docker stop "$cid" >/dev/null 2>&1 || true
    done
fi

# --- Поднимаем только postgres и ждём готовности ---
log "Запускаю $PG_CONTAINER..."
systemctl start "${PG_CONTAINER}.service" 2>/dev/null || docker start "$PG_CONTAINER" >/dev/null 2>&1 || true

ready=false
for _ in $(seq 1 30); do
    if docker exec --env-file="$PG_ENV" "$PG_CONTAINER" pg_isready -h "$PG_CONTAINER" &>/dev/null; then
        ready=true; break
    fi
    sleep 2
done
[[ "$ready" == true ]] || { err "$PG_CONTAINER не отвечает (pg_isready)"; exit 1; }

# --- Чистая замена: дропаем целевые БД (имена берём из самого дампа) ---
if [[ "$CLEAN" == true ]]; then
    log "CLEAN: дроп целевых БД перед заливкой..."
    mapfile -t _dbs < <(gunzip -c "$DUMP" | grep -oP '^CREATE DATABASE \K"?[A-Za-z0-9_]+' | tr -d '"' | sort -u)
    for db in "${_dbs[@]}"; do
        [[ "$db" =~ ^(postgres|template0|template1)$ ]] && continue
        info "  drop $db"
        docker exec --env-file="$PG_ENV" "$PG_CONTAINER" \
            psql -h "$PG_CONTAINER" -v ON_ERROR_STOP=0 -d postgres \
            -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${db}' AND pid <> pg_backend_pid();" \
            -c "DROP DATABASE IF EXISTS \"${db}\";" >/dev/null 2>&1 \
            || warn "  не удалось дропнуть $db (продолжаю)"
    done
else
    warn "merge-режим: данные грузятся поверх существующих БД (возможны конфликты)."
    warn "Для чистой замены перезапусти с --clean."
fi

# --- Восстановление БД ---
log "Заливаю дамп в postgres (роли + все БД)..."
info "Сообщения вида «… already exists» при заливке поверх существующих БД — норма."
if gunzip -c "$DUMP" | docker exec -i --env-file="$PG_ENV" "$PG_CONTAINER" \
    psql -h "$PG_CONTAINER" -v ON_ERROR_STOP=0 postgres >/tmp/restore-pg.log 2>&1; then
    log "БД восстановлена (полный лог: /tmp/restore-pg.log)"
else
    err "psql вернул ошибку — смотри /tmp/restore-pg.log"
fi

# --- Восстановление конфигов (опционально) ---
if [[ "$RESTORE_CONFIG" == true ]]; then
    restore_cfg() {
        local arc="$1" dest="$2" name="$3"
        [[ -f "$arc" ]] || { warn "$name: $arc нет в снимке — пропуск"; return 0; }
        log "$name: распаковка в $dest"
        mkdir -p "$dest"
        tar xzf "$arc" -C "$dest"
    }
    restore_cfg "$SNAPSHOT/synapse-config.tar.gz" "${MATRIX_DATA_PATH}/synapse"                        "Synapse config"
    restore_cfg "$SNAPSHOT/mas-config.tar.gz"     "${MATRIX_DATA_PATH}/matrix-authentication-service"  "MAS config"
fi

# --- Поднимаем всё обратно ---
log "Запускаю сервисы..."
if [[ -n "$PLAYBOOK_ROOT" ]] && command -v just &>/dev/null; then
    run_just start-all || warn "just start-all завершился с ошибкой — проверь вручную"
else
    warn "Плейбук/just не найдены — подними сервисы сам: just start-all"
fi

echo ""
log "Восстановление завершено."
info "Проверь: docker ps  /  journalctl -fu matrix-synapse"
