#!/usr/bin/env bash
# Presets: the file is read as data (no shell), the whole preset is checked before one setting is
# applied (a missing theme or a bad value changes nothing and every problem is listed), the checks
# are the ones the setters enforce, every key reaches its setter in order, and a failure half way is
# reported by key. Gsettings, dconf and gdbus are doubles; the themes are a fake tree. The light/dark
# scheme (org.x.apps.portal) is skipped without that schema, and a failed write never undoes a colour pack.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sandbox.sh
. "$ROOT/tests/lib/sandbox.sh"
SCRIPT="$ROOT/script/color-mint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

BODY="$TMP/body.sh"
awk '/^# Command-line dispatcher/{exit} {print}' "$SCRIPT" > "$BODY"

HOME_DIR="$TMP/home"
XDG_HOME="$TMP/xdg"
SYS_DIR="$TMP/sys"
CM_STATE="$TMP/cm-home"
PRESETS="$CM_STATE/presets"
MOCK="$TMP/mockbin"
GS_STATE="$TMP/gs-state"
GS_LOG="$TMP/gs.log"
mkdir -p "$HOME_DIR" "$XDG_HOME/themes" "$XDG_HOME/icons" "$SYS_DIR" "$PRESETS" "$MOCK" "$GS_STATE"

# Themes the fixtures may name: GTK, Cinnamon, icons and a real cursor theme.
for theme in Mint-Y-Aqua Mint-Y-Dark-Aqua; do
    mkdir -p "$XDG_HOME/themes/$theme/gtk-3.0" "$XDG_HOME/themes/$theme/cinnamon"
    : > "$XDG_HOME/themes/$theme/gtk-3.0/gtk.css"
done
mkdir -p "$XDG_HOME/icons/Mint-Y-Aqua" "$XDG_HOME/icons/Bibata-Modern-Classic/cursors"
printf '[Icon Theme]\nDirectories=16x16/apps\n' > "$XDG_HOME/icons/Mint-Y-Aqua/index.theme"

# Stateful gsettings: every call is logged, "set" is remembered and "get" returns it. GS_FAIL_KEY
# makes the set of one key fail, which is how a failure half way through a preset is simulated.
# GS_NO_PORTAL=1 removes the org.x.apps.portal schema, as on a system without XApp.
cat > "$MOCK/gsettings" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GS_LOG:?}"
op="${1:-}" schema="${2:-}" key="${3:-}"
if [ "$schema" = org.x.apps.portal ] && [ -n "${GS_NO_PORTAL:-}" ]; then
    echo "No such schema 'org.x.apps.portal'" >&2
    exit 1
fi
file="${GS_STATE:?}/$schema.$key"
case "$op" in
    get) if [ -f "$file" ]; then cat "$file"; else echo "''"; fi ;;
    set)
        if [ "$key" = "${GS_FAIL_KEY:-}" ]; then echo "simulated failure" >&2; exit 1; fi
        printf '%s\n' "${4:-}" > "$file"
        ;;
