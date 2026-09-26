#!/usr/bin/env bash
# =============================================================================
# Matrix-deploy-kit - bootstrap + (опционально) full deploy
# =============================================================================
#
# Режимы:
#
#   1. Интерактивный (по умолчанию) - клонирует playbook, копирует tools/ и
#      templates/, запускает wizard для vars.yml. Дальше - руками:
#        bash tools/prepare_server.sh --domain X
#        cd playbook && just roles && just install-all
#
#   2. Полный деплой (--full) - после wizard'а сам запускает preflight,
#      prepare_server и Ansible. Ответы на wizard по-прежнему даёшь вживую.
#
# Использование:
#   bash deploy.sh                          # интерактивный
#   bash deploy.sh --full --domain X --email admin@X
#   bash deploy.sh --full --domain X --skip-preflight --skip-ansible
#
# Коды возврата:
#   0  ОК
#   1  ошибка использования
#   2  preflight нашёл проблемы (только с --full)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/_lib.sh
source "${SCRIPT_DIR}/tools/_lib.sh"

# --- дефолты ---
DEPLOY_DIR="/root/matrix-docker-ansible-deploy"
PLAYBOOK_URL="https://github.com/spantaleev/matrix-docker-ansible-deploy.git"
FULL=false
DOMAIN=""
EMAIL=""
SKIP_PREFLIGHT=false
SKIP_PREPARE=false
SKIP_ANSIBLE=false
SKIP_WIZARD=false
DRY_RUN=false
EXTRA_PREPARE_ARGS=()

# --- usage ---
usage() {
    cat <<EOF
$(header_text "deploy.sh" 2>&1 || true)

Использование:
  bash $(basename "$0") [опции]

Опции:
  --full                    Полный деплой: после wizard'а выполнит
                           preflight, prepare_server и Ansible.
  --domain, -d DOMAIN       Bare-домен (для preflight и prepare_server)
  --email EMAIL             Email для certbot (для prepare_server)
  --skip-preflight          В --full: не запускать preflight
  --skip-prepare            В --full: не запускать prepare_server
                           (для случая когда сервер уже подготовлен)
  --skip-ansible            В --full: не запускать Ansible
                           (только собрать vars.yml + подготовить хост)
  --skip-wizard             Не запускать wizard (если vars.yml уже есть)
  --deploy-dir PATH         Куда клонировать playbook
                           (по умолчанию: ${DEPLOY_DIR})
  --playbook-url URL        URL playbook (по умолчанию: ${PLAYBOOK_URL})
  --dry-run                 Пройти все шаги (preflight/wizard/prepare/ansible),
                           ничего не меняя. Все опасные команды (apt, systemctl,
                           git clone, ansible) печатаются, но не выполняются.
                           Полезно для проверки конфигурации.
  -h, --help                Эта справка

EOF
}

# --- парсинг аргументов ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)
            FULL=true
            shift
            ;;
        --domain | -d)
            DOMAIN="$2"
            shift 2
            ;;
        --email)
            EMAIL="$2"
            shift 2
            ;;
        --skip-preflight)
            SKIP_PREFLIGHT=true
            shift
            ;;
        --skip-prepare)
            SKIP_PREPARE=true
            shift
            ;;
        --skip-ansible)
            SKIP_ANSIBLE=true
            shift
            ;;
        --skip-wizard)
            SKIP_WIZARD=true
            shift
            ;;
        --deploy-dir)
            DEPLOY_DIR="$2"
            shift 2
            ;;
        --playbook-url)
            PLAYBOOK_URL="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                EXTRA_PREPARE_ARGS+=("$1")
                shift
            done
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

if [[ "$DRY_RUN" == true ]]; then
    warn "=== DRY-RUN MODE === (ничего не меняется на диске и в сети)"
fi

if [[ "$DRY_RUN" != true ]]; then
    require_root
fi
require_cmd git "apt-get install -y git"
require_cmd bash

