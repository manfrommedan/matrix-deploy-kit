#!/usr/bin/env bash
# =============================================================================
# LiveKit JWT Application Service (MSC4512) — самодостаточный онбординг
# =============================================================================
#
# Для УЖЕ РАЗВЁРНУТОГО сервера (без wizard'а generate_vars.sh): скрипт сам
# добавляет недостающие блоки в vars.yml (идемпотентно, PyYAML-merge),
# генерирует/синхронизирует токены + lk-as.yaml, ставит registration в
# synapse-конфиг, валидирует nginx, применяет через just install-all
# и гоняет живые smoke-проверки.
#
# ⚠️  ЭКСПЕРИМЕНТАЛЬНАЯ ФИЧА - используй осторожно. Legacy-путь
# (livekit_service_url) не трогается; откат: --uninstall.
#
# Использование:
#   bash tools/livekit-as-setup.sh                 # полный онбординг (apply включён)
#   bash tools/livekit-as-setup.sh --dry-run       # только проверки, ничего не пишет
#   bash tools/livekit-as-setup.sh --skip-install  # конфиг + валидация, без ansible
#   bash tools/livekit-as-setup.sh --uninstall     # откат (убрать блоки + registration)
#   bash tools/livekit-as-setup.sh -h              # справка
#
# Опции (кратко):
#   --vars PATH         путь к vars.yml (авто из playbook inventory)
#   --playbook-dir PATH корень matrix-docker-ansible-deploy (автоопределение)
#   --domain DOMAIN     bare-домен (авто, если vars.yml один)
#   --ws-path PATH      livekit_server_path_prefix (иначе значение в vars.yml,
#                       иначе /livekit-server) — traefik подхватит сам
#   --skip-install      не запускать just roles / just install-all
#   --skip-smoke        не ждать живых HTTP-проверок в конце
#                       (автоматически включается вместе с --skip-install)
#   --uninstall         снять AS-режим и переустановить
#   --dry-run           только чтения и проверки, файлов не трогаем
#                       (root не нужен)
#   -y                  не переспрашивать
#
# Требования: Synapse v1.161+, lk-jwt-service 0.7+, python3+PyYAML, just, curl.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

VARS_FILE=""
PLAYBOOK_ROOT=""
DOMAIN=""
WS_PATH=""
SKIP_INSTALL=false
SKIP_SMOKE=false
UNINSTALL=false
DRY_RUN=false
ASSUME_YES=false

usage() {
    cat <<'EOF'
livekit-as-setup.sh — самодостаточный онбординг AS-режима lk-jwt-service (MSC4512)

  --vars PATH          путь к vars.yml
  --playbook-dir PATH  корень плейбука matrix-docker-ansible-deploy
  --domain DOMAIN      bare-домен
  --ws-path PATH       livekit_server_path_prefix (иначе /livekit-server)
  --skip-install       не запускать just roles / just install-all
  --skip-smoke         не ждать живых HTTP-проверок
                       (вместе с --skip-install smoke тоже пропускается:
                        конфиг ещё не применён)
  --uninstall          снять AS-режим
  --dry-run            только проверки, файлов не трогаем (root не нужен)
  -y                   не переспрашивать
  -h, --help           эта справка
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vars)
            VARS_FILE="$2"
            shift 2
            ;;
        --playbook-dir)
            PLAYBOOK_ROOT="$2"
            shift 2
            ;;
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --ws-path)
            WS_PATH="$2"
            shift 2
            ;;
        --skip-install)
            SKIP_INSTALL=true
            shift
            ;;
        --skip-smoke)
            SKIP_SMOKE=true
            shift
            ;;
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -y)
            ASSUME_YES=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            err "Неизвестный параметр: $1"
            usage
            exit 1
            ;;
    esac
done

# dry-run только читает - root не нужен (конвенция как в deploy.sh)
if [[ "$DRY_RUN" != true ]]; then
    require_root
fi

