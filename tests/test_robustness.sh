#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sandbox.sh
. "$ROOT/tests/lib/sandbox.sh"
SCRIPT="$ROOT/script/color-mint.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/color-mint-robustness.XXXXXX")"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

for locale in es_ES.UTF-8 C.UTF-8; do
    label=es
    [ "$locale" = C.UTF-8 ] && label=en
    home="$TMP/home-$label"; state="$TMP/state-$label"; mkdir -p "$home"
    printf sentinel > "$home/sentinel"
    before="$(sha256sum "$home/sentinel" | cut -d' ' -f1)"
    output="$TMP/help-$label"
    env -u LC_ALL -u LC_MESSAGES LANG="$locale" HOME="$home" CM_HOME="$state" bash "$SCRIPT" --help >"$output" 2>"$output.err" || fail "--help failed: $label"
    [ ! -e "$state" ] || fail "--help created state: $label"
    [ "$(sha256sum "$home/sentinel" | cut -d' ' -f1)" = "$before" ] || fail "--help modified HOME: $label"
    [ ! -s "$output.err" ] || fail "--help emitted diagnostics: $label"
done
pass 'help stays read-only under locale detection'

home="$TMP/version-home"; state="$TMP/version-state"; bin="$TMP/version-bin"
mkdir -p "$home" "$bin"
printf sentinel > "$home/sentinel"
for tool in gsettings dconf gdbus yad; do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$bin/$tool"
    chmod 755 "$bin/$tool"
done
out="$(PATH="$bin:$PATH" HOME="$home" CM_HOME="$state" CM_LANG_OVERRIDE=es bash "$SCRIPT" --version 2>"$TMP/version.err")" || fail '--version failed'
[ "$out" = 'Color Mint 3.1.0' ] || fail '--version output changed'
[ ! -e "$state" ] || fail '--version created state'
[ ! -s "$TMP/version.err" ] || fail '--version emitted diagnostics'
pass 'version stays side-effect free and backend-free'

# Bash 4.4 is the oldest supported release: an older shell must stop on the first lines, with status 1 and one message in
# the user's language, and touch nothing. The version is faked by a line placed after the shebang.
guard_run() {   # <fake BASH_VERSION> <VAR=value>...: these replace every language variable of the environment
    local version="$1"
    shift
    sed "1a BASH_VERSION='$version'" "$SCRIPT" > "$TMP/guard.sh"
    env -u LANG -u LC_ALL -u LC_MESSAGES -u CM_LANG_OVERRIDE "$@" HOME="$TMP/guard-home" CM_HOME="$TMP/guard-state" \
        bash "$TMP/guard.sh" --version >"$TMP/guard.out" 2>"$TMP/guard.err"
}
guard_message() {   # <es|en> <detected version, empty for none>: the message, without its newline
    if [ "$1" = es ]; then
        printf 'Color Mint necesita Bash 4.4 o superior (versión detectada: %s).' "${2:-ninguna}"
    else
        printf 'Color Mint needs Bash 4.4 or newer (detected: %s).' "${2:-none}"
    fi
}
# <es|en> <fake version> <VAR=value>...: refused with status 1, nothing on stdout, the message as the last line of stderr
# (a Bash without the named locale prints a setlocale warning of its own before it) and a newline after it.
guard_refuses() {
    local want="$1" version="$2" rc=0
    shift 2
    guard_run "$version" "$@" || rc=$?
    [ "$rc" -eq 1 ] || fail "Bash '$version' ($*) stopped with status $rc, not 1"
    [ ! -s "$TMP/guard.out" ] || fail "Bash '$version' ($*) printed on stdout"
    [ "$(tail -n 1 "$TMP/guard.err")" = "$(guard_message "$want" "$version")" ] \
        || fail "Bash '$version' ($*) did not print the $want message: $(cat "$TMP/guard.err")"
    [ "$(tail -c 1 "$TMP/guard.err" | od -An -tx1 | tr -d ' ')" = 0a ] \
        || fail "Bash '$version' ($*): the message has no final newline"
}
for version in '' '3.2.57(1)-release' '4.0.44(3)-release' '4.3.48(1)-release'; do
    guard_refuses en "$version" LANG=C.UTF-8
    guard_refuses es "$version" LANG=es_ES.UTF-8
done
# The language comes from CM_LANG_OVERRIDE, then LC_ALL, LC_MESSAGES and LANG; a variable that is set but empty is skipped.
while read -r want vars; do
    guard_refuses "$want" '3.2.57(1)-release' $vars
done <<'CASES'
en
en LANG=C.UTF-8
es LANG=es
es LANG=es_ES.UTF-8
es LANG=es-419
es LANG=C.UTF-8 CM_LANG_OVERRIDE=es
en LANG=es_ES.UTF-8 CM_LANG_OVERRIDE=en
es LANG=C.UTF-8 LC_ALL=es_ES.UTF-8
en LANG=es_ES.UTF-8 LC_ALL=C.UTF-8
es LANG=C.UTF-8 LC_MESSAGES=es_ES.UTF-8
en LANG=es_ES.UTF-8 LC_MESSAGES=C.UTF-8
en LANG=es_ES.UTF-8 LC_ALL=C.UTF-8 LC_MESSAGES=es_ES.UTF-8
es LANG=C.UTF-8 LC_ALL=es_ES.UTF-8 LC_MESSAGES=C.UTF-8
es LANG=C.UTF-8 LC_ALL=C.UTF-8 CM_LANG_OVERRIDE=es
es LANG=C.UTF-8 LC_MESSAGES=C.UTF-8 CM_LANG_OVERRIDE=es
en LANG=es_ES.UTF-8 LC_ALL=es_ES.UTF-8 LC_MESSAGES=es_ES.UTF-8 CM_LANG_OVERRIDE=en
es LANG=es_ES.UTF-8 CM_LANG_OVERRIDE=
es LANG=es_ES.UTF-8 LC_ALL=
es LANG=es_ES.UTF-8 LC_MESSAGES=
es LANG=es_ES.UTF-8 LC_ALL= LC_MESSAGES= CM_LANG_OVERRIDE=
CASES
for version in '4.4.0(1)-release' '4.4.20(1)-release' '4.9.9' '4.10.0' '5.0.0(1)-release' '5.2.21(1)-release' '9.9.9' '10.0.0'; do
    guard_run "$version" LANG=C.UTF-8 || fail "Bash $version was refused"
    [ "$(cat "$TMP/guard.out")" = 'Color Mint 3.1.0' ] || fail "Bash $version did not run the program"
    [ ! -s "$TMP/guard.err" ] || fail "Bash $version printed a diagnostic"
done
# A shell that is not Bash gets no further than the guard, so the guard must be plain POSIX (no [[ ]], no ${x,,}, no $'..').
if [ -n "$(sh -c 'printf %s "${BASH_VERSION:-}"')" ]; then
    printf 'SKIP: sh is Bash here, so the guard was not run by a POSIX shell\n'
else
    for pair in en:C.UTF-8 es:es_ES.UTF-8; do
        rc=0
        env -u LC_ALL -u LC_MESSAGES -u CM_LANG_OVERRIDE LANG="${pair#*:}" HOME="$TMP/guard-home" CM_HOME="$TMP/guard-state" \
            sh "$SCRIPT" --version >"$TMP/guard.out" 2>"$TMP/guard.err" || rc=$?
        [ "$rc" -eq 1 ] || fail "sh ($pair) stopped with status $rc, not 1"
        [ ! -s "$TMP/guard.out" ] || fail "sh ($pair) printed on stdout"
        [ "$(cat "$TMP/guard.err")" = "$(guard_message "${pair%%:*}" '')" ] \
            || fail "sh ($pair) did not print the ${pair%%:*} message: $(cat "$TMP/guard.err")"
    done
fi
[ ! -e "$TMP/guard-state" ] || fail 'the Bash guard created state'
pass 'a Bash older than 4.4 stops at once with a message in the user language; 4.4 and newer go on'

set +e
HOME="$TMP/unknown-home" CM_HOME="$TMP/unknown-state" CM_LANG_OVERRIDE=en bash "$SCRIPT" unknown-command >"$TMP/unknown.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'unknown command returned success'
grep -q 'GRAPHICAL MODE' "$TMP/unknown.out" || fail 'unknown command omitted help'
pass 'unknown commands return failure and useful help'

BODY="$TMP/body.sh"
awk '/^# Command-line dispatcher/{exit} {print}' "$SCRIPT" > "$BODY"
HOME="$TMP/hot-home" CM_HOME="$TMP/hot-state" CM_LANG_OVERRIDE=en bash -c '
    source "$1"
    cm_lang_init
    CM_TEST_GSET=""
    cm_gset() { CM_TEST_GSET="$3"; return 0; }
    cm_apply_hotcorners expo >/dev/null
    [ "$CM_TEST_GSET" = "['"'"'expo:true:0'"'"', '"'"'expo:false:0'"'"', '"'"'expo:false:0'"'"', '"'"'expo:false:0'"'"']" ]
    must_fail cm_apply_hotcorners bogus >/dev/null 2>&1
