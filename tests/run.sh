#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$ROOT/tests"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/color-mint-suite.XXXXXX")"
SUITE_TIMEOUT="${SUITE_TIMEOUT:-180}"
JOBS="${CM_TEST_JOBS:-1}"
PATH_BASE="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"

suites=(
    test_quality.sh
    test_aesthetics.sh
    test_security.sh
    test_robustness.sh
    test_functions.sh
    test_icons.sh
    test_atomicity.sh
    test_uninstall.sh
    test_color_mint.sh
    test_themes.sh
    test_presets.sh
    test_catalog.sh
    test_gui_render.sh
    lint.sh
)

pids=()
logs=()
active=()
cleaned=0

cleanup() {
    local pid
    [ "$cleaned" -eq 0 ] || return 0
    cleaned=1
    for pid in "${active[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${active[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    rm -rf "$TMP"
}

handle_signal() {
    local signal="$1"
    cleanup
    case "$signal" in
        HUP)  exit 129 ;;
        INT)  exit 130 ;;
        TERM) exit 143 ;;
    esac
}
trap cleanup EXIT
trap 'handle_signal HUP' HUP
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

case "$SUITE_TIMEOUT" in
    ''|*[!0-9]*)
        printf 'Invalid SUITE_TIMEOUT: %s\n' "$SUITE_TIMEOUT" >&2
        exit 2
        ;;
esac
[ "$SUITE_TIMEOUT" -gt 0 ] || { printf 'SUITE_TIMEOUT must be greater than zero\n' >&2; exit 2; }
case "$JOBS" in
    ''|*[!0-9]*)
        printf 'Invalid CM_TEST_JOBS: %s\n' "$JOBS" >&2
        exit 2
        ;;
esac
[ "$JOBS" -gt 0 ] || { printf 'CM_TEST_JOBS must be greater than zero\n' >&2; exit 2; }

is_suite() {
    local candidate="$1" suite
    for suite in "${suites[@]}"; do
        [ "$candidate" = "$suite" ] && return 0
    done
    return 1
}

requested=()
skipped=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h)
            printf 'Usage: %s [--skip suite]... [suite ...]\n' "$(basename "$0")"
            printf 'Suites: %s\n' "${suites[*]}"
            exit 0
            ;;
        --skip)
            [ "$#" -ge 2 ] || { printf '%s\n' '--skip needs a suite name' >&2; exit 2; }
            skipped+=("$2")
            shift 2
            ;;
        --skip=*)
            skipped+=("${1#--skip=}")
            shift
            ;;
        -*)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 2
            ;;
        *)
            requested+=("$1")
            shift
            ;;
    esac
done

for name in "${requested[@]+"${requested[@]}"}" "${skipped[@]+"${skipped[@]}"}"; do
    is_suite "$name" || { printf 'Unknown suite: %s\n' "$name" >&2; exit 2; }
done

candidates=("${suites[@]}")
[ "${#requested[@]}" -eq 0 ] || candidates=("${requested[@]}")
selected=()
for suite in "${candidates[@]}"; do
    keep=1
    for name in "${skipped[@]+"${skipped[@]}"}"; do
        [ "$suite" = "$name" ] && keep=0
    done
    [ "$keep" -eq 0 ] || selected+=("$suite")
done
[ "${#selected[@]}" -gt 0 ] || { printf '%s\n' 'No suites left to run' >&2; exit 2; }

passed=0
failed=0
blocked=0

printf 'Color Mint test suite\n'
printf 'Repository: %s\n\n' "$ROOT"
printf 'Running %d suite(s), up to %d concurrently; each suite has its own HOME, XDG tree and TMPDIR.\n\n' \
    "${#selected[@]}" "$JOBS"

extra_env=("CM_TEST_SANDBOX=1")
for extra_var in SHELLCHECK_BIN CM_REQUIRE_GUI_RENDER CM_SCREENSHOT_DIR CM_CHECK_PACKAGES CM_CHECK_SPICES CM_SPICES_SAMPLE; do
    [ -z "${!extra_var:-}" ] || extra_env+=("$extra_var=${!extra_var}")
done

launch_suite() {
    local suite="$1" log pid
    log="$TMP/$suite.log"
    mkdir -p \
        "$TMP/home-$suite" \
        "$TMP/xdg-config-$suite" \
        "$TMP/xdg-data-$suite" \
        "$TMP/xdg-cache-$suite" \
        "$TMP/xdg-state-$suite" \
        "$TMP/tmp-$suite"
    printf '%s\n' "==> $suite"
    env -i \
        PATH="$PATH_BASE" \
        HOME="$TMP/home-$suite" \
        TMPDIR="$TMP/tmp-$suite" \
        XDG_CONFIG_HOME="$TMP/xdg-config-$suite" \
        XDG_DATA_HOME="$TMP/xdg-data-$suite" \
        XDG_CACHE_HOME="$TMP/xdg-cache-$suite" \
        XDG_STATE_HOME="$TMP/xdg-state-$suite" \
        TERM=dumb \
        LANG=C.UTF-8 \
        LC_ALL=C.UTF-8 \
        "${extra_env[@]}" \
        timeout --signal=TERM --kill-after=5 "$SUITE_TIMEOUT" bash "$TESTS/$suite" >"$log" 2>&1 &
    pid="$!"
    pids+=("$pid")
    logs+=("$log")
    active+=("$pid")
}

reap_index() {
    local index="$1" suite pid log rc
    suite="${selected[$index]}"
    pid="${pids[$index]}"
    log="${logs[$index]}"
    wait "$pid"
    rc=$?
    if [ "$rc" -eq 0 ] && [ "${GITHUB_ACTIONS:-}" = true ]; then
        printf '::group::%s\n' "$suite"
        cat "$log"
        printf '::endgroup::\n'
    else
        cat "$log"
    fi
    case "$rc" in
        0) passed=$((passed + 1)); printf '%s\n\n' "PASS: suite $suite" ;;
        2) blocked=$((blocked + 1)); printf '%s\n\n' "BLOCKED: suite $suite (environment/tool unavailable)" ;;
        *)
            failed=$((failed + 1))
            printf '%s\n\n' "FAIL: suite $suite (exit $rc)"
            [ "${GITHUB_ACTIONS:-}" != true ] || printf '::error title=Test suite failed::%s exited with status %s\n' "$suite" "$rc"
            ;;
    esac
    active=("${active[@]:1}")
}

for i in "${!selected[@]}"; do
    launch_suite "${selected[$i]}"
    if [ "${#active[@]}" -ge "$JOBS" ]; then
        # Reap the oldest active suite to keep concurrency bounded and output deterministic.
        reap_index "$((i - JOBS + 1))"
    fi
done

while [ "${#active[@]}" -gt 0 ]; do
    first_index=$(( ${#selected[@]} - ${#active[@]} ))
    reap_index "$first_index"
done

printf 'Summary: %d passed, %d failed, %d blocked, %d total.\n' \
    "$passed" "$failed" "$blocked" "${#selected[@]}"

[ "$failed" -eq 0 ] || exit 1
[ "$blocked" -eq 0 ] || exit 2
exit 0