# --- нахождение плейбука и vars.yml ---
if [[ -z "$PLAYBOOK_ROOT" ]]; then
    for cand in "${SCRIPT_DIR}/.." "/root/matrix-docker-ansible-deploy" "/opt/matrix-docker-ansible-deploy"; do
        if [[ -f "${cand}/setup.yml" ]]; then
            PLAYBOOK_ROOT="$(cd "$cand" && pwd)"
            break
        fi
    done
fi
[[ -n "$PLAYBOOK_ROOT" ]] || die "плейбук не найден. Укажи --playbook-dir PATH"

if [[ -z "$VARS_FILE" ]]; then
    if [[ -n "$DOMAIN" ]]; then
        VARS_FILE="${PLAYBOOK_ROOT}/inventory/host_vars/matrix.${DOMAIN}/vars.yml"
    else
        for candidate in "${PLAYBOOK_ROOT}"/inventory/host_vars/matrix.*; do
            if [[ -f "${candidate}/vars.yml" ]]; then
                VARS_FILE="${candidate}/vars.yml"
                break
            fi
        done
    fi
fi
[[ -n "$VARS_FILE" && -f "$VARS_FILE" ]] || die "vars.yml не найден. Укажи --vars PATH"

DOMAIN="${DOMAIN:-$(awk '/^matrix_domain:/ {sub(/^matrix_domain:[[:space:]]*/,""); gsub(/^["'"'"']|["'"'"']$/,""); print; exit}' "$VARS_FILE")}"
[[ -n "$DOMAIN" ]] || die "matrix_domain не найден в vars.yml (укажи --domain)"
DATA_PATH="$(awk '/^matrix_base_data_path:/ {sub(/^matrix_base_data_path:[[:space:]]*/,""); gsub(/^["'"'"']|["'"'"']$/,""); print; exit}' "$VARS_FILE")"
DATA_PATH="${DATA_PATH:-/matrix}"
MATRIX_HOST="matrix.${DOMAIN}"
AS_FILE="$(dirname "$VARS_FILE")/lk-as.yaml"
SYNAPSE_CFG_DIR="${DATA_PATH}/synapse/config"
if [[ "$UNINSTALL" == true ]]; then MODE_LABEL="откат"; else MODE_LABEL="онбординг"; fi
if [[ "$UNINSTALL" == true ]]; then STEP3_LABEL="убираю AS-блоки"; else STEP3_LABEL="обеспечиваю AS-блоки"; fi

# --- зависимости ---
command -v python3 &>/dev/null || die "нет python3 (нужен + PyYAML). apt-get install -y python3-yaml"
if ! python3 -c 'import yaml' &>/dev/null; then
    if [[ "$DRY_RUN" == true ]]; then
        # dry-run не мутирует систему - ставим явно в обычном режиме
        die "нет PyYAML (merge vars.yml нужен для проверок): apt-get install -y python3-yaml"
    fi
    command -v apt-get &>/dev/null || die "нет PyYAML: apt-get install -y python3-yaml"
    info "Ставлю python3-yaml..."
    apt-get install -y -qq python3-yaml
fi
command -v curl &>/dev/null || die "нет curl"
if [[ "$DRY_RUN" != true && "$SKIP_INSTALL" != true ]]; then
    command -v just &>/dev/null || die "нет just (нужен в ${PLAYBOOK_ROOT}), либо --skip-install"
fi

echo ""
echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${YELLOW}  ЭКСПЕРИМЕНТАЛЬНАЯ ФИЧА - lk-jwt-service AS-mode (MSC4512), ${MODE_LABEL}${NC}"
echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "vars:    ${VARS_FILE}"
info "domain:  ${MATRIX_HOST}"
info "data:    ${DATA_PATH}"
[[ "$DRY_RUN" == true ]] && warn "DRY-RUN: файлы не трогаем"
echo ""

# === 1. Предпроверки ===
header_text "1/6  Предпроверки"
if grep -qE "^livekit_server_enabled:[[:space:]]*false" "$VARS_FILE"; then
    die "в vars.yml явно livekit_server_enabled: false — сначала включи звонки"