' bash "$BODY" || fail 'hot-corner incomplete/invalid input'
pass 'incomplete hot-corner input is safe under set -u'

# GTK and libadwaita read gtk.css once per process (measured with GTK 3.24 and GTK 4 + libadwaita 1.5), so the
# global accent message must not promise that open apps refresh by themselves.
for lang in en es; do
    out=$(HOME="$TMP/accent-home-$lang" CM_HOME="$TMP/accent-state-$lang" CM_LANG_OVERRIDE="$lang" \
        bash "$SCRIPT" panel gtk-accent '#e91e63' 2>&1) || fail "panel gtk-accent failed ($lang)"
    case "$lang" in
        en) want='opened from now on'; banned='automatically' ;;
        es) want='abras desde ahora';  banned='solas' ;;
    esac
    grep -qF -- "$want" <<<"$out" || fail "gtk-accent message ($lang) must say only new apps get the accent"
    if grep -qF -- "$banned" <<<"$out"; then fail "gtk-accent message ($lang) promises an automatic refresh"; fi
done
pass 'global GTK accent message does not promise a live refresh'

# The accent reaches GTK3 and libadwaita apps only; GTK4 without libadwaita paints nothing, and Flatpak and GTK2 do
# not get it by default (by their documentation). The GUI label and the help must not say "all apps".
for lang in en es; do
    label=$(HOME="$TMP/scope-home-$lang" CM_HOME="$TMP/scope-state-$lang" CM_LANG_OVERRIDE="$lang" bash -c '
        source "$1"; cm_lang_init; printf "%s" "${CM_COLOR_TARGET_LABELS[gtk_accent]}"' bash "$BODY")
    helpline=$(HOME="$TMP/scope-help-$lang" CM_HOME="$TMP/scope-help-state-$lang" CM_LANG_OVERRIDE="$lang" \
        bash "$SCRIPT" --help | grep -F 'gtk-accent')
    for text in "$label" "$helpline"; do
        grep -qF 'GTK3/libadwaita' <<<"$text" || fail "gtk-accent text ($lang) must name GTK3/libadwaita: $text"
        if grep -qiE 'all apps|todas las apps|GTK3/GTK4' <<<"$text"; then fail "gtk-accent text ($lang) promises every app: $text"; fi
    done
done
pass 'gtk-accent label and help name their real scope'

mkdir -p "$TMP/mockbin"
cat > "$TMP/mockbin/gsettings" <<'MOCK'
#!/usr/bin/env bash
if [ "${1:-}" = set ]; then
    printf 'backend failure\n' >&2
    exit 42
fi
if [ "${1:-}" = get ]; then
    printf "''\n"
fi
MOCK
chmod 755 "$TMP/mockbin/gsettings"
set +e
PATH="$TMP/mockbin:$PATH" HOME="$TMP/failure-home" CM_HOME="$TMP/failure-state" CM_LANG_OVERRIDE=en bash "$SCRIPT" desktop effects on >"$TMP/failure.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'backend failure was hidden'
grep -q 'ERROR: could not apply' "$TMP/failure.out" || fail 'backend error message missing'
pass 'backend failures propagate to the CLI'

BODY_CURSOR="$TMP/cursor-body.sh"
awk '/^# Command-line dispatcher/{exit} {print}' "$SCRIPT" > "$BODY_CURSOR"
missing_home="$TMP/cursor-missing-home"
set +e
HOME="$missing_home" CM_HOME="$TMP/cursor-state" CM_LANG_OVERRIDE=en bash -c '''
    source "$1"
    cm_lang_init
    cm_gset() { CM_TEST_SIZE="$3"; return 0; }
    gsettings() {
        if [ "${1:-}" = get ]; then printf "%s\n" "${CM_TEST_SIZE:-24}"; fi
        return 0
    }
    cm_apply_cursor_size 32 1
''' bash "$BODY_CURSOR" >"$TMP/cursor-missing.out" 2>"$TMP/cursor-missing.err"
rc=$?
set -e
# The read-back must succeed here: the failure under test is the persistence, not the verification.
if grep -q 'when read back' "$TMP/cursor-missing.err"; then fail "cursor-size failed at the read-back, not at the persistence"; fi
[ "$rc" -ne 0 ] || fail "cursor-size hid an atomic persistence failure"
[ ! -e "$missing_home/.Xresources" ] || fail "cursor-size created partial persistence in missing HOME"
pass 'cursor refresh failures propagate instead of reporting success'

# A Cinnamon that cannot be restarted (no D-Bus answer, no display: an automation or a non-Cinnamon session)
# does not undo a change that is already saved and persisted. The shared doubles keep one key store, so the
# read-back that `cursor-size` performs sees what was written.
# shellcheck source=lib/doubles.sh
. "$ROOT/tests/lib/doubles.sh"
cur_home="$TMP/cur-home"; cur_bin="$TMP/cur-bin"
mkdir -p "$cur_home/.icons/CurTheme/cursors"
cm_double_install "$cur_bin"
# State and key store sit outside HOME, so a HOME that does not exist stays missing.
cur_run() {   # cur_run <gdbus fails: 0|1> <home> <command...>
    local gdbus_fail="$1" home="$2"; shift 2
    mkdir -p "$TMP/cur-state"
    env PATH="$cur_bin:$PATH" HOME="$home" CM_HOME="$TMP/cur-state/${home##*/}" CM_LANG_OVERRIDE=en \
        DCONF_DB="$TMP/cur-state/${home##*/}.db" GDBUS_FAIL="$gdbus_fail" bash "$SCRIPT" "$@"
}
cur_log="$TMP/cur-state/cur-home/logs/color-mint.log"
set +e
cur_run 0 "$cur_home" theme cursor-size 48 >"$TMP/cur-ok.out" 2>"$TMP/cur-ok.err"; rc_ok=$?
set -e
[ "$rc_ok" -eq 0 ] || fail 'control: cursor-size failed although Cinnamon restarts'
grep -q 'saved and verified as 48px' "$TMP/cur-ok.out" || fail 'control: cursor-size did not report the saved size'
if grep -q 'Could not restart Cinnamon' "$cur_log"; then fail 'control: the restart was logged as failed'; fi
set +e
cur_run 1 "$cur_home" theme cursor-size 40 >"$TMP/cur-size.out" 2>"$TMP/cur-size.err"; rc_size=$?
cur_run 1 "$cur_home" theme cursor CurTheme >"$TMP/cur-theme.out" 2>"$TMP/cur-theme.err"; rc_theme=$?
set -e
[ "$rc_size" -eq 0 ] || fail 'cursor-size failed only because Cinnamon could not be restarted'
grep -q 'saved and verified as 40px' "$TMP/cur-size.out" || fail 'cursor-size said nothing about the size it saved'
[ ! -s "$TMP/cur-size.err" ] || fail 'cursor-size wrote diagnostics for a saved change'
[ "$rc_theme" -eq 0 ] || fail 'theme cursor failed only because Cinnamon could not be restarted'
grep -q 'Cursor theme applied: CurTheme' "$TMP/cur-theme.out" || fail 'theme cursor did not report the applied theme'
grep -q "^/org/cinnamon/desktop/interface/cursor-size$(printf '\t')40$" "$TMP/cur-state/cur-home.db" || fail 'the size is not in the key store'
grep -qx 'Xcursor.size: 40' "$cur_home/.Xresources" || fail 'the size was not persisted in .Xresources'
grep -qx 'XCURSOR_SIZE=40' "$cur_home/.config/environment.d/60-color-mint-cursor.conf" || fail 'the size was not persisted in environment.d'
grep -q 'Could not restart Cinnamon' "$cur_log" || fail 'the failed restart left no trace in the log'
pass 'a Cinnamon that cannot restart does not fail a cursor change that was saved'

# The two persistence steps still fail loudly: a HOME that cannot take .Xresources, and one whose
# environment.d cannot be created (a file sits where .config should be).
env_home="$TMP/cur-env"
mkdir -p "$env_home"; printf 'not a folder\n' > "$env_home/.config"
set +e
cur_run 0 "$TMP/cur-nohome" theme cursor-size 32 >/dev/null 2>"$TMP/cur-nohome.err"; rc_nohome=$?
cur_run 0 "$env_home" theme cursor-size 32 >/dev/null 2>"$TMP/cur-env.err"; rc_env=$?
set -e
[ "$rc_nohome" -ne 0 ] || fail 'cursor-size succeeded with no HOME to persist into'
[ "$rc_env" -ne 0 ] || fail 'cursor-size succeeded although environment.d could not be written'
[ -f "$env_home/.Xresources" ] || fail 'control: the .Xresources step should have succeeded before environment.d failed'
pass 'persistence failures of the cursor refresh still fail the command'

cat > "$TMP/mockbin-gsettings" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
state="${CM_TEST_BOUND_STATE:?}"
if [ "${1:-}" = set ]; then
    printf '%s\t%s\n' "$3" "$4" >> "$state"
    exit 0
fi
if [ "${1:-}" = get ]; then
    awk -F '\t' -v key="$3" '$1 == key {v=$2} END {if (v != "") print v; else print "24"}' "$state"
    exit 0
fi
exit 1
MOCK
mkdir -p "$TMP/bound-bin"
cp "$TMP/mockbin-gsettings" "$TMP/bound-bin/gsettings"
chmod 755 "$TMP/bound-bin/gsettings"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TMP/bound-bin/gdbus"
chmod 755 "$TMP/bound-bin/gdbus"
for lang in es en; do
    mkdir -p "$TMP/home-bound-$lang"
    for spec in 'desktop workspaces 1' 'desktop workspaces 20' 'fonts scaling 50' 'fonts scaling 200' 'theme cursor-size 16' 'theme cursor-size 96'; do
        read -r -a argv <<< "$spec"
        PATH="$TMP/bound-bin:$PATH" CM_TEST_BOUND_STATE="$TMP/bound-$lang.state" HOME="$TMP/home-bound-$lang" \
          CM_HOME="$TMP/state-bound-$lang" CM_LANG_OVERRIDE="$lang" bash "$SCRIPT" "${argv[@]}" >/dev/null 2>&1 || fail "valid boundary rejected: $lang/$spec"
    done
    for spec in 'desktop workspaces 0' 'desktop workspaces 21' 'fonts scaling 49' 'fonts scaling 201' 'theme cursor-size 15' 'theme cursor-size 97'; do
        read -r -a argv <<< "$spec"
        set +e
        PATH="$TMP/bound-bin:$PATH" CM_TEST_BOUND_STATE="$TMP/bound-invalid-$lang.state" HOME="$TMP/home-bound-invalid-$lang" \
          CM_HOME="$TMP/state-bound-invalid-$lang" CM_LANG_OVERRIDE="$lang" bash "$SCRIPT" "${argv[@]}" >/dev/null 2>&1
        rc=$?
        set -e
        [ "$rc" -ne 0 ] || fail "invalid boundary accepted: $lang/$spec"
    done
done
pass 'numeric boundaries are enforced'

# GUI tabs are separate processes keyed by the PID of their window generation: they must follow it and must not spin.
BODY="$TMP/body.sh"
awk '/^# Command-line dispatcher/{exit} {print}' "$SCRIPT" > "$BODY"
HOME="$TMP/home-tab-guard" CM_HOME="$TMP/state-tab-guard" CM_LANG_OVERRIDE=en bash -c '
    source "$1"
    sleeps=0
    sleep() { sleeps=$((sleeps + 1)); }
    unset SECONDS; SECONDS=7
    ! cm_tab_alive 2147483646 || { echo "dead key accepted"; exit 1; }
    for _ in 1 2 3 4 5 6 7 8 9 10; do cm_tab_alive "$$" || { echo "live key rejected"; exit 2; }; done
    [ "$sleeps" -eq 5 ] || { echo "burst throttle: $sleeps sleeps"; exit 3; }
    SECONDS=8
    cm_tab_alive "$$" && [ "$sleeps" -eq 5 ] || { echo "throttle did not reset"; exit 4; }
' bash "$BODY" || fail 'tab guard contract (dead key / burst throttle)'
python3 - "$SCRIPT" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
tabs = re.findall(r'(cm_tab_[a-z_]+)\(\) \{\n(.*?)\n\}\n', text, re.S)
helpers = {'cm_tab_alive', 'cm_tab_redraw'}
names = [name for name, _ in tabs if name not in helpers]
if len(names) != 7:
    raise SystemExit(f'expected 7 GUI tabs, found {len(names)}')
for name, body in tabs:
    if name in helpers:
        continue
    if 'while cm_tab_alive "$KEY"; do' not in body or 'while true' in body:
        raise SystemExit(f'{name} loop is not bound to the main window process')
PY
pass 'every GUI tab loop is bound to the main window process'

mkdir -p "$TMP/tab-bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf x >> "${CM_TEST_YAD_COUNT:?}"' 'exit 0' > "$TMP/tab-bin/yad"
printf '%s\n' '#!/usr/bin/env bash' '[ "${1:-}" = get ] && printf "'"''"'\n"' 'exit 0' > "$TMP/tab-bin/gsettings"
chmod 755 "$TMP/tab-bin/yad" "$TMP/tab-bin/gsettings"
: > "$TMP/tab.count"
sleep 2 & key=$!
PATH="$TMP/tab-bin:$PATH" CM_TEST_YAD_COUNT="$TMP/tab.count" HOME="$TMP/home-tab-orphan" CM_HOME="$TMP/state-tab-orphan" \
    CM_LANG_OVERRIDE=en timeout --kill-after=2 20 bash "$SCRIPT" __tab themes "$key" 1 >/dev/null 2>&1 &
tab=$!
rc=0; wait "$tab" || rc=$?
kill "$key" 2>/dev/null || true
[ "$rc" -eq 0 ] || fail "orphaned tab did not stop after its main window (exit $rc)"
[ "$(wc -c < "$TMP/tab.count")" -lt 400 ] || fail 'orphaned tab respawned yad without limit'
pass 'orphaned tab stops and a form that closes at once does not spin'

# A tab tells its buttons which window it belongs to through the environment (CM_TAB_KEY): the buttons are children of its yad.
mkdir -p "$TMP/env-bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "${CM_TAB_KEY-unset}" > "${CM_TEST_TAB_ENV:?}"' 'exit 0' > "$TMP/env-bin/yad"
chmod 755 "$TMP/env-bin/yad"
sleep 1 & key=$!
PATH="$TMP/env-bin:$TMP/tab-bin:$PATH" CM_TEST_TAB_ENV="$TMP/tab.env" HOME="$TMP/home-tab-env" CM_HOME="$TMP/state-tab-env" \
    CM_LANG_OVERRIDE=en timeout --kill-after=2 20 bash "$SCRIPT" __tab themes "$key" 3 >/dev/null 2>&1 || true
[ "$(cat "$TMP/tab.env" 2>/dev/null)" = "$key" ] || fail "a tab did not export its key to its yad: '$(cat "$TMP/tab.env" 2>/dev/null)'"
pass 'a tab exports its window key to the buttons of its form'

# A button does not redraw its tab (GtkSocket takes no second plug), so an import rebuilds the whole window: the tab
# leaves a mark in CM_HOME and ends the notebook. The pattern must find that notebook and no other yad; nothing may be
# signalled or written without a valid key, and a redraw that found no notebook leaves no mark.
mkdir -p "$TMP/redraw-bin" "$TMP/redraw-empty" "$TMP/state-redraw"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${CM_TEST_PGREP_LOG:?}"' \
    '[ ! -f "${CM_TEST_PGREP_OUT:-}" ] || cat "$CM_TEST_PGREP_OUT"' > "$TMP/redraw-bin/pgrep"
chmod 755 "$TMP/redraw-bin/pgrep"
sleep 60 & victim=$!
sleep 60 & bystander=$!
printf '%s\n' "$victim" > "$TMP/pgrep.out"
: > "$TMP/pgrep.log"
marks() { find "$1" -maxdepth 1 -name 'window-redraw.*' | wc -l; }
redraw_call() {
    env "$@" PATH="$TMP/redraw-bin:$PATH" CM_TEST_PGREP_LOG="$TMP/pgrep.log" CM_TEST_PGREP_OUT="$TMP/pgrep.out" \
        HOME="$TMP/home-redraw" CM_HOME="$TMP/state-redraw" CM_LANG_OVERRIDE=en \
        bash -c 'source "$1"; cm_tab_redraw' bash "$BODY"
}
redraw_call
redraw_call CM_TAB_KEY=
redraw_call CM_TAB_KEY=abc
redraw_call 'CM_TAB_KEY=4242 .*'
[ ! -s "$TMP/pgrep.log" ] || fail "a redraw looked for processes without a valid key: $(cat "$TMP/pgrep.log")"
kill -0 "$victim" 2>/dev/null || fail 'a redraw without a valid key signalled a process'
[ "$(marks "$TMP/state-redraw")" -eq 0 ] || fail 'a redraw without a valid key left a mark'
redraw_call CM_TAB_KEY=4242
wait "$victim" 2>/dev/null || true
! kill -0 "$victim" 2>/dev/null || fail 'the redraw did not stop the notebook that pgrep named'
kill -0 "$bystander" 2>/dev/null || fail 'the redraw stopped a process that pgrep did not name'
[ -f "$TMP/state-redraw/window-redraw.4242" ] || fail 'the redraw did not leave its mark (window-redraw.<key> in CM_HOME) for the window generation'
[ "$(marks "$TMP/state-redraw")" -eq 1 ] || fail 'the redraw left more than its one mark'
[ "$(wc -l < "$TMP/pgrep.log")" -eq 1 ] || fail "the redraw looked up processes more than once: $(cat "$TMP/pgrep.log")"
line="$(cat "$TMP/pgrep.log")"
case "$line" in "-u $(id -u) -f -- "*) ;; *) fail "the redraw must search the user's own processes by command line: $line" ;; esac
pattern="${line#*-- }"
notebook() { printf '%s\n' "$1" | grep -Eq -- "$pattern"; }
notebook 'yad --notebook --key=4242 --title=Color Mint --tab=Themes' || fail 'the pattern misses its own notebook'
notebook '/usr/bin/yad --notebook --key=4242 --title=x' || fail 'the pattern misses a notebook started by path'
must_fail notebook 'yad --notebook --key=42420 --title=x'
must_fail notebook 'yad --notebook --key=14242 --title=x'
must_fail notebook 'yad --plug=4242 --tabnum=1 --form'
must_fail notebook 'bash -c yad --notebook --key=4242 --title=x'
rm -f "$TMP/state-redraw/window-redraw.4242"
: > "$TMP/pgrep.out"
redraw_call CM_TAB_KEY=4242
[ "$(marks "$TMP/state-redraw")" -eq 0 ] || fail 'a redraw that found no notebook left a mark: the next Exit would rebuild the window'
# The mark's directory is gone (sourcing the program recreates CM_HOME, so the path is pointed elsewhere).
out="$(CM_TAB_KEY=4242 PATH="$TMP/redraw-bin:$PATH" CM_TEST_PGREP_LOG="$TMP/pgrep.log" CM_TEST_PGREP_OUT="$TMP/pgrep.out" \
    HOME="$TMP/home-redraw" CM_HOME="$TMP/state-redraw" CM_LANG_OVERRIDE=en CM_TEST_MARK="$TMP/missing-dir/mark" \
    bash -c 'source "$1"; cm_redraw_mark() { printf "%s\n" "$CM_TEST_MARK"; }; cm_tab_redraw' bash "$BODY" 2>&1)" \
    || fail 'a redraw whose mark cannot be written must succeed'
