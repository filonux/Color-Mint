#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sandbox.sh
. "$ROOT/tests/lib/sandbox.sh"
SCRIPT="$ROOT/script/color-mint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

[ -f "$SCRIPT" ] || fail "script missing"
bash -n "$SCRIPT"
pass "bash syntax"

mapfile -t metadata_header < <(sed -n '2,7p' "$SCRIPT")
expected_metadata=(
    '# MENU: Color Mint'
    '# DESCRIPTION: Advanced visual customization for Linux Mint Cinnamon'
    '# CONFIRM: false'
    '# TERMINAL: false'
    '# SUDO: false'
    '# ICON: ../assets/icon.png'
)
[ "${#metadata_header[@]}" -eq "${#expected_metadata[@]}" ] || fail "Scriptya metadata header length"
for i in "${!expected_metadata[@]}"; do
    [ "${metadata_header[$i]}" = "${expected_metadata[$i]}" ] || fail "Scriptya metadata header"
done
[ -f "$ROOT/assets/icon.png" ] || fail "Scriptya metadata icon path"
pass "Scriptya metadata header"

version_home="$TMP/home-version"
version_state="$TMP/state-version"
version_bin="$TMP/version-bin"
mkdir -p "$version_home" "$version_state" "$version_bin"
printf 'home sentinel\n' > "$version_home/sentinel"
printf 'state sentinel\n' > "$version_state/sentinel"
printf '%s\n' '#!/usr/bin/env bash' 'touch "${CM_VERSION_UNEXPECTED_CALL:?}"' > "$version_bin/gsettings"
printf '%s\n' '#!/usr/bin/env bash' 'touch "${CM_VERSION_UNEXPECTED_CALL:?}"' > "$version_bin/dconf"
printf '%s\n' '#!/usr/bin/env bash' 'touch "${CM_VERSION_UNEXPECTED_CALL:?}"' > "$version_bin/gdbus"
printf '%s\n' '#!/usr/bin/env bash' 'touch "${CM_VERSION_UNEXPECTED_CALL:?}"' > "$version_bin/yad"
chmod +x "$version_bin"/*
version_home_hash="$(sha256sum "$version_home/sentinel" | cut -d' ' -f1)"
version_state_hash="$(sha256sum "$version_state/sentinel" | cut -d' ' -f1)"
version_err="$TMP/version-stderr"
version_out="$(PATH="$version_bin:$PATH" HOME="$version_home" CM_HOME="$version_state" CM_LANG_OVERRIDE=es CM_VERSION_UNEXPECTED_CALL="$TMP/unexpected" bash "$SCRIPT" --version 2>"$version_err")"
[ "$version_out" = 'Color Mint 3.1.0' ] || fail "--version output"
[ ! -s "$version_err" ] || fail "--version emitted diagnostics"
[ ! -e "$TMP/unexpected" ] || fail "--version queried a desktop backend"
[ "$(sha256sum "$version_home/sentinel" | cut -d' ' -f1)" = "$version_home_hash" ] || fail "--version changed HOME"
[ "$(sha256sum "$version_state/sentinel" | cut -d' ' -f1)" = "$version_state_hash" ] || fail "--version changed state"
pass "version output and side-effect guard"

help_read_only() {
    local option="$1" locale="$2" label="$3"
    local home="$TMP/help-home-$label" state="$TMP/help-state-$label"
    mkdir -p "$home"
    printf 'home sentinel\n' > "$home/sentinel"
    local home_hash err out
    home_hash="$(sha256sum "$home/sentinel" | cut -d' ' -f1)"
    err="$TMP/help-stderr-$label"
    out="$(env -u LC_ALL -u LC_MESSAGES LANG="$locale" HOME="$home" CM_HOME="$state" bash "$SCRIPT" "$option" 2>"$err")"
    [ -s "$home/sentinel" ] || fail "help changed HOME"
    [ "$(sha256sum "$home/sentinel" | cut -d' ' -f1)" = "$home_hash" ] || fail "help changed HOME sentinel"
    [ ! -e "$state" ] || fail "help created persistent state ($option)"
    [ ! -s "$err" ] || fail "help emitted diagnostics ($option)"
    [[ "$out" == *"MODO GRÁFICO"* || "$label" = en ]] || fail "Spanish help ($option)"
    [[ "$out" == *"GRAPHICAL MODE"* || "$label" = es ]] || fail "English help ($option)"
}

help_read_only --help es_ES.UTF-8 es
help_read_only -h C.UTF-8 en
pass "CLI help is read-only"

run() {
    local lang="$1" home="$TMP/home-$1" state="$TMP/state-$1"
    mkdir -p "$home"
    HOME="$home" CM_HOME="$state" CM_LANG_OVERRIDE="$lang" bash "$SCRIPT" --help
}

es="$(run es)"
en="$(run en)"
[[ "$es" == *"MODO GRÁFICO"* && "$es" == *"Idioma"* ]] || fail "Spanish help"
[[ "$en" == *"GRAPHICAL MODE"* && "$en" == *"Language"* ]] || fail "English help"
[[ "$es" != *"GRAPHICAL MODE"* ]] || fail "Spanish help contains English heading"
[[ "$en" != *"MODO GRÁFICO"* ]] || fail "English help contains Spanish heading"
pass "CLI language output"

# Translation integrity: keys, printf placeholders and Pango tags must stay valid in both languages.
I18N_BODY="$TMP/i18n-body.sh"
awk '/^# Command-line dispatcher/{exit} {print}' "$SCRIPT" > "$I18N_BODY"
cat > "$TMP/i18n-check.sh" <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
count_fixed() { local v="$1" token="$2"; printf '%s' "$v" | grep -oF "$token" | wc -l || true; }
for key in "${!CM_TEXT_ES[@]}"; do
    [ -n "${CM_TEXT_EN[$key]+x}" ] || { echo "missing EN key: $key" >&2; exit 1; }
    es="${CM_TEXT_ES[$key]}"; en="${CM_TEXT_EN[$key]}"
    [ "$(count_fixed "$es" '%s')" -eq "$(count_fixed "$en" '%s')" ] || { echo "printf %s mismatch: $key" >&2; exit 1; }
    [ "$(count_fixed "$es" '%%')" -eq "$(count_fixed "$en" '%%')" ] || { echo "printf %% mismatch: $key" >&2; exit 1; }
    for v in "$es" "$en"; do
        [ "$(count_fixed "$v" '<b>')" -eq "$(count_fixed "$v" '</b>')" ] || { echo "unbalanced b tag: $key" >&2; exit 1; }
        [ "$(count_fixed "$v" '<span ')" -eq "$(count_fixed "$v" '</span>')" ] || { echo "unbalanced span tag: $key" >&2; exit 1; }
    done
done
[ "${#CM_TEXT_ES[@]}" -eq "${#CM_TEXT_EN[@]}" ] || { echo 'translation key count mismatch' >&2; exit 1; }
[[ "${CM_TEXT_ES[ui_button_values]}" == *'":"'* ]] || { echo 'Spanish ui_button_values quotes lost' >&2; exit 1; }
[[ "${CM_TEXT_EN[ui_button_values]}" == *'":"'* ]] || { echo 'English ui_button_values quotes lost' >&2; exit 1; }
[[ "${CM_TEXT_ES[u_terminal_custom]}" == *'""'* ]] || { echo 'Spanish terminal help placeholder truncated' >&2; exit 1; }
[[ "${CM_TEXT_EN[u_terminal_custom]}" == *'""'* ]] || { echo 'English terminal help placeholder truncated' >&2; exit 1; }
[ "${CM_TEXT_ES[light_mode]}" = 'Claro' ] || { echo 'Spanish light-mode label' >&2; exit 1; }
[ "${CM_TEXT_EN[light_mode]}" = 'Light' ] || { echo 'English light-mode label' >&2; exit 1; }
[[ "${CM_TEXT_ES[scaling_invalid]}" == *'(%).' ]] || { echo 'Spanish scaling message has the wrong percent escaping' >&2; exit 1; }
[[ "${CM_TEXT_EN[scaling_invalid]}" == *'(%).' ]] || { echo 'English scaling message has the wrong percent escaping' >&2; exit 1; }
echo 'PASS: translation keys, printf placeholders and Pango markup'
CHECK
chmod +x "$TMP/i18n-check.sh"
bash "$TMP/i18n-check.sh" "$I18N_BODY"
python3 - "$SCRIPT" "$I18N_BODY" <<'PYFMT'
import pathlib, re, subprocess, sys
script=pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
body_path=pathlib.Path(sys.argv[2])
body=body_path.read_text(encoding='utf-8')
cmd='source "$1"; for k in "${!CM_TEXT_EN[@]}"; do printf "%s\t%s\n" "$k" "${CM_TEXT_EN[$k]}"; done'
vals=dict(x.split('\t',1) for x in subprocess.check_output(['bash','-c',cmd,'bash',str(body_path)],text=True).splitlines())
for n,line in enumerate(script.splitlines(),1):
    for key in re.findall(r'cm_t\s+([A-Za-z0-9_]+)',line):
        v=vals.get(key,'')
        if ('%s' in v or '%%' in v) and f'printf "$(cm_t {key})"' not in line:
            raise SystemExit(f'formatted translation used without printf at line {n}: {key}')
print('PASS: formatted translations are only used through printf')
PYFMT

# GUI apply actions must protect changes with a backup and propagate failures.
GUI_BODY="$TMP/gui-body.sh"
awk '/^# Command-line dispatcher/{exit} {print}' "$SCRIPT" > "$GUI_BODY"
export GUI_BODY
HOME="$TMP/gui-home" CM_HOME="$TMP/gui-state" CM_LANG_OVERRIDE=en bash -c '
    source "$GUI_BODY"
    CM_LANG=en
    cm_apply_language_labels
    cm_backup_current() { return 17; }
    yad() { return 0; }
    cm_notify_applied() { :; }
    must_fail cm_ui_apply_themes_apply "" "" "" "" "" "" ""
    must_fail cm_ui_apply_panel_apply "" "" "" "" ""
    must_fail cm_ui_apply_desktop_apply "" "" "" "" "" "" "" ""
    must_fail cm_ui_apply_advanced_apply "" "" "" "" "" FALSE
    cm_confirm() { return 0; }
    cm_panel_reset_pending() { return 0; }
    must_fail cm_ui_apply_panel_reset
    must_fail cm_ui_apply_terminal_apply "" "" "" TRUE
    must_fail cm_ui_apply_fonts_apply "" "" "" "" ""
'
pass "GUI apply actions refuse changes when backup creation fails"

HOME="$TMP/gui-report" CM_HOME="$TMP/gui-report-state" CM_LANG_OVERRIDE=en bash -c '
    source "$GUI_BODY"
    CM_LANG=en
    cm_apply_language_labels
    applied=()
    failing_backend() { printf "%s\n" "ERROR: backend failed"; return 7; }
    must_fail cm_report "Panel: #112233" failing_backend
    [ "${#applied[@]}" -eq 1 ]
    [[ "${applied[0]}" == *"was not applied"* ]]
'
pass "cm_report preserves failure status and warning details"

# A warning from a command that worked is shown too: one line each, with a warning sign and without its prefix. Only a
# line that starts with the prefix counts; a failure keeps its single line.
HOME="$TMP/gui-report-warn" CM_HOME="$TMP/gui-report-warn-state" CM_LANG_OVERRIDE=en bash -c '
    source "$GUI_BODY"
    CM_LANG=en
    cm_apply_language_labels
    quiet() { printf "%s\n" "Done: all of it"; }
    chatty() { printf "%s\n" "WARNING: the first thing" "ADVERTENCIA: la segunda cosa" "a WARNING: inside a line" "ERROR: not a warning here"; }
    broken() { printf "%s\n" "WARNING: before the error" "ERROR: it failed"; return 3; }
    applied=(); cm_report "Quiet: 1" quiet
    [ "${#applied[@]}" -eq 1 ] && [ "${applied[0]}" = "Quiet: 1" ]
    applied=(); cm_report "Chatty: 2" chatty
    [ "${#applied[@]}" -eq 3 ]
    [ "${applied[0]}" = "Chatty: 2" ] && [ "${applied[1]}" = "⚠ the first thing" ] && [ "${applied[2]}" = "⚠ la segunda cosa" ]
    applied=(); must_fail cm_report "Broken: 3" broken
    [ "${#applied[@]}" -eq 1 ] && [[ "${applied[0]}" == "⚠ Broken was not applied — "* ]]
'
pass "cm_report shows the warnings of a command that worked, and only those"

HOME="$TMP/gui-home-status" CM_HOME="$TMP/gui-state-status" CM_LANG_OVERRIDE=en bash -c '
    source "$GUI_BODY"
    CM_LANG=en
    cm_apply_language_labels
    applied=()
    cm_report() { applied+=("warning"); return 23; }
    cm_backup_current() { return 0; }
    cm_reload_cinnamon() { :; }
    cm_notify_applied() { printf "%s\n" "$*" >"$CM_HOME/notification"; }
    must_fail cm_ui_apply_panel_apply "${CM_COLOR_TARGET_LABELS[accent]}" "${CM_ACCENT_PRESET_LABELS[custom]}" "#112233" "80" "30"
    [ -s "$CM_HOME/notification" ]
'
pass "GUI apply actions propagate application failure"

HOME="$TMP/gui-import" CM_HOME="$TMP/gui-import-state" CM_LANG_OVERRIDE=en bash -c '
    source "$GUI_BODY"
    CM_LANG=en
    cm_apply_language_labels
    cm_import_theme() { return 31; }
    yad() { return 0; }
    must_fail cm_ui_apply_themes_import "bad.zip" ""
'
pass "theme import failure propagates to __apply"

# The failure must come from the reset itself: pending, with a backup that works and a reset that fails, the command
# reports the error. It once passed because the real backup failed first, with no dconf.
HOME="$TMP/gui-reset" CM_HOME="$TMP/gui-reset-state" CM_LANG_OVERRIDE=en bash -c '
    source "$GUI_BODY"
    CM_LANG=en
    cm_apply_language_labels
    mkdir -p "$CM_HOME"
    cm_panel_reset_pending() { return 0; }
    cm_confirm() { return 0; }
    cm_backup_current() { printf "backup\n" >> "$CM_HOME/calls"; return 0; }
    cm_reset_panel_colors() { printf "reset\n" >> "$CM_HOME/calls"; printf "%s\n" "partial"; return 41; }
    cm_reload_cinnamon() { printf "reload\n" >> "$CM_HOME/calls"; }
    cm_notify_applied() { printf "notice\n" >> "$CM_HOME/calls"; }
    yad() { printf "%s\n" "$*" >> "$CM_HOME/dialogs"; return 0; }
    must_fail cm_ui_apply_panel_reset
    [ "$(tr "\n" " " < "$CM_HOME/calls")" = "backup reset " ] || { printf "FAIL: calls: %s\n" "$(cat "$CM_HOME/calls")" >&2; exit 1; }
    [[ "$(cat "$CM_HOME/dialogs")" == "--error --text="* ]] || { printf "FAIL: no error dialog\n" >&2; exit 1; }
'
pass "panel reset failure propagates to __apply"

# Restoring with no backup says so, as information. The Panel button used to do nothing, and Profiles asked to choose
# from a list that was empty. With backups, the Panel asks about the newest and Profiles still asks to pick one.
for lang_case in "en|There is no backup to restore yet.|Choose a backup from the list|(No backups yet)" \
                 "es|Todavía no hay ningún backup que restaurar.|Elige un backup de la lista|(Aún no hay backups)"; do
    IFS='|' read -r T_LANG T_NONE T_CHOOSE T_EMPTY <<< "$lang_case"
    export T_LANG T_NONE T_CHOOSE T_EMPTY
    HOME="$TMP/gui-nobackup-$T_LANG" CM_HOME="$TMP/gui-nobackup-$T_LANG-state" CM_LANG_OVERRIDE="$T_LANG" bash -c '
        source "$GUI_BODY"
        CM_LANG="$T_LANG"
        cm_apply_language_labels
        mkdir -p "$CM_HOME"
        yad() { printf "%s\n" "$*" >> "$CM_HOME/dialogs"; return 0; }
        cm_confirm() { printf "asked\n" >> "$CM_HOME/confirms"; return 0; }
        cm_restore_backup() { printf "%s\n" "$1" >> "$CM_HOME/restored"; return 0; }
        cm_notify_applied() { :; }
        bad() { printf "FAIL [%s]: %s\n" "$T_LANG" "$1" >&2; exit 1; }
        fresh() { rm -f "$CM_HOME/dialogs" "$CM_HOME/confirms" "$CM_HOME/restored"; }
        dialogs() { cat "$CM_HOME/dialogs" 2>/dev/null || true; }
        only_the_dialog() {  # <label> <type> <text>: one dialog of that type, with that text, and nothing asked or restored
            [ "$(dialogs | wc -l)" -eq 1 ] || bad "$1: expected one dialog, got: $(dialogs)"
            [[ "$(dialogs)" == "--$2 --text="*"$3"* ]] || bad "$1: expected a --$2 dialog with \"$3\", got: $(dialogs)"
            [ ! -e "$CM_HOME/confirms" ] && [ ! -e "$CM_HOME/restored" ] || bad "$1: it asked or restored"
        }

        fresh; cm_ui_apply_panel_backup
        only_the_dialog "Panel, no backups" info "$T_NONE"
        tab_backups() {  # what the Profiles tab gives yad for its backup selector: the value after the selector label
            rm -f "$CM_HOME/tab-args" "$CM_HOME/tab-ran"
            (
                cm_tab_alive() { [ ! -e "$CM_HOME/tab-ran" ] || return 1; : > "$CM_HOME/tab-ran"; }
                yad() { printf "%s\n" "$@" >> "$CM_HOME/tab-args"; }
                cm_tab_profiles KEY 7
            )
            awk -v want="--field=$(cm_t ui_available_backup):CB" "\$0 == want { getline; print; exit }" "$CM_HOME/tab-args"
        }

        fresh; cm_ui_apply_profiles_restore ""
        only_the_dialog "Profiles, no backups" info "$T_NONE"
        # An empty selector looks broken: with no backup it holds a placeholder, and choosing that is choosing nothing.
        [ "$(tab_backups)" = "$T_EMPTY" ] || bad "Profiles tab, no backups: the selector holds <$(tab_backups)>, expected the placeholder"
        fresh; cm_ui_apply_profiles_restore "$T_EMPTY"
        only_the_dialog "Profiles, placeholder picked, no backups" info "$T_NONE"

        mkdir -p "$CM_BACKUP_DIR/20260101-000000" "$CM_BACKUP_DIR/20260102-000000"
        fresh; cm_ui_apply_panel_backup
        [ ! -e "$CM_HOME/dialogs" ] || bad "Panel, with backups: it showed a dialog: $(dialogs)"
        [ "$(cat "$CM_HOME/confirms")" = asked ] || bad "Panel, with backups: it did not ask once"
        [ "$(cat "$CM_HOME/restored")" = 20260102-000000 ] || bad "Panel, with backups: it did not restore the newest"
        fresh; cm_ui_apply_profiles_restore ""
        only_the_dialog "Profiles, nothing picked" error "$T_CHOOSE"
        [ "$(tab_backups)" = "20260102-000000!20260101-000000" ] || bad "Profiles tab, with backups: the selector holds <$(tab_backups)>"
        fresh; cm_ui_apply_profiles_restore "$T_EMPTY"
        only_the_dialog "Profiles, placeholder picked after a backup appeared" error "$T_CHOOSE"
        fresh; cm_ui_apply_profiles_restore "20260101-000000"
        [ ! -e "$CM_HOME/dialogs" ] || bad "Profiles, picked: it showed a dialog: $(dialogs)"
        [ "$(cat "$CM_HOME/restored")" = 20260101-000000 ] || bad "Profiles, picked: it did not restore the one picked"
    ' || fail "restore with no backup (${T_LANG})"
done
pass "restoring with no backup says so (Panel and Profiles, English and Spanish); with backups nothing changes"

# The folder selector of the Themes tab reads "(None)" like the file selector above it (yad 0.40.0 draws an empty one as a blank
# button): it starts on a path that does not exist, and the import takes that placeholder for nothing chosen wherever yad delivers
# it. yad leaves empty values out of a button's command line, so a lone file or folder arrives as the first value.
for T_LANG in en es; do
    export T_LANG
    HOME="$TMP/gui-nofolder-$T_LANG" CM_HOME="$TMP/gui-nofolder-$T_LANG-state" CM_LANG_OVERRIDE="$T_LANG" bash -c '
        source "$GUI_BODY"
        CM_LANG="$T_LANG"
        cm_apply_language_labels
        mkdir -p "$CM_HOME" "$CM_HOME/chosen-folder"
        yad() { printf "%s\n" "$*" >> "$CM_HOME/dialogs"; return 0; }
        cm_import_theme() { printf "%s\n" "$1" >> "$CM_HOME/imported"; printf "%s\n" "$CM_HOME/imported-theme"; }
        cm_state_set() { :; }
        cm_tab_redraw() { :; }
        cm_notify_applied() { :; }
        bad() { printf "FAIL [%s]: %s\n" "$T_LANG" "$1" >&2; exit 1; }
        fresh() { rm -f "$CM_HOME/dialogs" "$CM_HOME/imported"; }
        imported() { cat "$CM_HOME/imported" 2>/dev/null || true; }
        nothing_chosen() {  # <label> <file value> <folder value>: the error asking to choose something, and no import
            fresh; must_fail cm_ui_apply_themes_import "$2" "$3"
            [[ "$(cat "$CM_HOME/dialogs" 2>/dev/null)" == "--error --text=$(cm_t ui_theme_file_required)"* ]] \
                || bad "$1: expected the error asking to choose something, got: $(cat "$CM_HOME/dialogs" 2>/dev/null)"
            [ -z "$(imported)" ] || bad "$1: it imported <$(imported)>"
        }
        (
            cm_tab_alive() { [ ! -e "$CM_HOME/tab-ran" ] || return 1; : > "$CM_HOME/tab-ran"; }
            yad() { printf "%s\n" "$@" >> "$CM_HOME/tab-args"; }
            cm_tab_themes KEY 1
        )
        folder_start=$(awk -v want="--field=$(cm_t ui_theme_dir):DIR" "\$0 == want { getline; print; exit }" "$CM_HOME/tab-args")
        [ "$folder_start" = "$CM_NO_FOLDER" ] || bad "the folder selector starts on <$folder_start>, expected the placeholder"
        [ ! -e "$folder_start" ] || bad "the placeholder path exists: GTK would draw it as a folder, not as (None)"
        [[ "$CM_NO_FOLDER" == /* ]] || bad "the placeholder <$CM_NO_FOLDER> is not an absolute path: empty, GTK draws a blank button; relative, it reads (None) only while the folder the GUI starts from lacks it"

        nothing_chosen "nothing chosen" "" ""
        nothing_chosen "the placeholder alone, as yad delivers it" "$CM_NO_FOLDER" ""
        nothing_chosen "the placeholder as the second value" "" "$CM_NO_FOLDER"
        fresh; cm_ui_apply_themes_import "$CM_HOME/a-theme.zip" "$CM_NO_FOLDER"
        [ "$(imported)" = "$CM_HOME/a-theme.zip" ] || bad "a file and the placeholder: imported <$(imported)>"
        fresh; cm_ui_apply_themes_import "$CM_HOME/chosen-folder" ""
        [ "$(imported)" = "$CM_HOME/chosen-folder" ] || bad "a folder alone (it arrives first): imported <$(imported)>"
        fresh; cm_ui_apply_themes_import "" "$CM_HOME/chosen-folder"
        [ "$(imported)" = "$CM_HOME/chosen-folder" ] || bad "a folder as the second value (a yad that keeps empty values): imported <$(imported)>"
        fresh; cm_ui_apply_themes_import "$CM_HOME/a-theme.zip" "$CM_HOME/chosen-folder"
        [ "$(imported)" = "$CM_HOME/a-theme.zip" ] || bad "a file and a folder: the file goes first, imported <$(imported)>"
        [ ! -e "$CM_HOME/dialogs" ] || bad "a valid choice showed a dialog: $(cat "$CM_HOME/dialogs")"
    ' || fail "the folder selector placeholder (${T_LANG})"
done
pass "the Themes tab folder selector starts on a placeholder that reads (None); the import ignores it wherever yad delivers it and still imports a real file or folder"

# The Panel reset has something to do only while it would change something: a Color Mint copy of the Cinnamon
# theme is active (or the theme cannot be read) with the original on record, or Color Mint's accent is in a gtk.css. The record of the original theme stays after a
# reset, and a gtk-4.0 block that only imports a theme for libadwaita is not an accent. Each case also runs the
# real reset: the predicate and the reset must agree on whether there was anything to do.
cat > "$TMP/gs-double.sh" <<'DOUBLE'
# The Cinnamon theme name as a file: gsettings reads and sets it; without the file it cannot be read.
gsettings() {
    case "$1" in
        get) [ -s "$CM_HOME/theme" ] || return 1; printf "'%s'\n" "$(cat "$CM_HOME/theme")" ;;
        set) printf '%s\n' "$4" > "$CM_HOME/theme" ;;
        *) return 1 ;;
    esac
}
DOUBLE
export GS_DOUBLE="$TMP/gs-double.sh"
HOME="$TMP/gui-pending" CM_HOME="$TMP/gui-pending-state" CM_LANG_OVERRIDE=en bash -c '
    source "$GUI_BODY"
    source "$GS_DOUBLE"
    CM_LANG=en
    cm_apply_language_labels
    bad() { printf "FAIL: %s\n" "$1" >&2; exit 1; }
    imp="@import \"/usr/share/themes/Foo/gtk-4.0/gtk.css\";"
    acc="@define-color accent_color #aa3366;"
    foreign="@define-color my_color #123456;"
    setup() {  # an empty home; the Cinnamon theme reads as $1, and cannot be read when $1 is empty
        rm -rf "$HOME" "$CM_HOME"
        mkdir -p "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0" "$CM_HOME"
        [ -z "$1" ] || printf "%s\n" "$1" > "$CM_HOME/theme"
    }
    block() {  # <gtk-3.0|gtk-4.0> [lines]: a Color Mint block with those lines
        local dir="$1"; shift
        printf "%s\n" "$CM_GTK_ACCENT_BEGIN" "$@" "$CM_GTK_ACCENT_END" > "$HOME/.config/$dir/gtk.css"
    }
    expect() {  # <label> <status the predicate must return>: the real reset must agree
        local want="$2" got=0 out rc=0
        cm_panel_reset_pending || got=$?
        [ "$got" -eq "$want" ] || bad "$1: the predicate returned $got, expected $want"
        out=$(cm_reset_panel_colors 2>&1) || rc=$?
        if [ "$want" -eq 0 ]; then
            { [ "$rc" -eq 0 ] && [ "$out" != "$(cm_t color_reset_none)" ]; } || bad "$1: pending, but the reset did nothing ($rc): $out"
        else
            { [ "$rc" -eq 1 ] && [ "$out" = "$(cm_t color_reset_none)" ]; } || bad "$1: not pending, but the reset did something ($rc): $out"
        fi
    }

    setup "";    expect "an empty home" 1
    setup Foo;   cm_state_set ORIGINAL_CINNAMON_THEME Foo;  expect "the original theme is active again" 1
    setup Bar;   cm_state_set ORIGINAL_CINNAMON_THEME Foo;  expect "a theme the user chose is active" 1
    [ "$(cat "$CM_HOME/theme")" = Bar ] || bad "a theme the user chose: the reset changed it to $(cat "$CM_HOME/theme")"
    setup CM-Foo; cm_state_set ORIGINAL_CINNAMON_THEME Foo; expect "a Color Mint copy is active" 0
    [ "$(cat "$CM_HOME/theme")" = Foo ] || bad "a Color Mint copy: the original theme was not put back"
    setup "";    cm_state_set ORIGINAL_CINNAMON_THEME Foo;  expect "the active theme cannot be read" 0
    setup Foo;   cm_state_set ORIGINAL_CINNAMON_THEME Foo;  block gtk-3.0 "$acc";  expect "an accent in gtk-3.0" 0
    setup Foo;   cm_state_set ORIGINAL_CINNAMON_THEME Foo;  block gtk-4.0 "$acc";  expect "an accent in gtk-4.0" 0
    setup Foo;   block gtk-4.0 "$imp";                      expect "only the libadwaita import" 1
    setup Foo;   block gtk-4.0 "$imp" "$acc";               expect "the import and an accent" 0
    setup Foo;   block gtk-4.0;                             expect "an empty block" 0
    setup Foo;   printf "%s\n" "$foreign" > "$HOME/.config/gtk-3.0/gtk.css"; printf "%s\n" "$foreign" > "$HOME/.config/gtk-4.0/gtk.css"
    expect "a gtk.css that is not Color Mint'\''s" 1
    setup Foo;   cm_state_set ORIGINAL_CINNAMON_THEME Foo;  block gtk-4.0 "$imp";  expect "the original theme and only the import" 1
    setup Bar;   cm_state_set ORIGINAL_CINNAMON_THEME Foo;  printf "%s\n" "$foreign" > "$HOME/.config/gtk-3.0/gtk.css";  expect "a theme the user chose and a gtk.css that is not Color Mint'\''s" 1
    setup Bar;   cm_state_set ORIGINAL_CINNAMON_THEME Foo;  block gtk-3.0 "$acc";  expect "a theme the user chose and an accent" 0
    [ "$(cat "$CM_HOME/theme")" = Bar ] || bad "a theme the user chose and an accent: the reset changed the theme"
' || fail "panel reset predicate"
pass "the panel reset is pending only while it would change something, and it agrees with the real reset (14 cases)"

# The Panel button: with nothing to reset it says so as information and goes no further (no question, no backup, no
# reload, no notice); the first press runs the reset for real and the second finds nothing again. A reset that
# fails still shows the error, one that worked still reports, and one that finds nothing after the question says so.
for lang_case in "en|No color customization is available to reset yet.|ERROR: could not reset the panel colors." \
                 "es|No hay ninguna personalización de color que restablecer todavía.|ERROR: no se pudo restablecer los colores del panel."; do
    IFS='|' read -r T_LANG T_NONE T_FAILED <<< "$lang_case"
    export T_LANG T_NONE T_FAILED
    HOME="$TMP/gui-noreset-$T_LANG" CM_HOME="$TMP/gui-noreset-$T_LANG-state" CM_LANG_OVERRIDE="$T_LANG" bash -c '
        source "$GUI_BODY"
        source "$GS_DOUBLE"
        CM_LANG="$T_LANG"
        cm_apply_language_labels
        mkdir -p "$HOME" "$CM_HOME"
        yad() { printf "%s\n" "$*" >> "$CM_HOME/dialogs"; return 0; }
        cm_confirm() { printf "ask\n" >> "$CM_HOME/calls"; return 0; }
        cm_backup_current() { printf "backup\n" >> "$CM_HOME/calls"; return 0; }
        cm_reload_cinnamon() { printf "reload\n" >> "$CM_HOME/calls"; }
        cm_notify_applied() { printf "notice\n" >> "$CM_HOME/calls"; printf "%s\n" "$*" > "$CM_HOME/notice"; }
        bad() { printf "FAIL [%s]: %s\n" "$T_LANG" "$1" >&2; exit 1; }
        fresh() { rm -f "$CM_HOME/dialogs" "$CM_HOME/calls" "$CM_HOME/notice"; }
        dialogs() { cat "$CM_HOME/dialogs" 2>/dev/null || true; }
        calls() { { tr "\n" " " < "$CM_HOME/calls"; } 2>/dev/null || true; }
        press() {  # one press of the button; whatever the outcome, it leaves no message file behind
            local left
            fresh; rc=0; cm_ui_apply_panel_reset || rc=$?
            left=$(compgen -G "${TMPDIR:-/tmp}/cm_reset_msg.*" || true)
            [ -z "$left" ] || bad "a press left its message file behind: $left"
        }
        only_info() {  # <label>: it returned 0, showed one --info dialog with the none text and did nothing else
            [ "$rc" -eq 0 ] || bad "$1: it returned $rc, and that is not a failure"
            [ "$(dialogs | wc -l)" -eq 1 ] && [[ "$(dialogs)" == "--info --text=$T_NONE --button="* ]] \
                || bad "$1: expected one --info dialog with \"$T_NONE\", got: $(dialogs)"
        }

        press; only_info "nothing to reset"
        [ -z "$(calls)" ] || bad "nothing to reset: it asked, backed up, reloaded or announced: $(calls)"

        cm_apply_gtk_accent_color "#aa3366" >/dev/null || bad "control: the accent was not applied"
        cm_panel_reset_pending || bad "control: the accent is not pending"
        press
        [ "$rc" -eq 0 ] || bad "first press: it returned $rc"
        [ "$(calls)" = "ask backup reload notice " ] || bad "first press: expected ask, backup, reload and notice, got: $(calls)"
        [ ! -e "$CM_HOME/dialogs" ] || bad "first press: it showed a dialog: $(dialogs)"
        [[ "$(cat "$CM_HOME/notice")" == "Color Mint $(cm_t colors_reset) "* ]] || bad "first press: the notice says: $(cat "$CM_HOME/notice")"
        if grep -qF "$CM_GTK_ACCENT_BEGIN" "$HOME/.config/gtk-3.0/gtk.css" 2>/dev/null; then bad "first press: the accent is still there"; fi
        press; only_info "second press"
        [ -z "$(calls)" ] || bad "second press: it asked, backed up, reloaded or announced: $(calls)"

        printf "%s\n" "CM-Mint-Y-Dark" > "$CM_HOME/theme"; cm_state_set ORIGINAL_CINNAMON_THEME Mint-Y-Dark
        press
        [ "$rc" -eq 0 ] && [ "$(calls)" = "ask backup reload notice " ] || bad "theme, first press: rc $rc, calls: $(calls)"
        [ "$(cat "$CM_HOME/theme")" = Mint-Y-Dark ] || bad "theme, first press: the original theme was not put back"
        press; only_info "theme, second press"
        [ -z "$(calls)" ] || bad "theme, second press: it did more than say so: $(calls)"

        cm_panel_reset_pending() { return 0; }
        cm_reset_panel_colors() { printf "%s\n" "ERROR: could not write /x/gtk.css" >&2; return 1; }
        press
        [ "$rc" -eq 1 ] || bad "failure: it returned $rc instead of 1"
        [ "$(dialogs | wc -l)" -eq 1 ] && [[ "$(dialogs)" == "--error --text=$T_FAILED --button="* ]] \
            || bad "failure: expected one --error dialog with \"$T_FAILED\", got: $(dialogs)"
        [ "$(calls)" = "ask backup " ] || bad "failure: expected ask and backup only, got: $(calls)"

        cm_reset_panel_colors() { printf "%s\n" "Colors reset."; return 0; }
        press
        [ "$rc" -eq 0 ] || bad "success: it returned $rc"
        [ ! -e "$CM_HOME/dialogs" ] || bad "success: it showed a dialog: $(dialogs)"
        [ "$(calls)" = "ask backup reload notice " ] || bad "success: expected ask, backup, reload and notice, got: $(calls)"

        cm_reset_panel_colors() { printf "%s\n" "$T_NONE" >&2; return 1; }
        press; only_info "nothing found after the question"
        [ "$(calls)" = "ask backup " ] || bad "nothing found after the question: expected ask and backup only, got: $(calls)"
    ' || fail "panel reset (${T_LANG})"
done
pass "the Panel reset button: nothing to reset says so as information, the first press resets and the second finds nothing, a failure errors and a success reports (English and Spanish)"

TMP_SCRIPT="$TMP/dispatcher-wrapper.sh"
{
    awk '/^# Command-line dispatcher$/{exit} {print}' "$SCRIPT"
    printf '%s\n' 'cm_backup_current() { return 55; }'
    awk '/^# Command-line dispatcher$/ { found=1 } found { print }' "$SCRIPT"
} > "$TMP_SCRIPT"
chmod +x "$TMP_SCRIPT"
set +e
HOME="$TMP/dispatcher-home" CM_HOME="$TMP/dispatcher-state" CM_LANG_OVERRIDE=en bash "$TMP_SCRIPT" __apply panel_apply "" "" "" "" "" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "__apply masked GUI failure status"
pass "__apply returns a non-zero GUI failure status"

mkdir -p "$TMP/home-persist"
HOME="$TMP/home-persist" CM_HOME="$TMP/state-persist" CM_LANG_OVERRIDE=en bash "$SCRIPT" l >"$TMP/toggle1"
grep -qx 'Idioma cambiado a español' "$TMP/toggle1" || fail "toggle to Spanish"
grep -qx 'LANGUAGE="es"' "$TMP/state-persist/state.conf" || fail "Spanish language persistence"
HOME="$TMP/home-persist" CM_HOME="$TMP/state-persist" bash "$SCRIPT" --help >"$TMP/help-persist"
grep -q 'MODO GRÁFICO' "$TMP/help-persist" || fail "persisted Spanish"
HOME="$TMP/home-persist" CM_HOME="$TMP/state-persist" bash "$SCRIPT" l >"$TMP/toggle2"
grep -qx 'Language switched to English' "$TMP/toggle2" || fail "toggle to English"
grep -qx 'LANGUAGE="en"' "$TMP/state-persist/state.conf" || fail "English language persistence"
pass "language toggle and persistence"

for spec in \
  'es|es_ES.UTF-8||MODO GRÁFICO' \
  'en|en_US.UTF-8||GRAPHICAL MODE' \
  'en|es_ES.UTF-8|en_US.UTF-8|GRAPHICAL MODE' \
  'es|en_US.UTF-8|es_ES.UTF-8|MODO GRÁFICO'
do
    IFS='|' read -r id lang lcmsg expected <<<"$spec"
    out="$TMP/locale-$id-${RANDOM}"
    HOME="$TMP/home-locale-$id-${RANDOM}" CM_HOME="$TMP/state-locale-$id-${RANDOM}" \
      LC_ALL='' LC_MESSAGES="$lcmsg" LANG="$lang" bash "$SCRIPT" --help 2>/dev/null >"$out"
    grep -q "$expected" "$out" || fail "locale detection $spec"
done
HOME="$TMP/home-locale-all-${RANDOM}" CM_HOME="$TMP/state-locale-all-${RANDOM}" \
  LC_ALL=es_ES.UTF-8 LC_MESSAGES=en_US.UTF-8 LANG=en_US.UTF-8 bash "$SCRIPT" --help 2>/dev/null >"$TMP/locale-all"
grep -q 'MODO GRÁFICO' "$TMP/locale-all" || fail 'LC_ALL precedence'
pass "system locale detection and POSIX precedence"

# Functional regression: language changes must not alter technical gsettings arguments.
mkdir -p "$TMP/mockbin"
cat > "$TMP/mockbin/gsettings" <<'MOCK'
#!/usr/bin/env bash
set -e
printf '%s\n' "$*" >> "${CM_TEST_GSET_LOG:?}"
if [ "${1:-}" = get ]; then
    case "${2:-}:" in
        org.cinnamon.desktop.wm.preferences:num-workspaces) printf "4\n" ;;
        org.cinnamon:desktop-effects) printf "true\n" ;;
        org.cinnamon:desktop-effects-on-menus) printf "true\n" ;;
        org.nemo.desktop:show-desktop-icons) printf "true\n" ;;
        *) printf "''\n" ;;
    esac
fi
MOCK
chmod +x "$TMP/mockbin/gsettings"
cat > "$TMP/mockbin/gdbus" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CM_TEST_GDBUS_LOG:-/dev/null}"
exit 0
MOCK
chmod +x "$TMP/mockbin/gdbus"

for lang in es en; do
    : >"$TMP/gset-$lang.log"
    PATH="$TMP/mockbin:$PATH" CM_TEST_GSET_LOG="$TMP/gset-$lang.log" CM_TEST_GDBUS_LOG="$TMP/gdbus-$lang.log" \
      HOME="$TMP/home-fn-$lang" CM_HOME="$TMP/state-fn-$lang" CM_LANG_OVERRIDE="$lang" \
      bash "$SCRIPT" desktop effects on >"$TMP/fn-$lang.out"
    grep -q 'desktop-effects true' "$TMP/gset-$lang.log" || fail "gsettings dispatch $lang"
done
cmp "$TMP/gset-es.log" "$TMP/gset-en.log" || fail "language changed technical gsettings command"
grep -q 'Efectos de ventana activados' "$TMP/fn-es.out" || fail "Spanish functional output"
grep -q 'Window effects enabled' "$TMP/fn-en.out" || fail "English functional output"
PATH="$TMP/mockbin:$PATH" CM_TEST_GSET_LOG="$TMP/fn-invalid.log" \
  HOME="$TMP/home-fn-invalid" CM_HOME="$TMP/state-fn-invalid" CM_LANG_OVERRIDE=en \
  bash "$SCRIPT" desktop effects broken >"$TMP/fn-invalid.out" 2>&1 && fail "invalid value accepted"
grep -q "ERROR: invalid value ('broken')" "$TMP/fn-invalid.out" || fail "invalid-value regression"
pass "functional dispatch and language-independent technical commands"

# The fixed workspace count takes effect while org.cinnamon.muffin dynamic-workspaces is off, its default and
# what Settings leaves (it has no switch for it). Turned on by hand, the change is made and said to have no visible
# effect. A count that is refused or cannot be set reads nothing and warns of nothing.
mkdir -p "$TMP/dynbin"
cat > "$TMP/dynbin/gsettings" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CM_TEST_GSET_LOG:?}"
case "${1:-}:${2:-}:${3:-}" in
    get:org.cinnamon.muffin:dynamic-workspaces)
        [ "${CM_TEST_DYNAMIC:-false}" != unreadable ] || exit 1
        printf '%s\n' "${CM_TEST_DYNAMIC:-false}" ;;
    set:org.cinnamon.desktop.wm.preferences:num-workspaces)
        [ -z "${CM_TEST_SET_FAIL:-}" ] || { printf 'boom\n' >&2; exit 1; } ;;
    get:*) printf "''\n" ;;
esac
MOCK
cp "$TMP/mockbin/gdbus" "$TMP/dynbin/gdbus"
chmod +x "$TMP/dynbin/gsettings"
for spec in "en|Workspaces set to 6|dynamic workspaces are on, so this number has no visible effect|Workspaces: 6" \
            "es|Espacios de trabajo ajustados a 6|los espacios de trabajo dinámicos están activados, así que este número no se nota|Espacios de trabajo: 6"; do
    IFS='|' read -r d_lang d_ok d_warn d_label <<< "$spec"
    dyn() {  # <dynamic-workspaces value> <count> [set fails]: runs `desktop workspaces <count>`; leaves DYN_RC, dyn.out, dyn.err and dyn.log
        : > "$TMP/dyn.log"
        DYN_RC=0
        PATH="$TMP/dynbin:$PATH" CM_TEST_GSET_LOG="$TMP/dyn.log" CM_TEST_DYNAMIC="$1" CM_TEST_SET_FAIL="${3:-}" \
          HOME="$TMP/home-dyn-$d_lang" CM_HOME="$TMP/state-dyn-$d_lang" CM_LANG_OVERRIDE="$d_lang" \
          bash "$SCRIPT" desktop workspaces "$2" >"$TMP/dyn.out" 2>"$TMP/dyn.err" || DYN_RC=$?
    }
    dyn false 6
    { [ "$DYN_RC" -eq 0 ] && [ "$(cat "$TMP/dyn.out")" = "$d_ok" ] && [ ! -s "$TMP/dyn.err" ]; } \
        || fail "workspaces ($d_lang), dynamic off: rc $DYN_RC, out: $(cat "$TMP/dyn.out"), err: $(cat "$TMP/dyn.err")"
    grep -qx 'set org.cinnamon.desktop.wm.preferences num-workspaces 6' "$TMP/dyn.log" || fail "workspaces ($d_lang): the count was not set"
    dyn true 6
    { [ "$DYN_RC" -eq 0 ] && [ "$(cat "$TMP/dyn.out")" = "$d_ok" ]; } \
        || fail "workspaces ($d_lang), dynamic on: rc $DYN_RC, out: $(cat "$TMP/dyn.out")"
    [[ "$(cat "$TMP/dyn.err")" == *"$d_warn"*"gsettings set org.cinnamon.muffin dynamic-workspaces false" ]] \
        || fail "workspaces ($d_lang), dynamic on: the warning is missing or wrong: $(cat "$TMP/dyn.err")"
    dyn unreadable 6
    { [ "$DYN_RC" -eq 0 ] && [ ! -s "$TMP/dyn.err" ]; } || fail "workspaces ($d_lang), dynamic unreadable: it warned or failed: $(cat "$TMP/dyn.err")"
    dyn true 0
    [ "$DYN_RC" -ne 0 ] || fail "workspaces ($d_lang): a count of 0 was accepted"
    if grep -qE 'dynamic-workspaces|^set ' "$TMP/dyn.log"; then fail "workspaces ($d_lang): a refused count read or set a key"; fi
    dyn true 6 1
    [ "$DYN_RC" -ne 0 ] || fail "workspaces ($d_lang): a count that could not be set reported success"
    if [[ "$(cat "$TMP/dyn.err")" == *"$d_warn"* ]] || grep -q 'dynamic-workspaces' "$TMP/dyn.log"; then
        fail "workspaces ($d_lang): it read the dynamic-workspaces key or warned after a failed set"
    fi
    PATH="$TMP/dynbin:$PATH" CM_TEST_GSET_LOG="$TMP/dyn.log" CM_TEST_DYNAMIC=true \
      HOME="$TMP/home-dyn-gui-$d_lang" CM_HOME="$TMP/state-dyn-gui-$d_lang" CM_LANG_OVERRIDE="$d_lang" \
      T_LANG="$d_lang" D_LABEL="$d_label" D_WARN="$d_warn" bash -c '
        source "$GUI_BODY"
        CM_LANG="$T_LANG"
        cm_apply_language_labels
        applied=()
        cm_report "$D_LABEL" cm_apply_workspaces 6 || { printf "FAIL: the report failed\n" >&2; exit 1; }
        { [ "${#applied[@]}" -eq 2 ] && [ "${applied[0]}" = "$D_LABEL" ] && [[ "${applied[1]}" == "⚠ $D_WARN"* ]]; } \
            || { printf "FAIL: the report holds: %s\n" "${applied[*]}" >&2; exit 1; }
    ' || fail "workspaces ($d_lang): the GUI report does not show the warning as a ⚠ line"
done
if grep -q 'ui_dynamic_workspaces' "$SCRIPT"; then fail "the Desktop tab shows a permanent dynamic-workspaces warning again"; fi
pass "workspaces: a dynamic-workspaces warning only when the key is on, in both languages, in the CLI and in the GUI report; none after a refused or failed count"

# Differential backend regression against the original script.
if [ -n "${ORIGINAL_ZIP:-}" ] && [ -f "$ORIGINAL_ZIP" ]; then
    DIFF_BIN="$TMP/diff-bin"; mkdir -p "$DIFF_BIN"
    cat > "$DIFF_BIN/gsettings" <<'EOF'
#!/usr/bin/env bash
printf 'gsettings\t%s\n' "$*" >>"${CM_TEST_DIFF_LOG:?}"
if [ "${1:-}" = get ]; then
  case "$2|$3" in
    'org.cinnamon.desktop.interface|gtk-theme') printf "'Mint-Y'\n";;
    'org.cinnamon.desktop.interface|icon-theme') printf "'Mint-Y-Dark'\n";;
    'org.cinnamon.desktop.interface|cursor-theme') printf "'Bibata'\n";;
    'org.cinnamon.desktop.interface|cursor-size') printf '24\n';;
    'org.cinnamon.desktop.interface|font-name') printf "'Noto Sans 10'\n";;
    'org.gnome.desktop.interface|monospace-font-name') printf "'Noto Sans Mono 10'\n";;
    'org.cinnamon|desktop-effects') printf 'true\n';;
    'org.cinnamon|desktop-effects-on-menus') printf 'true\n';;
    'org.cinnamon.desktop.wm.preferences|num-workspaces') printf '4\n';;
    'org.cinnamon.desktop.wm.preferences|button-layout') printf ':minimize,maximize,close\n';;
    'org.nemo.desktop|show-desktop-icons') printf 'true\n';;
    'org.cinnamon|panels-enabled') printf "['1:0:bottom']\n";;
    'org.cinnamon|panels-height') printf "['1:40']\n";;
    'org.cinnamon|hotcorner-layout') printf "['expo:false:0','scale:false:0','desktop:false:0','expo:false:0']\n";;
    *) printf "''\n";;
  esac
fi
EOF
    chmod +x "$DIFF_BIN/gsettings"
    cat > "$DIFF_BIN/dconf" <<'EOF'
#!/usr/bin/env bash
printf 'dconf\t%s\n' "$*" >>"${CM_TEST_DIFF_LOG:?}"
case "${1:-}" in read) printf "''\n";; dump) printf '[mock]\n';; esac
EOF
    chmod +x "$DIFF_BIN/dconf"
    cat > "$DIFF_BIN/gdbus" <<'EOF'
#!/usr/bin/env bash
printf 'gdbus\t%s\n' "$*" >>"${CM_TEST_DIFF_LOG:?}"; exit 1
EOF
    chmod +x "$DIFF_BIN/gdbus"
    ORIG_SCRIPT="$TMP/original-script.sh"
    unzip -p "$ORIGINAL_ZIP" '*/script/color-mint.sh' >"$ORIG_SCRIPT"
    CASES=(
      "desktop effects on" "desktop menu-effects off" "desktop workspaces 6"
      "desktop icons hide" "desktop panel-position top" "desktop window-buttons gnome"
      "desktop hotcorners expo scale none desktop" "terminal apply_palette nord"
      "terminal custom-colors #101010 #F0F0F0" "fonts font Noto-Sans-11"
      "fonts monospace Noto-Mono-11" "fonts rendering rgba slight" "fonts scaling 125"
      "theme cursor-size 32" "theme gtk Mint-Y" "theme icon Mint-Y-Dark"
    )
    for spec in "${CASES[@]}"; do
        read -r -a argv <<<"$spec"
        safe="$(printf '%s' "$spec" | tr ' /#' '____')"
        for lang in es en; do
            dir="$TMP/diff-$lang-$safe"
            rm -rf "$dir"; mkdir -p "$dir/home/.themes/Mint-Y-Dark/cinnamon" "$dir/home/.themes/Mint-Y/gtk-3.0" "$dir/home/.icons/Mint-Y-Dark" "$dir/cm"
            : >"$dir/log"
            script="$ORIG_SCRIPT"; [ "$lang" = en ] && script="$SCRIPT"
            PATH="$DIFF_BIN:$PATH" HOME="$dir/home" CM_HOME="$dir/cm" CM_TEST_DIFF_LOG="$dir/log" \
              LC_ALL=C LANG=C CM_LANG_OVERRIDE="$lang" bash "$script" "${argv[@]}" >/dev/null 2>&1 || true
        done
        cmp "$TMP/diff-es-$safe/log" "$TMP/diff-en-$safe/log" || fail "language changed backend command: $spec"
    done
    pass "differential backend regression against original script"