esac
MOCK
for tool in dconf gdbus; do
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >> "${GS_LOG:?}"\n' "$tool" > "$MOCK/$tool"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK/sleep"
chmod 755 "$MOCK"/*
printf "'b1dcc9dd'\n" > "$GS_STATE/org.gnome.Terminal.ProfilesList.default"

# run_cm <snippet>: the script's functions, with the doubles first in PATH and no real theme anywhere.
run_cm() {
    HOME="$HOME_DIR" CM_HOME="$CM_STATE" XDG_DATA_HOME="$XDG_HOME" XDG_DATA_DIRS="$SYS_DIR" \
        CM_LANG_OVERRIDE="${CM_TEST_LANG:-en}" PATH="$MOCK:$PATH" GS_STATE="$GS_STATE" GS_LOG="$GS_LOG" \
        GS_FAIL_KEY="${GS_FAIL_KEY:-}" GS_NO_PORTAL="${GS_NO_PORTAL:-}" bash -c 'source "$1"; cm_lang_init; eval "$2"' bash "$BODY" "$1"
}

write_preset() {   # write_preset <name> <line>...
    local name="$1"; shift
    printf '%s\n' "$@" > "$PRESETS/$name.conf"
}

# A preset that sets every key, with values that are all valid against the fixtures.
FULL=(
    'GTK_THEME="Mint-Y-Aqua"' 'ICON_THEME="Mint-Y-Aqua"' 'CURSOR_THEME="Bibata-Modern-Classic"'
    'CURSOR_SIZE="32"' 'CINNAMON_THEME="Mint-Y-Aqua"' 'COLOR_SCHEME="prefer-dark"' 'FONT_NAME="Noto Sans 10"'
    'MONOSPACE_FONT="Noto Sans Mono 10"' 'FONT_ANTIALIAS="grayscale"' 'FONT_HINTING="full"'
    'TEXT_SCALING="110"' 'ACCENT_COLOR="#112233"' 'PANEL_BG_COLOR="#223344"' 'PANEL_FG_COLOR="#EEEEEE"'
    'MENU_BG_COLOR="#334455"' 'MENU_FG_COLOR="#DDDDDD"' 'TOOLTIP_BG_COLOR="#445566"'
    'TOOLTIP_FG_COLOR="#CCCCCC"' 'GTK_ACCENT_COLOR="#556677"' 'PANEL_OPACITY="80"' 'PANEL_HEIGHT="36"'
    'TERMINAL_PALETTE="nord"' 'PANEL_POSITION="top"' 'WINDOW_BUTTONS="izquierda"'
    'HOTCORNER_TL="none"' 'HOTCORNER_TR="expo"' 'HOTCORNER_BL="scale"' 'HOTCORNER_BR="desktop"'
    'WORKSPACES="4"' 'DESKTOP_EFFECTS="on"' 'MENU_EFFECTS="off"' 'DESKTOP_ICONS="hide"'
    'DESKTOP_BG_COLOR="#2E3440"'
)

# --- the parser -----------------------------------------------------------------------------------
write_preset good '# a comment' '' 'GTK_THEME="Mint-Y-Aqua"' 'CURSOR_SIZE="32"'
run_cm 'cm_preset_parse "$CM_PRESETS_DIR/good.conf"; [ "${#CM_PRESET[@]}" = 2 ] && [ "${CM_PRESET[GTK_THEME]}" = Mint-Y-Aqua ] && [ "${CM_PRESET[CURSOR_SIZE]}" = 32 ]' \
    || fail 'positive control: a plain preset was not parsed'

parse_fails() {   # parse_fails <expected text in the error> <line>...
    local expect="$1" err; shift
    write_preset bad "$@"
    if err="$(run_cm 'cm_preset_parse "$CM_PRESETS_DIR/bad.conf"' 2>&1)"; then
        fail "the parser accepted: $*"
    fi
    case "$err" in *"$expect"*) ;; *) fail "the parser error for '$*' lacks '$expect': $err" ;; esac
}
parse_fails 'line 1' 'GTK_THEME=Mint-Y'
parse_fails 'line 2' 'GTK_THEME="Mint-Y-Aqua"' 'not a setting'
parse_fails 'line 1' '  GTK_THEME="Mint-Y-Aqua"'
parse_fails 'line 1' 'gtk_theme="Mint-Y-Aqua"'
parse_fails 'unknown key: NO_SUCH_KEY' 'NO_SUCH_KEY="x"'
parse_fails 'line 3' '# comment' '' 'GTK_THEME="$(touch x)"'
parse_fails 'disallowed characters' 'WINDOW_BUTTONS="a;b"'
parse_fails 'disallowed characters' 'WINDOW_BUTTONS="a|b"'
parse_fails 'disallowed characters' 'WINDOW_BUTTONS="`id`"'
parse_fails 'disallowed characters' 'WINDOW_BUTTONS="a\b"'
parse_fails 'disallowed characters' "$(printf 'WINDOW_BUTTONS="a\tb"')"
parse_fails 'disallowed characters' "$(printf 'WINDOW_BUTTONS="a\rb"')"
parse_fails 'line 1' 'GTK_THEME="a"b"'
: > "$PRESETS/empty.conf"
must_fail run_cm 'cm_preset_parse "$CM_PRESETS_DIR/empty.conf"' >/dev/null 2>&1
write_preset comments '# only a comment' ''
must_fail run_cm 'cm_preset_parse "$CM_PRESETS_DIR/comments.conf"' >/dev/null 2>&1
printf 'GTK_THEME="Mint-Y-Aqua"' > "$PRESETS/no-newline.conf"
run_cm 'cm_preset_parse "$CM_PRESETS_DIR/no-newline.conf"; [ "${CM_PRESET[GTK_THEME]}" = Mint-Y-Aqua ]' \
    || fail 'a last line without a newline was lost'
pass 'the parser reads KEY="value" lines as data and names the line it rejects'

# --- one rule per key, with its boundaries --------------------------------------------------------
check_ok() {   # check_ok <key> <value>...
    local key="$1" v; shift
    for v in "$@"; do
        run_cm "cm_preset_check_value '$key' '$v'" || fail "$key: '$v' should be accepted"
    done
}
check_bad() {   # check_bad <key> <value>...
    local key="$1" v; shift
    for v in "$@"; do
        if run_cm "cm_preset_check_value '$key' '$v'"; then fail "$key: '$v' should be refused"; fi
    done
}
check_ok CURSOR_SIZE 16 24 96 '016'
check_bad CURSOR_SIZE 15 97 0 '' abc -24 2.5 ' 24' 99999999999999999999 1000000000
# A number above 64 bits is refused quietly: the former inline checks accepted it, and Bash printed an error.
[ -z "$(run_cm 'cm_int_in_range 99999999999999999999 1 5; cm_preset_check_value WORKSPACES 99999999999999999999' 2>&1)" ] \
    || fail 'a number above 64 bits makes the range check print an error'
check_ok TEXT_SCALING 50 100 200
check_bad TEXT_SCALING 49 201 abc 99999999999999999999
check_ok PANEL_OPACITY 0 50 100
check_bad PANEL_OPACITY 101 -1 abc 99999999999999999999
check_ok PANEL_HEIGHT 16 40 100
check_bad PANEL_HEIGHT 15 101 abc 99999999999999999999
check_ok WORKSPACES 1 4 20
check_bad WORKSPACES 0 21 abc 99999999999999999999
check_ok ACCENT_COLOR '#abc' '#AABBCC' 'rgb(1, 2, 3)' '#AABBCCDD'
check_bad ACCENT_COLOR 'AABBCC' '#GGGGGG' '#12345' 'red' 'rgb(1,2)'
for key in PANEL_BG_COLOR PANEL_FG_COLOR MENU_BG_COLOR MENU_FG_COLOR TOOLTIP_BG_COLOR TOOLTIP_FG_COLOR GTK_ACCENT_COLOR DESKTOP_BG_COLOR; do
    check_ok "$key" '#123456'
    check_bad "$key" 'nope'
done
check_ok FONT_ANTIALIAS none grayscale rgba rgb
check_bad FONT_ANTIALIAS subpixel RGBA ''
check_ok FONT_HINTING none slight medium full
check_bad FONT_HINTING hinting Full
check_ok TERMINAL_PALETTE nord dracula catppuccin-mocha
check_bad TERMINAL_PALETTE nonexistent Nord
check_ok PANEL_POSITION top bottom
check_bad PANEL_POSITION left Top
for key in HOTCORNER_TL HOTCORNER_TR HOTCORNER_BL HOTCORNER_BR; do
    check_ok "$key" none expo scale desktop
    check_bad "$key" corner Expo
done
check_ok DESKTOP_EFFECTS on off true false si no
check_bad DESKTOP_EFFECTS maybe 1 show
check_ok MENU_EFFECTS on off
check_bad MENU_EFFECTS hide
check_ok DESKTOP_ICONS show hide true false si no
check_bad DESKTOP_ICONS on off 1
check_ok WINDOW_BUTTONS izquierda 'close,minimize:maximize'
check_ok FONT_NAME 'Noto Sans 10'
check_bad FONT_NAME '../x' 'a/b' 'a\b'
check_ok MONOSPACE_FONT 'Noto Sans Mono 10'
check_bad MONOSPACE_FONT '..'
check_ok GTK_THEME Mint-Y-Aqua Adwaita
check_bad GTK_THEME Missing-Theme '../Mint-Y-Aqua' 'a/b'
check_ok ICON_THEME Mint-Y-Aqua
check_bad ICON_THEME Mint-Y-Dark
check_ok CURSOR_THEME Bibata-Modern-Classic
check_bad CURSOR_THEME Missing-Cursor
check_ok CINNAMON_THEME Mint-Y-Aqua cinnamon
check_bad CINNAMON_THEME Missing-Cinnamon
check_ok COLOR_SCHEME default prefer-dark prefer-light
check_bad COLOR_SCHEME dark light Prefer-Dark prefer_dark '' 'prefer-dark '
check_bad NO_SUCH_KEY x
# A theme that is not there is told apart from a value that is wrong (status 2 and 1).
[ "$(run_cm 'cm_preset_check_value ICON_THEME Mint-Y-Dark || echo $?')" = 2 ] || fail 'a missing theme is not status 2'
[ "$(run_cm 'cm_preset_check_value ICON_THEME ../x || echo $?')" = 1 ] || fail 'a bad theme name is not status 1'
pass 'every key has its rule, with the boundaries the setters enforce'

# --- the checks are the setters' checks -----------------------------------------------------------
# The same values go to the check and to the real setter (doubles behind it). The setter accepts when
# the check does: no preset is passed by the check and then refused half way through.
parity() {   # parity <key> <setter call with {} for the value> <value>...
    local key="$1" call="$2" q="'" v want got
    shift 2
    for v in "$@"; do
        want=bad
        if run_cm "cm_preset_check_value '$key' '$v'"; then want=ok; fi
        got=bad
        if run_cm "${call//\{\}/$q$v$q}" >/dev/null 2>&1; then got=ok; fi
        [ "$want" = "$got" ] || fail "$key '$v': the check says $want, the setter $got"
    done
}
NUMS=(0 1 15 16 17 20 21 24 49 50 96 97 100 101 200 201 '' abc -1 1.5 99999999999999999999)
parity CURSOR_SIZE 'cm_apply_cursor_size {} 1' "${NUMS[@]}"
parity TEXT_SCALING 'cm_apply_text_scaling {}' "${NUMS[@]}"
parity WORKSPACES 'cm_apply_workspaces {}' "${NUMS[@]}"
parity DESKTOP_EFFECTS 'cm_apply_desktop_effects {}' on off true false si sí no maybe '' 1
parity MENU_EFFECTS 'cm_apply_menu_effects {}' on off true false si sí no maybe '' 1
parity DESKTOP_ICONS 'cm_apply_desktop_icons {}' show hide true false si sí no on '' 1
parity PANEL_POSITION 'cm_apply_panel_position {}' top bottom left Top
parity DESKTOP_BG_COLOR 'cm_apply_desktop_bg_color {} mantener' '#abc' '#AABBCC' 'rgb(1, 2, 3)' '#AABBCCDD' red '#12345' 'AABBCC'
parity GTK_ACCENT_COLOR 'cm_apply_gtk_accent_color {}' '#abc' '#AABBCC' 'rgb(1, 2, 3)' red '#12345'
parity TERMINAL_PALETTE 'cm_apply_terminal_palette {}' nord dracula nonexistent Nord
parity FONT_NAME 'cm_apply_font_name {}' 'Noto Sans 10' '../x' 'a/b'
parity MONOSPACE_FONT 'cm_apply_monospace_font {}' 'Noto Sans Mono 10' '../x'
parity GTK_THEME 'cm_apply_gtk_theme {}' Mint-Y-Aqua Missing-Theme Adwaita '../x'
parity ICON_THEME 'cm_apply_icon_theme {}' Mint-Y-Aqua Missing-Icons Adwaita
parity CURSOR_THEME 'cm_apply_cursor_theme {} 1' Bibata-Modern-Classic Missing-Cursor
parity CINNAMON_THEME 'cm_apply_cinnamon_theme {}' Mint-Y-Aqua Missing-Cinnamon cinnamon
parity COLOR_SCHEME 'cm_apply_color_scheme {}' default prefer-dark prefer-light dark light Prefer-Dark prefer_dark '' 'prefer-dark '
for aa in rgba rgb grayscale none bogus ''; do
    for hint in slight full none bogus ''; do
        want=bad
        if run_cm "cm_preset_check_value FONT_ANTIALIAS '$aa' && cm_preset_check_value FONT_HINTING '$hint'"; then want=ok; fi
        got=bad
        if run_cm "cm_apply_font_rendering '$aa' '$hint'" >/dev/null 2>&1; then got=ok; fi
        [ "$want" = "$got" ] || fail "rendering '$aa' '$hint': the check says $want, the setter $got"
    done
done
for corner in none expo scale desktop other; do
    want=bad
    if run_cm "cm_preset_check_value HOTCORNER_TL '$corner'"; then want=ok; fi
    got=bad
    if run_cm "cm_apply_hotcorners '$corner' none none none" >/dev/null 2>&1; then got=ok; fi
    [ "$want" = "$got" ] || fail "corner '$corner': the check says $want, the setter $got"
done
pass 'the preset checks agree with the setters on accepted and refused values'

# --- nothing is applied unless everything is valid ------------------------------------------------
: > "$GS_LOG"
write_preset ok 'GTK_THEME="Mint-Y-Aqua"' 'ICON_THEME="Mint-Y-Aqua"' 'CURSOR_SIZE="32"'
run_cm 'cm_load_preset ok' >/dev/null 2>&1 || fail 'positive control: a valid preset was refused'
grep -q 'set org.cinnamon.desktop.interface gtk-theme Mint-Y-Aqua' "$GS_LOG" || fail 'positive control: the valid preset did not reach gsettings'

# The first key is fine and the second names a theme that is not installed: the first must not be set.
: > "$GS_LOG"; rm -f "$GS_STATE"/org.cinnamon.desktop.interface.*
write_preset half 'GTK_THEME="Mint-Y-Aqua"' 'ICON_THEME="Mint-Y-Dark"' 'CURSOR_SIZE="32"'
err="$(run_cm 'cm_load_preset half' 2>&1 >/dev/null)" && fail 'a preset with a missing icon theme was applied'
[ ! -s "$GS_LOG" ] || fail "something reached gsettings or dconf before the refusal: $(cat "$GS_LOG")"
case "$err" in *"preset 'half' was not applied and nothing was changed"*"ICON_THEME: 'Mint-Y-Dark' is not installed"*) ;; *) fail "unclear refusal: $err" ;; esac
case "$err" in *GTK_THEME*) fail 'the valid GTK theme was reported as a problem' ;; esac
pass 'a preset with a missing theme changes nothing and says which one'

# Every problem is listed at once, each with its key and value.
write_preset many 'GTK_THEME="Gone-GTK"' 'CURSOR_SIZE="5"' 'PANEL_POSITION="left"' 'HOTCORNER_TL="expo"' 'FONT_ANTIALIAS="rgba"'
: > "$GS_LOG"
err="$(run_cm 'cm_load_preset many' 2>&1 >/dev/null)" && fail 'a preset with five problems was applied'
for want in "GTK_THEME: 'Gone-GTK' is not installed" "CURSOR_SIZE: '5' is not a valid value" \
            "PANEL_POSITION: 'left' is not a valid value" 'HOTCORNER_TL, HOTCORNER_TR, HOTCORNER_BL, HOTCORNER_BR go together' \
            'FONT_ANTIALIAS, FONT_HINTING go together'; do
    case "$err" in *"$want"*) ;; *) fail "the refusal lacks '$want': $err" ;; esac
done
[ ! -s "$GS_LOG" ] || fail 'a refused preset reached gsettings'
pass 'every problem of a preset is listed, with its key and value'

# The check reads nothing from the desktop and writes nothing: no gsettings call at all, no new file.
find "$HOME_DIR" "$CM_STATE" | sort > "$TMP/before.txt"
: > "$GS_LOG"
run_cm 'cm_preset_parse "$CM_PRESETS_DIR/many.conf" && cm_preset_validate many' >/dev/null 2>&1 || true
run_cm 'cm_preset_parse "$CM_PRESETS_DIR/ok.conf" && cm_preset_validate ok' >/dev/null 2>&1 || fail 'a valid preset did not validate'
find "$HOME_DIR" "$CM_STATE" | sort > "$TMP/after.txt"
[ ! -s "$GS_LOG" ] || fail 'validation called the desktop'
cmp -s "$TMP/before.txt" "$TMP/after.txt" || fail 'validation wrote files'
pass 'validation has no side effects'

# A syntax error also stops everything before the first setting.
write_preset syntax 'GTK_THEME="Mint-Y-Aqua"' 'oops'
: > "$GS_LOG"
must_fail run_cm 'cm_load_preset syntax' >/dev/null 2>&1
[ ! -s "$GS_LOG" ] || fail 'a preset with a syntax error reached gsettings'
pass 'a preset with a syntax error changes nothing'

# --- the order and the arguments each key reaches its setter with --------------------------------
write_preset full "${FULL[@]}"
CALLS="$TMP/calls.log"
: > "$CALLS"
STUBS='
CALLS="$2"
rec() { printf "%s\n" "$*" >> "$CALLS"; }
cm_apply_gtk_theme() { rec gtk "$@"; }
cm_apply_icon_theme() { rec icon "$@"; }
cm_apply_cursor_theme() { rec cursor "$@"; }
cm_apply_cursor_size() { rec cursor_size "$@"; }
cm_apply_cinnamon_theme() { rec cinnamon "$@"; }
cm_apply_color_scheme() { rec color_scheme "$@"; }
cm_apply_font_name() { rec font "$@"; }
cm_apply_monospace_font() { rec mono "$@"; }
cm_apply_font_rendering() { rec rendering "$@"; }
cm_apply_text_scaling() { rec scaling "$@"; }
cm_apply_accent_color() { rec accent "$@"; }
cm_apply_panel_bg_color() { rec panel_bg "$@"; }
cm_apply_panel_fg_color() { rec panel_fg "$@"; }
cm_apply_menu_bg_color() { rec menu_bg "$@"; }
cm_apply_menu_fg_color() { rec menu_fg "$@"; }
cm_apply_tooltip_bg_color() { rec tooltip_bg "$@"; }
cm_apply_tooltip_fg_color() { rec tooltip_fg "$@"; }
cm_apply_gtk_accent_color() { rec gtk_accent "$@"; }
cm_apply_panel_opacity() { rec opacity "$@"; }
cm_apply_panel_height() { rec height "$@"; }
cm_apply_terminal_palette() { rec palette "$@"; }
cm_apply_panel_position() { rec position "$@"; }
cm_apply_window_buttons() { rec buttons "$@"; }
cm_apply_hotcorners() { rec corners "$@"; }
cm_apply_workspaces() { rec workspaces "$@"; }
cm_apply_desktop_effects() { rec effects "$@"; }
cm_apply_menu_effects() { rec menu_effects "$@"; }
cm_apply_desktop_icons() { rec icons "$@"; }
cm_apply_desktop_bg_color() { rec desktop_bg "$@"; }
cm_reload_cinnamon() { rec reload; }
'
cat > "$TMP/expected-calls.txt" <<'EXPECTED'
gtk Mint-Y-Aqua
icon Mint-Y-Aqua
cursor Bibata-Modern-Classic 1
cursor_size 32 1
cinnamon Mint-Y-Aqua
color_scheme prefer-dark
font Noto Sans 10
mono Noto Sans Mono 10
rendering grayscale full
scaling 110
accent #112233
panel_bg #223344
panel_fg #EEEEEE
menu_bg #334455
menu_fg #DDDDDD
tooltip_bg #445566
tooltip_fg #CCCCCC
gtk_accent #556677
opacity 80
height 36
palette nord
position top
buttons izquierda
corners none expo scale desktop
workspaces 4
effects on
menu_effects off
icons hide
desktop_bg #2E3440 mantener
reload
EXPECTED
HOME="$HOME_DIR" CM_HOME="$CM_STATE" XDG_DATA_HOME="$XDG_HOME" XDG_DATA_DIRS="$SYS_DIR" CM_LANG_OVERRIDE=en \
    PATH="$MOCK:$PATH" GS_STATE="$GS_STATE" GS_LOG="$GS_LOG" \
    bash -c 'source "$1"; cm_lang_init; eval "$3"; cm_log() { :; }; cm_load_preset full >/dev/null' bash "$BODY" "$CALLS" "$STUBS" \
    || fail 'the full preset was not applied'
diff -u "$TMP/expected-calls.txt" "$CALLS" || fail 'the keys did not reach their setters in order with the right arguments'
pass 'every key reaches its setter once, in order, with the right arguments'

# A preset can leave keys out: only the ones it holds are applied.
write_preset partial 'GTK_THEME="Mint-Y-Aqua"' 'WORKSPACES="6"'
: > "$CALLS"
HOME="$HOME_DIR" CM_HOME="$CM_STATE" XDG_DATA_HOME="$XDG_HOME" XDG_DATA_DIRS="$SYS_DIR" CM_LANG_OVERRIDE=en \
    PATH="$MOCK:$PATH" GS_STATE="$GS_STATE" GS_LOG="$GS_LOG" \
    bash -c 'source "$1"; cm_lang_init; eval "$3"; cm_log() { :; }; cm_load_preset partial >/dev/null' bash "$BODY" "$CALLS" "$STUBS" \
    || fail 'a partial preset was not applied'
printf 'gtk Mint-Y-Aqua\nworkspaces 6\nreload\n' | diff -u - "$CALLS" || fail 'a partial preset applied keys it does not hold'
pass 'a preset with some keys applies only those'

# --- a failure half way through is reported by key ------------------------------------------------
write_preset stops 'GTK_THEME="Mint-Y-Aqua"' 'WORKSPACES="6"' 'DESKTOP_EFFECTS="on"'
: > "$GS_LOG"
err="$(GS_FAIL_KEY=num-workspaces run_cm 'cm_load_preset stops' 2>&1 >/dev/null)" && fail 'a preset whose setter failed reported success'
case "$err" in *'stopped at WORKSPACES'*'restore the last backup'*) ;; *) fail "the stop is not reported by key: $err" ;; esac
grep -q 'gtk-theme Mint-Y-Aqua' "$GS_LOG" || fail 'the setting before the failure was not applied'
if grep -q 'desktop-effects' "$GS_LOG"; then fail 'a setting after the failure was applied'; fi
pass 'a setter that fails stops the preset and names its key'

# --- the light/dark scheme ------------------------------------------------------------------------
# libadwaita apps follow org.x.apps.portal color-scheme. A system without that schema has nothing to
# write: the setter skips it and succeeds, so a preset that holds the key still loads there.
: > "$GS_LOG"
out="$(run_cm 'cm_apply_color_scheme prefer-dark' 2>&1)" || fail 'the scheme was refused although the portal is present'
grep -qx 'set org.x.apps.portal color-scheme prefer-dark' "$GS_LOG" || fail 'the scheme did not reach org.x.apps.portal'
case "$out" in *'Light/dark scheme applied: prefer-dark'*) ;; *) fail "unclear message: $out" ;; esac

: > "$GS_LOG"
out="$(GS_NO_PORTAL=1 run_cm 'cm_apply_color_scheme prefer-dark' 2>&1)" || fail 'a system without org.x.apps.portal made the scheme fail'
if grep -q '^set ' "$GS_LOG"; then fail 'the scheme was written on a system without the portal'; fi
case "$out" in *'Light/dark scheme skipped'*'org.x.apps.portal'*) ;; *) fail "the skip is not reported: $out" ;; esac

: > "$GS_LOG"
must_fail run_cm 'cm_apply_color_scheme dark' >/dev/null 2>&1
[ ! -s "$GS_LOG" ] || fail 'an invalid scheme reached gsettings'
err="$(GS_FAIL_KEY=color-scheme run_cm 'cm_apply_color_scheme prefer-dark' 2>&1 >/dev/null)" && fail 'a failed write of the scheme reported success'
case "$err" in *"could not apply 'org.x.apps.portal color-scheme'"*) ;; *) fail "the failed write does not name its key: $err" ;; esac

write_preset scheme 'GTK_THEME="Mint-Y-Aqua"' 'COLOR_SCHEME="prefer-dark"' 'WORKSPACES="6"'
: > "$GS_LOG"
GS_NO_PORTAL=1 run_cm 'cm_load_preset scheme' >/dev/null 2>&1 || fail 'a preset with COLOR_SCHEME was refused on a system without the portal'
grep -q 'gtk-theme Mint-Y-Aqua' "$GS_LOG" && grep -q 'num-workspaces 6' "$GS_LOG" || fail 'the other keys of the preset were not applied without the portal'
pass 'the scheme is written, skipped without org.x.apps.portal, and refused when invalid or unwritable'

# The colour pack writes the scheme of its mode.
while read -r mode scheme; do
    : > "$GS_LOG"
    run_cm "cm_apply_mint_y_pack Aqua $mode" >/dev/null 2>&1 || fail "the $mode pack failed"
    grep -qx "set org.x.apps.portal color-scheme $scheme" "$GS_LOG" || fail "the $mode pack did not write $scheme: $(tr '\n' ';' < "$GS_LOG")"
    [ "$(grep -c '^set org.x.apps.portal color-scheme ' "$GS_LOG")" -eq 1 ] || fail "the $mode pack wrote the scheme more than once"
done <<'MODES'
claro prefer-light
oscuro prefer-dark
MODES

# A scheme that cannot be written does not undo the pack: it stays applied, is recorded and returns 0.
: > "$GS_LOG"; rm -f "$CM_STATE/state.conf"
out="$(GS_FAIL_KEY=color-scheme run_cm 'cm_apply_mint_y_pack Aqua oscuro' 2>"$TMP/pack.err")" || fail 'a scheme that cannot be written aborted the colour pack'
case "$out" in *'Official Mint-Y color pack applied: Mint-Y-Dark-Aqua (icons: Mint-Y-Aqua)'*) ;; *) fail "the pack did not report success: $out" ;; esac
grep -q "could not apply 'org.x.apps.portal color-scheme'" "$TMP/pack.err" || fail 'the failed scheme was not reported on stderr'
[ "$(run_cm 'cm_state_get MINT_Y_COLOR none')" = Aqua ] && [ "$(run_cm 'cm_state_get MINT_Y_MODE none')" = oscuro ] \
    || fail 'the pack was not recorded after the scheme failed'
for setting in 'org.cinnamon.desktop.interface gtk-theme Mint-Y-Dark-Aqua' 'org.cinnamon.desktop.interface icon-theme Mint-Y-Aqua' 'org.cinnamon.theme name Mint-Y-Dark-Aqua'; do
    grep -qx "set $setting" "$GS_LOG" || fail "the pack did not write $setting before the scheme failed"
done

# A theme that cannot be set is a failed pack, not a reported success: it stops there, writes no scheme
# and records nothing (the pack used to print "applied" and return 0).
for key in gtk-theme icon-theme name; do
    : > "$GS_LOG"; rm -f "$CM_STATE/state.conf"
    out="$(GS_FAIL_KEY=$key run_cm 'cm_apply_mint_y_pack Aqua claro' 2>"$TMP/pack.err")" && fail "the pack reported success although $key could not be set"
    case "$out" in *'color pack applied'*) fail "the pack announced success although $key failed" ;; esac
    grep -q "could not apply" "$TMP/pack.err" || fail "the failure of $key was not reported"
    if grep -q '^set org.x.apps.portal' "$GS_LOG"; then fail "the pack wrote the scheme after $key failed"; fi
    [ "$(run_cm 'cm_state_get MINT_Y_COLOR none')" = none ] || fail "the pack was recorded although $key failed"
done

# Without the portal the pack is the same as before.
: > "$GS_LOG"
GS_NO_PORTAL=1 run_cm 'cm_apply_mint_y_pack Aqua claro' >/dev/null 2>&1 || fail 'the colour pack failed without the portal'
if grep -q '^set org.x.apps.portal' "$GS_LOG"; then fail 'the pack wrote the scheme without the portal'; fi
pass 'the colour pack writes its mode as the scheme and a failed write does not undo it'

# --- the Profiles tab validates a preset before it takes a backup ---------------------------------
# cm_backup_current is a double that writes BACKUP to the log gsettings writes to, so the count and the
# order against the first setting can be read. A refused preset must leave no backup: one per attempt
# would bury the one worth keeping.
cat > "$MOCK/yad" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${YAD_LOG:?}"
MOCK
chmod 755 "$MOCK/yad"
YAD_LOG="$TMP/yad.log"
profiles_load() {   # profiles_load <name> [backup status]: the tab's action; fills GS_LOG and YAD_LOG
    : > "$GS_LOG"; : > "$YAD_LOG"
    YAD_LOG="$YAD_LOG" run_cm "cm_backup_current() { echo BACKUP >> \"\$GS_LOG\"; return ${2:-0}; }; cm_notify_applied() { :; }; cm_ui_apply_profiles_load '$1'" >/dev/null 2>&1
}
backups_taken() { grep -c '^BACKUP$' "$GS_LOG" || true; }

write_preset gui 'GTK_THEME="Mint-Y-Aqua"' 'ICON_THEME="Mint-Y-Dark"'
if profiles_load gui; then fail 'the Profiles tab did not report a refused preset as a failure'; fi
grep -q -- '--error' "$YAD_LOG" || fail 'the Profiles tab showed no error dialog'
grep -q "ICON_THEME: 'Mint-Y-Dark' is not installed" "$YAD_LOG" || fail 'the error dialog does not say which theme is missing'
if grep -q -- '--info' "$YAD_LOG"; then fail 'a refused preset showed a success dialog'; fi
[ "$(backups_taken)" = 0 ] || fail 'a preset refused for a missing theme left a backup'
[ -z "$(grep '^set ' "$GS_LOG")" ] || fail 'a refused preset reached the desktop'

write_preset gui-syntax 'GTK_THEME=Mint-Y-Aqua'
if profiles_load gui-syntax; then fail 'a preset with a syntax error was not reported as a failure'; fi
grep -q 'line 1' "$YAD_LOG" || fail 'the error dialog does not name the line that is wrong'
[ "$(backups_taken)" = 0 ] || fail 'a preset with a syntax error left a backup'
write_preset gui-value 'CURSOR_SIZE="999"'
if profiles_load gui-value; then fail 'a preset with a bad value was not reported as a failure'; fi
[ "$(backups_taken)" = 0 ] || fail 'a preset with a bad value left a backup'
if profiles_load nothere; then fail 'a preset that does not exist was not reported as a failure'; fi
grep -q "nothere" "$YAD_LOG" || fail 'the error dialog does not name the preset that was not found'
[ "$(backups_taken)" = 0 ] || fail 'a preset that does not exist left a backup'
printf 'GTK_THEME="Mint-Y-Aqua"\n' > "$CM_STATE/x.conf"   # valid, one folder up: only the name check refuses it
if profiles_load '../x'; then fail 'a preset name with a path was accepted'; fi
[ "$(backups_taken)" = 0 ] || fail 'a preset name with a path left a backup'
[ -z "$(grep '^set ' "$GS_LOG")" ] || fail 'a preset outside the presets folder reached the desktop'
rm -f "$CM_STATE/x.conf"
if profiles_load ''; then fail 'no preset chosen was not reported as a failure'; fi
[ "$(backups_taken)" = 0 ] || fail 'choosing no preset left a backup'

# Control: a valid preset takes exactly one backup, before the first setting changes.
write_preset gui-ok 'GTK_THEME="Mint-Y-Aqua"' 'CURSOR_SIZE="32"'
profiles_load gui-ok || fail 'a valid preset was refused by the Profiles tab'
[ "$(backups_taken)" = 1 ] || fail "a valid preset took $(backups_taken) backups instead of one"
backup_line="$(grep -n -m1 '^BACKUP$' "$GS_LOG" | cut -d: -f1)"
first_set="$(grep -n -m1 '^set ' "$GS_LOG" | cut -d: -f1)"
[ -n "$first_set" ] || fail 'control: a valid preset changed nothing, so the order cannot be read'
[ "$backup_line" -lt "$first_set" ] || fail 'the backup was taken after the first setting changed'
if grep -q -- '--error' "$YAD_LOG"; then fail 'a valid preset showed an error dialog'; fi

# A valid preset whose setter fails half way keeps its backup: the desktop may be half changed.
write_preset gui-half 'GTK_THEME="Mint-Y-Aqua"' 'ICON_THEME="Mint-Y-Aqua"'
if GS_FAIL_KEY=icon-theme profiles_load gui-half; then fail 'a setter that failed was not reported by the Profiles tab'; fi
[ "$(backups_taken)" = 1 ] || fail 'a preset that stopped half way had no backup to restore'
grep -q 'ICON_THEME' "$YAD_LOG" || fail 'the dialog does not name the key where the preset stopped'

# A backup that cannot be taken stops a valid preset before it changes anything.
if profiles_load gui-ok 1; then fail 'a failed backup did not stop the preset'; fi
[ -z "$(grep '^set ' "$GS_LOG")" ] || fail 'a preset was applied although its backup failed'
rm -f "$MOCK/yad"
pass 'the Profiles tab validates a preset before it takes a backup, which comes before the first change'

# --- Spanish --------------------------------------------------------------------------------------
err="$(CM_TEST_LANG=es run_cm 'cm_load_preset half' 2>&1 >/dev/null)" && fail 'Spanish: a refused preset was applied'
case "$err" in *"el preset 'half' no se aplicó y no se cambió nada"*"ICON_THEME: 'Mint-Y-Dark' no está instalado"*) ;; *) fail "Spanish refusal: $err" ;; esac
write_preset bad 'NO_SUCH_KEY="x"'
err="$(CM_TEST_LANG=es run_cm 'cm_load_preset bad' 2>&1 >/dev/null)" && fail 'Spanish: an unknown key was accepted'
case "$err" in *'línea 1'*'clave desconocida: NO_SUCH_KEY'*) ;; *) fail "Spanish parser error: $err" ;; esac
err="$(CM_TEST_LANG=es run_cm 'cm_apply_color_scheme dark' 2>&1 >/dev/null)" && fail 'Spanish: an invalid scheme was accepted'
case "$err" in *"el esquema de color 'dark' no es válido"*) ;; *) fail "Spanish scheme error: $err" ;; esac
out="$(CM_TEST_LANG=es GS_NO_PORTAL=1 run_cm 'cm_apply_color_scheme prefer-dark' 2>&1)" || fail 'Spanish: the skip failed'
case "$out" in *'Esquema claro/oscuro omitido'*) ;; *) fail "Spanish skip message: $out" ;; esac
pass 'the refusals are in Spanish'

# --- what the script saves is what it can read ----------------------------------------------------
# The key table, the file cm_save_preset writes and the file cm_load_preset reads must list the same keys
# in the same order, or a saved preset would lose a setting.
run_cm 'cm_save_preset roundtrip' >/dev/null 2>&1 || fail 'cm_save_preset failed'
grep -oE '^[A-Z_]+=' "$PRESETS/roundtrip.conf" | tr -d '=' > "$TMP/saved-keys.txt"
run_cm 'printf "%s\n" "${CM_PRESET_KEYS[@]}"' > "$TMP/table-keys.txt"
diff -u "$TMP/table-keys.txt" "$TMP/saved-keys.txt" || fail 'cm_save_preset and CM_PRESET_KEYS list different keys'
run_cm 'cm_preset_parse "$CM_PRESETS_DIR/roundtrip.conf"' || fail 'a preset the script saved was not read back'
pass 'a saved preset lists the keys of the table, in order, and is read back'

# The scheme goes right after the Cinnamon theme, holds the current value, and is empty without the portal.
printf "'prefer-dark'\n" > "$GS_STATE/org.x.apps.portal.color-scheme"
run_cm 'cm_save_preset with-scheme' >/dev/null 2>&1 || fail 'cm_save_preset failed with the portal present'
grep -qx 'COLOR_SCHEME="prefer-dark"' "$PRESETS/with-scheme.conf" || fail 'the saved preset lacks the current scheme'
[ "$(grep -A1 '^CINNAMON_THEME=' "$PRESETS/with-scheme.conf" | tail -n1)" = 'COLOR_SCHEME="prefer-dark"' ] \
    || fail 'COLOR_SCHEME does not follow CINNAMON_THEME in the saved preset'
GS_NO_PORTAL=1 run_cm 'cm_save_preset no-portal' >/dev/null 2>&1 || fail 'cm_save_preset failed without the portal'
grep -qx 'COLOR_SCHEME=""' "$PRESETS/no-portal.conf" || fail 'the scheme was not saved empty without the portal'
run_cm 'cm_preset_parse "$CM_PRESETS_DIR/no-portal.conf"' || fail 'a preset saved without the portal is not read back'
write_preset empty-scheme 'GTK_THEME="Mint-Y-Aqua"' 'COLOR_SCHEME=""'
: > "$GS_LOG"
run_cm 'cm_load_preset empty-scheme' >/dev/null 2>&1 || fail 'a preset with an empty COLOR_SCHEME does not load'
if grep -q 'org.x.apps.portal' "$GS_LOG"; then fail 'an empty COLOR_SCHEME reached the portal'; fi
rm -f "$GS_STATE/org.x.apps.portal.color-scheme"
pass 'a saved preset keeps the scheme after the Cinnamon theme and loads without the portal'

# Against the real gsettings, with a private schema and a file backend: the probe the setter relies on
# (a missing schema makes "get" fail) and the enum are the real ones, not a double's.
if command -v glib-compile-schemas >/dev/null 2>&1 && command -v gsettings >/dev/null 2>&1; then
    REAL="$TMP/real-gs"
    mkdir -p "$REAL/schemas" "$REAL/config"
    cat > "$REAL/schemas/org.x.apps.portal.gschema.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<schemalist>
  <enum id="org.x.apps.portal.ColorScheme">
    <value nick="default" value="0"/>
    <value nick="prefer-dark" value="1"/>
    <value nick="prefer-light" value="2"/>
  </enum>
  <schema id="org.x.apps.portal" path="/org/x/apps/portal/">
    <key name="color-scheme" enum="org.x.apps.portal.ColorScheme">
      <default>'default'</default>
      <summary>Light or dark preference</summary>
    </key>
  </schema>
</schemalist>
XML
    glib-compile-schemas "$REAL/schemas"
    real_cm() {   # real_cm <schema dir or ''> <snippet>: the real gsettings, no double in PATH
        HOME="$HOME_DIR" CM_HOME="$CM_STATE" XDG_CONFIG_HOME="$REAL/config" GSETTINGS_BACKEND=keyfile \
            GSETTINGS_SCHEMA_DIR="$1" CM_LANG_OVERRIDE=en bash -c 'source "$1"; cm_lang_init; eval "$2"' bash "$BODY" "$2"
    }
    out="$(real_cm "" 'cm_apply_color_scheme prefer-dark' 2>&1)" || fail 'the real gsettings without the schema made the scheme fail'
    case "$out" in *'skipped'*) ;; *) fail "the real gsettings without the schema was not skipped: $out" ;; esac
    out="$(real_cm "$REAL/schemas" 'cm_apply_color_scheme prefer-dark' 2>&1)" || fail "the real gsettings refused the scheme: $out"
    [ "$(real_cm "$REAL/schemas" 'gsettings get org.x.apps.portal color-scheme')" = "'prefer-dark'" ] || fail 'the real gsettings did not keep prefer-dark'
    [ "$(real_cm "$REAL/schemas" 'cm_save_preset real-scheme >/dev/null; grep "^COLOR_SCHEME=" "$CM_PRESETS_DIR/real-scheme.conf"')" = 'COLOR_SCHEME="prefer-dark"' ] \
        || fail 'cm_save_preset did not read the real value'
    pass 'the scheme works against the real gsettings, with and without the schema'
else
    printf 'INFO: glib-compile-schemas or gsettings missing: the real-gsettings check was skipped\n'
fi

# --- the seeded presets -----------------------------------------------------------------------------
# A tree with the names the official Mint packages install, read in their repositories on 2026-10-25:
# mint-themes (Mint-Y and Mint-Y-Dark, each with nine colours, GTK and Cinnamon in the same folder),
# mint-y-icons (Mint-Y and twelve colours: no Dark variant and no cursors/) and mint-cursor-themes (eight
# cursor themes: cursors/ and no Directories= line). The seeds must name only what that tree holds.
OFFICIAL="$TMP/official/share"
OFFICIAL_USER="$TMP/official-user"
OFFICIAL_HOME="$TMP/official-home"
SEED_HOME="$TMP/seed-home"
SEED_GS="$TMP/seed-gs"
SEED_PRESETS="$SEED_HOME/presets"
mkdir -p "$OFFICIAL/themes" "$OFFICIAL/icons" "$OFFICIAL_USER" "$OFFICIAL_HOME" "$SEED_GS"
printf "'b1dcc9dd'\n" > "$SEED_GS/org.gnome.Terminal.ProfilesList.default"
for base in Mint-Y Mint-Y-Dark; do
    for color in '' -Aqua -Blue -Grey -Orange -Pink -Purple -Red -Sand -Teal; do
        mkdir -p "$OFFICIAL/themes/$base$color/gtk-3.0" "$OFFICIAL/themes/$base$color/gtk-4.0" "$OFFICIAL/themes/$base$color/cinnamon"
        : > "$OFFICIAL/themes/$base$color/gtk-3.0/gtk.css"
        # Just the structure the colour and panel setters work on: a panel with an rgba background, menu
        # and tooltip blocks, and a repeated accent colour. The real stylesheets are far larger.
        cat > "$OFFICIAL/themes/$base$color/cinnamon/cinnamon.css" <<'CSS'
.panel-top, .panel-bottom { background-color: rgba(34, 34, 34, 0.95); color: #dddddd; }
#panel { color: #dddddd; }
.menu, .popup-menu { background-color: #222222; color: #dddddd; }
#Tooltip { background-color: #333333; color: #dddddd; }
.workspace-button:hover, .grouped-window-list-item-box:focus { background-color: #8fa876; border-color: #8fa876; }
CSS
    done
done
for color in '' -Aqua -Blue -Cyan -Grey -Navy -Orange -Pink -Purple -Red -Sand -Teal -Yaru; do
    mkdir -p "$OFFICIAL/icons/Mint-Y$color"
    printf '[Icon Theme]\nName=Mint-Y%s\nDirectories=16x16/apps\n' "$color" > "$OFFICIAL/icons/Mint-Y$color/index.theme"
done
OFFICIAL_CURSORS=(Bibata-Modern-Classic Bibata-Modern-Ice Bibata-Original-Classic Bibata-Original-Ice
                  GoogleDot-Black GoogleDot-White XCursor-Pro-Dark XCursor-Pro-Light)
for cursor in "${OFFICIAL_CURSORS[@]}"; do
    mkdir -p "$OFFICIAL/icons/$cursor/cursors"
    printf '[Icon Theme]\nName=%s\n' "$cursor" > "$OFFICIAL/icons/$cursor/index.theme"
done

run_official() {   # run_official <snippet>: the official tree only, a clean home, its own settings
    HOME="$OFFICIAL_HOME" CM_HOME="$SEED_HOME" XDG_DATA_HOME="$OFFICIAL_USER" XDG_DATA_DIRS="${OFFICIAL_DIRS:-$OFFICIAL}" \
        CM_LANG_OVERRIDE=en PATH="$MOCK:$PATH" GS_STATE="$SEED_GS" GS_LOG="$GS_LOG" \
        bash -c 'source "$1"; cm_lang_init; eval "$2"' bash "$BODY" "$1"
}
seed_value() { sed -n "s/^$2=\"\\(.*\\)\"\$/\\1/p" "$SEED_PRESETS/$1.conf"; }

# The tree is faithful, or the checks below prove nothing: the cursor catalog holds exactly the cursor
# themes, no icon theme is a cursor theme and there is no dark icon theme.
want_cursors="$(printf '%s\n' "${OFFICIAL_CURSORS[@]}" | sort -u)"
[ "$(run_official cm_list_cursor_themes)" = "$want_cursors" ] || fail 'the official tree does not list exactly the eight cursor themes'
run_official cm_list_icon_themes | grep -qx 'Mint-Y-Aqua' || fail 'positive control: the official tree lacks the Mint-Y-Aqua icons'
if run_official cm_list_icon_themes | grep -qx 'Mint-Y-Dark'; then fail 'the official tree has a dark icon theme'; fi
if run_official cm_list_cursor_themes | grep -qx 'Mint-Y'; then fail 'the official tree offers the Mint-Y icons as a cursor theme'; fi

: > "$GS_LOG"; rm -rf "$SEED_HOME"
run_official cm_bootstrap_presets || fail 'the seeds were not created'
for seed in default nord-dark; do
    [ -f "$SEED_PRESETS/$seed.conf" ] || fail "the seed '$seed' was not created"
done
if find "$SEED_PRESETS" -type f ! -name '*.conf' | grep -q .; then fail 'seeding left a stray file in the presets folder'; fi

# Each seed names only what the official packages install, kind by kind, by the catalogs the GUI offers.
# The check against the cursor catalog matters: a preset can name any icon folder as a cursor theme and
# pass the validation (the folder exists), so only the catalog tells a cursor theme from an icon theme.
for seed in default nord-dark; do
    for pair in 'GTK_THEME cm_list_gtk_themes' 'ICON_THEME cm_list_icon_themes' \
                'CURSOR_THEME cm_list_cursor_themes' 'CINNAMON_THEME cm_list_cinnamon_themes'; do
        key="${pair%% *}" list="${pair#* }"
        value="$(seed_value "$seed" "$key")"
        [ -n "$value" ] || fail "the seed '$seed' has no $key"
        run_official "$list" | grep -qxF -- "$value" || fail "the seed '$seed' names $key '$value', which the official packages do not install"
    done
done

# A seed is refused by no rule and applies whole: every theme it names ends up in the settings.
for seed in default nord-dark; do
    : > "$GS_LOG"; rm -f "$SEED_GS"/org.cinnamon.* "$SEED_GS"/org.x.* "$SEED_GS"/org.gnome.desktop.*
    err="$(run_official "cm_load_preset $seed" 2>&1 >/dev/null)" || fail "the seed '$seed' was refused on a system with the Mint packages: $err"
    [ -z "$err" ] || fail "loading the seed '$seed' printed errors: $err"
    for pair in 'GTK_THEME org.cinnamon.desktop.interface.gtk-theme' 'ICON_THEME org.cinnamon.desktop.interface.icon-theme' \
                'CURSOR_THEME org.cinnamon.desktop.interface.cursor-theme' 'COLOR_SCHEME org.x.apps.portal.color-scheme'; do
        key="${pair%% *}" setting="${pair#* }"
        [ "$(cat "$SEED_GS/$setting" 2>/dev/null)" = "$(seed_value "$seed" "$key")" ] \
            || fail "loading the seed '$seed' did not leave $key as '$(seed_value "$seed" "$key")' in $setting"
    done
    # The accent and the panel opacity edit a copy of the Cinnamon theme (CM-<theme>), which is then the
    # active one; the copy's base is the theme the seed names.
    cinnamon="$(seed_value "$seed" CINNAMON_THEME)"
    [ "$(cat "$SEED_GS/org.cinnamon.theme.name" 2>/dev/null)" = "CM-$cinnamon" ] || fail "loading the seed '$seed' did not leave the Cinnamon theme CM-$cinnamon"
    [ -f "$OFFICIAL_HOME/.themes/CM-$cinnamon/cinnamon/cinnamon.css" ] || fail "the editable copy CM-$cinnamon of the seed '$seed' was not made"
    for key in ACCENT_COLOR PANEL_OPACITY; do
        [ "$(run_official "cm_state_get $key none")" = "$(seed_value "$seed" "$key")" ] || fail "loading the seed '$seed' did not record $key"
    done
done

# The scheme goes with the look: a dark GTK theme asks libadwaita for dark and a light one for light,
# or a dark look would leave libadwaita apps light. It follows the Cinnamon theme in the file.
for seed in default nord-dark; do
    case "$(seed_value "$seed" GTK_THEME)" in *Dark*) want=prefer-dark ;; *) want=prefer-light ;; esac
    [ "$(seed_value "$seed" COLOR_SCHEME)" = "$want" ] || fail "the seed '$seed' has GTK theme $(seed_value "$seed" GTK_THEME) but scheme '$(seed_value "$seed" COLOR_SCHEME)'"
    [ "$(grep -A1 '^CINNAMON_THEME=' "$SEED_PRESETS/$seed.conf" | tail -n1)" = "COLOR_SCHEME=\"$want\"" ] \
        || fail "COLOR_SCHEME does not follow CINNAMON_THEME in the seed '$seed'"
    # The keys keep the order of the table, like a preset that cm_save_preset writes.
    run_official 'printf "%s\n" "${CM_PRESET_KEYS[@]}"' > "$TMP/table-keys.txt"
    grep -oE '^[A-Z_]+=' "$SEED_PRESETS/$seed.conf" | tr -d '=' > "$TMP/seed-keys.txt"
    [ "$(grep -Fxf "$TMP/seed-keys.txt" "$TMP/table-keys.txt")" = "$(cat "$TMP/seed-keys.txt")" ] || fail "the keys of the seed '$seed' are not in the order of the table"
done

# Control: the seeds before the fix (an icon theme and a cursor theme that no package installs) fail here.
cat > "$SEED_PRESETS/before-fix.conf" <<'OLD'
GTK_THEME="Mint-Y-Dark"
ICON_THEME="Mint-Y-Dark"
CURSOR_THEME="Mint-Y"
OLD
err="$(run_official 'cm_load_preset before-fix' 2>&1 >/dev/null)" && fail 'the dark icon theme that no package installs was accepted'
case "$err" in *"ICON_THEME: 'Mint-Y-Dark' is not installed"*) ;; *) fail "the old icon theme was not named: $err" ;; esac
run_official cm_list_cursor_themes | grep -qxF 'Mint-Y' && fail 'control: Mint-Y passes the cursor catalog, so the catalog check cannot fail'
rm -f "$SEED_PRESETS/before-fix.conf"

# Without the Mint packages a seed is refused whole and nothing reaches the desktop.
mkdir -p "$TMP/no-mint/share/themes" "$TMP/no-mint/share/icons"
: > "$GS_LOG"
err="$(OFFICIAL_DIRS="$TMP/no-mint/share" run_official 'cm_load_preset default' 2>&1 >/dev/null)" && fail 'a seed was applied on a system without the Mint packages'
case "$err" in *"preset 'default' was not applied and nothing was changed"*"GTK_THEME: 'Mint-Y' is not installed"*) ;; *) fail "the refusal without the Mint packages is unclear: $err" ;; esac
[ ! -s "$GS_LOG" ] || fail "a refused seed reached the desktop: $(cat "$GS_LOG")"

# A seed the user edited is never overwritten, and seeding again changes nothing.
printf '# mine\nGTK_THEME="Mint-Y-Aqua"\n' > "$SEED_PRESETS/default.conf"
cp -a "$SEED_PRESETS" "$TMP/seed-before"
run_official cm_bootstrap_presets || fail 'seeding again failed'
diff -r "$TMP/seed-before" "$SEED_PRESETS" > /dev/null || fail 'seeding again changed a preset the user had edited'
pass 'the seeded presets name only what the official Mint packages install, apply whole and match their light or dark scheme'

# --- the official looks ----------------------------------------------------------------------------
# Twenty looks, one light and one dark for each of the ten Mint-Y colours, typed here by hand so the test
# does not derive them from the script's table. mint-y-icons has no dark variant, so a dark look keeps the
# icons of its colour; Cyan, Navy and Yaru icons have no GTK or Cinnamon theme of their colour and no look.
# Columns: name, GTK and Cinnamon theme, icon theme, cursor theme, scheme.
LOOKS_TABLE='mint-green Mint-Y Mint-Y Bibata-Modern-Classic prefer-light
mint-green-dark Mint-Y-Dark Mint-Y Bibata-Modern-Ice prefer-dark
mint-aqua Mint-Y-Aqua Mint-Y-Aqua Bibata-Modern-Classic prefer-light
mint-aqua-dark Mint-Y-Dark-Aqua Mint-Y-Aqua Bibata-Modern-Ice prefer-dark
mint-blue Mint-Y-Blue Mint-Y-Blue Bibata-Modern-Classic prefer-light
mint-blue-dark Mint-Y-Dark-Blue Mint-Y-Blue Bibata-Modern-Ice prefer-dark
mint-grey Mint-Y-Grey Mint-Y-Grey Bibata-Modern-Classic prefer-light
mint-grey-dark Mint-Y-Dark-Grey Mint-Y-Grey Bibata-Modern-Ice prefer-dark
mint-orange Mint-Y-Orange Mint-Y-Orange Bibata-Modern-Classic prefer-light
mint-orange-dark Mint-Y-Dark-Orange Mint-Y-Orange Bibata-Modern-Ice prefer-dark
mint-pink Mint-Y-Pink Mint-Y-Pink Bibata-Modern-Classic prefer-light
mint-pink-dark Mint-Y-Dark-Pink Mint-Y-Pink Bibata-Modern-Ice prefer-dark
mint-purple Mint-Y-Purple Mint-Y-Purple Bibata-Modern-Classic prefer-light
mint-purple-dark Mint-Y-Dark-Purple Mint-Y-Purple Bibata-Modern-Ice prefer-dark
mint-red Mint-Y-Red Mint-Y-Red Bibata-Modern-Classic prefer-light
mint-red-dark Mint-Y-Dark-Red Mint-Y-Red Bibata-Modern-Ice prefer-dark
mint-sand Mint-Y-Sand Mint-Y-Sand Bibata-Modern-Classic prefer-light
mint-sand-dark Mint-Y-Dark-Sand Mint-Y-Sand Bibata-Modern-Ice prefer-dark
mint-teal Mint-Y-Teal Mint-Y-Teal Bibata-Modern-Classic prefer-light
mint-teal-dark Mint-Y-Dark-Teal Mint-Y-Teal Bibata-Modern-Ice prefer-dark'
look_names() { printf '%s\n' "$LOOKS_TABLE" | cut -d' ' -f1; }
looks_where() { printf '%s\n' "$LOOKS_TABLE" | awk -v col="$1" -v val="$2" '$col == val { print $1 }'; }   # looks naming <val> in column <col>
files_of_looks() { find "$SEED_PRESETS" -maxdepth 1 -name 'mint-*.conf' -printf '%f\n' | sed 's/\.conf$//' | sort; }
marks_of_looks() { run_official 'cm_state_get SEEDED_LOOKS ""' | tr ' ' '\n' | sed '/^$/d' | sort; }
[ "$(look_names | wc -l)" = 20 ] && [ "$(look_names | sort -u | wc -l)" = 20 ] || fail 'the table of looks does not hold twenty different names'

: > "$GS_LOG"; rm -rf "$SEED_HOME"
run_official cm_bootstrap_presets >"$TMP/looks.out" 2>&1 || fail 'the looks were not created on a system with the Mint packages'
[ ! -s "$TMP/looks.out" ] || fail "creating the looks printed something: $(cat "$TMP/looks.out")"
[ "$(files_of_looks)" = "$(look_names | sort)" ] || fail 'the looks created are not exactly the twenty of the table'
if find "$SEED_PRESETS" -type f ! -name '*.conf' | grep -q .; then fail 'creating the looks left a stray file in the presets folder'; fi

# Each file is exactly what the table says: five lines after the comment, in the order of the key table, the
# Cinnamon theme the same folder as the GTK theme (mint-themes carries both), mode 644.
while read -r name gtk icons cursor scheme; do
    printf '# Look "%s" - official Mint themes, icons and cursor; panel, fonts, accent and terminal stay as they are\nGTK_THEME="%s"\nICON_THEME="%s"\nCURSOR_THEME="%s"\nCINNAMON_THEME="%s"\nCOLOR_SCHEME="%s"\n' \
        "$name" "$gtk" "$icons" "$cursor" "$gtk" "$scheme" > "$TMP/expected-look.conf"
    cmp -s "$TMP/expected-look.conf" "$SEED_PRESETS/$name.conf" \
        || fail "the look '$name' is not what the table says: $(diff "$TMP/expected-look.conf" "$SEED_PRESETS/$name.conf" | tr '\n' ' ')"
    [ "$(stat -c %a "$SEED_PRESETS/$name.conf")" = 644 ] || fail "the look '$name' is not mode 644"
done <<< "$LOOKS_TABLE"
pass 'the twenty official looks are created with exactly the themes, cursor and scheme of the table'

# Every look validates with no refusal and no notice (no missing theme, no cursor without cursors/); the
# control is a look with a theme that is not there, which the same loop must report.
check_looks='c=0; for f in "$CM_PRESETS_DIR"/mint-*.conf; do n="${f##*/}"; n="${n%.conf}"; c=$((c+1))
    cm_preset_parse "$f" && cm_preset_validate "$n" && cm_preset_print_notes "$n" || echo "REFUSED $n"; done; echo "checked $c"'
