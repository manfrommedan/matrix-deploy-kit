#!/usr/bin/env bash
# Тесты для tools/preflight.sh - DNS / порты / SSL preflight.

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../preflight.sh"

test_preflight_help() {
    bash "$SCRIPT" --help >/dev/null 2>&1
}

test_preflight_without_domain_fails() {
    set +e
    bash "$SCRIPT" >/dev/null 2>&1
    local rc=$?
    set -e
    [[ $rc -eq 1 ]]
}

test_preflight_invalid_domain_fails() {
    set +e
    bash "$SCRIPT" --domain "not_valid" >/dev/null 2>&1
    local rc=$?
    set -e
    [[ $rc -eq 1 ]]
}

test_preflight_unknown_flag_fails() {
    set +e
    bash "$SCRIPT" --unknown-flag >/dev/null 2>&1
    local rc=$?
    set -e
    [[ $rc -eq 1 ]]
}

test_preflight_example_no_dns_no_ssl_no_ports() {
    set +e
    bash "$SCRIPT" --domain example.com --no-ssl --no-ports >/dev/null 2>&1
    local rc=$?
    set -e
    # exit 2 = найдены проблемы (DNS)
    # exit 3 = сетевые проблемы
    [[ $rc -eq 2 || $rc -eq 3 ]]
}

test_preflight_subdomains_csv() {
    set +e
    bash "$SCRIPT" --domain example.com --subdomains "a,b,c" --no-ssl --no-ports >/dev/null 2>&1
    local rc=$?
    set -e
    # Не должно быть usage-ошибки (rc=1)
    [[ $rc -ne 1 ]]
}

test_preflight_resolving_domain_with_correct_ip() {
    # google.com резолвится, IP 142.250.185.206 принадлежит ему
    set +e
    bash "$SCRIPT" --domain google.com --ip 142.250.185.206 --subdomains www --no-ssl --no-ports >/dev/null 2>&1
    local rc=$?
    set -e
    # 0 = OK, 2 = найдены проблемы (порты/cert), 3 = network
    [[ $rc -eq 0 || $rc -eq 2 || $rc -eq 3 ]]
}
