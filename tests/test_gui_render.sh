#!/usr/bin/env bash
# Real-render audit: starts the actual GUI under a virtual X server at 1366x768 (the smallest common
# laptop screen) with the system yad and measures what a user would see: the window fits the screen,
# the seven tabs are drawn, the picture is not blank, and yad prints no GTK errors. The same run also
# covers a non-UTF-8 locale. Skipped when Xvfb, xwininfo, xdotool, yad or ImageMagick are missing; CI sets
# CM_REQUIRE_GUI_RENDER=1 so a missing tool fails there instead. CM_SCREENSHOT_DIR keeps the pictures.
# "Get more themes" is drawn too, with a download that works and one that fails: its form, its wait window and its notice.
# The last section checks what libadwaita apps paint from the CSS Color Mint writes: a real GTK 4 process
# (tests/lib/gtk4_probe.py) draws a button and the test reads its pixel. It is skipped on its own, under the same
# CM_REQUIRE_GUI_RENDER rule, when python3-gi, GTK 4.10 or libadwaita is missing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sandbox.sh
. "$ROOT/tests/lib/sandbox.sh"
SCRIPT="$ROOT/script/color-mint.sh"
TMP="$(mktemp -d)"
XPID=""
cleanup() {
    local n
    if [ -n "$XPID" ]; then
        kill "$XPID" 2>/dev/null || true
        # A run that follows at once must not meet a server still dying: wait until it is gone, socket and lock included.
        for n in $(seq 1 40); do kill -0 "$XPID" 2>/dev/null || break; sleep 0.25; done
        kill -9 "$XPID" 2>/dev/null || true
        wait "$XPID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

missing=()
for tool in Xvfb xwininfo xdotool yad; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
# ImageMagick 7 ("magick") or 6 ("convert" and "import"): "import" grabs the virtual screen.
if command -v magick >/dev/null 2>&1; then IM_BIN=magick; SHOT=(magick import)
elif command -v convert >/dev/null 2>&1 && command -v import >/dev/null 2>&1; then IM_BIN=convert; SHOT=(import)
else missing+=("ImageMagick"); IM_BIN=""; SHOT=()
fi
if [ "${#missing[@]}" -gt 0 ]; then
    [ -z "${CM_REQUIRE_GUI_RENDER:-}" ] || fail "GUI render audit needs: ${missing[*]}"
    printf 'SKIP: GUI render audit needs %s (set CM_REQUIRE_GUI_RENDER=1 to make this a failure)\n' "${missing[*]}"
    exit 0
fi

# The GUI only needs these tools to exist; the tabs fall back to their defaults.
mkdir -p "$TMP/bin"
for tool in dconf gdbus; do printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/$tool"; done
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${CM_TEST_CALLS_LOG:-/dev/null}"' '[ "${1:-}" = get ] && printf "%s\n" "'"''"'"' 'exit 0' > "$TMP/bin/gsettings"
chmod 755 "$TMP/bin"/*

display=""
for n in $(seq 90 140); do
    if [ ! -e "/tmp/.X11-unix/X$n" ] && [ ! -e "/tmp/.X$n-lock" ]; then display=":$n"; break; fi
done
[ -n "$display" ] || fail 'no free X display number'
# -noreset: by default Xvfb resets, closing and reopening its sockets, each time its last client disconnects, and a client that
# connects in that gap gets "cannot open display". This test causes it constantly (the xwininfo polls, and the window rebuild that
# ends every client at once and starts new ones), so under load yad failed to start. Measured on 300 back-to-back connections with
# the CPU saturated: 12 failures without the flag, 0 with it.
Xvfb "$display" -screen 0 1366x768x24 -nolisten tcp -noreset >"$TMP/xvfb.log" 2>&1 &
XPID=$!
for _ in $(seq 1 20); do [ -S "/tmp/.X11-unix/X${display#:}" ] && break; sleep 0.5; done
[ -S "/tmp/.X11-unix/X${display#:}" ] || fail "virtual X server did not start: $(head -3 "$TMP/xvfb.log")"
# The socket file only proves that the server was created. Wait until it answers a client, so that a server that never came up
# is reported as such and not as "only 0 of 7 tabs were drawn" with "cannot open display" (seen once in 40 back-to-back runs).
for _ in $(seq 1 40); do
    DISPLAY="$display" xwininfo -root >/dev/null 2>&1 && break
    kill -0 "$XPID" 2>/dev/null || break
    sleep 0.25
done
kill -0 "$XPID" 2>/dev/null || fail "virtual X server stopped at start: $(head -3 "$TMP/xvfb.log")"
DISPLAY="$display" xwininfo -root >/dev/null 2>&1 || fail "virtual X server does not accept clients: $(head -3 "$TMP/xvfb.log")"

shots="${CM_SCREENSHOT_DIR:-$TMP/shots}"
mkdir -p "$shots"

# One theme of each kind in the render's own HOME, so the form always has something to apply whatever the
# machine ships: the lists hold only what Cinnamon's panel would offer, and a minimal system has no GTK 3 theme.
seed_themes() {
    mkdir -p "$1/.themes/Render-GTK/gtk-3.0" "$1/.themes/Render-Cinnamon/cinnamon" "$1/.icons/Render-Icons" "$1/.icons/Render-Cursor/cursors"
    : > "$1/.themes/Render-GTK/gtk-3.0/gtk.css"
    printf '[Icon Theme]\nName=Render-Icons\nDirectories=16x16/apps\n' > "$1/.icons/Render-Icons/index.theme"
}

# state_procs <state folder>: every process of this uid that carries that CM_HOME, yad or not. The tabs and the buttons run in sessions
# of their own, so the signal sent to the runner's group does not reach them.
state_procs() {
    local p
    for p in $(pgrep -u "$(id -u)"); do
        { tr '\0' '\n' < "/proc/$p/environ"; } 2>/dev/null | grep -qxF "CM_HOME=$1" && printf '%s\n' "$p"
    done
    return 0
}

# proc_diag <label>: pid, ppid, pgid, sid, state and command of each pid read from stdin, for a process that outlived its case: the
# group and the session say whether the signal sent to the runner could reach it.
proc_diag() {
    local label="$1" p stat rest state ppid pgid sid cmd
    while read -r p; do
        stat="$(cat "/proc/$p/stat" 2>/dev/null)" || { printf 'DIAG %s: pid=%s gone\n' "$label" "$p" >&2; continue; }
        rest="${stat##*) }"      # field 2, the command name, may hold spaces and parentheses: read on from its last ")"
        read -r state ppid pgid sid _ <<< "$rest"
        cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" || cmd=''
        printf 'DIAG %s: pid=%s ppid=%s pgid=%s sid=%s state=%s cmd=%s\n' "$label" "$p" "$ppid" "$pgid" "$sid" "$state" "${cmd:0:100}" >&2
    done
}

# reap_state <state folder>: stop what a pressed button left running and wait until it is gone. "Apply themes" runs in its
# own session by design, so ending the GUI does not end its notice: with nothing to apply it is titled "... with warnings"
# and would stay on the screen for the rest of the run, where "Get more themes" would take it for its own. When something outlives
# the 5 s, the dump names it (and this test, to compare groups and sessions).
reap_state() {
    local n p left
    for n in $(seq 1 20); do
        left="$(state_procs "$1")"
        [ -n "$left" ] || return 0
        for p in $left; do kill "$p" 2>/dev/null || true; done
        sleep 0.25
    done
    state_procs "$1" | proc_diag reap
    printf '%s\n' "$$" | proc_diag 'reap (this test)'
    fail "processes of $1 outlive their case"
}

# case_yads <state folder>: the yad processes of one case, told apart by the CM_HOME in their environment.
case_yads() {
    local p
    for p in $(pgrep -u "$(id -u)" -x yad); do
        { tr '\0' '\n' < "/proc/$p/environ"; } 2>/dev/null | grep -qxF "CM_HOME=$1" && printf '%s\n' "$p"
    done
    return 0
}

# start_diag <case> <runner pid> <runner's stderr file> <state folder>: what a window that did not come up in time leaves to
# look at. Call it before stopping the runner, so that "alive" is the state at the moment of the failure.
start_diag() {
    local label="$1" runner="$2" err="$3" tree
    printf 'DIAG %s: runner %s, Xvfb %s, %s yad processes of the case\n' "$label" \
        "$(kill -0 "$runner" 2>/dev/null && echo alive || echo gone)" "$(kill -0 "$XPID" 2>/dev/null && echo alive || echo gone)" \
        "$(case_yads "$4" | wc -l)" >&2
    tree="$(DISPLAY="$display" timeout 5 xwininfo -root -tree 2>&1 | grep -E '^     0x|"YAD"|^xwininfo: error' | head -n 12 | tr -s ' ')" || true
    printf '%s\n' "${tree:-no windows listed}" | sed "s/^/DIAG $label: window: /" >&2
    [ -s "$err" ] || printf 'DIAG %s: the runner printed nothing\n' "$label" >&2
    head -n 8 "$err" 2>/dev/null | sed "s/^/DIAG $label.err: /" >&2 || true
    grep -v -E 'xkbcomp|XKEYBOARD|^> ' "$TMP/xvfb.log" 2>/dev/null | tail -n 5 | sed 's/^/DIAG xvfb.log: /' >&2 || true
}

# render <label> <language> [env assignments...]: start the GUI, wait for it, measure, take a picture.
render() {
    local label="$1" lang="$2" click="$3"; shift 3
    local runner gui_pid main_line geometry plugs width height colours hit y
    seed_themes "$TMP/home-$label"
    DISPLAY="$display" env "$@" PATH="$TMP/bin:$PATH" HOME="$TMP/home-$label" CM_HOME="$TMP/state-$label" \
        CM_LANG_OVERRIDE="$lang" XDG_CURRENT_DESKTOP=X-Cinnamon CM_TEST_CALLS_LOG="$TMP/calls-$label.log" \
        timeout --kill-after=3 45 bash "$SCRIPT" gui >"$TMP/$label.out" 2>"$TMP/$label.err" &
    runner=$!
    main_line=""
    plugs=0
    for _ in $(seq 1 60); do
        main_line="$(DISPLAY="$display" xwininfo -root -tree 2>/dev/null | grep -m1 '"Color Mint"' || true)"
        plugs="$(DISPLAY="$display" xwininfo -root -tree 2>/dev/null | grep '"YAD"' | grep -c -E ' [6-9][0-9]{2}x' || true)"
        [ -n "$main_line" ] && [ "$plugs" -ge 7 ] && break
        sleep 0.5
    done
    if [ -z "$main_line" ] || [ "$plugs" -lt 7 ]; then
        start_diag "$label" "$runner" "$TMP/$label.err" "$TMP/state-$label"
        kill "$runner" 2>/dev/null || true
        [ -n "$main_line" ] || fail "$label: the main window never appeared"
        fail "$label: only $plugs of 7 tabs were drawn"
    fi
    gui_pid="$(pgrep -P "$runner" | head -n1 || true)"
    sleep 1
    DISPLAY="$display" "${SHOT[@]}" -window root "$shots/gui-1366x768-$label.png"
    if [ "$click" = 1 ]; then
        # End to end: pressing "Apply themes" must reach the backend with the values shown in the form.
        # The button sits just under the cursor size on the first tab; scan down from there, closing any popup in between.
        : > "$TMP/calls-$label.log"
        hit=0
        for y in $(seq 456 6 620); do
            DISPLAY="$display" xdotool mousemove 480 "$y" click 1 2>/dev/null || true
            sleep 0.5
            if grep -q '^set org.cinnamon.desktop.interface gtk-theme' "$TMP/calls-$label.log"; then hit=1; break; fi
            DISPLAY="$display" xdotool key Escape 2>/dev/null || true
        done
        [ "$hit" = 1 ] || { kill "$runner" 2>/dev/null || true; fail "$label: pressing Apply themes did not reach the backend"; }
        grep -q '^set org.cinnamon.desktop.interface cursor-size ' "$TMP/calls-$label.log" \
            || { kill "$runner" 2>/dev/null || true; fail "$label: Apply themes did not pass the cursor size"; }
        printf 'INFO: %s: Apply themes pressed at y=%s reached the backend with %s settings\n' "$label" "$y" \
            "$(grep -c '^set ' "$TMP/calls-$label.log")"
    fi
    kill "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
    [ -z "$gui_pid" ] || ipcrm -M "$gui_pid" 2>/dev/null || true
    [ "$click" = 0 ] || reap_state "$TMP/state-$label"

    geometry="$(printf '%s' "$main_line" | grep -o -E '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -n1)"
    width="${geometry%%x*}"
    height="${geometry#*x}"; height="${height%%+*}"
    [ "$width" -le 1366 ] || fail "$label: window is $width px wide on a 1366 px screen"
    [ $((height + 36 + 40)) -le 768 ] || fail "$label: window is $height px tall; with a 40 px panel and a 36 px title bar it is cut on 1366x768"
    colours="$("$IM_BIN" "$shots/gui-1366x768-$label.png" -format '%k' info:)"
    [ "$colours" -ge 200 ] || fail "$label: the screenshot looks blank ($colours colours)"
    ! grep -q -E 'CRITICAL|Unable to parse|cannot open display|Invalid byte sequence|from markup' "$TMP/$label.err" \
        || fail "$label: yad reported errors: $(grep -m2 -E 'CRITICAL|Unable to parse|cannot open display|Invalid byte sequence|from markup' "$TMP/$label.err" | tr '\n' ' ')"
    printf 'INFO: %s: window %sx%s, %s tabs, %s colours\n' "$label" "$width" "$height" "$plugs" "$colours"
}

render english en 1 LC_ALL=C.UTF-8
pass 'real GUI fits a 1366x768 screen, draws every tab and Apply themes reaches the backend (English)'
render spanish-posix es 0 LANG=C LC_ALL=
pass 'real GUI starts under a non-UTF-8 locale and draws every tab (Spanish)'

# A button does not redraw its tab (GtkSocket takes no second plug: a new yad for the tab opens as a loose window
# and leaves the tab blank), so importing a theme rebuilds the whole window, as the language button does. The proof is
# the process: the notebook's PID changes, the seven plugs come back embedded with the theme first in its list, and
# nothing is left behind. The yads of this run are told apart by the CM_HOME in their environment.
run_yads() { case_yads "$TMP/state-redraw"; }
yad_with_arg() {
    local p
    for p in $(run_yads); do
        { tr '\0' '\n' < "/proc/$p/cmdline"; } 2>/dev/null | grep -qx -- "$1" && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}
count_plugs() { DISPLAY="$display" xwininfo -root -tree 2>/dev/null | grep '"YAD"' | grep -c -E ' [6-9][0-9]{2}x' || true; }

# What the rebuild left behind when it did not happen: the yads of the run, the rebuild mark and what the two programs printed.
redraw_diag() {
    local p
    start_diag redraw "$runner" "$TMP/redraw.err" "$state"
    printf 'DIAG redraw: old notebook %s, new notebook %s, %s embedded tabs, %s yads\n' "${old_nb:-none}" "${new_nb:-none}" "$plugs" "${after:-?}" >&2
    for p in $(run_yads); do printf 'DIAG yad %s: %s\n' "$p" "$(tr '\0' ' ' < "/proc/$p/cmdline" | cut -c1-110)" >&2; done
    ls "$state" 2>/dev/null | sed 's/^/DIAG state: /' >&2 || true
    head -c 600 "$TMP/apply.out" 2>/dev/null | sed 's/^/DIAG apply.out: /' >&2 || true
}

redraw_check() {
    local home="$TMP/home-redraw" state="$TMP/state-redraw" runner old_nb new_nb themes key before after plugs=0 left colours
    seed_themes "$home"
    mkdir -p "$TMP/incoming/Redraw-Imported/gtk-3.0" "$TMP/dialogs"
    : > "$TMP/incoming/Redraw-Imported/gtk-3.0/gtk.css"
    # The confirmation dialog waits for a click; a stand-in records it so the import can finish by itself.
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${CM_TEST_DIALOG_LOG:?}"' 'exit 0' > "$TMP/dialogs/yad"
    chmod 755 "$TMP/dialogs/yad"
    : > "$TMP/dialogs.log"
    DISPLAY="$display" env LC_ALL=C.UTF-8 PATH="$TMP/bin:$PATH" HOME="$home" CM_HOME="$state" CM_LANG_OVERRIDE=en \
        XDG_CURRENT_DESKTOP=X-Cinnamon CM_TEST_CALLS_LOG="$TMP/calls-redraw.log" \
        timeout --kill-after=3 60 bash "$SCRIPT" gui >"$TMP/redraw.out" 2>"$TMP/redraw.err" &
    runner=$!
    for _ in $(seq 1 60); do
        plugs="$(count_plugs)"
        [ "$plugs" -ge 7 ] && break
        sleep 0.5
    done
    [ "$plugs" -ge 7 ] || { redraw_diag; kill "$runner" 2>/dev/null || true; fail "redraw: only $plugs of 7 tabs were drawn"; }
    sleep 1
    old_nb="$(yad_with_arg --notebook)" || { redraw_diag; kill "$runner" 2>/dev/null || true; fail 'redraw: the notebook yad was not found'; }
    themes="$(yad_with_arg --tabnum=1)" || { redraw_diag; kill "$runner" 2>/dev/null || true; fail 'redraw: the Themes tab yad was not found'; }
    before="$(run_yads | wc -l)"
    [ "$before" -eq 8 ] || { redraw_diag; kill "$runner" 2>/dev/null || true; fail "redraw: expected 8 yad processes (notebook and 7 tabs), found $before"; }
    key="$(tr '\0' '\n' < "/proc/$themes/environ" | sed -n 's/^CM_TAB_KEY=//p')"
    [[ "$key" =~ ^[0-9]+$ ]] && tr '\0' '\n' < "/proc/$old_nb/cmdline" | grep -qxF -- "--key=$key" \
        || { kill "$runner" 2>/dev/null || true; fail "redraw: the Themes yad does not carry the notebook's key (got '$key')"; }
    ! tr '\0' '\n' < "/proc/$themes/cmdline" | grep -qE '^Redraw-Imported' \
        || { kill "$runner" 2>/dev/null || true; fail 'redraw: control failed, the theme was listed before the import'; }

    # What a button does: the same program, with the environment its yad gave it.
    CM_TEST_DIALOG_LOG="$TMP/dialogs.log" DISPLAY="$display" PATH="$TMP/dialogs:$TMP/bin:$PATH" HOME="$home" CM_HOME="$state" \
        CM_LANG_OVERRIDE=en CM_TAB_KEY="$key" \
        bash "$SCRIPT" __apply themes_import "" "$TMP/incoming/Redraw-Imported" >"$TMP/apply.out" 2>&1 \
        || { kill "$runner" 2>/dev/null || true; fail "redraw: the import failed: $(head -2 "$TMP/apply.out" | tr '\n' ' ')"; }
    new_nb=""
    for _ in $(seq 1 60); do
        new_nb="$(yad_with_arg --notebook || true)"
        plugs="$(count_plugs)"; after="$(run_yads | wc -l)"
        [ -n "$new_nb" ] && [ "$new_nb" != "$old_nb" ] && [ "$plugs" -ge 7 ] && [ "$after" -eq 8 ] && break
        sleep 0.5
    done
    [ -n "$new_nb" ] && [ "$new_nb" != "$old_nb" ] \
        || { redraw_diag; kill "$runner" 2>/dev/null || true; fail "redraw: importing a theme left the same notebook (pid $old_nb)"; }
    ! kill -0 "$old_nb" 2>/dev/null || { kill "$runner" 2>/dev/null || true; fail "redraw: the old notebook (pid $old_nb) is still alive"; }
    [ "$plugs" -eq 7 ] || { kill "$runner" 2>/dev/null || true; fail "redraw: $plugs embedded tabs after the import, expected 7"; }
    [ "$after" -eq 8 ] || { kill "$runner" 2>/dev/null || true; fail "redraw: $after yad processes after the import, expected 8"; }
    themes="$(yad_with_arg --tabnum=1)" || { kill "$runner" 2>/dev/null || true; fail 'redraw: no Themes tab after the import'; }
    tr '\0' '\n' < "/proc/$themes/cmdline" | grep -qE '^Redraw-Imported(!|$)' \
        || { kill "$runner" 2>/dev/null || true; fail 'redraw: the rebuilt Themes form does not list the imported theme first'; }
    [ ! -e "$state/window-redraw.$key" ] || { kill "$runner" 2>/dev/null || true; fail 'redraw: the rebuild mark was not consumed'; }
    sleep 1
    DISPLAY="$display" "${SHOT[@]}" -window root "$shots/gui-1366x768-redraw.png"
    colours="$("$IM_BIN" "$shots/gui-1366x768-redraw.png" -format '%k' info:)"
    kill "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
    ipcrm -M "$key" 2>/dev/null || true
    [ "$colours" -ge 200 ] || fail "redraw: the window looks blank after the import ($colours colours)"
    left=1
    for _ in $(seq 1 20); do left="$(run_yads | wc -l)"; [ "$left" -eq 0 ] && break; sleep 0.25; done
    [ "$left" -eq 0 ] || { run_yads | proc_diag redraw; fail "redraw: $left yad processes outlive the window"; }
    [ "$(grep -c -- '--info' "$TMP/dialogs.log")" -eq 1 ] && ! grep -q -- '--error' "$TMP/dialogs.log" \
        || fail "redraw: the import must end in one confirmation and no error: $(tr '\n' ' ' < "$TMP/dialogs.log" | cut -c1-200)"
    ! grep -q -E 'CRITICAL|Unable to parse|cannot open display|Invalid byte sequence|from markup' "$TMP/redraw.err" \
        || fail "redraw: yad reported errors: $(grep -m2 -E 'CRITICAL|Unable to parse|from markup' "$TMP/redraw.err" | tr '\n' ' ')"
    printf 'INFO: redraw: notebook %s -> %s, %s yad processes before and after, %s tabs embedded, %s colours, 0 left on exit\n' \
        "$old_nb" "$new_nb" "$after" "$plugs" "$colours"
}
redraw_check
pass 'importing a theme rebuilds the real window: a new notebook, the seven tabs embedded again with the theme first, and nothing left behind'

# --- "Import theme" with nothing chosen: what the real button delivers -----------------------------------------------
# Both selectors of the Themes tab start on "(None)" (the folder one on a placeholder path), and yad leaves an empty value out of a
# button's command line, so the import may get the placeholder as either value. test_color_mint.sh feeds the import every shape
# yad can deliver; this presses the real button of the real window and reads which dialog it raised. A stand-in `yad` first on
# the PATH records --error/--info/--warning and starts the real one for the rest (the window itself). The tab is scrolled with
# the pointer over the label column: over a drop-down the wheel changes the selection instead.
import_check() {
    local home="$TMP/home-import" state="$TMP/state-import" bin="$TMP/import-bin" runner gui_pid plugs=0 y hit=0 shots_file colours
    seed_themes "$home"
    mkdir -p "$state" "$bin"
    printf '%s\n' '#!/usr/bin/env bash' \
        'for a in "$@"; do case "$a" in --error|--info|--warning) printf "%s\n" "$*" >> "${CM_TEST_DIALOG_LOG:?}"; exit 0 ;; esac; done' \
        "exec $(printf '%q' "$(command -v yad)") \"\$@\"" > "$bin/yad"
    chmod 755 "$bin/yad"
    : > "$TMP/import-dialogs.log"
    DISPLAY="$display" env LC_ALL=C.UTF-8 PATH="$bin:$TMP/bin:$PATH" HOME="$home" CM_HOME="$state" CM_LANG_OVERRIDE=en \
        XDG_CURRENT_DESKTOP=X-Cinnamon CM_TEST_CALLS_LOG="$TMP/calls-import.log" CM_TEST_DIALOG_LOG="$TMP/import-dialogs.log" \
        timeout --kill-after=3 60 bash "$SCRIPT" gui >"$TMP/import.out" 2>"$TMP/import.err" &
    runner=$!
    for _ in $(seq 1 60); do
        plugs="$(count_plugs)"
        [ "$plugs" -ge 7 ] && break
        sleep 0.5
    done
    if [ "$plugs" -lt 7 ]; then
        start_diag import "$runner" "$TMP/import.err" "$state"
        kill "$runner" 2>/dev/null || true
        fail "import: only $plugs of 7 tabs were drawn"
    fi
    gui_pid="$(pgrep -P "$runner" | head -n1 || true)"
    sleep 1
    DISPLAY="$display" xdotool mousemove 100 330 2>/dev/null || true
    for _ in $(seq 1 25); do DISPLAY="$display" xdotool click 5 2>/dev/null || true; sleep 0.05; done
    sleep 0.7
    shots_file="$shots/gui-1366x768-import.png"
    DISPLAY="$display" "${SHOT[@]}" -window root "$shots_file"
    colours="$("$IM_BIN" "$shots_file" -format '%k' info:)"
    # The button is the last control: from the bottom edge of the viewport upward, the first click that lands on a control is its own.
    for y in $(seq 600 -4 568); do
        DISPLAY="$display" xdotool mousemove 480 "$y" click 1 2>/dev/null || true
        for _ in 1 2 3 4; do
            [ -s "$TMP/import-dialogs.log" ] && { hit=1; break; }
            sleep 0.25
        done
        [ "$hit" = 1 ] && break
        DISPLAY="$display" xdotool key Escape 2>/dev/null || true
    done
    if [ "$hit" != 1 ]; then
        start_diag import "$runner" "$TMP/import.err" "$state"
        kill "$runner" 2>/dev/null || true
        fail 'import: pressing Import theme raised no dialog'
    fi
    sleep 0.5
    kill "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
    [ -z "$gui_pid" ] || ipcrm -M "$gui_pid" 2>/dev/null || true
    reap_state "$state"
    [ "$colours" -ge 200 ] || fail "import: the screenshot looks blank ($colours colours)"
    # The failure dialog is tested first: after the exact-text check below it could never be reached, because that dialog is never
    # the exact text, so every import that ran would be reported as a wrong or repeated dialog.
    ! grep -qF 'could not be imported' "$TMP/import-dialogs.log" \
        || fail "import: with nothing chosen the button raised the import-failure dialog: $(tr '\n' ' ' < "$TMP/import-dialogs.log" | cut -c1-200)"
    [ "$(wc -l < "$TMP/import-dialogs.log")" -eq 1 ] \
        && grep -qF -- '--error --text=Choose a theme file or an already extracted folder to import.' "$TMP/import-dialogs.log" \
        || fail "import: with nothing chosen the button must ask for a file or a folder, once: $(tr '\n' ' ' < "$TMP/import-dialogs.log" | cut -c1-200)"
    [ "$(ls -A "$home/.themes" | tr '\n' ' ')" = 'Render-Cinnamon Render-GTK ' ] && ! grep -qs '^LAST_IMPORTED_THEME=' "$state/state.conf" \
        || fail 'import: pressing Import theme with nothing chosen changed the themes'
    ! grep -q -E 'CRITICAL|Unable to parse|cannot open display|Invalid byte sequence|from markup' "$TMP/import.err" \
        || fail "import: yad reported errors: $(grep -m2 -E 'CRITICAL|Unable to parse|from markup' "$TMP/import.err" | tr '\n' ' ')"
    printf 'INFO: import: Import theme pressed at y=%s with both selectors empty raised the "choose a file or a folder" dialog, %s colours, nothing imported\n' "$y" "$colours"
}
import_check
pass 'the real Import theme button, pressed with both selectors on "(None)", asks for a file or a folder and does not try to import the placeholder'

# --- "Get more themes": its form, its wait window and its notice, drawn by the real yad -------------------------------
# The button's own mode (__apply themes_more) runs on the virtual screen with a curl that waits a few seconds and then
# serves a theme or answers 404; the keys come from xdotool (there is no window manager, so the pointer decides who gets
# them). What test_catalog.sh cannot see: the form and the wait window are centred and inside 1366x768, the wait window
# is open while curl runs and gone when it ends, a failed download is titled "⚠ Color Mint" (it once said "with
# warnings"), every window is painted, the exit status is the button's and nothing is left behind.
more_bin="$TMP/more-bin"
more_runner=""
mkdir -p "$more_bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$more_bin/apt-get"      # with apt-get the form lists theme packs, whatever the machine is
cat > "$more_bin/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CM_RENDER_MARK:?}.calls"
: > "$CM_RENDER_MARK.started"
out=""
while [ "$#" -gt 0 ]; do case "$1" in --output) out="$2"; shift ;; --) break ;; esac; shift; done
sleep "${CM_RENDER_CURL_DELAY:-4}"
: > "$CM_RENDER_MARK.finished"
case "${CM_RENDER_CURL_MODE:-ok}" in
    ok) cp -- "${CM_RENDER_ZIP:?}" "$out" ;;
    *)  echo 'curl: (22) The requested URL returned error: 404' >&2; exit 22 ;;
esac
FAKE
chmod 755 "$more_bin/apt-get" "$more_bin/curl"
python3 - "$TMP/more-good.zip" <<'PY' || fail 'could not build the theme archive for the Get more themes check'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], 'w') as archive:
    for name, data in (('Render-Spice/', b''), ('Render-Spice/cinnamon/', b''), ('Render-Spice/cinnamon/cinnamon.css', b'css'),
                       ('Render-Spice/metadata.json', b'{}')):
        info = zipfile.ZipInfo(name, date_time=(2026, 10, 27, 12, 0, 0))
        info.create_system = 3
        is_dir = name.endswith('/')
        info.external_attr = ((0o40755 if is_dir else 0o100644) << 16) | (0x10 if is_dir else 0)
        archive.writestr(info, b'' if is_dir else data)
PY

more_fail() { [ -z "$more_runner" ] || kill "$more_runner" 2>/dev/null || true; fail "$1"; }
# top_line <title regex> <min width> <max width>: the xwininfo line of the first top-level window (a child of the root)
# with that title and a width in that range; the range tells the wait window (380) from the notice (420).
top_line() {
    local l g
    DISPLAY="$display" xwininfo -root -tree 2>/dev/null | grep -E "^     0x[0-9a-f]+ \"$1\":" | while IFS= read -r l; do
        g="$(printf '%s' "$l" | grep -o -E '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -n1)"
        if [ "${g%%x*}" -ge "$2" ] && [ "${g%%x*}" -le "$3" ]; then printf '%s\n' "$l"; break; fi
    done || true
}
# wait_top <title regex> <min width> <max width> <tries>: poll every half second until that window is on the screen.
wait_top() {
    local n line
    for n in $(seq 1 "$4"); do
        line="$(top_line "$1" "$2" "$3")"
        if [ -n "$line" ]; then printf '%s' "$line"; return 0; fi
        sleep 0.5
    done
    return 1
}
# window_box <xwininfo line>: "width height x y".
window_box() { IFS='x+' read -r w h x y <<< "$(printf '%s' "$1" | grep -o -E '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -n1)"; }
# painted <label> <window line>: take a picture of that window; it must not be blank. Echoes the colour count.
painted() {
    local file="$shots/gui-1366x768-$1.png" id n
    read -r id _ <<< "$2"
    DISPLAY="$display" "${SHOT[@]}" -window "$id" "$file" 2>/dev/null || more_fail "$1: could not take a picture of the window"
    n="$("$IM_BIN" "$file" -format '%k' info:)"
    [ "$n" -ge 50 ] || more_fail "$1: the window looks blank ($n colours)"
    printf '%s' "$n"
}
# centred <label> <width> <height> <x> <y>: --center on a 1366x768 screen, 20 px of slack.
centred() {
    local dx=$(($4 - (1366 - $2) / 2)) dy=$(($5 - (768 - $3) / 2))
    [ "${dx#-}" -le 20 ] && [ "${dy#-}" -le 20 ] || more_fail "$1: ${2}x$3 at +$4+$5 is not centred on 1366x768"
}

# more_check <case> <curl mode> <name typed> <curl delay> <title of the notice> <exit status expected>
more_check() {
    local label="$1" mode="$2" name="$3" delay="$4" notice_title="$5" want_rc="$6"
    local home="$TMP/home-$label" state="$TMP/state-$label" mark="$TMP/mark-$label" line id n left rc=0
    local w h x y fw fh wx ww wh nw nh c_form c_wait c_note
    mkdir -p "$home" "$state"
    DISPLAY="$display" env LC_ALL=C.UTF-8 PATH="$more_bin:$TMP/bin:$PATH" HOME="$home" CM_HOME="$state" CM_LANG_OVERRIDE=en \
        XDG_CURRENT_DESKTOP=X-Cinnamon CM_APPLY_DETACHED=1 CM_TEST_CALLS_LOG="$TMP/calls-$label.log" CM_RENDER_MARK="$mark" \
        CM_RENDER_CURL_MODE="$mode" CM_RENDER_ZIP="$TMP/more-good.zip" CM_RENDER_CURL_DELAY="$delay" \
        timeout --kill-after=3 60 bash "$SCRIPT" __apply themes_more >"$TMP/$label.out" 2>"$TMP/$label.err" &
    more_runner=$!

    # 1. The form: drawn, centred, inside the screen.
    line="$(wait_top 'Get more themes' 1 2000 60)" || { start_diag "$label" "$more_runner" "$TMP/$label.err" "$state"; more_fail "$label: the form never appeared"; }
    window_box "$line"; fw="$w"; fh="$h"
    [ "$fw" -le 1366 ] && [ $((fh + 36 + 40)) -le 768 ] || more_fail "$label: the form is ${fw}x$fh and is cut on 1366x768"
    centred "$label form" "$fw" "$fh" "$x" "$y"
    c_form="$(painted "$label-form" "$line")"
    read -r id _ <<< "$line"

    # 2. Typing the name and pressing Enter: the pack list has the focus first, so Tab goes to the name.
    sleep 0.8
    DISPLAY="$display" xdotool mousemove "$((x + fw / 2))" "$((y + fh / 2))" 2>/dev/null || true
    DISPLAY="$display" xdotool windowfocus "$id" 2>/dev/null || true
    sleep 0.3
    DISPLAY="$display" xdotool key Tab 2>/dev/null || true
    sleep 0.2
    DISPLAY="$display" xdotool type --delay 30 "$name" 2>/dev/null || true
    sleep 0.3
    DISPLAY="$display" xdotool key Return 2>/dev/null || true

    # 3. The wait window: open while curl runs, centred, painted.
    line="$(wait_top 'Color Mint' 300 400 40)" || more_fail "$label: the wait window never appeared after the form was answered"
    window_box "$line"; ww="$w"; wh="$h"; wx="$x"
    [ "$ww" -ge 360 ] && [ "$wh" -ge 80 ] && [ $((wh + 36 + 40)) -le 768 ] || more_fail "$label: the wait window is ${ww}x$wh"
    centred "$label wait window" "$ww" "$wh" "$wx" "$y"
    c_wait="$(painted "$label-wait" "$line")"
    sleep 0.3
    [ -e "$mark.started" ] && [ ! -e "$mark.finished" ] || more_fail "$label: the wait window must be open while curl runs"
    [ -z "$(top_line 'Get more themes' 1 2000)" ] || more_fail "$label: the form is still open behind the wait window"
    n=0
    for _ in $(seq 1 60); do
        [ -z "$(top_line 'Color Mint' 300 400)" ] && { n=1; break; }
        sleep 0.5
    done
    [ "$n" = 1 ] || more_fail "$label: the wait window is still open after curl returned"
    [ -e "$mark.finished" ] || more_fail "$label: the wait window closed before the download ended"

    # 4. The notice: the right title, inside the screen, painted; closing it ends the button with its status.
    line="$(wait_top "$notice_title" 410 460 40)" \
        || more_fail "$label: no notice titled '${notice_title//\\/}' appeared; the windows are: $(DISPLAY="$display" xwininfo -root -tree 2>/dev/null | grep -E '^     0x[0-9a-f]+ "' | head -n3 | tr -s ' ' | tr '\n' ';')"
    ! DISPLAY="$display" xwininfo -root -tree 2>/dev/null | grep -q 'with warnings' || more_fail "$label: a window titled \"... with warnings\" is still on the screen"
    window_box "$line"; nw="$w"; nh="$h"
    [ $((nh + 36 + 40)) -le 768 ] || more_fail "$label: the notice is ${nw}x$nh and is cut on 1366x768"
    c_note="$(painted "$label-notice" "$line")"
    read -r id _ <<< "$line"
    sleep 0.5
    DISPLAY="$display" xdotool mousemove 200 100 2>/dev/null || true
    DISPLAY="$display" xdotool windowfocus "$id" 2>/dev/null || true
    sleep 0.2
    DISPLAY="$display" xdotool key Return 2>/dev/null || true
    for _ in $(seq 1 40); do kill -0 "$more_runner" 2>/dev/null || break; sleep 0.25; done
    ! kill -0 "$more_runner" 2>/dev/null || more_fail "$label: the button did not end after its notice was closed"
    wait "$more_runner" || rc=$?
    more_runner=""
    [ "$rc" -eq "$want_rc" ] || fail "$label: the button ended with status $rc, expected $want_rc"

    # 5. What is left, and what was done.
    left=1
    for _ in $(seq 1 20); do left="$(case_yads "$state" | wc -l)"; [ "$left" -eq 0 ] && break; sleep 0.25; done
    [ "$left" -eq 0 ] || { case_yads "$state" | proc_diag "$label"; fail "$label: $left yad processes outlive the button"; }
    [ -z "$(top_line 'Color Mint' 1 2000)" ] && [ -z "$(top_line 'Get more themes' 1 2000)" ] || fail "$label: a window of the button is still on the screen"
    [ -z "$(find "$state" -name '.more-err.*' 2>/dev/null | head -n 1)" ] || fail "$label: the error file of the download was left behind"
    [ "$(wc -l < "$mark.calls")" -eq 1 ] && grep -qF -- "$name" "$mark.calls" || fail "$label: expected one download of '$name': $(cut -c1-120 "$mark.calls")"
    ! grep -q -E 'CRITICAL|Unable to parse|cannot open display|Invalid byte sequence|from markup' "$TMP/$label.err" \
        || fail "$label: yad reported errors: $(grep -m2 -E 'CRITICAL|Unable to parse|from markup' "$TMP/$label.err" | tr '\n' ' ')"
    if [ "$want_rc" -eq 0 ]; then
        [ -f "$home/.themes/Render-Spice/cinnamon/cinnamon.css" ] || fail "$label: the downloaded theme was not installed"
    else
        [ -z "$(find "$home/.themes" -mindepth 1 2>/dev/null | head -n 1)" ] || fail "$label: a failed download installed something"
    fi
    printf 'INFO: %s: form %sx%s (%s colours), wait window %sx%s (%s), notice %sx%s (%s), status %s, nothing left\n' \
        "$label" "$fw" "$fh" "$c_form" "$ww" "$wh" "$c_wait" "$nw" "$nh" "$c_note" "$rc"
}

more_check more-ok ok Render-Spice 4 'Color Mint' 0
pass 'Get more themes draws its form, a wait window that is open while curl runs and its confirmation, centred and inside 1366x768, and leaves nothing behind'
more_check more-bad http404 Render-Missing 3 '⚠ Color Mint' 1
pass 'a failed download ends in a warning titled "⚠ Color Mint" (no "with warnings" tail), installs nothing and ends the button with status 1'

# --- GTK 4 and libadwaita: what is painted from the CSS Color Mint writes -------------------------------------------
# libadwaita ignores the GTK theme: a theme's gtk-4.0 style and the accent reach its apps only through the user's
# ~/.config/gtk-4.0/gtk.css, which the real program writes here, on a throwaway home with gsettings as a double.
# GTK reads that file once per process, so each case is a new process. The theme's two stylesheets differ in the
# accent and in window_bg_color, so the pixel and the named colours say which sheet was imported and who won.
# shellcheck source=lib/doubles.sh
. "$ROOT/tests/lib/doubles.sh"
G4_PINK='#e91e63' G4_GREEN='#26a269' G4_BLUE='#1a5fb4' G4_LIGHT_BG='#ffeedd' G4_DARK_BG='#112233'
G4_ORANGE='#e66100' G4_ORANGE_DARK='#c64600' G4_ORANGE_BG='#ddeeff' G4_ORANGE_DARK_BG='#332211'
G4_BLACK='#000000' G4_THEME_FG='#102030'       # black is the text the program puts on pink; the theme's own text is neither black nor white
G4_NAMES=(accent_bg_color accent_color theme_selected_bg_color)      # the colours of the accent that the program defines
G4_FG_NAMES=(accent_fg_color theme_selected_fg_color)                # and the two of the text on it

# g4_sheet <file> <accent> <window background>: a gtk-4.0 stylesheet that sets every colour above, the text included.
g4_sheet() {
    printf '@define-color accent_bg_color %s;\n@define-color accent_color %s;\n@define-color theme_selected_bg_color %s;\n@define-color accent_fg_color %s;\n@define-color theme_selected_fg_color %s;\n@define-color window_bg_color %s;\n' \
        "$2" "$2" "$2" "$G4_THEME_FG" "$G4_THEME_FG" "$3" > "$1"
}

# g4_home <case>: a home whose active GTK theme is Probe-Green: gtk-4.0/gtk.css green on light, gtk-dark.css blue on dark.
# It also has Probe-Orange (the same two sheets in other colours) and Probe-Plain (no gtk-4.0 style) to change to.
g4_home() {
    local themes="$TMP/g4/$1/.themes"
    mkdir -p "$themes/Probe-Green/gtk-3.0" "$themes/Probe-Green/gtk-4.0" "$themes/Probe-Orange/gtk-3.0" \
        "$themes/Probe-Orange/gtk-4.0" "$themes/Probe-Plain/gtk-3.0" "$TMP/g4/no-data"
    : > "$themes/Probe-Green/gtk-3.0/gtk.css"; : > "$themes/Probe-Orange/gtk-3.0/gtk.css"; : > "$themes/Probe-Plain/gtk-3.0/gtk.css"
    g4_sheet "$themes/Probe-Green/gtk-4.0/gtk.css" "$G4_GREEN" "$G4_LIGHT_BG"
    g4_sheet "$themes/Probe-Green/gtk-4.0/gtk-dark.css" "$G4_BLUE" "$G4_DARK_BG"
    g4_sheet "$themes/Probe-Orange/gtk-4.0/gtk.css" "$G4_ORANGE" "$G4_ORANGE_BG"
    g4_sheet "$themes/Probe-Orange/gtk-4.0/gtk-dark.css" "$G4_ORANGE_DARK" "$G4_ORANGE_DARK_BG"
    cm_double_db_set "$TMP/g4/$1/dconf.db" /org/cinnamon/desktop/interface/gtk-theme "'Probe-Green'"
}

# g4_scheme <case> <prefer-dark|prefer-light>: the colour scheme the portal holds on that home.
g4_scheme() { cm_double_db_set "$TMP/g4/$1/dconf.db" /org/x/apps/portal/color-scheme "'$2'"; }

# g4_cm <case> <arguments>: the program as a user runs it, on that home.
g4_cm() {
    local home="$TMP/g4/$1"; shift
    env HOME="$home" CM_HOME="$home/state" CM_LANG_OVERRIDE=en XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
        XDG_DATA_DIRS="$TMP/g4/no-data" PATH="$TMP/g4/bin:$PATH" DCONF_DB="$home/dconf.db" bash "$SCRIPT" "$@" >"$home.out" 2>&1 \
        || fail "GTK 4 render: color-mint.sh $* failed: $(tr '\n' ' ' < "$home.out" | cut -c1-200)"
}

# g4_paint <case> [--dark]: a new GTK 4 process on that home; its answer is kept in $TMP/g4/<case>.txt.
g4_paint() {
    local home="$TMP/g4/$1"; shift
    env -i PATH="$PATH" HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" XDG_CACHE_HOME="$home/.cache" \
        DISPLAY="$display" GDK_BACKEND=x11 GSK_RENDERER=cairo GTK_A11Y=none NO_AT_BRIDGE=1 GSETTINGS_BACKEND=memory \
        LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 PYTHONWARNINGS=ignore \
        timeout --kill-after=3 30 python3 "$ROOT/tests/lib/gtk4_probe.py" "$@" "${G4_NAMES[@]}" "${G4_FG_NAMES[@]}" window_bg_color >"$home.txt" 2>"$home.err" \
        || fail "GTK 4 render, ${home##*/}: the probe failed: $(grep -v libEGL "$home.err" | head -n2 | tr '\n' ' ')"
}