[ -z "$out" ] || fail "a redraw whose mark cannot be written must be silent: $out"
: > "$TMP/pgrep.log"
out="$(CM_TAB_KEY=4242 HOME="$TMP/home-redraw" CM_HOME="$TMP/state-redraw" CM_LANG_OVERRIDE=en \
    bash -c 'source "$1"; PATH="$2"; cm_tab_redraw' bash "$BODY" "$TMP/redraw-empty" 2>&1)" || fail 'a redraw without pgrep must do nothing and succeed'
[ -z "$out" ] || fail "a redraw without pgrep must be silent: $out"
[ ! -s "$TMP/pgrep.log" ] || fail 'a redraw ran pgrep from outside its PATH'
[ "$(marks "$TMP/state-redraw")" -eq 0 ] || fail 'a redraw without pgrep left a mark'
kill "$bystander" 2>/dev/null || true
wait "$bystander" 2>/dev/null || true
pass 'a redraw ends only its own notebook and leaves a mark, only with a valid key; with no notebook it leaves nothing'

# The import redraws the tab once it is remembered and before the dialog (which waits for a click); a refused
# import neither remembers nor redraws.
wire_import() {
    CM_TEST_IMPORT_OK="$1" HOME="$TMP/home-wire" CM_HOME="$TMP/state-wire" CM_LANG_OVERRIDE=en \
        bash -c '
            source "$1"; cm_lang_init; log="$2"; : > "$log"
            cm_import_theme() { [ "$CM_TEST_IMPORT_OK" = 1 ] && printf "%s\n" "$HOME/.themes/Wired"; }
            cm_state_set() { echo "state $1=$2" >> "$log"; }
            cm_tab_redraw() { echo redraw >> "$log"; }
            cm_notify_applied() { echo notify >> "$log"; }
            yad() { echo error-dialog >> "$log"; }
            cm_ui_apply_themes_import "" "/some/folder"
        ' bash "$BODY" "$TMP/wire.log" >/dev/null 2>&1
}
wire_import 1 || fail 'a good import reported failure'
[ "$(tr '\n' ' ' < "$TMP/wire.log")" = 'state LAST_IMPORTED_THEME=Wired redraw notify ' ] \
    || fail "the import must remember, redraw, then notify: $(tr '\n' ' ' < "$TMP/wire.log")"