fi

# Round-trip every visible selector label back to its language-neutral key.
BODY="$TMP/functions.sh"
awk '/^# Command-line dispatcher/{exit} {print}' "$SCRIPT" > "$BODY"
for lang in es en; do
    cat > "$TMP/selector-$lang.sh" <<EOF2
set -euo pipefail
CM_HOME="$TMP/selector-home-$lang"
mkdir -p "\$CM_HOME"
SCRIPT_PATH="$SCRIPT"
source "$BODY"
CM_LANG="$lang"
cm_apply_language_labels
check() {
  local fn="\$1" arr="\$2" key label got
  declare -n a="\$arr"
  for key in "\${!a[@]}"; do
    label="\${a[\$key]}"
    got="\$(\$fn "\$label")"
    [ "\$got" = "\$key" ] || { printf 'selector mismatch %s %s: %s -> %s\\n' "\$fn" "\$key" "\$label" "\$got" >&2; exit 1; }
  done
}
check cm_accent_preset_key_from_label CM_ACCENT_PRESET_LABELS
check cm_color_target_key_from_label CM_COLOR_TARGET_LABELS
check cm_button_preset_key_from_label CM_BUTTON_PRESET_LABELS
check cm_corner_key_from_label CM_CORNER_LABELS
check cm_bgmode_key_from_label CM_BGMODE_LABELS
check cm_panelpos_key_from_label CM_PANELPOS_LABELS
check cm_onoff_key_from_label CM_ONOFF_LABELS
check cm_showhide_key_from_label CM_SHOWHIDE_LABELS
check cm_palette_key_from_label CM_PALETTE_LABELS
check cm_antialias_key_from_label CM_ANTIALIAS_LABELS
check cm_hinting_key_from_label CM_HINTING_LABELS
EOF2
    bash "$TMP/selector-$lang.sh"