[ "$(run_official "$check_looks" 2>&1)" = 'checked 20' ] || fail "a look is refused or draws a notice: $(run_official "$check_looks" 2>&1)"
write_preset_to() { printf '%s\n' "${@:2}" > "$SEED_PRESETS/$1.conf"; }
write_preset_to mint-zz-control 'GTK_THEME="Mint-Y-Gone"'
case "$(run_official "$check_looks" 2>&1)" in *'REFUSED mint-zz-control'*'checked 21'*) ;; *) fail 'control: the check of the looks does not report a look with a missing theme' ;; esac
rm -f "$SEED_PRESETS/mint-zz-control.conf"

# Loading one look writes its themes and the scheme and nothing else: no font, panel, accent or terminal key.
: > "$GS_LOG"; rm -f "$SEED_GS"/org.*
find "$OFFICIAL_HOME" | sort > "$TMP/look-home-before.txt"
run_official 'cm_load_preset mint-red-dark' >"$TMP/look-load.out" 2>&1 || fail "a look was refused: $(cat "$TMP/look-load.out")"
for pair in 'org.cinnamon.desktop.interface.gtk-theme Mint-Y-Dark-Red' 'org.cinnamon.desktop.wm.preferences.theme Mint-Y-Dark-Red' \
            'org.cinnamon.desktop.interface.icon-theme Mint-Y-Red' 'org.cinnamon.desktop.interface.cursor-theme Bibata-Modern-Ice' \
            'org.cinnamon.theme.name Mint-Y-Dark-Red' 'org.x.apps.portal.color-scheme prefer-dark'; do
    [ "$(cat "$SEED_GS/${pair%% *}" 2>/dev/null)" = "${pair#* }" ] || fail "loading mint-red-dark did not leave ${pair%% *} as ${pair#* }"
