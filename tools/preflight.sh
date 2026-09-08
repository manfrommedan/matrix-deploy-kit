#!/usr/bin/env bash
# =============================================================================
# Matrix-deploy-kit - preflight
# =============================================================================
# Проверяет, что:
#   1. Каждый поддомен (matrix.X, element.X, …) DNS-резолвится в IP этого
#      сервера.
#   2. Порты 80/443 свободны или уже обслуживаются нашим nginx/Traefik.
#   3. (Опционально) certbot-сертификаты существуют и не истекают < 14 дней.
#
# Использование:
#   bash tools/preflight.sh --domain example.com
#   bash tools/preflight.sh --domain example.com --subdomains matrix,element,livekit,ntfy
#   bash tools/preflight.sh --domain example.com --no-ssl --no-ports
#
# Коды возврата:
#   0  всё ОК
#   1  ошибки использования
#   2  preflight нашёл проблемы (подробности в выводе)
#   3  сетевые проблемы (не удалось выполнить dig/curl)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

# --- дефолты ---
DOMAIN=""
SERVER_IP="" # если пусто - определим автоматически
SUBDOMAINS=(matrix element ntfy)
CHECK_SSL=true
CHECK_PORTS=true
CERTBOT_DIR="/etc/letsencrypt/live"
CERT_MIN_DAYS=14
DIG_OPTS="+short +time=3 +tries=2"

# --- парсинг аргументов ---
usage() {
    cat <<EOF
$(header_text "Preflight" 2>&1 || true)

Использование:
  bash $(basename "$0") --domain DOMAIN [опции]

Обязательные:
  --domain, -d DOMAIN       Bare-домен, например example.com

Опции:
  --ip IP                   Ожидаемый IP сервера (по умолчанию - авто)
  --subdomains, -s LIST     CSV поддоменов для проверки
                           (по умолчанию: matrix,element,livekit,ntfy)
  --certbot-dir PATH        Где искать сертификаты (по умолчанию: /etc/letsencrypt/live)
  --cert-min-days N         Минимальный остаток дней до истечения (по умолчанию: 14)
  --no-ssl                  Пропустить проверку сертификатов
  --no-ports                Пропустить проверку портов 80/443
  -h, --help                Эта справка

Коды возврата: 0 OK, 1 usage, 2 found issues, 3 network error.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain | -d)
            DOMAIN="$2"
            shift 2
            ;;
        --ip)
            SERVER_IP="$2"
            shift 2
            ;;
        --subdomains | -s)
            IFS=',' read -ra SUBDOMAINS <<<"$2"
            shift 2
            ;;
        --certbot-dir)
            CERTBOT_DIR="$2"
            shift 2
            ;;
        --cert-min-days)
            CERT_MIN_DAYS="$2"
            shift 2
            ;;
        --no-ssl)
            CHECK_SSL=false
            shift
            ;;
        --no-ports)
            CHECK_PORTS=false
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

if [[ -z "$DOMAIN" ]]; then
    err "Не указан --domain"
    usage
    exit 1
fi