done
pass "selector labels round-trip to stable internal keys"

# No user-visible Spanish literals should remain in the GUI wiring outside the translation tables.
python3 - "$SCRIPT" <<'PY'
import pathlib, sys
s=pathlib.Path(sys.argv[1]).read_text().splitlines()
gui_start=next(i for i,l in enumerate(s,1) if l.startswith('cm_ui_apply_'))
gui_end=next(i for i,l in enumerate(s,1) if l.startswith('cm_main_window()'))
for i,line in enumerate(s,1):
    if not (gui_start <= i <= gui_end) or line.lstrip().startswith('#'):
        continue
    for bad in ('--field="Valores:', '--field="Claro"', '--field="Oscuro"', 'cm_report "Opacidad:', 'cm_report "Alto:', 'cm_report "Fondo de escritorio:'):
        if bad in line:
            raise SystemExit(f'hardcoded GUI text found at line {i}: {bad}')
apply_at=next(i for i,l in enumerate(s) if l.strip() == '__apply)')
block=s[apply_at:apply_at+20]
if sum('themes_import)' in line for line in block) != 1:
    raise SystemExit('duplicate themes_import dispatcher branch')
print('PASS: GUI has no known untranslated hardcoded labels')
PY

# GUI structural snapshot: capture the first YAD form from each tab in both languages.
cat > "$TMP/mockbin/yad" <<'MOCKYAD'
#!/usr/bin/env bash
set -e
if printf '%s\n' "$*" | grep -q -- '--plug='; then
    printf '%s\n' "$@" > "${CM_TEST_YAD_LOG:?}"
    kill -TERM "$PPID" 2>/dev/null || true