done
allowed='org.cinnamon.desktop.interface gtk-theme|org.cinnamon.desktop.wm.preferences theme|org.cinnamon.desktop.interface icon-theme|org.cinnamon.desktop.interface cursor-theme|org.gnome.desktop.interface cursor-theme|org.cinnamon.theme name|org.x.apps.portal color-scheme'
[ -z "$(grep '^set ' "$GS_LOG" | cut -d' ' -f2-3 | grep -vxE "$allowed")" ] \
    || fail "loading a look wrote more than its themes and scheme: $(grep '^set ' "$GS_LOG" | cut -d' ' -f2-3 | grep -vxE "$allowed" | tr '\n' ';')"
if grep -q '^dconf ' "$GS_LOG"; then fail 'loading a look touched the terminal'; fi
find "$OFFICIAL_HOME" | sort > "$TMP/look-home-after.txt"
cmp -s "$TMP/look-home-before.txt" "$TMP/look-home-after.txt" \
    || fail "loading a look changed the home (an editable Cinnamon copy is the accent's and the opacity's): $(diff "$TMP/look-home-before.txt" "$TMP/look-home-after.txt" | tr '\n' ' ')"
pass 'every look validates with no notice, and loading one writes its themes and scheme only'

# Created once: running again changes nothing (files, marks and state), and each name is marked once.
cp -a "$SEED_HOME" "$TMP/looks-before"
run_official cm_bootstrap_presets >/dev/null 2>&1 || fail 'a second run failed'
diff -r "$TMP/looks-before" "$SEED_HOME" >/dev/null || fail 'a second run changed the presets or the state'
[ "$(marks_of_looks)" = "$(look_names | sort)" ] || fail 'the marks are not the twenty looks'
[ "$(run_official 'cm_state_get SEEDED_LOOKS ""' | tr ' ' '\n' | sort | uniq -d | wc -l)" = 0 ] || fail 'a look is marked twice'
rm -rf "$TMP/looks-before"