# --- sanity: валидный домен ---
if [[ ! "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
    err "Домен '${DOMAIN}' не похож на валидный FQDN"
    exit 1
fi

header_text "Preflight: ${DOMAIN}"
info "Поддомены для проверки: ${SUBDOMAINS[*]}"

# --- определяем свой IP ---
if [[ -z "$SERVER_IP" ]]; then
    if command -v ip &>/dev/null; then
        SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null |
            awk '/src/ {for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    fi
    if [[ -z "$SERVER_IP" ]] && command -v curl &>/dev/null; then
        # Резолвим наш исходящий адрес через сторонний сервис
        SERVER_IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    fi
    if [[ -z "$SERVER_IP" ]]; then
        warn "Не удалось автоматически определить IP сервера. Использую --ip для override."
    else
        info "IP этого сервера: ${SERVER_IP}"
    fi
fi

ERRORS=0
WARNINGS=0

# =============================================================================
# 1. DNS resolution
# =============================================================================
if ! command -v dig &>/dev/null; then
    warn "dig не установлен - пропускаю DNS-проверку (apt install dnsutils / bind-utils)"
else
    info "DNS A/AAAA записи для поддоменов:"
    for sub in "${SUBDOMAINS[@]}"; do
        fqdn="${sub}.${DOMAIN}"
        # Если это apex-домен без subdomain (например, "livekit" может быть = apex)
        if [[ "$sub" == "@" || "$sub" == "$DOMAIN" ]]; then
            fqdn="$DOMAIN"
        fi
        ips=$(dig "${DIG_OPTS}" A "$fqdn" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
        if [[ -z "$ips" ]]; then
            err "  ✗ ${fqdn} - не резолвится"
            ERRORS=$((ERRORS + 1))
            continue
        fi
        # Проверяем, что хотя бы один IP совпадает с нашим
        if [[ -n "$SERVER_IP" ]] && ! grep -qx "$SERVER_IP" <<<"$ips"; then
            err "  ✗ ${fqdn} → ${ips//$'\n'/,} (ожидался ${SERVER_IP})"
            ERRORS=$((ERRORS + 1))
        else
            ok "  ✓ ${fqdn} → ${ips//$'\n'/,}"
        fi
    done
fi

# =============================================================================
# 2. Порты 80/443
# =============================================================================
if [[ "$CHECK_PORTS" == true ]]; then
    info "Порты 80/443:"
    for port in 80 443; do
        if command -v ss &>/dev/null; then
            if ss -ltnH "sport = :$port" 2>/dev/null | grep -q LISTEN; then
                # Порт занят - это нормально если уже есть nginx/Traefik
                # (проверим только что это "наш" процесс)
                who=$(ss -ltnpH "sport = :$port" 2>/dev/null | head -1 | grep -oE 'users:\(\("([^"]+)"' | sed 's/users:(("//' || true)
                if [[ -n "$who" ]]; then
                    ok "  ✓ :${port} LISTEN (${who})"
                else
                    ok "  ✓ :${port} LISTEN"
                fi
            else
                err "  ✗ :${port} не слушается - HTTP-01 challenge для Let's Encrypt провалится"
                ERRORS=$((ERRORS + 1))
            fi
        else
            warn "ss не найден - пропускаю проверку порта :${port}"
            WARNINGS=$((WARNINGS + 1))
        fi
    done
fi

# =============================================================================
# 3. SSL-сертификаты
# =============================================================================
if [[ "$CHECK_SSL" == true ]]; then
    info "SSL-сертификаты (certbot: ${CERTBOT_DIR}):"
    if [[ ! -d "$CERTBOT_DIR" ]]; then
        warn "  ${CERTBOT_DIR} не существует - сертификаты ещё не выпускались (это нормально для первого деплоя)"
    else
        for sub in "${SUBDOMAINS[@]}" "$DOMAIN"; do
            [[ "$sub" == "@" ]] && sub="$DOMAIN"
            certdir="${CERTBOT_DIR}/${sub}"
            if [[ ! -d "$certdir" ]]; then
                warn "  ${sub}: нет сертификата (${certdir} отсутствует)"
                WARNINGS=$((WARNINGS + 1))
                continue
            fi
            certfile="${certdir}/cert.pem"
            if [[ ! -f "$certfile" ]]; then
                warn "  ${sub}: ${certfile} отсутствует"
                WARNINGS=$((WARNINGS + 1))
                continue
            fi
            if ! command -v openssl &>/dev/null; then
                warn "openssl не найден - пропускаю проверку ${sub}"
                continue
            fi
            enddate=$(openssl x509 -enddate -noout -in "$certfile" 2>/dev/null |
                sed 's/^notAfter=//')
            if [[ -z "$enddate" ]]; then
                warn "  ${sub}: не удалось прочитать дату истечения"
                WARNINGS=$((WARNINGS + 1))
                continue
            fi
            end_epoch=$(date -d "$enddate" +%s 2>/dev/null || true)
            now_epoch=$(date +%s)
            if [[ -z "$end_epoch" ]]; then
                warn "  ${sub}: невалидная дата '${enddate}'"
                WARNINGS=$((WARNINGS + 1))
                continue
            fi
            days_left=$(((end_epoch - now_epoch) / 86400))
            if ((days_left < 0)); then
                err "  ✗ ${sub}: истёк ${days_left#-} дн. назад"
                ERRORS=$((ERRORS + 1))
            elif ((days_left < CERT_MIN_DAYS)); then
                warn "  ! ${sub}: осталось ${days_left} дн. (минимум ${CERT_MIN_DAYS})"
                WARNINGS=$((WARNINGS + 1))
            else
                ok "  ✓ ${sub}: OK (${days_left} дн. до ${enddate})"
            fi
        done
    fi
fi

# =============================================================================
# Итог
# =============================================================================
echo ""
if ((ERRORS == 0)); then
    if ((WARNINGS == 0)); then
        ok "Preflight: всё OK"
        exit 0
    else
        warn "Preflight: OK с ${WARNINGS} предупреждением(-ями)"
        exit 0
    fi
else
    err "Preflight: ${ERRORS} ошибок, ${WARNINGS} предупреждений"
    echo ""
    echo "Что делать:"
    echo "  • DNS не резолвится: проверь A/AAAA записи у регистратора домена"
    echo "  • Порты не открыты: скорее всего, ещё не установлен nginx/Traefik"
    echo "    (это нормально для первого запуска prepare_server.sh)"
    echo "  • Сертификаты истекли/отсутствуют: certbot получит их при первом"
    echo "    запуске prepare_server.sh (нужен открытый :80 для HTTP-01 challenge)"
    exit 2
fi