fi
if ! grep -qE "^(livekit_server_|matrix_livekit_jwt_service_)" "$VARS_FILE"; then
    warn "в vars.yml не видно livekit_* блоков — звонки могут быть выключены wizard'ом."
    if [[ "$ASSUME_YES" != true ]]; then
        yes_no "Продолжить?" "y" || die "отменено"
    fi
fi
NGINX_CONF=""
if command -v nginx &>/dev/null; then
    NGINX_CONF="/etc/nginx/sites-enabled/matrix.conf"
    [[ ! -f "$NGINX_CONF" ]] && NGINX_CONF="/etc/nginx/sites-available/matrix.conf"
fi

# === 2. Токены ===
header_text "2/6  Токены (as_token/hs_token)"
AS_TOKEN_FILE=""
HS_TOKEN_FILE=""
if [[ -f "$AS_FILE" ]]; then
    AS_TOKEN_FILE="$(awk -F'"' '/^as_token:/ {print $2; exit}' "$AS_FILE")"
    HS_TOKEN_FILE="$(awk -F'"' '/^hs_token:/ {print $2; exit}' "$AS_FILE")"
    [[ -n "$AS_TOKEN_FILE" && -n "$HS_TOKEN_FILE" ]] || die "lk-as.yaml найден, но as_token/hs_token не читаются: $AS_FILE"
    ok "использую токены из существующего $AS_FILE"
else
    AS_TOKEN_FILE="$(openssl rand -hex 32)"
    HS_TOKEN_FILE="$(openssl rand -hex 32)"
    log "сгенерированы новые токены (lk-as.yaml будет создан)"
fi

# === 3. Merge vars.yml ===
header_text "3/6  vars.yml (${STEP3_LABEL})"
BACKUP="${VARS_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
DRAFT=""
if [[ "$DRY_RUN" == true ]]; then
    DRAFT="$(mktemp)"
    cp "$VARS_FILE" "$DRAFT"
    VARS_TARGET="$DRAFT"
else
    cp -p "$VARS_FILE" "$BACKUP"
    info "бэкап: ${BACKUP}"
    VARS_TARGET="$VARS_FILE"
fi

if ! env VARS_TARGET="$VARS_TARGET" WS_PATH="$WS_PATH" AS_TOKEN="$AS_TOKEN_FILE" HS_TOKEN="$HS_TOKEN_FILE" \
    UNINSTALL="$UNINSTALL" python3 <<'PYEOF'; then
import os, sys
import yaml

path = os.environ["VARS_TARGET"]
ws = os.environ.get("WS_PATH", "")
as_tok, hs_tok = os.environ["AS_TOKEN"], os.environ["HS_TOKEN"]
uninstall = os.environ.get("UNINSTALL") == "true"

URL_TMPL = "{{ livekit_server_websocket_public_url }}"
SVC_TMPL = "{{ matrix_livekit_jwt_service_public_url }}"
AS_PATH_IN_CONTAINER = "/data/lk-as.yaml"
AS_ENV_KEYS = ("LIVEKIT_AS_TOKEN", "LIVEKIT_HS_TOKEN", "LIVEKIT_HS_SERVER_NAME")

with open(path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f)
if data is None:
    data = {}

changed = []