# A look the user deleted is not created again (its mark stays); one the user edited is kept as it is.
rm -f "$SEED_PRESETS/mint-red.conf"
printf '# mine\nGTK_THEME="Mint-Y-Aqua"\n' > "$SEED_PRESETS/mint-blue.conf"
cp "$SEED_PRESETS/mint-blue.conf" "$TMP/blue-edited.conf"
run_official cm_bootstrap_presets >/dev/null 2>&1 || fail 'the run after a deletion failed'
[ ! -e "$SEED_PRESETS/mint-red.conf" ] || fail 'a look the user deleted was created again'
cmp -s "$TMP/blue-edited.conf" "$SEED_PRESETS/mint-blue.conf" || fail 'a look the user edited was overwritten'
[ "$(marks_of_looks | grep -cx 'mint-red')" = 1 ] || fail 'the mark of a deleted look was lost'
[ "$(files_of_looks | wc -l)" = 19 ] || fail 'a run after a deletion changed the number of looks'

# A link in place of a look is not replaced and not written through, whatever it points to; it counts as
# the user's own look, so the look is marked and a link to nothing does not get a file made at its end.
rm -rf "$SEED_HOME"; mkdir -p "$SEED_PRESETS" "$TMP/elsewhere"
printf 'precious\n' > "$TMP/elsewhere/sand-target.conf"
ln -s "$TMP/elsewhere/sand-target.conf" "$SEED_PRESETS/mint-sand.conf"
ln -s "$TMP/elsewhere/not-there.conf" "$SEED_PRESETS/mint-teal.conf"
run_official cm_bootstrap_presets >/dev/null 2>&1 || fail 'the run with links in the presets folder failed'
[ "$(readlink "$SEED_PRESETS/mint-sand.conf")" = "$TMP/elsewhere/sand-target.conf" ] && [ -L "$SEED_PRESETS/mint-sand.conf" ] || fail 'a link in place of a look was replaced'
[ "$(cat "$TMP/elsewhere/sand-target.conf")" = precious ] || fail 'a look was written through a link'
[ -L "$SEED_PRESETS/mint-teal.conf" ] && [ ! -e "$TMP/elsewhere/not-there.conf" ] || fail 'a link to nothing was replaced or written through'
[ "$(files_of_looks | wc -l)" = 20 ] && [ "$(marks_of_looks)" = "$(look_names | sort)" ] || fail 'the links left the looks or the marks incomplete'
pass 'a look is created once: not again, not after a deletion, not over an edit or a link'

