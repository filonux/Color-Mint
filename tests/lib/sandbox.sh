#!/usr/bin/env bash
# Sourced first by every test suite. It makes the suite hermetic however it is started.
#
# A suite that is not sandboxed yet re-runs itself under `env -i` with a throw-away HOME,
# XDG tree and TMPDIR and with no desktop session (no DISPLAY, WAYLAND_DISPLAY,
# DBUS_SESSION_BUS_ADDRESS or XDG_RUNTIME_DIR). It therefore cannot reach the real
# gsettings/dconf database, the session bus, the X server or the user's files, even when
# a developer starts it by hand on a live Cinnamon desktop. tests/run.sh builds the same
# environment itself and sets CM_TEST_SANDBOX=1, so nothing is wrapped twice.

if [ "${CM_TEST_SANDBOX:-}" != 1 ]; then
    __cm_sandbox="$(mktemp -d "${TMPDIR:-/tmp}/color-mint-sandbox.XXXXXX")" || exit 2
    mkdir -p "$__cm_sandbox/home" "$__cm_sandbox/config" "$__cm_sandbox/data" \
        "$__cm_sandbox/cache" "$__cm_sandbox/state" "$__cm_sandbox/tmp"
    __cm_env=(
        "PATH=${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
        "HOME=$__cm_sandbox/home"
        "TMPDIR=$__cm_sandbox/tmp"
        "XDG_CONFIG_HOME=$__cm_sandbox/config"
        "XDG_DATA_HOME=$__cm_sandbox/data"
        "XDG_CACHE_HOME=$__cm_sandbox/cache"
        "XDG_STATE_HOME=$__cm_sandbox/state"
        "TERM=dumb"
        "LANG=C.UTF-8"
        "LC_ALL=C.UTF-8"
        "CM_TEST_SANDBOX=1"
    )
    for __cm_var in SHELLCHECK_BIN CM_REQUIRE_GUI_RENDER CM_SCREENSHOT_DIR CM_CHECK_PACKAGES CM_CHECK_SPICES CM_SPICES_SAMPLE; do
        [ -z "${!__cm_var:-}" ] || __cm_env+=("$__cm_var=${!__cm_var}")
    done
    __cm_rc=0
    env -i "${__cm_env[@]}" bash "${BASH_SOURCE[1]}" "$@" || __cm_rc=$?
    rm -rf "$__cm_sandbox"
    exit "$__cm_rc"
fi

# Assertion helpers. `! cmd` is ignored by `set -e` and, in a child `bash -c`, only the last
# status counts, so a command that unexpectedly succeeds would pass silently. These helpers
# stop the shell with status 1; `export -f` makes them available in the child shells too.
must_fail() {
    if "$@"; then
        printf 'FAIL: command was expected to fail: %s\n' "$*" >&2
        exit 1
    fi
    return 0
}

must_print_nothing() {
    local out
    out="$("$@" 2>/dev/null)" || true
    if [ -n "$out" ]; then
        printf 'FAIL: expected no output from: %s\n%s\n' "$*" "$out" >&2
        exit 1
    fi
    return 0
}

export -f must_fail must_print_nothing
