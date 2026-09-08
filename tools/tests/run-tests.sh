#!/usr/bin/env bash
# =============================================================================
# Matrix-deploy-kit - test runner (pure bash, no deps)
# =============================================================================
# Тесты в tools/tests/*.sh - обычные bash-файлы, определяющие функции:
#
#   setup() { ... }                          # опционально
#   teardown() { ... }                       # опционально
#   test_my_test() {                         # ОБЯЗАТЕЛЬНО
#       assert_eq "$actual" "$expected"
#   }
#
# Хелперы (объявлены в этом файле, доступны после `source`):
#   assert       - true если команда вернула 0
#   assert_eq A B [msg]
#   assert_fail  - true если команда вернула НЕ 0
#   pass         - ничего не делает, явный success
#   fail [msg]   - явный fail
#   skip [reason] - пропуск теста
#
# Использование:
#   bash tools/tests/run-tests.sh
#   bash tools/tests/run-tests.sh --tap
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    DIM=''
    NC=''
fi

TAP_MODE=false
[[ "${1:-}" == "--tap" ]] && TAP_MODE=true && shift

# --- счётчики ---
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
CURRENT_TEST=""
CURRENT_FILE=""

# --- хелперы (доступны в тестах после source этого файла) ---
fail() {
    echo -e "    ${RED}FAIL${NC}: $*" >&2
    return 1
}

assert() {
    if ! "$@"; then
        fail "command failed: $*"
        return 1
    fi
    return 0
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local msg="${3:-values differ}"
    if [[ "$actual" != "$expected" ]]; then
        fail "$msg: expected '$expected', got '$actual'"
        return 1
    fi
    return 0
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-substring not found}"
    if [[ "$haystack" != *"$needle"* ]]; then
        fail "$msg: '$needle' not in '$haystack'"
        return 1
    fi
    return 0
}

assert_fail() {
    if "$@"; then
        fail "command succeeded but should have failed: $*"
        return 1
    fi
    return 0
}

pass() { return 0; }

SKIP_NEXT=""
skip() {
    SKIP_NEXT="${1:-no reason}"
    return 0
}

# --- запуск одного теста ---
run_test() {
    local test_name="$1"
    local test_fn="$2"
    CURRENT_TEST="$test_name"
    TOTAL=$((TOTAL + 1))

    if [[ -n "$SKIP_NEXT" ]]; then
        SKIPPED=$((SKIPPED + 1))
        local reason="$SKIP_NEXT"
        SKIP_NEXT=""
        if [[ "$TAP_MODE" == true ]]; then
            echo "ok $TOTAL - $test_name # SKIP $reason"
        else
            echo -e "  ${DIM}○${NC} $test_name ${DIM}(skipped: $reason)${NC}"
        fi
        return 0
    fi

    set +e
    if declare -F setup >/dev/null 2>&1; then setup >/dev/null 2>&1; fi
    "$test_fn"
    local rc=$?
    if declare -F teardown >/dev/null 2>&1; then teardown >/dev/null 2>&1; fi
    set -e

    if [[ $rc -eq 0 ]]; then
        PASSED=$((PASSED + 1))
        if [[ "$TAP_MODE" == true ]]; then
            echo "ok $TOTAL - $test_name"
        else
            echo -e "  ${GREEN}✓${NC} $test_name"
        fi
    else
        FAILED=$((FAILED + 1))
        if [[ "$TAP_MODE" == true ]]; then
            echo "not ok $TOTAL - $test_name"
        else
            echo -e "  ${RED}✗${NC} $test_name"
        fi
    fi
}

# --- запуск одного файла ---
run_test_file() {
    local file="$1"
    CURRENT_FILE="$file"
    local file_name
    file_name=$(basename "$file" .sh)

    if [[ "$TAP_MODE" != true ]]; then
        echo ""
        echo -e "${YELLOW}━━━ ${file_name} ━━━${NC}"
    fi

    # Запоминаем какие test_* уже были ДО source, чтобы запустить только новые
    local before
    before=$(declare -F | awk '/^declare -f test_/{print $3}' | sort)

    # Загружаем файл в текущий shell (он определит test_* функции)
    # shellcheck source=/dev/null
    source "$file"

    # Найти test_* функции, которые появились ПОСЛЕ source.
    # declare -F выводит "declare -f funcname" (без скобок).
    local after
    after=$(declare -F | awk '/^declare -f test_/{print $3}' | sort)
    local test_fns
    test_fns=$(comm -13 <(echo "$before") <(echo "$after"))

    local fn
    for fn in $test_fns; do
        run_test "$fn" "$fn"
    done

    # Очищаем test_* и setup/teardown, чтобы они не утекли в следующий файл
    for fn in $test_fns; do unset -f "$fn"; done
    if declare -F setup >/dev/null 2>&1; then unset -f setup; fi
    if declare -F teardown >/dev/null 2>&1; then unset -f teardown; fi
}

# --- main ---
cd "$KIT_DIR"

files=()
if [[ $# -gt 0 ]]; then
    for arg in "$@"; do files+=("$arg"); done
else
    while IFS= read -r f; do files+=("$f"); done < <(find tools/tests -name 'test_*.sh' -o -name 'tests_*.sh' 2>/dev/null | sort)
fi

if [[ ${#files[@]} -eq 0 ]]; then
    echo "No test files found in tools/tests/" >&2
    exit 1
fi

START_TIME=$(date +%s)
for f in "${files[@]}"; do
    run_test_file "$f"
done
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# --- итог ---
if [[ "$TAP_MODE" != true ]]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if ((FAILED == 0)); then
        echo -e "${GREEN}All tests passed${NC}: $PASSED passed, $SKIPPED skipped, $TOTAL total in ${DURATION}s"
        exit 0
    else
        echo -e "${RED}FAILURES${NC}: $FAILED failed, $PASSED passed, $SKIPPED skipped, $TOTAL total in ${DURATION}s"
        exit 1
    fi
else
    echo "# tests $TOTAL passed $PASSED failed $FAILED skipped $SKIPPED duration ${DURATION}s"
    [[ $FAILED -gt 0 ]] && exit 1 || exit 0
fi