# The catalogs are read once per run, and only when a look has still to be created: this runs on every start.
count_scans() {   # count_scans <dirs>: a bootstrap whose four catalog functions record each call
    : > "$TMP/scans.log"
    OFFICIAL_DIRS="$1" run_official "for f in cm_list_gtk_themes cm_list_cinnamon_themes cm_list_icon_themes cm_list_cursor_themes; do
        eval \"real_\$(declare -f \"\$f\")\"; eval \"\$f() { echo \$f >> '$TMP/scans.log'; real_\$f; }\"; done; cm_bootstrap_presets" >/dev/null 2>&1 \
        || fail 'a bootstrap that counts catalog reads failed'
    sort "$TMP/scans.log" | uniq -c | sed 's/^ *//' | tr '\n' ';'
}
rm -rf "$SEED_HOME"
[ "$(count_scans "$OFFICIAL")" = '1 cm_list_cinnamon_themes;1 cm_list_cursor_themes;1 cm_list_gtk_themes;1 cm_list_icon_themes;' ] \
    || fail "creating twenty looks did not read each catalog once: $(count_scans "$OFFICIAL")"
[ -z "$(count_scans "$OFFICIAL")" ] || fail 'a run with every look already marked read the catalogs'
rm -rf "$SEED_HOME"
[ "$(count_scans "$TMP/no-mint/share")" = '1 cm_list_cinnamon_themes;1 cm_list_cursor_themes;1 cm_list_gtk_themes;1 cm_list_icon_themes;' ] \
    || fail 'a system without the Mint packages did not read each catalog once'