fi
exit 0
MOCKYAD
chmod +x "$TMP/mockbin/yad"
cat > "$TMP/mockbin/gsettings" <<'MOCKGSET'
#!/usr/bin/env bash
set -e
if [ "${1:-}" = get ]; then
    case "${2:-}" in
        org.cinnamon.desktop.interface) printf "'Mint-Y'\n" ;;
        org.cinnamon.desktop.wm.preferences) printf "'close,minimize,maximize:menu'\n" ;;
        org.cinnamon) printf "['expo:true:0','scale:true:0','desktop:false:0','expo:false:0']\n" ;;
        org.nemo.desktop) printf "true\n" ;;
        org.gnome.Terminal.ProfilesList) printf "'00000000-0000-0000-0000-000000000000'\n" ;;
        *) printf "''\n" ;;
    esac
fi
MOCKGSET
chmod +x "$TMP/mockbin/gsettings"
for lang in es en; do
    for tab in themes panel desktop advanced terminal fonts profiles; do
        rm -f "$TMP/yad-$lang-$tab.log"
        set +e
        PATH="$TMP/mockbin:$PATH" CM_TEST_YAD_LOG="$TMP/yad-$lang-$tab.log" \
          HOME="$TMP/home-ui-$lang-$tab" CM_HOME="$TMP/state-ui-$lang-$tab" CM_LANG_OVERRIDE="$lang" \
          bash "$SCRIPT" __tab "$tab" "$$" 1 >/dev/null 2>&1 &
        pid=$!
        wait "$pid" 2>/dev/null || true
        set -e
        [ -s "$TMP/yad-$lang-$tab.log" ] || fail "GUI snapshot $lang/$tab (no form captured)"
    done
