#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sandbox.sh
. "$ROOT/tests/lib/sandbox.sh"
SCRIPT="$ROOT/script/color-mint.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/color-mint-functions.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

MOCK="$TMP/mockbin"; mkdir -p "$MOCK"
cat > "$MOCK/gsettings" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
log="${CM_TEST_LOG:?}"
printf 'gsettings %s\n' "$*" >> "$log"
if [ "${1:-}" = get ]; then
    case "${2:-}|${3:-}" in
        'org.cinnamon.desktop.wm.preferences|num-workspaces') printf '4\n' ;;
        'org.cinnamon|desktop-effects') printf 'true\n' ;;
        'org.cinnamon|desktop-effects-on-menus') printf 'true\n' ;;
        *) printf "''\n" ;;
    esac
fi
MOCK
cat > "$MOCK/dconf" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'dconf %s\n' "$*" >> "${CM_TEST_LOG:?}"
case "${1:-}" in
    dump) printf '[mock]\n' ;;
    read) printf "''\n" ;;
    load|write) cat >/dev/null || true ;;
esac
MOCK
cat > "$MOCK/gdbus" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'gdbus %s\n' "$*" >> "${CM_TEST_LOG:?}"
exit 1
MOCK
cat > "$MOCK/yad" <<'MOCK'
#!/usr/bin/env bash
printf 'yad %s\n' "$*" >> "${CM_TEST_LOG:?}"
exit 1
MOCK
chmod 755 "$MOCK"/*

HOME="$TMP/home-cli" CM_HOME="$TMP/cm-cli" CM_LANG_OVERRIDE=en CM_TEST_LOG="$TMP/cli.log" PATH="$MOCK:$PATH" \
    bash "$SCRIPT" desktop effects off >/dev/null 2>&1 || fail 'desktop CLI dispatch'
grep -q 'gsettings set org.cinnamon desktop-effects false' "$TMP/cli.log" || fail 'desktop effects backend contract'

HOME="$TMP/home-cli" CM_HOME="$TMP/cm-cli" CM_LANG_OVERRIDE=en CM_TEST_LOG="$TMP/cli.log" PATH="$MOCK:$PATH" \
    bash "$SCRIPT" desktop workspaces 6 >/dev/null 2>&1 || fail 'workspace CLI dispatch'
grep -q 'gsettings set org.cinnamon.desktop.wm.preferences num-workspaces 6' "$TMP/cli.log" || fail 'workspace backend contract'
pass 'CLI dispatch reaches the expected backend contracts'

BODY="$TMP/body.sh"
awk '/^# Command-line dispatcher/{exit} {print}' "$SCRIPT" > "$BODY"
HOME="$TMP/home-gui" CM_HOME="$TMP/cm-gui" CM_LANG_OVERRIDE=en bash -c '
    source "$1"
    cm_lang_init
    cm_apply_language_labels
    backup_count=0
    cm_ui_backup_before_apply() { backup_count=$((backup_count + 1)); return 0; }
    cm_report() { shift; "$@"; }
    cm_apply_panel_position() { return 0; }
    cm_apply_window_buttons() { return 0; }
    cm_apply_desktop_effects() { return 0; }
    cm_apply_menu_effects() { return 0; }
    cm_apply_workspaces() { return 0; }
    cm_apply_desktop_icons() { return 0; }
    cm_apply_desktop_bg_color() { return 0; }
    cm_reload_cinnamon() { return 0; }
    cm_notify_applied() { return 0; }
    cm_ui_apply_desktop_apply \
        "${CM_PANELPOS_LABELS[top]}" \
        "${CM_BUTTON_PRESET_LABELS[gnome]}" \
        "${CM_ONOFF_LABELS[on]}" \
        "${CM_ONOFF_LABELS[off]}" \
        6 \
        "${CM_SHOWHIDE_LABELS[show]}" \
        "#123456" \
        "${CM_BGMODE_LABELS[solo_color]}" || exit 1
    [ "$backup_count" -eq 1 ]
' bash "$BODY" || fail 'GUI Apply did not protect destructive change with backup'
pass 'GUI Apply functions invoke backup before changes'

set +e
HOME="$TMP/home-gui-failure" CM_HOME="$TMP/cm-gui-failure" CM_LANG_OVERRIDE=en bash -c '
    source "$1"
    cm_lang_init
    cm_ui_backup_before_apply() { return 0; }
    cm_report() { return 37; }
    cm_ui_apply_desktop_apply "top" "gnome" "on" "on" 6 "show" "" "keep"
' bash "$BODY"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'GUI report failure was hidden'
pass 'GUI action status propagates to caller'

set +e
HOME="$TMP/home-apply-failure" CM_HOME="$TMP/cm-apply-failure" CM_LANG_OVERRIDE=en bash "$SCRIPT" __apply desktop_apply >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail '__apply accepted a missing GUI payload'
pass '__apply rejects incomplete GUI payloads with failure'

for lang in en es; do
    HOME="$TMP/home-$lang" CM_HOME="$TMP/cm-$lang" CM_LANG_OVERRIDE="$lang" bash "$SCRIPT" --help >/dev/null 2>&1 || fail "help function path: $lang"
done
pass 'function paths execute in both languages'

# The notice dialog (cm_notify_applied): a success is an info window; a "⚠" line makes it a warning whose title and heading
# end in "with warnings"; a caller whose summary already says that it failed sets CM_NOTIFY_SUFFIX empty and gets neither tail.
NOTICE_LOG="$TMP/notice.log"
cat > "$TMP/notice-case.sh" <<'CASE'
source "$1"
cm_lang_init
cm_notify() { :; }
yad() { { printf 'CALL'; local a; for a in "$@"; do printf '\t%s' "${a//$'\n'/\\n}"; done; printf '\n'; } >> "$NOTICE_LOG"; }
cm_notify_applied "Color Mint" "All done" "first line"
cm_notify_applied "Color Mint" "Applied" "⚠ one step failed" "the rest went fine"
CM_NOTIFY_SUFFIX="" cm_notify_applied "Color Mint" "Could not get it" "⚠ nothing was installed"
CASE
HOME="$TMP/home-notice" CM_HOME="$TMP/cm-notice" CM_LANG_OVERRIDE=en NOTICE_LOG="$NOTICE_LOG" bash "$TMP/notice-case.sh" "$BODY" \
    || fail 'cm_notify_applied did not run'
[ "$(wc -l < "$NOTICE_LOG")" -eq 3 ] || fail "three notices expected: $(cat "$NOTICE_LOG")"
notice_field() { sed -n "${1}p" "$NOTICE_LOG" | tr '\t' '\n' | grep -cxF -- "$2" || true; }   # <line> <argument>: how many times it is an argument
[ "$(notice_field 1 '--info')" -eq 1 ] && [ "$(notice_field 1 '--title=Color Mint')" -eq 1 ] \
    || fail 'a success must be an info window titled with the program name'
[ "$(notice_field 2 '--warning')" -eq 1 ] && [ "$(notice_field 2 '--title=⚠ Color Mint — with warnings')" -eq 1 ] \
    && sed -n 2p "$NOTICE_LOG" | grep -qF 'Applied — with warnings' \
    || fail 'a ⚠ line must make a warning whose title and heading end in "with warnings"'
[ "$(notice_field 3 '--warning')" -eq 1 ] && [ "$(notice_field 3 '--title=⚠ Color Mint')" -eq 1 ] \
    && sed -n 3p "$NOTICE_LOG" | grep -qF '⚠ Could not get it</span>' && ! sed -n 3p "$NOTICE_LOG" | grep -qF 'with warnings' \
    || fail 'an empty CM_NOTIFY_SUFFIX must give the warning with neither tail'
pass 'the notice dialog is an info window, or a warning whose title and heading say "with warnings" unless the caller turns that off'