pass 'the catalogs are read once per run, and not at all when every look is already marked'

# Partial installs: a look is created only if the catalogs offer all four of its themes. The looks that must
# be missing come from the table (the looks that name the broken theme); a mark exists exactly for the looks
# that exist; and completing the install later creates the rest without touching what was made.
partial() {   # partial <what is broken> <snippet that breaks a copy of the tree> <the looks that must be missing>
    local label="$1" mutate="$2" missing="$3" p="$TMP/partial" want got
    rm -rf "$p" "$SEED_HOME"; mkdir -p "$p"; cp -a "$OFFICIAL" "$p/share"
    (cd "$p/share" && eval "$mutate") || fail "partial install ($label): the tree was not broken"
    want="$(comm -23 <(look_names | sort) <(printf '%s\n' "$missing" | sort))"
    OFFICIAL_DIRS="$p/share" run_official cm_bootstrap_presets >/dev/null 2>&1 || fail "partial install ($label): the bootstrap failed"
    got="$(files_of_looks)"
    [ "$got" = "$want" ] || fail "partial install ($label): the looks created differ from the expected: $(diff <(echo "$want") <(echo "$got") | tr '\n' ' ')"
    [ "$(marks_of_looks)" = "$want" ] || fail "partial install ($label): a look is marked without having been created, or created without a mark"
    for seed in default nord-dark; do [ -f "$SEED_PRESETS/$seed.conf" ] || fail "partial install ($label): the seed '$seed' is missing"; done
    if find "$SEED_PRESETS" -type f ! -name '*.conf' | grep -q .; then fail "partial install ($label): a stray file was left"; fi
    (cd "$SEED_PRESETS" && sha256sum mint-*.conf 2>/dev/null) > "$TMP/partial-before.sum" || true
    OFFICIAL_DIRS="$p/share" run_official cm_bootstrap_presets >/dev/null 2>&1 || fail "partial install ($label): the second run failed"
    [ "$(files_of_looks)" = "$want" ] || fail "partial install ($label): a second run changed the looks"
    OFFICIAL_DIRS="$OFFICIAL" run_official cm_bootstrap_presets >/dev/null 2>&1 || fail "partial install ($label): the run after completing the install failed"
    [ "$(files_of_looks)" = "$(look_names | sort)" ] && [ "$(marks_of_looks)" = "$(look_names | sort)" ] \
        || fail "partial install ($label): completing the install did not create the missing looks"
    [ ! -s "$TMP/partial-before.sum" ] || (cd "$SEED_PRESETS" && sha256sum -c --quiet "$TMP/partial-before.sum") >/dev/null 2>&1 \
        || fail "partial install ($label): completing the install changed a look already made"
}
DARK_LOOKS="$(looks_where 5 prefer-dark)"
partial 'no mint-themes' 'rm -rf themes/Mint-Y*' "$(look_names)"
partial 'no mint-y-icons' 'rm -rf icons/Mint-Y*' "$(look_names)"
partial 'no mint-cursor-themes' 'rm -rf icons/Bibata-* icons/GoogleDot-* icons/XCursor-*' "$(look_names)"
partial 'Bibata-Modern-Ice missing' 'rm -rf icons/Bibata-Modern-Ice' "$DARK_LOOKS"
partial 'Bibata-Modern-Ice without cursors/' 'rm -rf icons/Bibata-Modern-Ice/cursors' "$DARK_LOOKS"
partial 'no dark GTK themes' 'rm -rf themes/Mint-Y-Dark*' "$DARK_LOOKS"
partial 'GTK theme without gtk.css' 'rm -f themes/Mint-Y-Teal/gtk-3.0/gtk.css' "$(looks_where 2 Mint-Y-Teal)"
partial 'theme without cinnamon/' 'rm -rf themes/Mint-Y-Dark-Sand/cinnamon' "$(looks_where 2 Mint-Y-Dark-Sand)"
partial 'icons without index.theme' 'rm -f icons/Mint-Y-Pink/index.theme' "$(looks_where 3 Mint-Y-Pink)"
partial 'icons hidden by Hidden=true' "printf '[Icon Theme]\\nHidden=true\\nDirectories=16x16/apps\\n' > icons/Mint-Y-Purple/index.theme" "$(looks_where 3 Mint-Y-Purple)"
# Only the Aqua colour installed: a name that is the start of another (Mint-Y of Mint-Y-Aqua) is not the same theme.
partial 'only the Aqua colour' 'find themes icons -mindepth 1 -maxdepth 1 -name "Mint-Y*" ! -name "*Aqua" -exec rm -rf {} +' \
    "$(look_names | grep -vxE 'mint-aqua|mint-aqua-dark')"
# The first of these must hold the broken tree itself, so the checks above cannot pass on a tree that was not broken.
[ "$(find "$TMP/partial/share/themes" -maxdepth 1 -name 'Mint-Y*' | wc -l)" = 2 ] || fail 'control: the Aqua-only tree is not the one the case describes'
pass 'a look is created only when the catalogs offer all its themes; marks follow the looks; completing the install adds the rest'