must_fail wire_import 0
[ "$(tr '\n' ' ' < "$TMP/wire.log")" = 'error-dialog ' ] \
    || fail "a refused import must only show its error: $(tr '\n' ' ' < "$TMP/wire.log")"
pass 'a good import redraws its tab between remembering the theme and the dialog; a refused one leaves the tab alone'

# Window lifecycle: every generation of the window (first start, each language switch) gets its own yad
# key, its tabs get the language explicitly, and nothing outlives it: a plug left behind could attach to the
# next notebook with the same key and leave tabs duplicated or missing.
mkdir -p "$TMP/win-bin" "$TMP/win"
for tool in dconf gsettings gdbus; do printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/win-bin/$tool"; done
cat > "$TMP/win-bin/yad" <<'WINYAD'
#!/usr/bin/env bash
dir="${CM_TEST_WIN:?}"
case " $* " in
    *" --notebook "*)
        n=$(( $(cat "$dir/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$dir/n"
        printf '%s\n' "$*" > "$dir/notebook.$n"
        args="$*"; key="${args##*--key=}"; key="${key%% *}"
        for _ in $(seq 1 300); do
            [ "$(grep -c -- "--plug=$key " "$dir/plugs" 2>/dev/null || true)" -ge 7 ] && break
            sleep 0.1
        done
        if [ "${CM_TEST_WIN_MODE:-switch}" = hold ]; then sleep 60; exit 1; fi
        if [ "${CM_TEST_WIN_MODE:-switch}" = deaf ]; then echo "$$" > "$dir/notebook.pid"; trap '' TERM HUP; exec sleep 60; fi
        if [ "${CM_TEST_WIN_MODE:-switch}" = redraw ] && [ "$n" -eq 1 ]; then : > "${CM_HOME:?}/window-redraw.$key"; exit 143; fi
        [ "$n" -eq 1 ] && exit 10
        exit 1 ;;
    *--plug=*)
        printf '%s lang=%s\n' "$*" "${CM_LANG_OVERRIDE:-}" >> "$dir/plugs"
        sleep 60 ;;
esac
exit 0
WINYAD
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${CM_TEST_WIN:?}/ipcrm"' 'exit 0' > "$TMP/win-bin/ipcrm"
chmod 755 "$TMP/win-bin"/*
win_clean() { pkill -f -- "$TMP/win-bin/yad" 2>/dev/null || true; : > "$TMP/win/plugs"; rm -f "$TMP/win"/n "$TMP/win"/notebook.* "$TMP/win/ipcrm"; }
win_left() { pgrep -f -- "--plug=$1 |--key=$1 |__tab [a-z]+ $1 " || true; }

win_clean
rc=0
PATH="$TMP/win-bin:$PATH" CM_TEST_WIN="$TMP/win" XDG_CURRENT_DESKTOP=X-Cinnamon HOME="$TMP/home-win" CM_HOME="$TMP/state-win" \
    CM_LANG_OVERRIDE=es timeout --kill-after=3 90 bash "$SCRIPT" gui >/dev/null 2>"$TMP/win.err" || rc=$?
[ "$rc" -eq 0 ] || fail "window with a language switch exited with $rc ($(head -c 200 "$TMP/win.err"))"
[ "$(cat "$TMP/win/n")" -eq 2 ] || fail 'the language button did not rebuild the window once'
key1="$(grep -o -- '--key=[0-9]*' "$TMP/win/notebook.1" | cut -d= -f2)"
key2="$(grep -o -- '--key=[0-9]*' "$TMP/win/notebook.2" | cut -d= -f2)"
[ -n "$key1" ] && [ -n "$key2" ] && [ "$key1" != "$key2" ] || fail "each generation needs its own key ($key1, $key2)"
for key in "$key1" "$key2"; do
    [ "$(grep -c -- "--plug=$key " "$TMP/win/plugs")" -eq 7 ] || fail "generation $key did not start exactly 7 plugs"
    [ "$(grep -o -- '--tabnum=[0-9]' "$TMP/win/plugs" | sort -u | wc -l)" -eq 7 ] || fail 'a tab is missing from the plugs'
done
[ "$(grep -- "--plug=$key1 " "$TMP/win/plugs" | grep -c ' lang=es$')" -eq 7 ] || fail 'first generation tabs are not Spanish'
[ "$(grep -- "--plug=$key2 " "$TMP/win/plugs" | grep -c ' lang=en$')" -eq 7 ] || fail 'tabs must get the new language explicitly, not the exported one'
[ -z "$(win_left "$key1")$(win_left "$key2")" ] || fail 'processes of a stopped window generation are still alive'
for key in "$key1" "$key2"; do
    [ "$(grep -cx -- "-M $key" "$TMP/win/ipcrm")" -ge 2 ] || fail "shared-memory key $key was not cleared before and after its generation"
done
pass 'each window generation has its own key, explicit language, and leaves nothing behind'

# A tab that asks for a rebuild gets a new generation with the same language; Exit (any other status) ends the window.
win_clean
rc=0
PATH="$TMP/win-bin:$PATH" CM_TEST_WIN="$TMP/win" CM_TEST_WIN_MODE=redraw XDG_CURRENT_DESKTOP=X-Cinnamon HOME="$TMP/home-win" CM_HOME="$TMP/state-win" \
    CM_LANG_OVERRIDE=es timeout --kill-after=3 90 bash "$SCRIPT" gui >/dev/null 2>"$TMP/win.err" || rc=$?
[ "$rc" -eq 0 ] || fail "window with a rebuild request exited with $rc ($(head -c 200 "$TMP/win.err"))"
[ "$(cat "$TMP/win/n")" -eq 2 ] || fail 'a rebuild request did not rebuild the window exactly once'
key1="$(grep -o -- '--key=[0-9]*' "$TMP/win/notebook.1" | cut -d= -f2)"
key2="$(grep -o -- '--key=[0-9]*' "$TMP/win/notebook.2" | cut -d= -f2)"
[ -n "$key1" ] && [ -n "$key2" ] && [ "$key1" != "$key2" ] || fail "a rebuild needs its own key ($key1, $key2)"
[ "$(grep -- "--plug=$key2 " "$TMP/win/plugs" | grep -c ' lang=es$')" -eq 7 ] || fail 'a rebuild must keep the language (only the language button switches it)'
[ ! -e "$TMP/state-win/window-redraw.$key1" ] || fail 'the rebuild mark was not consumed'
[ -z "$(win_left "$key1")$(win_left "$key2")" ] || fail 'processes of a rebuilt window generation are still alive'
win_clean
pass 'a rebuild request starts a new generation in the same language and consumes its mark'

for sig in TERM HUP; do
    win_clean
    PATH="$TMP/win-bin:$PATH" CM_TEST_WIN="$TMP/win" CM_TEST_WIN_MODE=hold XDG_CURRENT_DESKTOP=X-Cinnamon HOME="$TMP/home-win" \
        CM_HOME="$TMP/state-win" CM_LANG_OVERRIDE=en bash "$SCRIPT" gui >/dev/null 2>&1 &
    main=$!
    for _ in $(seq 1 300); do [ "$(grep -c -- '--plug=' "$TMP/win/plugs" 2>/dev/null || true)" -ge 7 ] && break; sleep 0.1; done
    [ "$(grep -c -- '--plug=' "$TMP/win/plugs")" -ge 7 ] || { kill "$main" 2>/dev/null || true; fail "SIG$sig: the window never reached 7 plugs"; }
    key="$(grep -o -- '--key=[0-9]*' "$TMP/win/notebook.1" | cut -d= -f2)"
    # Each tab leads a process group of its own, so one signal stops its shell and its yad plug together.
    leaders=0
    while read -r pid pgid; do
        [ "$pid" = "$pgid" ] || { kill "$main" 2>/dev/null || true; fail "SIG$sig: a tab shell shares a process group (pid $pid, group $pgid)"; }
        leaders=$((leaders + 1))
    done < <(ps -eo pid=,pgid=,args= | awk -v key="$key" '$0 ~ ("__tab [a-z]+ " key " ") { print $1, $2 }')
    [ "$leaders" -eq 7 ] || { kill "$main" 2>/dev/null || true; fail "SIG$sig: expected 7 tab shells in groups of their own, found $leaders"; }
    kill "-$sig" "$main"
    rc=0; wait "$main" || rc=$?
    want=143; [ "$sig" = HUP ] && want=129
    [ "$rc" -eq "$want" ] || fail "SIG$sig: exit status $rc, expected $want"
    left=""
    for _ in $(seq 1 20); do left="$(win_left "$key")"; [ -z "$left" ] && break; sleep 0.1; done
    [ -z "$left" ] || fail "SIG$sig left the notebook or its tabs running: $left"
done
win_clean
pass 'TERM and HUP stop the notebook and every tab'

# The tabs get their TERM before the teardown waits for anything. Each tab leads a session of its own, so a signal to the
# program's group never reaches it: when the teardown is cut short (the caller's timeout --kill-after, on a slow machine), every
# tab not yet signalled stays running without its notebook. Here the notebook ignores TERM, so the teardown stays in its wait
# for it, and a `sleep` that takes ten times longer (a loaded machine) stretches that wait to 10 s: every tab must be gone
# while the notebook is still alive. The control runs the same scenario on a copy with the old order (tabs signalled after
# the wait for the notebook), which must leave the tabs running.
mkdir -p "$TMP/slow-bin"
printf '%s\n' '#!/usr/bin/env bash' '[ "${1:-}" != 0.1 ] || set -- 1' "exec $(command -v sleep) \"\$@\"" > "$TMP/slow-bin/sleep"
chmod 755 "$TMP/slow-bin/sleep"
deaf_rc=0
deaf_window() {
    local script="$1" main key nb early=0
    win_clean
    rm -f "$TMP/win/notebook.pid"
    PATH="$TMP/slow-bin:$TMP/win-bin:$PATH" CM_TEST_WIN="$TMP/win" CM_TEST_WIN_MODE=deaf XDG_CURRENT_DESKTOP=X-Cinnamon \
        HOME="$TMP/home-win" CM_HOME="$TMP/state-win" CM_LANG_OVERRIDE=en bash "$script" gui >/dev/null 2>&1 &
    main=$!
    for _ in $(seq 1 300); do [ -s "$TMP/win/notebook.pid" ] && break; sleep 0.1; done
    [ -s "$TMP/win/notebook.pid" ] || { kill -KILL "$main" 2>/dev/null || true; win_clean; fail 'deaf notebook: the window never started'; }
    nb="$(cat "$TMP/win/notebook.pid")"
    key="$(grep -o -- '--key=[0-9]*' "$TMP/win/notebook.1" | cut -d= -f2)"
    kill -TERM "$main"
    for _ in $(seq 1 80); do
        if [ -z "$(win_left "$key")" ]; then kill -0 "$nb" 2>/dev/null && early=1; break; fi
        sleep 0.05
    done
    kill -KILL "$nb" 2>/dev/null || true
    for _ in $(seq 1 100); do kill -0 "$main" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$main" 2>/dev/null || true
    deaf_rc=0; wait "$main" 2>/dev/null || deaf_rc=$?
    win_clean
    [ "$early" = 1 ]
}
python3 - "$SCRIPT" "$TMP/old-order.sh" <<'PY' || fail 'the control cannot be built: cm_win_teardown changed shape'
import sys
src = open(sys.argv[1], encoding='utf-8').read()
term = '    for pid in "${CM_TAB_PIDS[@]}"; do cm_win_signal "$pid" TERM; done\n'
wait = '    for pid in "${CM_TAB_PIDS[@]}"; do wait "$pid" 2>/dev/null; done\n'
if src.count(term) != 1 or src.count(wait) != 1 or src.index(term) > src.index(wait):
    sys.exit(1)
open(sys.argv[2], 'w', encoding='utf-8').write(src.replace(term, '').replace(wait, term + wait))
PY
deaf_window "$SCRIPT" || fail 'a tab was still running while the teardown waited for a notebook that ignores TERM'
[ "$deaf_rc" -eq 143 ] || fail "the window ended with status $deaf_rc once the notebook was gone, expected 143"
must_fail deaf_window "$TMP/old-order.sh"
pass 'every tab is stopped before the teardown waits for the notebook; the old order leaves them running'

# An apply runs in a session of its own and keeps its exit status (see the __apply dispatcher).
mkdir -p "$TMP/setsid-bin"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s|%s\n" "$*" "${CM_APPLY_DETACHED:-}" >> "${CM_TEST_WIN:?}/setsid"' \
    '[ "${1:-}" = --wait ] && shift' 'exec "$@"' > "$TMP/setsid-bin/setsid"
chmod 755 "$TMP/setsid-bin/setsid"
rm -f "$TMP/win/setsid"
rc=0
PATH="$TMP/setsid-bin:$TMP/win-bin:$PATH" CM_TEST_WIN="$TMP/win" HOME="$TMP/home-win" CM_HOME="$TMP/state-win" CM_LANG_OVERRIDE=en \
    bash "$SCRIPT" __apply themes_import "" "" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "a failing __apply must keep its exit status (got $rc)"
[ "$(wc -l < "$TMP/win/setsid")" -eq 1 ] || fail '__apply must detach exactly once'
grep -qxF -- "--wait bash $SCRIPT __apply themes_import  |1" "$TMP/win/setsid" || fail "__apply was not re-run in its own session: $(cat "$TMP/win/setsid")"
pass '__apply runs in its own session and keeps its exit status'

cat > "$TMP/trim-case.sh" <<'CASE'
set -euo pipefail
# shellcheck disable=SC1090
source "$BODY"
t() {
    local value="$1"
    cm_trim_var value
    [ "$value" = "$2" ] || { printf 'trim %q -> %q (wanted %q)\n' "$1" "$value" "$2"; exit 1; }
}
t '  1:25  ' '1:25'
t $'\t expo:true:0 \n' 'expo:true:0'
t 'a  b' 'a  b'
t '' ''
t '   ' ''
t "it's \"q\" \\ z" "it's \"q\" \\ z"
CASE
BODY="$BODY" HOME="$TMP/home-trim" CM_HOME="$TMP/state-trim" CM_LANG_OVERRIDE=en bash "$TMP/trim-case.sh" || fail 'cm_trim_var contract'
pass 'whitespace trimming keeps quotes and backslashes intact'

cat > "$TMP/path-case.sh" <<'CASE'
set -euo pipefail
# shellcheck disable=SC1090
source "$BODY"
check() {
    SCRIPT_PATH="$1"
    if cm_gui_path_is_safe; then got=safe; else got=unsafe; fi
    [ "$got" = "$2" ] || { printf 'path %q: %s (wanted %s)\n' "$1" "$got" "$2"; exit 1; }
}
check '/home/user/Color Mint/script/color-mint.sh' safe
check '/home/user/ñandú/color-mint.sh' safe
check '/opt/100%/color-mint.sh' safe
check '/home/user/we"ird/color-mint.sh' unsafe
check '/home/user/back\slash/color-mint.sh' unsafe
check '/home/user/$HOME/color-mint.sh' unsafe
check '/home/user/`id`/color-mint.sh' unsafe
check '/home/user/50%5/color-mint.sh' unsafe
check $'/home/user/new\nline/color-mint.sh' unsafe
CASE
BODY="$BODY" HOME="$TMP/home-path-case" CM_HOME="$TMP/state-path-case" CM_LANG_OVERRIDE=en bash "$TMP/path-case.sh" || fail 'GUI path safety contract'

mkdir -p "$TMP/guard-bin" "$TMP/we\"ird"
for tool in dconf gsettings gdbus; do printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/guard-bin/$tool"; done
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${CM_TEST_YAD_LOG:?}"' 'exit 0' > "$TMP/guard-bin/yad"
chmod 755 "$TMP/guard-bin"/*
cp "$SCRIPT" "$TMP/we\"ird/color-mint.sh"
: > "$TMP/yad.log"
rc=0
PATH="$TMP/guard-bin:$PATH" CM_TEST_YAD_LOG="$TMP/yad.log" HOME="$TMP/home-unsafe-path" CM_HOME="$TMP/state-unsafe-path" \
    CM_LANG_OVERRIDE=en bash "$TMP/we\"ird/color-mint.sh" gui >"$TMP/unsafe.out" 2>"$TMP/unsafe.err" || rc=$?
[ "$rc" -eq 1 ] || fail "GUI started from an unsafe path (exit $rc)"
grep -q 'cannot run from this path' "$TMP/unsafe.err" || fail 'unsafe path message missing'
grep -q -- '--error' "$TMP/yad.log" || fail 'unsafe path dialog missing'
pass 'GUI refuses to start from a path that cannot be embedded safely'

# The GUI writes gtk.css, fonts.conf and .Xresources, so it refuses any desktop that is not Cinnamon and leaves no
# trace (not even its state folder under the default CM_HOME). An unset XDG_CURRENT_DESKTOP (bare session) only warns.
mkdir -p "$TMP/desk-bin" "$TMP/desk-nolocale"
for tool in dconf gsettings gdbus notify-send yad; do
    cat > "$TMP/desk-bin/$tool" <<'STUB'
#!/usr/bin/env bash
{ printf '%s %s' "${0##*/}" "$*" | tr '\n' ' '; printf '\n'; } >> "${CM_TEST_CALLS:?}"
exit 0
STUB
done
printf '%s\n' '#!/usr/bin/env bash' 'echo ANSI_X3.4-1968' > "$TMP/desk-nolocale/locale"
chmod 755 "$TMP/desk-bin"/* "$TMP/desk-nolocale"/*
# gui_session <language> <XDG_CURRENT_DESKTOP, or - for unset> [extra PATH dir]: sets rc and the desk.* files.
# CM_HOME stays unset on purpose: the default state folder lives under HOME, so "HOME is empty" covers it.
gui_session() {
    rm -rf "$TMP/desk-home"; mkdir -p "$TMP/desk-home"; : > "$TMP/desk.calls"
    rc=0
    (
        if [ "$2" = - ]; then unset XDG_CURRENT_DESKTOP; else export XDG_CURRENT_DESKTOP="$2"; fi
        PATH="${3:+$3:}$TMP/desk-bin:$PATH" CM_TEST_CALLS="$TMP/desk.calls" HOME="$TMP/desk-home" \
            CM_LANG_OVERRIDE="$1" bash "$SCRIPT" gui >"$TMP/desk.out" 2>"$TMP/desk.err" </dev/null
    ) || rc=$?
}
expect_refused() {
    gui_session "$1" "$2"
    [ "$rc" -eq 1 ] || fail "GUI did not refuse the '$2' session (exit $rc)"
    grep -qF -- "$3" "$TMP/desk.err" || fail "refusal message missing for '$2' ($1)"
    if [ "$(grep -c '' "$TMP/desk.calls")" -ne 1 ] || ! grep -q '^yad --error ' "$TMP/desk.calls"; then
        fail "'$2' session: expected one error dialog and no other call, got: $(tr '\n' ';' < "$TMP/desk.calls")"
    fi
    [ -z "$(find "$TMP/desk-home" -mindepth 1 -print -quit)" ] || fail "refused '$2' session wrote into HOME"
}
expect_starts() {
    gui_session "$1" "$2"
    [ "$rc" -eq 0 ] || fail "GUI did not start in the '$2' session (exit $rc)"
    grep -q '^yad ' "$TMP/desk.calls" || fail "'$2' session: the main window was not opened"
    if grep -q -- '--error' "$TMP/desk.calls"; then fail "'$2' session: unexpected error dialog"; fi
    if grep -Eq 'only works in a Cinnamon|solo funciona en una sesión' "$TMP/desk.err"; then fail "'$2' session: refusal message printed"; fi
}
expect_refused en GNOME 'only works in a Cinnamon session, and this one is "GNOME"'
expect_refused es KDE 'solo funciona en una sesión de Cinnamon y esta es «KDE»'
expect_refused en ubuntu:GNOME 'this one is "ubuntu:GNOME"'
expect_starts en X-Cinnamon
expect_starts es X-Cinnamon:GNOME
expect_starts en Cinnamon
if grep -q 'XDG_CURRENT_DESKTOP' "$TMP/desk.err"; then fail 'Cinnamon session: unexpected warning'; fi
expect_starts en -
grep -q 'XDG_CURRENT_DESKTOP is not set' "$TMP/desk.err" || fail 'unset desktop: warning missing'

# Without a UTF-8 locale yad cannot show the refusal: the notification and stderr carry it instead.
gui_session es GNOME "$TMP/desk-nolocale"
[ "$rc" -eq 1 ] || fail "GUI did not refuse without a UTF-8 locale (exit $rc)"
if ! grep -q '^notify-send ' "$TMP/desk.calls" || grep -q '^yad ' "$TMP/desk.calls"; then
    fail "refusal without a UTF-8 locale must notify and not call yad, got: $(tr '\n' ';' < "$TMP/desk.calls")"
fi
grep -qF 'solo funciona en una sesión de Cinnamon' "$TMP/desk.err" || fail 'refusal without a UTF-8 locale: stderr message missing'
[ -z "$(find "$TMP/desk-home" -mindepth 1 -print -quit)" ] || fail 'refusal without a UTF-8 locale wrote into HOME'
pass 'GUI refuses non-Cinnamon sessions without touching anything, and only warns when the desktop is unknown'

# The main window follows the screen: the designed 950x740 only when the screen can hold it.
mkdir -p "$TMP/geo-bin"
printf '%s\n' '#!/usr/bin/env bash' 'cat "${CM_TEST_XRANDR:?}"' > "$TMP/geo-bin/xrandr"
printf '%s\n' '#!/usr/bin/env bash' 'cat "${CM_TEST_XDPYINFO:?}"' > "$TMP/geo-bin/xdpyinfo"
chmod 755 "$TMP/geo-bin/xrandr" "$TMP/geo-bin/xdpyinfo"
geo() {
    printf '%s' "$1" > "$TMP/xrandr.out"
    printf '%s' "${2:-}" > "$TMP/xdpyinfo.out"
    PATH="$TMP/geo-bin:$PATH" CM_TEST_XRANDR="$TMP/xrandr.out" CM_TEST_XDPYINFO="$TMP/xdpyinfo.out" \
        HOME="$TMP/home-geo" CM_HOME="$TMP/state-geo" CM_LANG_OVERRIDE=en bash -c 'source "$1"; cm_gui_geometry' bash "$BODY"
}
expect_geo() {
    local got
    got="$(geo "$2" "${3:-}")"
    [ "$got" = "$1" ] || fail "window geometry: wanted '$1', got '$got' for: $(printf '%s' "$2" | tr '\n' ';')"
}
expect_geo '950 658' $'Screen 0: current 1366 x 768\nscreen connected primary 1366x768+0+0\n'
expect_geo '950 610' $'Screen 0: current 1280 x 720\nscreen connected primary 1280x720+0+0\n'
expect_geo '950 740' $'Screen 0: current 1920 x 1080\nscreen connected primary 1920x1080+0+0\n'
expect_geo '950 490' $'LVDS-1 connected 1024x600+0+0\n'
expect_geo '950 658' $'HDMI-1 connected 1920x1080+0+0\neDP-1 connected primary 1366x768+1920+0\n'
expect_geo '640 460' $'x connected primary 640x480+0+0\n'
expect_geo '950 610' '' $'  dimensions:    1280x720 pixels (338x190 millimeters)\n'
expect_geo '950 680' ''
pass 'main window size follows the screen with safe fallbacks'

# yad cannot parse UTF-8 labels under a non-UTF-8 locale: the GUI switches to a UTF-8 one first.
mkdir -p "$TMP/loc-bin"
cat > "$TMP/loc-bin/locale" <<'LOC'
#!/usr/bin/env bash
[ "${1:-}" = charmap ] || exit 1
case "${LC_ALL:-${LANG:-C}}" in
    C.UTF-8) echo UTF-8 ;;
    *) echo ANSI_X3.4-1968 ;;
esac
LOC
printf '%s\n' '#!/usr/bin/env bash' 'echo ANSI_X3.4-1968' > "$TMP/guard-bin/locale-never"
chmod 755 "$TMP/loc-bin/locale" "$TMP/guard-bin/locale-never"
HOME="$TMP/home-loc" CM_HOME="$TMP/state-loc" CM_LANG_OVERRIDE=en bash -c '
    source "$1"
    PATH="$2:$PATH"
    LC_ALL="" LANG=C
    cm_ensure_utf8_locale || exit 1
    [ "$LC_ALL" = "C.UTF-8" ] || exit 2
    LC_ALL="C.UTF-8"; unset CM_PROBE
    cm_ensure_utf8_locale || exit 3
' bash "$BODY" "$TMP/loc-bin" || fail 'UTF-8 locale selection'
mkdir -p "$TMP/never-bin"
cp "$TMP/guard-bin/locale-never" "$TMP/never-bin/locale"
HOME="$TMP/home-loc" CM_HOME="$TMP/state-loc" CM_LANG_OVERRIDE=en bash -c '
    source "$1"
    PATH="$2:$PATH"
    LC_ALL="" LANG=C
    must_fail cm_ensure_utf8_locale
' bash "$BODY" "$TMP/never-bin" || fail 'a system without any UTF-8 locale must be reported'
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s LC_ALL=%s\n" "$*" "${LC_ALL:-}" >> "${CM_TEST_YAD_LOG:?}"' 'exit 0' > "$TMP/guard-bin/yad"
: > "$TMP/yad-locale.log"
rc=0
PATH="$TMP/loc-bin:$TMP/guard-bin:$PATH" CM_TEST_YAD_LOG="$TMP/yad-locale.log" HOME="$TMP/home-gui-locale" CM_HOME="$TMP/state-gui-locale" \
    LANG=C LC_ALL='' CM_LANG_OVERRIDE=en timeout 30 bash "$SCRIPT" gui >/dev/null 2>"$TMP/gui-locale.err" || rc=$?
[ "$rc" -eq 0 ] || fail "GUI did not start under LANG=C (exit $rc)"
grep -q 'LC_ALL=C.UTF-8' "$TMP/yad-locale.log" || fail 'yad was not started with a UTF-8 locale'
grep -q -- "--window-icon=$TMP/state-gui-locale/icon.png" "$TMP/yad-locale.log" || fail 'the main window must use the embedded program icon'
[ -f "$TMP/state-gui-locale/icon.png" ] || fail 'starting the GUI must install the embedded icon'
rc=0
PATH="$TMP/never-bin:$TMP/guard-bin:$PATH" CM_TEST_YAD_LOG="$TMP/yad-locale.log" HOME="$TMP/home-gui-locale" CM_HOME="$TMP/state-gui-locale" \
    LANG=C LC_ALL='' CM_LANG_OVERRIDE=en timeout 30 bash "$SCRIPT" gui >/dev/null 2>"$TMP/gui-locale.err" || rc=$?
[ "$rc" -eq 1 ] || fail "GUI without any UTF-8 locale must exit 1 (exit $rc)"
grep -q 'needs a UTF-8 locale' "$TMP/gui-locale.err" || fail 'missing UTF-8 locale message'
pass 'GUI starts under a non-UTF-8 locale and reports a missing UTF-8 locale'

cat > "$TMP/accent-case.sh" <<'CASE'
set -euo pipefail
# shellcheck disable=SC1090
source "$BODY"
check() {
    local got
    got="$(cm_accent_fg "$1")"
    [ "$got" = "$2" ] || { printf 'accent %s: got %s, wanted %s\n' "$1" "$got" "$2"; exit 1; }
}
check '#ffffff' '#000000'
check '#000000' '#ffffff'
check '#1c71d8' '#ffffff'
check '#f6d32d' '#000000'
check '#e05252' '#000000'
check '#c76b6b' '#000000'
check '#2ec27e' '#000000'
check '#9141ac' '#ffffff'
CASE
BODY="$BODY" HOME="$TMP/home-accent" CM_HOME="$TMP/state-accent" CM_LANG_OVERRIDE=en bash "$TMP/accent-case.sh" || fail 'accent text colour contract'
pass 'accent text colour picks the higher WCAG contrast'

# yad 0.40.0 (Mint 22.x, Ubuntu 24.04) has no --css and ignores it, while newer yad applies it, so the GUI
# would look different per distro. The GUI follows the system theme everywhere: no stylesheet option.
if grep -n -E -- '--css|style\.css' "$SCRIPT" >/dev/null; then fail 'the GUI must not pass a stylesheet to yad'; fi
[ ! -e "$TMP/state-gui-locale/style.css" ] || fail 'starting the GUI wrote a stylesheet'
pass 'GUI follows the system theme (no stylesheet is passed to yad or written)'

# Button fields: yad 0.40.0 reads "label!icon", yad 5 and later read "label!tooltip" and take the icon from
# "label!icon!tooltip". Both generations were verified with a real GUI; the wrong form shows the icon name as a tooltip.
mkdir -p "$TMP/yadv"
yad_version() {
    printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && printf "%%s\\n" "%s"\n' "$1" > "$TMP/yadv/yad"
    chmod 755 "$TMP/yadv/yad"
    PATH="$TMP/yadv:$PATH" HOME="$TMP/home-yadv" CM_HOME="$TMP/state-yadv" CM_LANG_OVERRIDE=en \
        bash -c 'unset CM_YAD_NEW_FIELDS; source "$1"; cm_yad_btn_icon gtk-apply' bash "$BODY"
}
[ "$(yad_version '0.40.0 (GTK+ 3.24.41)')" = '!gtk-apply' ] || fail 'yad 0.40.0 button icon syntax'
[ "$(yad_version '14.1 (GTK+ 3.24.41)')" = '!gtk-apply!' ] || fail 'yad 14.1 button icon syntax'
[ "$(yad_version '5.0 (GTK+ 3.24.41)')" = '!gtk-apply!' ] || fail 'yad 5.0 button icon syntax'
[ "$(yad_version 'unexpected output')" = '!gtk-apply' ] || fail 'unknown yad version must use the 0.40.0 syntax'
rm -f "$TMP/yadv/yad"
[ "$(PATH="$TMP/yadv:$PATH" HOME="$TMP/home-yadv" CM_HOME="$TMP/state-yadv" CM_LANG_OVERRIDE=en \
    bash -c 'unset CM_YAD_NEW_FIELDS; source "$1"; yad() { return 127; }; cm_yad_btn_icon gtk-undo' bash "$BODY")" = '!gtk-undo' ] \
    || fail 'a missing yad must use the 0.40.0 syntax'
# detected once and inherited: the tabs are separate processes and must agree with the main window
[ "$(CM_YAD_NEW_FIELDS=1 HOME="$TMP/home-yadv" CM_HOME="$TMP/state-yadv" CM_LANG_OVERRIDE=en \
    bash -c 'source "$1"; cm_yad_btn_icon gtk-open' bash "$BODY")" = '!gtk-open!' ] || fail 'the detected syntax must be inherited by the tabs'
if grep -n -E '![a-z-]+:FBTN' "$SCRIPT" | grep -v 'cm_yad_btn_icon' >/dev/null; then fail 'every button field must take its icon through cm_yad_btn_icon'; fi
pass 'button icons use the syntax of the installed yad generation'

# Dependencies on other distros: apt keeps its install flow; dnf, pacman and zypper get the exact command to run.
cat > "$TMP/pm-case.sh" <<'CASE'
set -euo pipefail
# shellcheck disable=SC1090
source "$BODY"
for manager in zypper pacman dnf apt-get; do
    mkdir -p "$TMP/pm-$manager"
    printf '#!/bin/sh\nexit 0\n' > "$TMP/pm-$manager/$manager"
    chmod 755 "$TMP/pm-$manager/$manager"
done
mkdir -p "$TMP/pm-empty"
real_path="$PATH"
PATH="$TMP/pm-empty"
[ -z "$(cm_pkg_manager)" ] || exit 1
PATH="$TMP/pm-zypper"; [ "$(cm_pkg_manager)" = zypper ] || exit 2
PATH="$TMP/pm-zypper:$TMP/pm-pacman"; [ "$(cm_pkg_manager)" = pacman ] || exit 3
PATH="$TMP/pm-zypper:$TMP/pm-pacman:$TMP/pm-dnf"; [ "$(cm_pkg_manager)" = dnf ] || exit 4
PATH="$TMP/pm-zypper:$TMP/pm-pacman:$TMP/pm-dnf:$TMP/pm-apt-get"; [ "$(cm_pkg_manager)" = apt ] || exit 5
PATH="$real_path"
check() { [ "$(cm_pkg_name "$1" "$2")" = "$3" ] || { printf 'package for %s/%s: got %s, wanted %s\n' "$1" "$2" "$(cm_pkg_name "$1" "$2")" "$3"; exit 6; }; }
check apt yad yad;                check apt dconf dconf-cli;       check apt gsettings libglib2.0-bin
check apt gdbus libglib2.0-bin;   check dnf dconf dconf;           check dnf gsettings glib2
check pacman gdbus glib2;         check pacman dconf dconf;        check zypper gsettings glib2-tools
check zypper gdbus glib2-tools;   check zypper dconf dconf;        check dnf unzip unzip
line() { [ "$(cm_pkg_install_line "$@")" = "${EXPECT}" ] || { printf 'install line: got %s\n' "$(cm_pkg_install_line "$@")"; exit 7; }; }
EXPECT='sudo apt-get update && sudo apt-get install -y yad dconf-cli'; line apt yad dconf-cli
EXPECT='sudo dnf install -y yad dconf';                               line dnf yad dconf
EXPECT='sudo pacman -S --needed yad dconf';                           line pacman yad dconf
EXPECT='sudo zypper install yad dconf';                               line zypper yad dconf
CASE
env BODY="$BODY" TMP="$TMP" HOME="$TMP/home-pm" CM_HOME="$TMP/state-pm" CM_LANG_OVERRIDE=en bash "$TMP/pm-case.sh" || fail "package manager mapping (exit $?)"

# End to end, without a terminal: a system with dnf (and one with no known manager) is told what to run, never asked to install.
mkdir -p "$TMP/deps-bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${CM_TEST_YAD_LOG:?}"' 'exit 1' > "$TMP/deps-bin/yad"
chmod 755 "$TMP/deps-bin/yad"
deps_run() {
    : > "$TMP/yad-deps.log"
    HOME="$TMP/home-deps" CM_HOME="$TMP/state-deps" CM_LANG_OVERRIDE=en CM_TEST_YAD_LOG="$TMP/yad-deps.log" PATH="$TMP/deps-bin:$PATH" DEPS_MANAGER="$1" \
        bash -c '
            source "$1"
            cm_lang_init
            command() {
                if [ "${1:-}" = -v ]; then
                    case "$2" in
                        apt-get|dnf|pacman|zypper) [ "$2" = "$DEPS_MANAGER" ] && return 0; return 1 ;;
                        gsettings|dconf) return 0 ;;
                        zz-missing-tool) return 1 ;;
                    esac
                fi
                builtin command "$@"
            }
            cm_check_dependencies zz-missing-tool gsettings dconf
        ' bash "$BODY" </dev/null >/dev/null 2>&1
}
rc=0; deps_run dnf || rc=$?
[ "$rc" -eq 1 ] || fail "dnf system: missing dependencies must stop the program (exit $rc)"
grep -q -- '--error' "$TMP/yad-deps.log" || fail 'dnf system: the dialog must be an error, not an install question'
grep -q 'sudo dnf install -y zz-missing-tool' "$TMP/yad-deps.log" || fail 'dnf system: the exact command is missing'
! grep -q -- '--question' "$TMP/yad-deps.log" || fail 'dnf system: must not offer to install'
rc=0; deps_run none || rc=$?
[ "$rc" -eq 1 ] || fail "unknown system: exit $rc"
grep -q 'Install them with your package manager and open Color Mint again' "$TMP/yad-deps.log" || fail 'unknown system: generic message missing'
rc=0; deps_run apt-get || rc=$?
grep -q -- '--question' "$TMP/yad-deps.log" || fail 'apt system: keeps the install question'
pass 'missing dependencies: apt keeps its flow, other package managers get the exact command'

# CI helper for the container jobs: it runs the exact install line Color Mint prints (minus sudo, which a container
# lacks) and then checks the commands. Package managers are doubles; the sudo double fails if the helper keeps it.
mkdir -p "$TMP/ci-min" "$TMP/ci-bin" "$TMP/ci-cmds"
for tool in bash dirname mktemp sed head awk sort yes rm cat; do ln -sf "$(command -v "$tool")" "$TMP/ci-min/$tool"; done
for manager in apt-get dnf pacman zypper; do
    printf '#!/bin/sh\necho "%s $*" >> "$CI_LOG"\n' "$manager" > "$TMP/ci-bin/$manager"
done
printf '#!/bin/sh\necho "sudo called" >> "$CI_LOG"\nexit 1\n' > "$TMP/ci-bin/sudo"
for tool in yad dconf gsettings gdbus; do printf '#!/bin/sh\nexit 0\n' > "$TMP/ci-cmds/$tool"; done
chmod 755 "$TMP/ci-bin"/* "$TMP/ci-cmds"/*
ci_run() {
    : > "$TMP/ci.log"
    env PATH="$TMP/ci-min:$TMP/ci-bin:$TMP/ci-cmds" CI_LOG="$TMP/ci.log" "$BASH" "$ROOT/tests/lib/program_deps.sh" "$@" >/dev/null 2>&1
}
ci_expect() {
    local manager="$1" wanted="$2"
    ci_run "$manager" || fail "container helper failed for $manager"
    [ "$(cat "$TMP/ci.log")" = "$wanted" ] || fail "container helper ran the wrong commands for $manager: $(tr '\n' '|' < "$TMP/ci.log")"
}
ci_expect apt    "$(printf 'apt-get update\napt-get install -y dconf-cli libglib2.0-bin yad')"
ci_expect dnf    'dnf install -y dconf glib2 yad'
ci_expect pacman "$(printf 'pacman -Syu --noconfirm\npacman -S --needed dconf glib2 yad')"
ci_expect zypper 'zypper install dconf glib2-tools yad'
must_fail ci_run none
must_fail ci_run
rm -f "$TMP/ci-cmds/gdbus"
must_fail ci_run dnf
pass 'container CI helper installs the packages the program names and verifies their commands'