done
python3 - "$TMP" <<'PY'
import pathlib, sys, re
base=pathlib.Path(sys.argv[1])
for tab in 'themes panel desktop advanced terminal fonts profiles'.split():
    logs=[(base/f'yad-es-{tab}.log').read_text().splitlines(),(base/f'yad-en-{tab}.log').read_text().splitlines()]
    fields=[]
    for log in logs:
        fields.append([line[9:] for line in log if line.startswith('--field=')])
    if len(fields[0]) != len(fields[1]):
        raise SystemExit(f'field count differs for {tab}: {len(fields[0])} vs {len(fields[1])}')
    def typ(field):
        m=re.search(r':(LBL|CB|NUM|CLR|CHK|SCL|FBTN)(?:$)', field)
        return m.group(1) if m else ''
    if [typ(x) for x in fields[0]] != [typ(x) for x in fields[1]]:
        raise SystemExit(f'field types differ for {tab}')
    if fields[0] == fields[1]:
        raise SystemExit(f'no visible language change captured for {tab}')
print('PASS: GUI field counts/types survive language switch')
PY

# Main-window language button: YAD exit code 10 must toggle language and rebuild tabs.
cat > "$TMP/mockbin/yad" <<'MOCKMAINYAD'
#!/usr/bin/env bash
set -e
if printf '%s\n' "$*" | grep -q -- '--notebook'; then
    n="$(cat "${CM_TEST_NOTEBOOK_COUNT:?}" 2>/dev/null || echo 0)"
    n=$((n + 1))
    printf '%s\n' "$n" > "$CM_TEST_NOTEBOOK_COUNT"
    printf '%s\n' "$@" > "${CM_TEST_NOTEBOOK_LOG:?}.$n"
    [ "$n" -eq 1 ] && exit 10
    exit 1