# --- sharing: a preset leaves and enters as a file ----------------------------------------------------
# Export copies a saved preset out; import stores one someone shared. Both read it as data and need valid
# values; a theme this system lacks is only a notice (loading it later is refused and names it). Import
# never applies anything, never overwrites, and no name or path can leave the presets folder.
SHARE="$TMP/share"
mkdir -p "$SHARE/in" "$SHARE/out"
rm -f "$PRESETS"/*.conf
write_preset mylook '# my look' 'GTK_THEME="Mint-Y-Aqua"' 'ICON_THEME="Mint-Y-Aqua"' 'CURSOR_THEME="Bibata-Modern-Classic"' 'COLOR_SCHEME="prefer-dark"'

run_cm "cm_export_preset mylook '$SHARE/out/shared.conf'" >/dev/null 2>&1 || fail 'a valid preset was not exported'
cmp -s "$PRESETS/mylook.conf" "$SHARE/out/shared.conf" || fail 'the exported file differs from the preset'
[ "$(stat -c %a "$SHARE/out/shared.conf")" = 644 ] || fail 'the exported file must be readable by whoever receives it (mode 644)'
run_cm "cm_export_preset mylook '$SHARE/out'" >/dev/null 2>&1 || fail 'exporting into a folder failed'
cmp -s "$PRESETS/mylook.conf" "$SHARE/out/mylook.conf" || fail 'exporting into a folder did not name the file after the preset'

printf precious > "$SHARE/out/keep.conf"
must_fail run_cm "cm_export_preset mylook '$SHARE/out/keep.conf'" >/dev/null 2>&1
[ "$(cat "$SHARE/out/keep.conf")" = precious ] || fail 'export overwrote an existing file'
ln -s "$SHARE/out/keep.conf" "$SHARE/out/dangling.conf"
must_fail run_cm "cm_export_preset mylook '$SHARE/out/dangling.conf'" >/dev/null 2>&1
[ "$(cat "$SHARE/out/keep.conf")" = precious ] || fail 'export wrote through a symbolic link'
err="$(run_cm "cm_export_preset mylook '$SHARE/out/keep.conf'" 2>&1 >/dev/null)" || true
case "$err" in *"already exists"*) ;; *) fail "the refusal to overwrite does not say so: $err" ;; esac

write_preset foreign 'GTK_THEME="Not-Installed-Here"'
run_cm "cm_export_preset foreign '$SHARE/out/foreign.conf'" >/dev/null 2>&1 || fail 'a look for another system (themes missing here) must be exportable'
write_preset badvalue 'CURSOR_SIZE="999"'
must_fail run_cm "cm_export_preset badvalue '$SHARE/out/badvalue.conf'" >/dev/null 2>&1
write_preset junk 'touch "$HOME/pwn"'
must_fail run_cm "cm_export_preset junk '$SHARE/out/junk.conf'" >/dev/null 2>&1
[ ! -e "$SHARE/out/badvalue.conf" ] && [ ! -e "$SHARE/out/junk.conf" ] || fail 'a preset that is not valid was exported'
for bad in ../x a/b .hidden; do must_fail run_cm "cm_export_preset '$bad' '$SHARE/out/z.conf'" >/dev/null 2>&1; done
must_fail run_cm "cm_export_preset nothere '$SHARE/out/z.conf'" >/dev/null 2>&1
must_fail run_cm 'cm_export_preset mylook' >/dev/null 2>&1
must_fail run_cm 'cm_export_preset' >/dev/null 2>&1
[ ! -e "$SHARE/out/z.conf" ] || fail 'export created a file for a refused request'

# Import: a file that parses and has valid values is stored as it is, and never applied.
cp "$PRESETS/mylook.conf" "$SHARE/in/shared.conf"
: > "$GS_LOG"
out="$(run_cm "cm_import_preset '$SHARE/in/shared.conf'" 2>"$TMP/import.err")" || fail "a valid preset was not imported: $(cat "$TMP/import.err")"
case "$out" in *"imported as 'shared'"*"preset load shared"*) ;; *) fail "the import does not say what it stored and how to apply it: $out" ;; esac
cmp -s "$SHARE/in/shared.conf" "$PRESETS/shared.conf" || fail 'the imported preset differs from the file'
[ "$(stat -c %a "$PRESETS/shared.conf")" = 644 ] || fail 'the imported preset must have mode 644'
[ ! -s "$TMP/import.err" ] || fail "an import with nothing to report printed on stderr: $(cat "$TMP/import.err")"
[ ! -s "$GS_LOG" ] || fail "importing a preset reached the desktop: $(cat "$GS_LOG")"
run_cm "cm_import_preset '$SHARE/in/shared.conf' renamed" >/dev/null 2>&1 || fail 'importing under another name failed'
cmp -s "$SHARE/in/shared.conf" "$PRESETS/renamed.conf" || fail 'the preset imported under another name differs'
printf 'GTK_THEME="Mint-Y-Dark-Aqua"\n' > "$SHARE/in/other.conf"
must_fail run_cm "cm_import_preset '$SHARE/in/other.conf' shared" >/dev/null 2>&1
cmp -s "$SHARE/in/shared.conf" "$PRESETS/shared.conf" || fail 'a second import replaced a preset that already existed'

# Hostile or broken files: nothing is stored, nothing runs, and the reason names the line or the key.
import_fails() {   # import_fails <expected text in the error> <line>...
    local expect="$1" got; shift
    printf '%s\n' "$@" > "$SHARE/in/bad.conf"
    if got="$(run_cm "cm_import_preset '$SHARE/in/bad.conf'" 2>&1)"; then fail "an invalid preset was imported: $*"; fi
    case "$got" in *"$expect"*) ;; *) fail "the import error for '$*' lacks '$expect': $got" ;; esac
    [ ! -e "$PRESETS/bad.conf" ] || fail "an invalid preset was stored: $*"
}
import_fails 'line 1' 'GTK_THEME="Mint-Y-Aqua"; touch "$HOME/pwn"'
import_fails 'line 1' 'GTK_THEME="$(touch "$HOME/pwn")"'
import_fails 'disallowed characters' 'GTK_THEME="$(touch pwn)"'
import_fails 'disallowed characters' 'GTK_THEME="`touch pwn`"'
import_fails 'unknown key: NO_SUCH_KEY' 'NO_SUCH_KEY="x"'
import_fails 'line 1' 'touch "$HOME/pwn"'
import_fails "CURSOR_SIZE: '999' is not a valid value" 'CURSOR_SIZE="999"'
import_fails "PANEL_POSITION: 'middle' is not a valid value" 'GTK_THEME="Mint-Y-Aqua"' 'PANEL_POSITION="middle"'
import_fails 'go together' 'FONT_ANTIALIAS="grayscale"'
: > "$SHARE/in/empty.conf"
must_fail run_cm "cm_import_preset '$SHARE/in/empty.conf'" >/dev/null 2>&1
printf '# only a comment\n' > "$SHARE/in/comments.conf"
must_fail run_cm "cm_import_preset '$SHARE/in/comments.conf'" >/dev/null 2>&1
[ ! -e "$HOME_DIR/pwn" ] || fail 'a hostile preset ran code'

# Size: only the 64 KB limit tells these two valid files apart (comments pad them). yes stderr is dropped: with
# SIGPIPE ignored (CI runners) it prints "Broken pipe" once head has its bytes.
{ printf 'GTK_THEME="Mint-Y-Aqua"\n'; head -c 60000 < <(yes '# padding' 2>/dev/null); printf '\n'; } > "$SHARE/in/medium.conf"
run_cm "cm_import_preset '$SHARE/in/medium.conf'" >/dev/null 2>&1 || fail 'a valid preset of 60 KB was refused'
{ printf 'GTK_THEME="Mint-Y-Aqua"\n'; head -c 70000 < <(yes '# padding' 2>/dev/null); printf '\n'; } > "$SHARE/in/big.conf"
err="$(run_cm "cm_import_preset '$SHARE/in/big.conf'" 2>&1)" && fail 'a preset larger than 64 KB was imported'
case "$err" in *"64 KB"*) ;; *) fail "the refusal for a big preset does not say why: $err" ;; esac
[ ! -e "$PRESETS/big.conf" ] || fail 'a big preset was stored'

# Where it comes from and what it is called.
ln -s "$SHARE/in/shared.conf" "$SHARE/in/link.conf"
must_fail run_cm "cm_import_preset '$SHARE/in/link.conf'" >/dev/null 2>&1
mkdir -p "$SHARE/in/dir.conf"
must_fail run_cm "cm_import_preset '$SHARE/in/dir.conf'" >/dev/null 2>&1
must_fail run_cm "cm_import_preset '$SHARE/in/missing.conf'" >/dev/null 2>&1
must_fail run_cm 'cm_import_preset' >/dev/null 2>&1
for bad in ../escape a/b .hidden; do must_fail run_cm "cm_import_preset '$SHARE/in/shared.conf' '$bad'" >/dev/null 2>&1; done
[ ! -e "$CM_STATE/escape.conf" ] && [ ! -e "$PRESETS/.hidden.conf" ] || fail 'a name left the presets folder'
[ -z "$(find "$PRESETS" -name '.import.*' -o -name '.*.tmp.*')" ] || fail 'the import left temporary files'

# A look for another system: stored, with a notice naming what is missing; loading it is refused whole.
write_preset tmp 'GTK_THEME="Not-Installed-Here"' 'ICON_THEME="Also-Missing"' 'CURSOR_THEME="Mint-Y-Aqua"'
cp "$PRESETS/tmp.conf" "$SHARE/in/visitor.conf"; rm -f "$PRESETS/tmp.conf"
: > "$GS_LOG"
run_cm "cm_import_preset '$SHARE/in/visitor.conf'" >/dev/null 2>"$TMP/import.err" || fail "a preset that names missing themes was refused: $(cat "$TMP/import.err")"
for said in "Notes on the preset 'visitor'" "GTK_THEME: 'Not-Installed-Here' is not installed" "ICON_THEME: 'Also-Missing' is not installed" \
    "CURSOR_THEME: 'Mint-Y-Aqua' is not a cursor theme"; do
    grep -qF "$said" "$TMP/import.err" || fail "the import notice lacks: $said ($(cat "$TMP/import.err"))"
done
cmp -s "$SHARE/in/visitor.conf" "$PRESETS/visitor.conf" || fail 'the preset with missing themes was not stored as it came'
err="$(run_cm 'cm_load_preset visitor' 2>&1 >/dev/null)" && fail 'a preset with missing themes was applied'
case "$err" in *"GTK_THEME: 'Not-Installed-Here' is not installed"*"nothing was changed"*|*"nothing was changed"*"GTK_THEME: 'Not-Installed-Here' is not installed"*) ;; *) fail "loading the imported preset does not name what is missing: $err" ;; esac
[ ! -s "$GS_LOG" ] || fail "an imported preset with missing themes reached the desktop: $(cat "$GS_LOG")"

# Measured with libXcursor 1.2.1 (the one in Mint 22.x): a theme with no cursors/ resolves to what it
# inherits and otherwise to the "default" theme, so the pointer is never lost, only not the one named. That
# is not a reason to refuse it (a user may have set it, and the Themes tab re-applies the current one), but
# the setter and the presets say so instead of reporting a cursor that is not shown.
err="$(run_cm 'cm_apply_cursor_theme Mint-Y-Aqua' 2>&1 >/dev/null)" || fail 'a cursor theme with no cursors/ must still be accepted'
case "$err" in *"'Mint-Y-Aqua' has no cursors of its own"*) ;; *) fail "the setter does not say the cursor theme has no cursors: $err" ;; esac
err="$(run_cm 'cm_apply_cursor_theme Bibata-Modern-Classic' 2>&1 >/dev/null)" || fail 'a real cursor theme was refused'
[ -z "$err" ] || fail "a real cursor theme drew a notice: $err"
write_preset oldcursor 'GTK_THEME="Mint-Y-Aqua"' 'CURSOR_THEME="Mint-Y-Aqua"'
err="$(run_cm 'cm_load_preset oldcursor' 2>&1 >/dev/null)" || fail 'a preset naming a cursor theme with no cursors/ must still load'
case "$err" in *"CURSOR_THEME: 'Mint-Y-Aqua' is not a cursor theme"*) ;; *) fail "loading does not note the cursor theme: $err" ;; esac
write_preset goodcursor 'GTK_THEME="Mint-Y-Aqua"' 'CURSOR_THEME="Bibata-Modern-Classic"'
err="$(run_cm 'cm_load_preset goodcursor' 2>&1 >/dev/null)" || fail 'a preset with a real cursor theme failed to load'
[ -z "$err" ] || fail "a preset with a real cursor theme drew a notice: $err"

# A full round trip: every key of the table goes out and comes back identical, and a look loads after it.
write_preset trip "${FULL[@]}"
cp "$PRESETS/trip.conf" "$TMP/trip-original.conf"
run_cm "cm_export_preset trip '$SHARE/out/trip.conf'" >/dev/null 2>&1 || fail 'the full preset was not exported'
rm -f "$PRESETS/trip.conf"
run_cm "cm_import_preset '$SHARE/out/trip.conf'" >/dev/null 2>&1 || fail 'the exported full preset was not imported back'
cmp -s "$TMP/trip-original.conf" "$PRESETS/trip.conf" || fail 'the preset that went out and came back is not the same'
run_cm "cm_export_preset mylook '$SHARE/out/mylook-again.conf'" >/dev/null 2>&1 || fail 'the look was not exported'
rm -f "$PRESETS/mylook.conf"
run_cm "cm_import_preset '$SHARE/out/mylook-again.conf' mylook" >/dev/null 2>&1 || fail 'the look was not imported back'
run_cm 'cm_load_preset mylook' >/dev/null 2>"$TMP/trip.err" || fail "the look that went out and came back does not load: $(cat "$TMP/trip.err")"

# The command line reaches both, in both languages, and the help lists them.
CLI_HOME="$TMP/cli-home"
cli() { HOME="$HOME_DIR" CM_HOME="$CLI_HOME" XDG_DATA_HOME="$XDG_HOME" XDG_DATA_DIRS="$SYS_DIR" PATH="$MOCK:$PATH" \
    GS_STATE="$GS_STATE" GS_LOG="$GS_LOG" CM_LANG_OVERRIDE="${CM_TEST_LANG:-en}" bash "$SCRIPT" "$@"; }
cli preset import "$SHARE/in/shared.conf" cli-copy >/dev/null 2>&1 || fail 'the command line did not import the preset'
cmp -s "$SHARE/in/shared.conf" "$CLI_HOME/presets/cli-copy.conf" || fail 'the command line stored something else'
cli preset export cli-copy "$SHARE/out/from-cli.conf" >/dev/null 2>&1 || fail 'the command line did not export the preset'
cmp -s "$SHARE/in/shared.conf" "$SHARE/out/from-cli.conf" || fail 'the command line exported something else'
for lang in en es; do
    help_text="$(CM_TEST_LANG=$lang cli --help 2>&1)" || fail "the $lang help failed"
    for command in 'preset export' 'preset import'; do
        case "$help_text" in *"$command"*) ;; *) fail "the $lang help does not list: $command" ;; esac
    done
done
pass 'presets are exported and imported as files: validated, never applied, never overwritten, kept inside their folder'

printf 'All preset tests passed.\n'