# --- валидация ---
if [[ -n "$DOMAIN" ]] && ! [[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
    die "Домен '${DOMAIN}' не похож на валидный FQDN"
fi

if [[ "$FULL" == true && -z "$DOMAIN" ]]; then
    die "--full требует --domain"
fi

# 1. Плейбук
if [[ "$DRY_RUN" == true ]]; then
    log "[DRY] would: git clone ${PLAYBOOK_URL} ${DEPLOY_DIR}"
elif [[ -d "$DEPLOY_DIR" ]]; then
    warn "Директория ${DEPLOY_DIR} уже существует"
    if yes_no "Удалить и клонировать заново?" "n"; then
        rm -rf "$DEPLOY_DIR"
    fi
fi
if [[ "$DRY_RUN" != true ]] && [[ ! -d "$DEPLOY_DIR" ]]; then
    log "Клонирую playbook → ${DEPLOY_DIR}"
    git clone "$PLAYBOOK_URL" "$DEPLOY_DIR" 2>&1 | tail -1
fi

# 2. tools/ и templates/ в плейбук.
#    templates/ обязательны: prepare_server.sh ищет их в ../templates от tools/.
if [[ "$DRY_RUN" == true ]]; then
    log "[DRY] would: copy tools/*.sh + templates/* to ${DEPLOY_DIR}/"
else
    log "Копирую tools/ и templates/ в playbook"
    mkdir -p "${DEPLOY_DIR}/tools" "${DEPLOY_DIR}/templates"
    cp "${SCRIPT_DIR}/tools/"*.sh "${DEPLOY_DIR}/tools/"
    chmod +x "${DEPLOY_DIR}/tools/"*.sh
    cp "${SCRIPT_DIR}/templates/"* "${DEPLOY_DIR}/templates/" 2>/dev/null || true

    # Чтобы наши файлы не светились в git status плейбука
    for ex in "tools/" "templates/"; do
        grep -qx "$ex" "${DEPLOY_DIR}/.git/info/exclude" 2>/dev/null ||
            echo "$ex" >>"${DEPLOY_DIR}/.git/info/exclude"
    done
fi

# 3. Wizard vars.yml
if [[ "$DRY_RUN" == true ]]; then
    log "[DRY] would: запустить wizard для генерации vars.yml (интерактивно)"
elif [[ "$SKIP_WIZARD" == true ]]; then
    log "Пропускаю wizard (--skip-wizard)"
elif [[ ! -f "${DEPLOY_DIR}/inventory/host_vars/matrix.${DOMAIN:-example.com}/vars.yml" ]]; then
    echo
    log "Запускаю wizard для генерации vars.yml"
    cd "$DEPLOY_DIR"
    bash tools/generate_vars.sh
else
    info "vars.yml уже существует - пропускаю wizard. Используй --skip-wizard=false чтобы пересоздать."
fi

# 4. Preflight (только в --full и если есть домен)
if [[ "$FULL" == true ]]; then
    if [[ "$SKIP_PREFLIGHT" == true ]]; then
        log "Preflight пропущен (--skip-preflight)"
    else
        log "Preflight: ${DOMAIN}"
        # В dry-run используем локальный preflight (клона плейбука ещё нет)
        preflight_script="${SCRIPT_DIR}/tools/preflight.sh"
        if [[ "$DRY_RUN" != true ]]; then
            preflight_script="${DEPLOY_DIR}/tools/preflight.sh"
        fi
        set +e
        bash "$preflight_script" --domain "$DOMAIN" --no-ssl
        rc=$?
        set -e
        if [[ $rc -ne 0 ]]; then
            if [[ $rc -eq 2 ]]; then
                if [[ "$DRY_RUN" == true ]]; then
                    log "[DRY] preflight нашёл проблемы - в обычном режиме спросил бы"
                else
                    err "Preflight нашёл проблемы. Продолжаю по вашему запросу - но деплой может провалиться."
                    if ! yes_no "Продолжить всё равно?" "n"; then
                        die "Прервано пользователем"
                    fi
                fi
            else
                die "Preflight завершился с ошибкой (rc=$rc)"
            fi
        fi
    fi
fi

# 5. prepare_server (только в --full)
if [[ "$FULL" == true && "$SKIP_PREPARE" == false ]]; then
    prepare_args=(--domain "$DOMAIN")
    [[ -n "$EMAIL" ]] && prepare_args+=(--email "$EMAIL")
    if ((${#EXTRA_PREPARE_ARGS[@]} > 0)); then
        prepare_args+=("${EXTRA_PREPARE_ARGS[@]}")
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY] would run: prepare_server.sh ${prepare_args[*]}"
        log "[DRY]   (Docker, nginx, certbot, ufw, fail2ban, swap,"
        log "[DRY]    landing page, /tos, ntfy, random LiveKit ports)"
    else
        log "Подготовка сервера"
        bash "${DEPLOY_DIR}/tools/prepare_server.sh" "${prepare_args[@]}"
    fi
fi

# 6. Ansible (только в --full и если не сказано пропустить)
if [[ "$FULL" == true && "$SKIP_ANSIBLE" == false ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY] would run: cd ${DEPLOY_DIR} && export LC_ALL=C.UTF-8 && just roles && just install-all"
        log "[DRY] (AS-режим: pre-seed lk-as.yaml в synapse config-dir до install-all"
        log "[DRY]  + tools/install-livekit-as.sh после него)"
    else
        log "Установка ролей и запуск Ansible"
        cd "$DEPLOY_DIR"
        export LC_ALL=C.UTF-8

        # 6.A Pre-seed lk-as.yaml ДО install-all.
        # Wizard уже прописал в vars.yml app_service_config_files: [/data/lk-as.yaml],
        # а Synapse на старте делает open() на каждый такой путь (synapse/config/appservice.py load_appservices)
        # - файла нет = ошибка конфигурации = crash-loop. install-all стартует matrix-synapse,
        # а 6.5-хук положит файл слишком поздно. Доложим его заранее.
        # На ФРЕШ-сервере юзер matrix и config-dir ещё не существуют (создаст install-all)
        # - тогда кладём root:root 644: synapse от non-root читает через dir 0750 matrix:matrix,
        # а chown -R в MDAD на config-dir не делает (только Synology) - 644 закрывает окно
        # crash-loop между install-all и 6.5 (6.5 всё равно переустановит 640 matrix:matrix).
        for as_src in "${DEPLOY_DIR}"/inventory/host_vars/matrix.*/lk-as.yaml; do
            [[ -f "$as_src" ]] || continue
            as_vars="$(dirname "$as_src")/vars.yml"
            as_data_path="$(awk '/^matrix_base_data_path:/ {sub(/^matrix_base_data_path:[[:space:]]*/,""); gsub(/^["'"'"']|["'"'"']$/,""); print; exit}' "$as_vars")"
            as_data_path="${as_data_path:-/matrix}"
            as_cfg_dir="${as_data_path}/synapse/config"
            mkdir -p "$as_cfg_dir"
            as_owner=""
            as_group=""
            if [[ -f "${as_cfg_dir}/homeserver.yaml" ]]; then
                as_owner="$(stat -c %U "${as_cfg_dir}/homeserver.yaml" 2>/dev/null || true)"
                as_group="$(stat -c %G "${as_cfg_dir}/homeserver.yaml" 2>/dev/null || true)"
            elif id matrix &>/dev/null; then
                # config-dir принадлежит matrix_user_name (дефолт "matrix")
                as_owner="matrix"
                as_group="matrix"
            fi
            as_mode=640
            if [[ -z "$as_owner" ]]; then
                # fresh-сервер: файл root:root, а dir скоро станет 0750 matrix:matrix (synapse-роль).
                # 644: non-root synapse читает через dir (world-read на файл гейтится dir).
                as_mode=644
            fi
            install -m "$as_mode" ${as_owner:+-o "$as_owner"} ${as_group:+-g "$as_group"} \
                "$as_src" "${as_cfg_dir}/lk-as.yaml"
            log "Pre-seed AS registration: ${as_cfg_dir}/lk-as.yaml (${as_mode}${as_owner:+, ${as_owner}:${as_group}})"
            break
        done

        just roles
        just install-all
    fi
fi

# 6.5. AS-режим LiveKit (ЭКСПЕРИМЕНТАЛЬНАЯ ФИЧА) - только если wizard его сгенерировал
AS_STATUS=""
if [[ "$FULL" == true && "$SKIP_ANSIBLE" == false ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        if ls "${DEPLOY_DIR}"/inventory/host_vars/matrix.*/lk-as.yaml 2>/dev/null; then
            log "[DRY] would run: bash tools/install-livekit-as.sh -y"
            AS_STATUS="[DRY] AS-режим будет поставлен (install-livekit-as.sh)"
        fi
    else
        for as_file in "${DEPLOY_DIR}"/inventory/host_vars/matrix.*/lk-as.yaml; do
            [[ -f "$as_file" ]] || continue
            log "Найден lk-as.yaml (${as_file}) - установка Application Service режима"
            if bash "${DEPLOY_DIR}/tools/install-livekit-as.sh" \
                --vars "$(dirname "$as_file")/vars.yml" -y; then
                AS_STATUS="AS-режим установлен (MSC4512, lk-as.yaml)"
            else
                AS_STATUS="AS-режим НЕ установлен - legacy-звонки будут работать. Вручную: bash ${DEPLOY_DIR}/tools/install-livekit-as.sh --vars $(dirname "$as_file")/vars.yml"
                warn "install-livekit-as.sh завершился неудачей - звонки на legacy-режиме будут работать,"
                warn "  но AS-режим не активировался (повторная команда - в «Итоге» ниже)."
            fi
            break
        done
    fi
fi

# 7. Итог
AS_STATUS_LINE=""
if [[ -n "$AS_STATUS" ]]; then
    # статус 6.5 выносим в итог, чтобы при неудаче он не утонул в логe
    AS_STATUS_LINE="${AS_STATUS}"$'\n\n'
fi
cat <<EOF

$(ok "Готово.")
${AS_STATUS_LINE}
Что дальше:

  • Зайти в Element Web:        https://element.${DOMAIN:-example.com}/
  • Залогиниться в админку:      https://matrix.${DOMAIN:-example.com}/
  • Создать админ-пользователя:
      docker exec matrix-authentication-service \\
        mas-cli manage register-user --yes admin --password <ПАРОЛЬ> --admin

  • Бэкап:                       bash ${DEPLOY_DIR}/tools/backup.sh
  • Healthcheck:                 bash ${DEPLOY_DIR}/tools/healthcheck.sh
  • Обновление:                  bash ${DEPLOY_DIR}/tools/update.sh
EOF