if not uninstall:
    # 1) experimental_features_custom — merge (чужие флаги не трогаем)
    efc = data.get("matrix_synapse_experimental_features_custom")
    if not isinstance(efc, dict):
        if efc is not None:
            print("WARN: matrix_synapse_experimental_features_custom не dict - заменяю на {} + msc4512", file=sys.stderr)
        efc = {}
    if efc.get("msc4512_enabled") is not True:
        efc["msc4512_enabled"] = True
        changed.append("experimental_features_custom.msc4512_enabled = true")
    data["matrix_synapse_experimental_features_custom"] = efc

    # 2) версия jwt-сервиса — AS-режим есть с 0.7; держим latest
    #    (mdad: image tag :latest на ghcr; self-build на arm чеканет main)
    key = "matrix_livekit_jwt_service_version"
    cur = data.get(key)
    if cur != "latest":
        if cur is not None:
            print(f"WARN: {key} = {cur} - перезаписываю latest (AS-режим нужен с 0.7)", file=sys.stderr)
        changed.append(f"{key}: {cur if cur is not None else 'нет (mdad-default)'} -> latest")
        data[key] = "latest"

    # 3) transports — upsert livekit-записи (чужие записи не трогаем).
    #    Переопределяем ВЕСЬ список, а не _custom: у MDAD список = default+auto+custom,
    #    а default уже содержит livekit-запись TOЛЬКО c livekit_service_url -
    #    без полного переопреждения получились бы ДВЕ записи.
    key = "matrix_synapse_matrix_rtc_transports"
    transports = data.get(key)
    if not isinstance(transports, list):
        transports = [{"type": "livekit", "url": URL_TMPL, "livekit_service_url": SVC_TMPL}]
        changed.append("matrix_synapse_matrix_rtc_transports: создан (livekit с url + legacy)")
    else:
        entry = None
        for e in transports:
            if isinstance(e, dict) and e.get("type") == "livekit":
                entry = e
                break
        if entry is None:
            entry = {"type": "livekit", "url": URL_TMPL, "livekit_service_url": SVC_TMPL}
            transports.append(entry)
            changed.append("transports: добавлена livekit-запись")
        else:
            if entry.get("url") != URL_TMPL:
                entry["url"] = URL_TMPL
                changed.append("transports[livekit].url -> {{ livekit_server_websocket_public_url }}")
            if entry.get("livekit_service_url") != SVC_TMPL:
                entry["livekit_service_url"] = SVC_TMPL
                changed.append("transports[livekit].livekit_service_url -> {{ matrix_livekit_jwt_service_public_url }}")
    # parity с install-livekit-as.sh: MDAD склеивает transports + transports_custom,
    # livekit-запись во ВТОРОМ списке даст дубль (первая победит)
    custom = data.get("matrix_synapse_matrix_rtc_transports_custom")
    if isinstance(custom, list) and any(isinstance(e, dict) and e.get("type") == "livekit" for e in custom):
        print("WARN: matrix_synapse_matrix_rtc_transports_custom содержит livekit-запись - "
              "после merge будет ДВЕ livekit-записи (первая победит). Убери её из custom.", file=sys.stderr)
    data[key] = transports

    # 4) app_service_config_files — upsert пути
    key = "matrix_synapse_app_service_config_files"
    files_ = data.get(key)
    if not isinstance(files_, list):
        files_ = [AS_PATH_IN_CONTAINER]
        changed.append("app_service_config_files: создан")
    elif AS_PATH_IN_CONTAINER not in files_:
        files_.append(AS_PATH_IN_CONTAINER)
        changed.append("app_service_config_files: добавлен /data/lk-as.yaml")
    data[key] = files_

    # 5) env jwt-сервиса — пересобираем, чужие строки сохраняем
    ext = data.get("matrix_livekit_jwt_service_environment_variables_extension") or ""
    kept = [l for l in ext.splitlines() if l.strip() and not next((p for p in AS_ENV_KEYS if l.lstrip().startswith(p + "=")), None)]
    kept.append(f"LIVEKIT_AS_TOKEN={as_tok}")
    kept.append(f"LIVEKIT_HS_TOKEN={hs_tok}")
    kept.append("LIVEKIT_HS_SERVER_NAME={{ matrix_domain }}")
    new_ext = "\n".join(kept) + "\n"
    if ext != new_ext:
        data["matrix_livekit_jwt_service_environment_variables_extension"] = new_ext
        changed.append("env-expand jwt: LIVEKIT_AS/HS_TOKEN + HS_SERVER_NAME")
    # Ловушка require_matching_lk_url: ручной LIVEKIT_URL в env сверяется
    # побуквенно c transports[].url - любое расхождение = 400 M_INVALID_PARAM
    for l in ext.splitlines():
        if l.strip().startswith("LIVEKIT_URL="):
            print("WARN: в env есть LIVEKIT_URL - он должен побуквенно совпадать с transports[].url "
                  "(тот же публичный wss и path), иначе звонки будут падать с 400", file=sys.stderr)
            break

    # 6) path prefix
    key = "livekit_server_path_prefix"
    if ws:
        if data.get(key) != ws:
            data[key] = ws
            changed.append(f"livekit_server_path_prefix = {ws}")
    elif key not in data:
        data[key] = "/livekit-server"
        changed.append("livekit_server_path_prefix = /livekit-server (default)")
