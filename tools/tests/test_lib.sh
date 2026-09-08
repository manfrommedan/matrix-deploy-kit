#!/usr/bin/env bash
# Тесты для tools/_lib.sh - общая библиотека.
# Запуск: bash tools/tests/run-tests.sh

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib.sh"

setup() {
    # shellcheck source=../_lib.sh
    source "$LIB"
}

test_lib_all_functions_defined() {
    for fn in log ok info warn err header_text divider die yes_no require_root require_cmd gen_dynamic_port; do
        if ! declare -F "$fn" >/dev/null; then
            fail "missing function: $fn"
            return 1
        fi
    done
}

test_gen_dynamic_port_default_range() {
    for _ in 1 2 3 4 5; do
        port=$(gen_dynamic_port)
        if ! [[ "$port" =~ ^[0-9]+$ ]]; then
            fail "not a number: $port"
            return 1
        fi
        if ((port < 49152 || port > 65535)); then
            fail "out of range: $port"
            return 1
        fi
    done
}

test_gen_dynamic_port_custom_range() {
    for _ in 1 2 3 4 5; do
        port=$(gen_dynamic_port 10000 20000)
        if ((port < 10000 || port > 20000)); then
            fail "out of custom range: $port"
            return 1
        fi
    done
}

test_gen_dynamic_port_avoids_duplicates() {
    used=""
    for _ in $(seq 1 50); do
        p=$(gen_dynamic_port "" "" "$used")
        if grep -qx "$p" <<<"$used"; then
            fail "duplicate: $p"
            return 1
        fi
        used+="$p"$'\n'
    done
}

test_gen_dynamic_port_covers_range() {
    min=99999
    max=0
    for _ in $(seq 1 200); do
        p=$(gen_dynamic_port)
        ((p < min)) && min=$p
        ((p > max)) && max=$p
    done
    if ! ((min < 55000 && max > 60000)); then
        fail "range not covered: min=$min max=$max"
        return 1
    fi
}

test_die_exits_with_code_1() {
    set +e
    die "test" 2>/dev/null
    local rc=$?
    set -e
    [[ $rc -eq 1 ]]
}

test_yes_no_y_returns_0() {
    set +e
    echo "y" | yes_no "test" "n" >/dev/null 2>&1
    local rc=$?
    set -e
    [[ $rc -eq 0 ]]
}

test_yes_no_n_returns_1() {
    set +e
    echo "n" | yes_no "test" "y" >/dev/null 2>&1
    local rc=$?
    set -e
    [[ $rc -eq 1 ]]
}

test_yes_no_default_y() {
    set +e
    echo "" | yes_no "test" "y" >/dev/null 2>&1
    local rc=$?
    set -e
    [[ $rc -eq 0 ]]
}

test_yes_no_default_n() {
    set +e
    echo "" | yes_no "test" "n" >/dev/null 2>&1
    local rc=$?
    set -e
    [[ $rc -eq 1 ]]
}

test_require_cmd_existing() {
    require_cmd bash
}

test_require_cmd_missing() {
    set +e
    require_cmd "definitely-not-a-real-command-12345" 2>/dev/null
    local rc=$?
    set -e
    [[ $rc -eq 1 ]]
}

test_header_text_includes_arg() {
    local out
    out=$(header_text "TestHeader" 2>&1)
    [[ "$out" == *"TestHeader"* ]]
}