fi
exit 0
MOCKMAINYAD
chmod +x "$TMP/mockbin/yad"
for cmd in dconf gsettings gdbus; do
    cat > "$TMP/mockbin/$cmd" <<'MOCKCMD'
#!/usr/bin/env bash
if [ "${1:-}" = get ]; then printf "''\n"; fi
exit 0
MOCKCMD
    chmod +x "$TMP/mockbin/$cmd"
done
: > "$TMP/notebook-count"
set +e
(
    PATH="$TMP/mockbin:$PATH" CM_TEST_NOTEBOOK_COUNT="$TMP/notebook-count" CM_TEST_NOTEBOOK_LOG="$TMP/notebook" \
      HOME="$TMP/home-main" CM_HOME="$TMP/state-main" CM_LANG_OVERRIDE=es \
      bash "$SCRIPT" gui >/dev/null 2>&1
) 2>/dev/null
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "main window language toggle (rc=$rc)"
[ "$(cat "$TMP/notebook-count")" -eq 2 ] || fail "main window was not rebuilt after language toggle"
grep -q -- '--button=Idioma: ES/EN:10' "$TMP/notebook.1" || fail "Spanish language button missing"
grep -q -- '--tab=🎨  Temas' "$TMP/notebook.1" || fail "Spanish tabs missing"
grep -q -- '--button=Language: ES/EN:10' "$TMP/notebook.2" || fail "English language button missing after toggle"
grep -q -- '--tab=🎨  Themes' "$TMP/notebook.2" || fail "English tabs missing after toggle"
grep -qx 'LANGUAGE="en"' "$TMP/state-main/state.conf" || fail "GUI language toggle not persisted"
pass "main GUI language button and tab rebuild"