else:
    # --- uninstall ---
    efc = data.get("matrix_synapse_experimental_features_custom")
    if isinstance(efc, dict) and "msc4512_enabled" in efc:
        del efc["msc4512_enabled"]
        changed.append("experimental_features_custom: убран msc4512_enabled")
        if not efc:
            del data["matrix_synapse_experimental_features_custom"]

    key = "matrix_synapse_matrix_rtc_transports"
    transports = data.get(key)
    if isinstance(transports, list):
        kept = [e for e in transports if not (isinstance(e, dict) and e.get("type") == "livekit")]
        if len(kept) != len(transports):
            changed.append("transports: убрана livekit-запись (MDAD-default воссоздаст ее без url - legacy жив)")
            if kept:
                data[key] = kept
            else:
                del data[key]

    key = "matrix_synapse_app_service_config_files"
    files_ = data.get(key)
    if isinstance(files_, list) and AS_PATH_IN_CONTAINER in files_:
        files_ = [f for f in files_ if f != AS_PATH_IN_CONTAINER]
        changed.append("app_service_config_files: убран /data/lk-as.yaml")
        if files_:
            data[key] = files_
        else:
            del data[key]

    key = "matrix_livekit_jwt_service_environment_variables_extension"
    ext = data.get(key) or ""
    before = [l for l in ext.splitlines() if l.strip()]
    kept = [l for l in before if not any(l.lstrip().startswith(p + "=") for p in AS_ENV_KEYS)]
    if len(kept) != len(before):
        changed.append("env-expand jwt: убраны AS-строки")
        data[key] = ("\n".join(kept) + "\n") if kept else ""

    if "livekit_server_path_prefix" in data and data["livekit_server_path_prefix"] != "/livekit-server":
        del data["livekit_server_path_prefix"]
        changed.append("livekit_server_path_prefix: убран (MDAD-default вернётся)")

    key = "matrix_livekit_jwt_service_version"
    if data.get(key) == "latest":
        del data[key]
        changed.append("matrix_livekit_jwt_service_version: убран latest (MDAD-default вернётся)")

if changed:
    # safe_dump перекраивает формат (комментарии vars.yml теряются - файл генерируемый)
    with open(path, "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, sort_keys=False, allow_unicode=True, default_flow_style=False, width=4096)
    for c in changed:
        print(f"PATCHED: {c}")
    print("NOTE: vars.yml переписан PyYAML - формат перекроен, комментарии в нём потеряны"
          " (значимые значения сохранены)", file=sys.stderr)
else:
    print("OK: vars.yml уже в нужном состоянии (идемпотентно, ничего не пишется)")
PYEOF
    BACKUP_MSG=""
    [[ "$DRY_RUN" == true ]] || BACKUP_MSG=" Бэкап: ${BACKUP}"
    die "merge vars.yml не удался (см. выше)${BACKUP_MSG}"
fi
[[ -n "$DRAFT" ]] && rm -f "$DRAFT"

# === 4. Registration-файл ===
if [[ "$UNINSTALL" == false ]]; then
    header_text "4/6  lk-as.yaml (registration)"
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY] запись: ${AS_FILE}"
        info "[DRY] установка: ${SYNAPSE_CFG_DIR}/lk-as.yaml (mode 640)"
    else
        cat >"$AS_FILE" <<ASEOF