# g4_get <case> <item>: what the probe printed for pixel or a named colour.
g4_get() { sed -n "s/^$2=//p" "$TMP/g4/$1.txt"; }

# g4_is <case> <item> <expected> <why>
g4_is() {
    local got
    got="$(g4_get "$1" "$2")"
    [ "$got" = "$3" ] || fail "GTK 4 render, $1: $2 is '${got:-nothing}' and should be $3: $4"
}

# g4_accent_is <case> <colour> <why>: the button and every colour of the accent show that colour.
g4_accent_is() {
    local name
    g4_is "$1" pixel "$2" "$3"
    for name in "${G4_NAMES[@]}"; do g4_is "$1" "$name" "$2" "$3"; done
}

# g4_fg_is <case> <colour> <why>: the text on the accent is that colour under both of its names.
g4_fg_is() {
    local name
    for name in "${G4_FG_NAMES[@]}"; do g4_is "$1" "$name" "$2" "$3"; done
}

gtk4_render_audit() {
    local probe="$ROOT/tests/lib/gtk4_probe.py" reason="python3 is missing" code=2 base_pixel base_win base_fg
    # Only the probe's own "GTK 4 is not available" (exit 2) is a skip. A probe that is not there, or that crashes,
    # must fail on every machine: reading it as "not available" would hide the whole audit behind a SKIP.
    [ -f "$probe" ] || fail "GTK 4 render audit: $probe is missing"
    if command -v python3 >/dev/null 2>&1; then
        code=0
        PYTHONDONTWRITEBYTECODE=1 python3 "$probe" --check 2>"$TMP/g4-check.err" || code=$?
        reason="$(grep -v '^$' "$TMP/g4-check.err" | tail -n1 || true)"
    fi
    case "$code" in
        0) ;;
        2)
            [ -z "${CM_REQUIRE_GUI_RENDER:-}" ] || fail "GTK 4 render audit needs python3-gi, gir1.2-gtk-4.0 and gir1.2-adw-1 (${reason:-no reason given})"
            printf 'SKIP: GTK 4 render audit needs python3-gi, gir1.2-gtk-4.0 and gir1.2-adw-1 (%s; set CM_REQUIRE_GUI_RENDER=1 to make this a failure)\n' \
                "${reason:-no reason given}"
            return 0
            ;;
        *) fail "GTK 4 render audit: the probe crashed (exit $code): ${reason:-no output}" ;;
    esac
    cm_double_install "$TMP/g4/bin"

    # Control: with no user stylesheet libadwaita paints its own colours, which none of the cases below may match.
    g4_home control; g4_paint control
    base_pixel="$(g4_get control pixel)"; base_win="$(g4_get control window_bg_color)"; base_fg="$(g4_get control accent_fg_color)"
    case "$base_pixel" in "$G4_PINK"|"$G4_GREEN"|"$G4_BLUE"|"$G4_ORANGE"|"$G4_ORANGE_DARK") fail "GTK 4 render: the control button is already $base_pixel" ;; esac
    case "$base_win" in "$G4_LIGHT_BG"|"$G4_DARK_BG"|"$G4_ORANGE_BG"|"$G4_ORANGE_DARK_BG") fail "GTK 4 render: the control window is already $base_win" ;; esac
    case "$base_fg" in "$G4_BLACK"|"$G4_THEME_FG") fail "GTK 4 render: the control text colour is already $base_fg" ;; esac

    g4_home accent; g4_cm accent panel gtk-accent "$G4_PINK"; g4_paint accent
    g4_accent_is accent "$G4_PINK" 'the accent alone must colour the button and define its colours'
    g4_fg_is accent "$G4_BLACK" 'the text on a pink accent must be black, the colour with more contrast than white'
    g4_is accent window_bg_color "$base_win" 'the accent alone must change nothing else'
    pass 'libadwaita paints the global accent Color Mint writes, with the text colour that reads on it'

    # The accent goes in first and the import after it: the block must still put the import above the accent lines.
    g4_home import; g4_cm import theme libadwaita on; g4_paint import
    g4_accent_is import "$G4_GREEN" 'the imported light style alone must colour the button'
    g4_fg_is import "$G4_THEME_FG" 'the imported style alone must set the text colour'
    g4_is import window_bg_color "$G4_LIGHT_BG" 'the imported light style must be the one in force'
    g4_home both; g4_cm both panel gtk-accent "$G4_PINK"; g4_cm both theme libadwaita on; g4_paint both
    g4_accent_is both "$G4_PINK" 'the accent must win over the imported style'
    g4_fg_is both "$G4_BLACK" 'the text colour of the accent must win over the imported style'
    g4_is both window_bg_color "$G4_LIGHT_BG" 'the rest of the imported style must still apply under the accent'
    # The order a user follows: the box first, an accent later. Each writer must keep what the other one wrote.
    g4_home late; g4_cm late theme libadwaita on; g4_cm late panel gtk-accent "$G4_PINK"; g4_paint late
    g4_accent_is late "$G4_PINK" 'an accent set after the import must still win over the imported style'
    g4_is late window_bg_color "$G4_LIGHT_BG" 'an accent set after the import must keep the import'
    pass "libadwaita paints the theme's gtk-4.0 style, and the global accent wins over it whichever of the two was set first"

    # prefer-dark makes the program import gtk-dark.css; the probe forces libadwaita's dark scheme, as the portal does.
    g4_home dark; g4_scheme dark prefer-dark
    g4_cm dark theme libadwaita on; g4_paint dark --dark
    g4_accent_is dark "$G4_BLUE" 'on the dark scheme the dark style must be the one imported'
    g4_is dark window_bg_color "$G4_DARK_BG" 'on the dark scheme the light style must not be imported'
    # The light scheme and the default one take gtk.css even when the theme has a dark sheet too.
    g4_home light; g4_scheme light prefer-light; g4_cm light theme libadwaita on; g4_paint light
    g4_accent_is light "$G4_GREEN" 'on the light scheme the light style must be the one imported'
    g4_is light window_bg_color "$G4_LIGHT_BG" 'on the light scheme the dark style must not be imported'
    # A theme with no gtk-dark.css has its gtk.css imported on the dark scheme (with a warning), not nothing and not a missing file.
    g4_home nodark; rm "$TMP/g4/nodark/.themes/Probe-Green/gtk-4.0/gtk-dark.css"; g4_scheme nodark prefer-dark
    g4_cm nodark theme libadwaita on; g4_paint nodark --dark
    g4_accent_is nodark "$G4_GREEN" 'with no gtk-dark.css the dark scheme must import gtk.css'
    g4_is nodark window_bg_color "$G4_LIGHT_BG" 'with no gtk-dark.css the dark scheme must import gtk.css'
    pass 'the import takes the dark sheet on the dark scheme, the light one otherwise and gtk.css when a dark theme has no dark sheet'

    # A theme deleted after `theme libadwaita on`: GTK reports the missing file and goes on with what follows it.
    g4_home stale; g4_cm stale panel gtk-accent "$G4_PINK"; g4_cm stale theme libadwaita on
    rm -rf "$TMP/g4/stale/.themes/Probe-Green"; g4_paint stale
    g4_accent_is stale "$G4_PINK" 'an import of a deleted theme must not take the accent with it'
    g4_fg_is stale "$G4_BLACK" 'an import of a deleted theme must not take the text colour with it'
    g4_is stale window_bg_color "$base_win" 'a deleted theme must style nothing'
    pass 'an import of a deleted theme leaves the accent working and libadwaita unstyled'

    # The import follows the GTK theme and the scheme that Color Mint changes afterwards, and only when there is one.
    g4_home follow; g4_cm follow theme libadwaita on; g4_cm follow theme gtk Probe-Orange; g4_paint follow
    g4_accent_is follow "$G4_ORANGE" 'a new GTK theme must move the import to its own style'
    g4_is follow window_bg_color "$G4_ORANGE_BG" 'a new GTK theme must move the import to its own style'
    g4_home followdark; g4_scheme followdark prefer-dark; g4_cm followdark theme libadwaita on; g4_cm followdark theme gtk Probe-Orange
    g4_paint followdark --dark
    g4_accent_is followdark "$G4_ORANGE_DARK" 'on the dark scheme a new GTK theme must bring its dark sheet'
    g4_is followdark window_bg_color "$G4_ORANGE_DARK_BG" 'on the dark scheme a new GTK theme must bring its dark sheet'
    g4_home plain; g4_cm plain theme libadwaita on; g4_cm plain theme gtk Probe-Plain; g4_paint plain
    g4_is plain pixel "$base_pixel" 'a theme with no gtk-4.0 style must take the old import away'
    g4_is plain window_bg_color "$base_win" 'a theme with no gtk-4.0 style must take the old import away'
    g4_home unasked; g4_cm unasked panel gtk-accent "$G4_PINK"; g4_cm unasked theme gtk Probe-Orange; g4_paint unasked
    g4_accent_is unasked "$G4_PINK" 'changing the theme must not touch the accent'
    g4_is unasked window_bg_color "$base_win" 'changing the theme must not import a style nobody asked for'
    # A preset sets the theme and the scheme together: the import must end up on the pair, once the whole preset is in.
    g4_home pair; g4_scheme pair prefer-light; mkdir -p "$TMP/g4/pair/state/presets"
    printf '%s\n' 'GTK_THEME="Probe-Orange"' 'COLOR_SCHEME="prefer-dark"' > "$TMP/g4/pair/state/presets/pair.conf"
    g4_cm pair theme libadwaita on; g4_cm pair preset load pair; g4_paint pair --dark
    g4_accent_is pair "$G4_ORANGE_DARK" 'a preset must leave the import on the theme and the scheme it set'
    g4_is pair window_bg_color "$G4_ORANGE_DARK_BG" 'a preset must leave the import on the theme and the scheme it set'
    pass 'the import follows a new GTK theme and scheme (light and dark), is taken away by a theme with no gtk-4.0 style, and is never made unasked'

    # Taking one part away must leave the other.
    g4_home off; g4_cm off panel gtk-accent "$G4_PINK"; g4_cm off theme libadwaita on; g4_cm off theme libadwaita off; g4_paint off
    g4_accent_is off "$G4_PINK" '`theme libadwaita off` must keep the accent'
    g4_is off window_bg_color "$base_win" '`theme libadwaita off` must take the imported style away'
    g4_home reset; g4_cm reset panel gtk-accent "$G4_PINK"; g4_cm reset theme libadwaita on; g4_cm reset panel reset-colors; g4_paint reset
    g4_accent_is reset "$G4_GREEN" 'resetting the colours must take the accent away and keep the imported style'
    g4_fg_is reset "$G4_THEME_FG" 'resetting the colours must take the accent away and keep the imported style'
    g4_is reset window_bg_color "$G4_LIGHT_BG" 'resetting the colours must keep the imported style'
    pass '`theme libadwaita off` keeps the accent and resetting the accent keeps the imported style'

    # A path with a double quote and a backslash (a home folder can have them) reaches GTK as written: both are escaped.
    g4_home 'q"u\ote'; g4_cm 'q"u\ote' theme libadwaita on; g4_paint 'q"u\ote'
    g4_accent_is 'q"u\ote' "$G4_GREEN" 'a quote or a backslash in the path must not break the import'
    g4_is 'q"u\ote' window_bg_color "$G4_LIGHT_BG" 'a quote or a backslash in the path must not break the import'
    pass 'an import whose path has a double quote and a backslash still loads'
    printf 'INFO: gtk4: libadwaita own %s, accent %s, theme alone %s, theme and accent %s, dark theme %s\n' \
        "$base_pixel" "$(g4_get accent pixel)" "$(g4_get import pixel)" "$(g4_get both pixel)" "$(g4_get dark pixel)"
}
gtk4_render_audit