# Preserve the GUI apply field wiring: labels may change, field types and %N indexes must not.
python3 - "$SCRIPT" "$ROOT" <<'PY'
import re, sys, pathlib, zipfile
script=pathlib.Path(sys.argv[1]).read_text()
root=pathlib.Path(sys.argv[2])
expected=[
    'cm_fbtn_apply themes_apply 5 6 9 10 7 2 3',
    'cm_fbtn_apply themes_more',
    'cm_fbtn_apply themes_import 14 15',
    'cm_fbtn_apply panel_apply 1 2 3 5 6',
    'cm_fbtn_apply panel_reset',
    'cm_fbtn_apply panel_backup',
    'cm_fbtn_apply desktop_apply 2 3 5 6 7 8 10 11',
    'cm_fbtn_apply advanced_apply 2 3 4 5 7 10',
    'cm_fbtn_apply terminal_apply 1 3 4 5',
    'cm_fbtn_apply fonts_apply 2 3 5 6 9',
    'cm_fbtn_apply profiles_save 2',
    'cm_fbtn_apply profiles_load 5',
    'cm_fbtn_apply profiles_restore 8',
]
for item in expected:
    if item not in script:
        raise SystemExit(f'missing GUI wiring: {item}')
print('PASS: GUI apply wiring')
PY

# Check original archive entries are not renamed/deleted when ORIGINAL_ZIP is supplied.
if [ -n "${ORIGINAL_ZIP:-}" ] && [ -f "$ORIGINAL_ZIP" ]; then
python3 - "$ORIGINAL_ZIP" "$ROOT" <<'PY'
import sys, zipfile, pathlib
z=zipfile.ZipFile(sys.argv[1])
root=pathlib.Path(sys.argv[2])
original=[n for n in z.namelist() if not n.endswith('/')]
archive_root=pathlib.PurePosixPath(original[0]).parts[0]
for n in original:
    rel=n.split('/',1)[1] if n.startswith(archive_root+'/') else n
    if not (root/rel).is_file():
        raise SystemExit(f'missing original path: {n}')
extras=[]
original_rel={n.split('/',1)[1] if n.startswith(archive_root+'/') else n for n in original}
for p in root.rglob('*'):
    if p.is_file():
        rel=p.relative_to(root).as_posix()
        if rel not in original_rel and rel != 'README.es.md' and not rel.startswith('tests/'):
            extras.append(rel)
if extras:
    raise SystemExit('unexpected project files: '+', '.join(extras))
print('PASS: original file paths preserved')
PY
fi

# Deep invariants against the original archive, when supplied.
if [ -n "${ORIGINAL_ZIP:-}" ] && [ -f "$ORIGINAL_ZIP" ]; then
python3 - "$ORIGINAL_ZIP" "$SCRIPT" "$ROOT" <<'PYCHK'
import hashlib, pathlib, re, sys, zipfile
zpath, script_path, root = sys.argv[1:]
root=pathlib.Path(root)
with zipfile.ZipFile(zpath) as z:
    files=[n for n in z.namelist() if not n.endswith('/')]
    archive_root=pathlib.PurePosixPath(files[0]).parts[0]
    orig={n[len(archive_root)+1:]: z.read(n) for n in files if n.startswith(archive_root+'/')}
for rel,data in orig.items():
    p=root/rel
    if not p.is_file(): raise SystemExit(f'missing original file: {rel}')
    if rel not in {'README.md','script/color-mint.sh','PLAN.txt','tests/test_color_mint.sh','tests/test_atomicity.sh'} and hashlib.sha256(p.read_bytes()).digest()!=hashlib.sha256(data).digest():
        raise SystemExit(f'original file content changed: {rel}')
old_script=orig['script/color-mint.sh'].decode('utf-8')
new_script=pathlib.Path(script_path).read_text(encoding='utf-8')
def branch_targets(s):
    marker='# Command-line dispatcher'
    if marker not in s: raise SystemExit('dispatcher marker not found')
    s=s[s.index(marker):]
    m=re.search(r'^case "\$\{1:-gui\}" in\n(?P<body>.*?)(?=^esac$)', s, re.M|re.S)
    if not m: raise SystemExit('dispatcher block not found')
    body=m.group('body')
    body=re.sub(r'^    l\).*?(?=^    -h\|--help\))', '', body, flags=re.M|re.S)
    body=re.sub(r'cm_lang_init\n\n', '', body)
    return re.findall(r'^\s{12}([A-Za-z0-9_-]+\))\s+([A-Za-z0-9_]+)', body, re.M)
if branch_targets(old_script)!=branch_targets(new_script):
    raise SystemExit('dispatcher command/function mapping changed')
print('PASS: original files and dispatcher invariants')
PYCHK
fi

# The GUI text budget and rendering audit lives in tests/test_aesthetics.sh.

# Simulated end-to-end user journey. External state-changing commands are
# replaced with persistent mocks, so the complete workflow can run safely.
SIM="$TMP/user-sim"; mkdir -p "$SIM/bin" "$SIM/home" "$SIM/cm"
cat > "$SIM/bin/gsettings" <<'MOCK'
#!/usr/bin/env bash
set -e
f="${CM_TEST_STATE:?}/gsettings.db"; log="${CM_TEST_LOG:?}"
cmd="${1:-}"; schema="${2:-}"; key="${3:-}"; val="${4:-}"
printf 'gsettings %s %s %s %s\n' "$cmd" "$schema" "$key" "$val" >>"$log"
getv(){ awk -F'\t' -v s="$1" -v k="$2" '$1==s && $2==k {v=$3} END{if(v!="") print v}' "$f" 2>/dev/null; }
setv(){ touch "$f"; awk -F'\t' -v s="$1" -v k="$2" '$1!=s || $2!=k' "$f" >"$f.tmp" 2>/dev/null || true; printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$f.tmp"; mv "$f.tmp" "$f"; }
case "$cmd" in
get)
 v="$(getv "$schema" "$key")"; if [ -n "$v" ]; then printf '%s\n' "$v"; else
 case "$schema|$key" in
  'org.cinnamon.desktop.interface|gtk-theme') printf "'Mint-Y'\n";;
  'org.cinnamon.desktop.interface|icon-theme') printf "'Mint-Y-Dark'\n";;
  'org.cinnamon.desktop.interface|cursor-theme') printf "'Bibata-Modern-Classic'\n";;
  'org.cinnamon.desktop.interface|cursor-size') printf '24\n';;
  'org.cinnamon.desktop.interface|font-name') printf "'Noto Sans 10'\n";;
  'org.gnome.desktop.interface|monospace-font-name') printf "'Noto Sans Mono 10'\n";;
  'org.cinnamon.theme|name') printf "'Mint-Y-Dark'\n";;
  'org.cinnamon|panels-enabled') printf "['1:0:bottom']\n";;
  'org.cinnamon|panels-height') printf "['1:40']\n";;
  'org.cinnamon|hotcorner-layout') printf "['expo:false:0','scale:false:0','desktop:false:0','expo:false:0']\n";;
  'org.cinnamon|desktop-effects') printf 'true\n';;
  'org.cinnamon|desktop-effects-on-menus') printf 'true\n';;
  'org.cinnamon.desktop.wm.preferences|num-workspaces') printf '4\n';;
  'org.cinnamon.desktop.wm.preferences|button-layout') printf ':minimize,maximize,close\n';;
  'org.nemo.desktop|show-desktop-icons') printf 'true\n';;
  'org.cinnamon.desktop.background|primary-color') printf '#2E3440\n';;
  'org.cinnamon.desktop.background|picture-options') printf 'zoom\n';;
  'org.gnome.Terminal.ProfilesList|default') printf "'11111111-1111-1111-1111-111111111111'\n";;
  *) printf "''\n";;
 esac; fi;;
set) setv "$schema" "$key" "$val";;
*) exit 1;; esac
MOCK
chmod +x "$SIM/bin/gsettings"
cat > "$SIM/bin/dconf" <<'MOCK'
#!/usr/bin/env bash
set -e
printf 'dconf %s\n' "$*" >>"${CM_TEST_LOG:?}"
case "${1:-}" in dump) printf '[mock]\n';; load) cat >/dev/null;; write) :;; read) printf "''\n";; esac
MOCK
chmod +x "$SIM/bin/dconf"
cat > "$SIM/bin/gdbus" <<'MOCK'
#!/usr/bin/env bash
printf 'gdbus %s\n' "$*" >>"${CM_TEST_LOG:?}"
exit 1
MOCK
chmod +x "$SIM/bin/gdbus"
cat > "$SIM/bin/notify-send" <<'MOCK'
#!/usr/bin/env bash
printf 'notify %s\n' "$*" >>"${CM_TEST_LOG:?}"
exit 0
MOCK
chmod +x "$SIM/bin/notify-send"