# lk-jwt-service Application Service registration (MSC4512, MSC4502)
# Управляется: tools/livekit-as-setup.sh (токены не меняй руками)
#
# Скоуп - c io.element.msc4502: ВНУТРИ URN (simple-версия роняет Synapse:
# "Unknown application service scope", appservice/__init__.py:71).
# proxy_* - namespace-ключи (простые proxy_prefix/proxy_url в v1.161 игнорирует).
id: "lk-jwt-service"
as_token: "${AS_TOKEN_FILE}"
hs_token: "${HS_TOKEN_FILE}"
sender_localpart: "_lk_jwt_service"
url: null    # event-traffic не нужен, но ключ обязателен

namespaces:
  users:
    - exclusive: false
      regex: ".*"        # покрыть всех (нужна is_joined проверка)

io.element.msc4502.scopes:
  - "urn:matrix:client:io.element.msc4502:rooms:is_joined"

io.element.msc4512.proxy_prefix: "rtc/livekit"
io.element.msc4512.proxy_url: "http://matrix-livekit-jwt-service:8080"
ASEOF
        chmod 600 "$AS_FILE"
        ok "записан: ${AS_FILE}"

        mkdir -p "$SYNAPSE_CFG_DIR"
        # Владелец = host-юзер MDAD (matrix_user_name, дефолт "matrix"), к которому
        # belong конфиг-файлы. Не matrix-synapse (такого host-юзера по умолчанию нет).
        OWNER="$(stat -c %U "${SYNAPSE_CFG_DIR}/homeserver.yaml" 2>/dev/null || echo matrix)"
        GROUP="$(stat -c %G "${SYNAPSE_CFG_DIR}/homeserver.yaml" 2>/dev/null || echo matrix)"
        install -m 640 -o "$OWNER" -g "$GROUP" "$AS_FILE" "${SYNAPSE_CFG_DIR}/lk-as.yaml"
        ok "установлен: ${SYNAPSE_CFG_DIR}/lk-as.yaml (640, ${OWNER}:${GROUP})"
    fi
else
    header_text "4/6  lk-as.yaml (откат)"
    if [[ "$DRY_RUN" != true && -f "${SYNAPSE_CFG_DIR}/lk-as.yaml" ]]; then
        rm -f "${SYNAPSE_CFG_DIR}/lk-as.yaml"
        ok "удалён: ${SYNAPSE_CFG_DIR}/lk-as.yaml"
    else
        info "активной копии в ${SYNAPSE_CFG_DIR} нет"
    fi
    info "inventory-копию ${AS_FILE} (там токены) можно удалить вручную"
fi