mkdir -p "$SIM/home/.themes/Mint-Y-Dark/cinnamon" "$SIM/home/.themes/Mint-Y-Dark/gtk-3.0"
mkdir -p "$SIM/home/.themes/Mint-Y/gtk-3.0" "$SIM/home/.icons/Mint-Y-Dark" "$SIM/home/.icons/Bibata-Modern-Classic"
cat > "$SIM/home/.themes/Mint-Y-Dark/cinnamon/cinnamon.css" <<'CSS'
.panel-top, .panel-bottom { background-color: #222222; color: #dddddd; }
#panel { color: #dddddd; }
.menu, .popup-menu { background-color: #222222; color: #dddddd; }
#Tooltip { background-color: #333333; color: #dddddd; }
CSS
cat > "$SIM/home/.themes/Mint-Y-Dark/gtk-3.0/gtk.css" <<'CSS'
/* isolated test theme */
CSS

run_user(){
 local lang="$1"; shift
 if [ -n "$lang" ]; then
   PATH="$SIM/bin:$PATH" HOME="$SIM/home" CM_HOME="$SIM/cm" CM_LANG_OVERRIDE="$lang" CM_TEST_STATE="$SIM" CM_TEST_LOG="$SIM/log" bash "$SCRIPT" "$@"
 else
   PATH="$SIM/bin:$PATH" HOME="$SIM/home" CM_HOME="$SIM/cm" CM_TEST_STATE="$SIM" CM_TEST_LOG="$SIM/log" bash "$SCRIPT" "$@"
 fi
}
: > "$SIM/log"
run_user en --help >"$SIM/help-en"
run_user es --help >"$SIM/help-es"
grep -q 'GRAPHICAL MODE' "$SIM/help-en" && grep -q 'MODO GRÁFICO' "$SIM/help-es" || fail "user simulation language entry"
run_user en theme list-gtk >/dev/null
run_user en theme list-icon >/dev/null
run_user en desktop list-button-presets >/dev/null
run_user en terminal list >/dev/null
run_user en desktop effects on >"$SIM/effects"
run_user en desktop menu-effects off >"$SIM/menu-effects"
run_user en desktop panel-position top >"$SIM/position"
run_user en desktop window-buttons gnome >"$SIM/buttons"
run_user en desktop hotcorners expo scale none desktop >"$SIM/corners"
run_user en desktop workspaces 6 >"$SIM/workspaces"
run_user en desktop icons hide >"$SIM/icons"
run_user en desktop bg-color '#123456' solo_color >"$SIM/bg"
run_user en terminal apply_palette nord >"$SIM/palette"
run_user en terminal custom-colors '#101010' '#F0F0F0' >"$SIM/custom"
run_user en fonts font 'Noto Sans 11' >"$SIM/font"
run_user en fonts monospace 'Noto Sans Mono 11' >"$SIM/mono"
run_user en fonts rendering rgba slight >"$SIM/rendering"
run_user en fonts scaling 125 >"$SIM/scaling"
run_user en preset save simulated-user >/dev/null
run_user en preset list >"$SIM/presets"
run_user en preset load simulated-user >/dev/null
printf 'LANGUAGE="en"\n' >"$SIM/cm/state.conf"
run_user '' l >"$SIM/toggle"
grep -qx 'Idioma cambiado a español' "$SIM/toggle" || fail "user simulation language toggle"
printf 'LANGUAGE=es\n' >"$SIM/cm/state.conf"
run_user '' desktop effects off >"$SIM/effects-es"
grep -qx 'Efectos de ventana desactivados' "$SIM/effects-es" || fail "user simulation Spanish action after toggle"
grep -qx 'simulated-user' "$SIM/presets" || fail "user simulation preset list"
[ -f "$SIM/home/.config/fontconfig/fonts.conf" ] || fail "user simulation font workflow"
grep -q 'desktop-effects true' "$SIM/log" || fail "user simulation effects write"
grep -q 'desktop-effects-on-menus false' "$SIM/log" || fail "user simulation menu effects write"
grep -q 'num-workspaces 6' "$SIM/log" || fail "user simulation workspace write"
grep -q 'button-layout :close' "$SIM/log" || fail "user simulation button preset write"
grep -q 'dconf write /org/gnome/terminal/legacy/profiles:/:11111111-1111-1111-1111-111111111111/palette' "$SIM/log" || fail "user simulation terminal palette"
pass "simulated end-to-end user journey"

# High-value invariant: every translated selector label must be unique in each
# language. Duplicate visible labels can make reverse mapping select the wrong value.
for lang in es en; do
    checker="$TMP/selector-unique-$lang.sh"
    sed -n '1,/^# Command-line dispatcher/p' "$SCRIPT" | sed '/^# Command-line dispatcher/q' >"$checker"
    cat >>"$checker" <<'EOF'
cm_lang_init(){ :; }
EOF
    cat >>"$checker" <<EOF
CM_LANG="$lang"
cm_apply_language_labels
for name in CM_ACCENT_PRESET_LABELS CM_COLOR_TARGET_LABELS CM_BUTTON_PRESET_LABELS CM_CORNER_LABELS CM_BGMODE_LABELS CM_PANELPOS_LABELS CM_ONOFF_LABELS CM_SHOWHIDE_LABELS CM_PALETTE_LABELS CM_ANTIALIAS_LABELS CM_HINTING_LABELS; do
    declare -n a="\$name"
    declare -A seen=()
    for value in "\${a[@]}"; do
        if [[ -n "\${seen[\$value]+x}" ]]; then
            printf 'duplicate visible label in %s (%s): %s\n' "\$lang" "\$name" "\$value" >&2
            exit 1
        fi
        seen["\$value"]=1
    done
done
EOF
    bash "$checker" || fail "duplicate selector label in $lang"
done
pass "selector visible labels are unique in ES and EN"

# High-value invariant: every FBTN action may only reference fields that exist
# in its own form. This protects the fragile YAD %N wiring from translation edits.
python3 - "$SCRIPT" <<'PYFBTN'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
for m in re.finditer(r'(cm_tab_[a-z_]+\(\) \{.*?\n\})', s, re.S):
    block=m.group(1)
    name=re.match(r'(cm_tab_[a-z_]+)', block).group(1)
    if ':FBTN' not in block:
        continue
    fields=len(re.findall(r'--field=', block))
    for cmd in re.findall(r'cm_fbtn_apply\s+[^\n\"]+', block):
        nums=[int(x) for x in re.findall(r'\b(\d+)\b', cmd)]
        for n in nums[1:]:
            if not 1 <= n <= fields:
                raise SystemExit(f'{name}: FBTN field index {n} outside {fields} fields')
print('PASS: FBTN field indexes stay inside their translated forms')
PYFBTN

# High-value error-path test: backend failures must remain failures and must
# produce the selected language rather than leaking a translated sibling.
cat > "$TMP/mockbin/gsettings" <<'MOCKFAILGSET'
#!/usr/bin/env bash
if [ "${1:-}" = set ]; then
  printf 'mock backend failure\n' >&2
  exit 42
fi
if [ "${1:-}" = get ]; then printf "''\n"; fi
MOCKFAILGSET
chmod +x "$TMP/mockbin/gsettings"
for lang in es en; do
    out="$TMP/error-$lang"
    set +e
    PATH="$TMP/mockbin:$PATH" HOME="$TMP/home-error-$lang" CM_HOME="$TMP/state-error-$lang" CM_LANG_OVERRIDE="$lang" \
      bash "$SCRIPT" desktop effects on >"$out" 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "backend failure returned success ($lang)"
    if [ "$lang" = es ]; then
        grep -q 'ERROR: no se pudo aplicar' "$out" || fail "Spanish backend error missing"
        ! grep -q "ERROR: could not apply" "$out" || fail "English backend error leaked into Spanish"
    else
        grep -q "ERROR: could not apply" "$out" || fail "English backend error missing"
        ! grep -q 'ERROR: no se pudo aplicar' "$out" || fail "Spanish backend error leaked into English"
    fi
done
pass "backend failure paths preserve language and failure semantics"

# Boundary contract: extrema valid values are accepted; just-outside values are rejected.
cat > "$TMP/mockbin/gsettings-success" <<'MOCKBOUNDGSET'
#!/usr/bin/env bash
set -e
state="${CM_TEST_BOUND_STATE:?}"
if [ "${1:-}" = set ]; then
  printf '%s\t%s\n' "$3" "$4" >>"$state"
  [ -n "${CM_TEST_GSET_LOG:-}" ] && printf '%s\n' "$*" >>"$CM_TEST_GSET_LOG"
  exit 0
fi
if [ "${1:-}" = get ]; then
  awk -F '\t' -v key="$3" '$1==key {v=$2} END{if(v!="") print v; else print "24"}' "$state"
  exit 0
fi
exit 1
MOCKBOUNDGSET
mkdir -p "$TMP/bound-bin"
cp "$TMP/mockbin/gsettings-success" "$TMP/bound-bin/gsettings"
chmod +x "$TMP/bound-bin/gsettings"
for lang in es en; do
    mkdir -p "$TMP/home-bound-$lang"
    for spec in 'desktop workspaces 1' 'desktop workspaces 20' 'fonts scaling 50' 'fonts scaling 200' 'theme cursor-size 16' 'theme cursor-size 96'; do
        read -r -a argv <<<"$spec"
        PATH="$TMP/bound-bin:$TMP/mockbin:$PATH" CM_TEST_GSET_LOG="$TMP/bound-$lang.log" CM_TEST_BOUND_STATE="$TMP/bound-$lang.state" HOME="$TMP/home-bound-$lang" \
          CM_HOME="$TMP/state-bound-$lang" CM_LANG_OVERRIDE="$lang" bash "$SCRIPT" "${argv[@]}" >/dev/null 2>&1 || fail "valid boundary rejected: $lang/$spec"
    done
    for spec in 'desktop workspaces 0' 'desktop workspaces 21' 'fonts scaling 49' 'fonts scaling 201' 'theme cursor-size 15' 'theme cursor-size 97'; do
        read -r -a argv <<<"$spec"
        set +e
        PATH="$TMP/bound-bin:$TMP/mockbin:$PATH" CM_TEST_GSET_LOG="$TMP/bound-invalid-$lang.log" CM_TEST_BOUND_STATE="$TMP/bound-invalid-$lang.state" HOME="$TMP/home-bound-invalid-$lang" \
          CM_HOME="$TMP/state-bound-invalid-$lang" CM_LANG_OVERRIDE="$lang" bash "$SCRIPT" "${argv[@]}" >/dev/null 2>&1
        rc=$?
        set -e
        [ "$rc" -ne 0 ] || fail "invalid boundary accepted: $lang/$spec"
        # The backend here accepts every set, so a refusal must come from the range check: a value that got through
        # would be in the state file. With the failing double first it was refused whatever the range.
        [ ! -s "$TMP/bound-invalid-$lang.state" ] || fail "a value outside the range reached gsettings: $lang/$spec"
    done
done
pass "numeric boundary contract"

pass "reset-message bilingual coverage"
printf 'All tests passed.\n'