# === 5. nginx ===
header_text "5/6  nginx"
if command -v nginx &>/dev/null; then
    if nginx -t >/dev/null 2>&1; then
        ok "nginx -t: OK"
    else
        die "nginx -t не прошёл: nginx -t"
    fi
    if [[ -n "$NGINX_CONF" && -f "$NGINX_CONF" ]]; then
        if grep -qE 'proxy_set_header[[:space:]]+Upgrade' "$NGINX_CONF"; then
            ok "${NGINX_CONF}: Upgrade-хедеры на месте (WS до SFU пройдёт)"
        else
            warn "${NGINX_CONF}: нет proxy_set_header Upgrade - WS до SFU не поднимется."
            info "Добавь в server-блок matrix.${DOMAIN}:"
            PP="${WS_PATH:-$(awk '/^livekit_server_path_prefix:/ {sub(/^livekit_server_path_prefix:[[:space:]]*/,""); gsub(/^["'"'"']|["'"'"']$/,""); print; exit}' "$VARS_FILE")}"
            PP="${PP:-/livekit-server}"
            info "  location ${PP}/ {"
            info "      proxy_pass http://127.0.0.1:81;"
            info "      proxy_set_header Host \$host;"
            info "      proxy_set_header X-Forwarded-Proto https;"
            info "      proxy_http_version 1.1;"
            info "      proxy_set_header Upgrade \$http_upgrade;"
            info "      proxy_set_header Connection \"upgrade\";"
            info "      proxy_read_timeout 600s;"
            info "  }"
        fi
        if ! (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -qE '127\.0\.0\.1:81'; then
            warn "127.0.0.1:81 не слушает - traefik недоступен для nginx (будет 502)"
        fi
    else
        info "matrix.conf не найден - вероятно, traefik-only (WS идут напрямую через traefik - ок)"
    fi
else
    info "nginx не установлен (traefik-only) - WS идут напрямую через traefik"
fi

# === 6. Применение ===
header_text "6/6  Применение"
if [[ "$DRY_RUN" == true || "$SKIP_INSTALL" == true ]]; then
    info "ansible пропущен (dry-run: ${DRY_RUN}, --skip-install: ${SKIP_INSTALL})"
    if [[ "$ASSUME_YES" != true ]]; then
        echo ""
        info "Применить вручную:  cd ${PLAYBOOK_ROOT} && just roles && just install-all"
    fi
else
    log "cd ${PLAYBOOK_ROOT} && just roles && just install-all (несколько минут)..."
    (
        cd "$PLAYBOOK_ROOT"
        export LC_ALL="${LC_ALL:-C.UTF-8}" LANG="${LANG:-C.UTF-8}"
        just roles
        just install-all
    )
    ok "ansible применён"
fi

# === Живые smoke-проверки ===
# При --skip-install конфиг ещё не применён (install-all не гонялся),
# живой сервер живёт на старом конфиге - smoke дал бы ложные алерты.
if [[ "$SKIP_SMOKE" == false && "$DRY_RUN" != true && "$SKIP_INSTALL" != true ]]; then
    echo ""
    info "Smoke-проверки (HTTP, до 30c на шаг)..."
    base="https://${MATRIX_HOST}"

    code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${base}/_matrix/federation/v1/version" 2>/dev/null || echo "000")"
    if [[ "$code" == "000" ]]; then
        for _i in 1 2 3 4 5 6; do
            sleep 5
            code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${base}/_matrix/federation/v1/version" 2>/dev/null || echo "000")"
            [[ "$code" != "000" ]] && break
        done
    fi
    case "$code" in
        200)
            ver="$(curl -s --max-time 5 "${base}/_matrix/federation/v1/version" 2>/dev/null |
                python3 -c 'import sys,json;print(json.load(sys.stdin).get("server_version","?"))' 2>/dev/null || echo '?')"
            if [[ "$ver" =~ ^([0-9]+)\.([0-9]+) ]]; then
                if ((BASH_REMATCH[1] * 1000 + BASH_REMATCH[2] >= 1161)); then
                    ok "Synapse ${ver} (>= 1.161, msc4512 есть)"
                else
                    warn "Synapse ${ver} < 1.161 - msc4512/is_joined могут отсутствовать; обнови Synapse"
                fi
            else
                ok "federation/version жив (ответ: ${ver})"
            fi
            ;;
        *) warn "federation/version: HTTP ${code} (ожидалось 200)" ;;
    esac

    code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${base}/_matrix/client/unstable/org.matrix.msc4143/rtc/transports" 2>/dev/null || echo "000")"
    case "$code" in
        200 | 401) ok "rtc/transports жив (HTTP ${code}; 401 = нужен AT, норма)" ;;
        404) warn "rtc/transports: 404 - msc4143 не включился (в MDAD включается сам при ненулевых transports; install-all ещё отрабатывает?)" ;;
        000) info "rtc/transports: нет ответа (узел ещё стартует)" ;;
        *) warn "rtc/transports: HTTP ${code}" ;;
    esac

    code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -X POST \
        -H 'Content-Type: application/json' -d '{}' \
        "${base}/_matrix/client/unstable/io.element.msc4195/rtc/livekit/get_token" 2>/dev/null || echo "000")"
    if [[ "$UNINSTALL" == false ]]; then
        case "$code" in
            401 | 400 | 403 | 500 | 501) ok "MSC4512-прокси зарегистрирован (HTTP ${code} - дальше отвечает jwt-сервис)" ;;
            404) err "MSC4512-прокси: 404 - роут не зарегистрирован (нет msc4512_enabled / lk-as.yaml не смонтирован / Synapse < 1.161). Логи: journalctl -u matrix-synapse" ;;
            502 | 504) warn "MSC4512-прокси: HTTP ${code} - форвард на jwt-сервис не поднят (docker logs matrix-livekit-jwt-service)" ;;
            000) info "MSC4512-прокси: нет ответа (узел ещё стартует)" ;;
            *) warn "MSC4512-прокси: HTTP ${code}" ;;
        esac
    else
        case "$code" in
            404) ok "после отката: MSC4512-прокси 404 (как и должно)" ;;
            000) info "после отката: MSC4512-прокси без ответа" ;;
            *) warn "после отката: MSC4512-прокси ${code} (ожидалось 404; возможно, install-all ещё отрабатывает)" ;;
        esac
    fi

    if command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "matrix-livekit-jwt-service"; then
        # версия образа: AS-режим есть с 0.7 (mdad master: 0.7.0 на сегодня)
        lks_ver="$(docker inspect --format '{{.Config.Image}}' matrix-livekit-jwt-service 2>/dev/null | awk -F: '{print $NF}')"
        if [[ "$lks_ver" == "latest" ]]; then
            info "lk-jwt-service: образ :latest (= то, на что сейчас указывает реестр; актуальная версия ниже)"
        elif [[ "$lks_ver" =~ ^(0\.[0-6])\.[0-9]+$ ]]; then
            warn "lk-jwt-service ${lks_ver} < 0.7 - AS-режим (LIVEKIT_AS_TOKEN/...) в этой версии не читается"
            info "  обнови: matrix_livekit_jwt_service_version: latest в vars.yml + just install-all"
        elif [[ "$lks_ver" =~ ^[0-9] ]]; then
            ok "lk-jwt-service: образ v${lks_ver} (>= 0.7, AS-режим есть)"
        fi
        if [[ "$UNINSTALL" == false ]]; then
            if docker logs matrix-livekit-jwt-service 2>&1 | tail -200 | grep -q "Using application service configuration"; then
                ok "jwt-сервис: AS-конфиг активен (видит LIVEKIT_AS_TOKEN/HS_TOKEN)"
            else
                warn "jwt-сервис: 'Using application service configuration' в логах нет - AS-режим НЕ активировался"
                info "  docker logs matrix-livekit-jwt-service | grep -iE 'as|application service'"
            fi
        else
            info "jwt-сервис: AS-env исчезнет после следующего install-all"
        fi
    else
        info "контейнер matrix-livekit-jwt-service не найден (docker недоступен?) - skip"
    fi
fi

echo ""
if [[ "$UNINSTALL" == false ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        log "AS-режим готов (dry-run: файлы не писались - apply: перезапусти без --dry-run)"
    elif [[ "$SKIP_INSTALL" == true ]]; then
        log "AS-режим: конфиг готов (install-all не выполнялся, smoke пропущен)."
        info "Применить: cd ${PLAYBOOK_ROOT} && just roles && just install-all"
    else
        log "AS-режим установлен."
        info "Реальный звонок в свежем Element Call/Web - проверка. Логи: journalctl -u matrix-synapse | docker logs -f matrix-livekit-jwt-service"
    fi
    info "Откат: bash ${SCRIPT_DIR}/livekit-as-setup.sh --uninstall -y"
else
    if [[ "$DRY_RUN" == true ]]; then
        log "AS-режим будет снят (dry-run: файлы не писались)"
    else
        log "AS-режим снят"
    fi
    info "Возврат: bash ${SCRIPT_DIR}/livekit-as-setup.sh -y"
fi
