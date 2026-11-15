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
command -v flock >/dev/null 2>&1 || fail "flock missing"

BODY="$TMP/functions.sh"
awk '/^# Command-line dispatcher/{exit} {print}' "$SCRIPT" > "$BODY"
export BODY

setup_env() {
    local root="$1" home="$2"
    mkdir -p "$home"
    HOME="$home" CM_HOME="$root" CM_LANG_OVERRIDE=en bash -c 'source "$BODY"'
}

# File replacement stays in the target directory, preserves mode, and leaves no temp file.
HOME="$TMP/home-basic" CM_HOME="$TMP/basic" CM_LANG_OVERRIDE=en bash -c '
    source "$BODY"
    mkdir -p "$HOME/config"
    printf "old\\n" >"$HOME/config/item"
    chmod 600 "$HOME/config/item"
    printf "new\\n" | cm_atomic_write "$HOME/config/item"
    [ "$(cat "$HOME/config/item")" = new ]
    [ "$(stat -c %a "$HOME/config/item")" = 600 ]
    must_print_nothing find "$HOME/config" -maxdepth 1 -name ".item.tmp.*" -print -quit
'
pass "atomic file replacement and permission preservation"

# Concurrent state updates must serialize and produce one valid entry per key.
STATE_HOME="$TMP/home-state" STATE_CM="$TMP/state"
mkdir -p "$STATE_HOME"
for i in $(seq 1 24); do
    HOME="$STATE_HOME" CM_HOME="$STATE_CM" CM_LANG_OVERRIDE=en KEY_NO="$i" bash -c 'source "$BODY"; cm_lang_init; cm_state_set "RACE_${KEY_NO}" "value-${KEY_NO}"' &
done
wait
for i in $(seq 1 24); do
    grep -qx "RACE_${i}=\"value-${i}\"" "$STATE_CM/state.conf" || fail "missing state key $i"
done
[ "$(grep -c '^RACE_[0-9]\+=' "$STATE_CM/state.conf")" -eq 24 ] || fail "duplicate or lost state entries"
must_print_nothing find "$STATE_CM" -maxdepth 1 -name '.state.conf.tmp.*' -print -quit
pass "concurrent state updates"

# Concurrent logging must not lose complete lines or leave an intermediate log.
LOG_HOME="$TMP/home-log" LOG_CM="$TMP/log-state"
mkdir -p "$LOG_HOME"
for i in $(seq 1 24); do
    HOME="$LOG_HOME" CM_HOME="$LOG_CM" CM_LANG_OVERRIDE=en LOG_NO="$i" bash -c 'source "$BODY"; cm_lang_init; cm_log INFO "race-$LOG_NO"' &
done
wait
[ "$(wc -l < "$LOG_CM/logs/color-mint.log")" -eq 24 ] || fail "lost log lines"
for i in $(seq 1 24); do
    grep -q "race-$i$" "$LOG_CM/logs/color-mint.log" || fail "missing log line $i"
done
must_print_nothing find "$LOG_CM/logs" -maxdepth 1 -name '.color-mint.log.tmp.*' -print -quit
pass "concurrent log updates"

# Generator failures must not publish partial state, logs, or managed blocks.
HOME="$TMP/home-state-generator-failure" CM_HOME="$TMP/state-generator-failure" CM_LANG_OVERRIDE=en bash -c '
    source "$BODY"
    cm_lang_init
    printf "%s\n" "KEEP=\"old\"" >"$CM_STATE_FILE"
    cp "$CM_STATE_FILE" "$CM_STATE_FILE.before"
    awk() { return 17; }
    must_fail cm_state_set KEEP new
    cmp "$CM_STATE_FILE.before" "$CM_STATE_FILE"
    must_print_nothing find "$CM_HOME" -maxdepth 1 -name ''.state.conf.build.*'' -print -quit
'
pass "state generator failure keeps previous file"

HOME="$TMP/home-log-generator-failure" CM_HOME="$TMP/log-generator-failure" CM_LANG_OVERRIDE=en bash -c '
    source "$BODY"
    cm_lang_init
    printf "%s\n" "old log line" >"$CM_LOG_FILE"
    cp "$CM_LOG_FILE" "$CM_LOG_FILE.before"
    cat() { return 23; }
    cm_log INFO "must-not-publish"
    cmp "$CM_LOG_FILE.before" "$CM_LOG_FILE"
    must_print_nothing find "$CM_HOME" -type f -name ''.color-mint.log.build.*'' -print -quit
'
pass "log generator failure keeps previous file"

HOME="$TMP/home-marked-generator-failure" CM_HOME="$TMP/marked-generator-failure" CM_LANG_OVERRIDE=en bash -c '
    source "$BODY"
    cm_lang_init
    mkdir -p "$HOME"
    printf "%s\n" "before" "# BEGIN Color Mint TEST" "old" "# END Color Mint TEST" "after" >"$HOME/managed.css"
    cp "$HOME/managed.css" "$HOME/managed.css.before"
    # The first awk is the unclosed-block check and must succeed, so the failure injected is the strip itself.
    calls=0
    awk() { calls=$((calls + 1)); if [ "$calls" -eq 1 ]; then command awk "$@"; else return 29; fi; }
    content="$(printf "%s\n" "# BEGIN Color Mint TEST" "new" "# END Color Mint TEST")"
    must_fail cm_atomic_marked_replace "$HOME/managed.css" "# BEGIN Color Mint TEST" "# END Color Mint TEST" "$content" 2>"$HOME/err"
    [ "$calls" -eq 2 ]
    must_print_nothing cat "$HOME/err"
    cmp "$HOME/managed.css.before" "$HOME/managed.css"
    must_print_nothing find "$HOME" -maxdepth 1 -name ''.managed.css.build.*'' -print -quit
'
pass "managed-block generator failure keeps previous file"

# A block whose closing marker is missing is refused: the strip would drop every line after the opening one.
HOME="$TMP/home-marked-unclosed" CM_HOME="$TMP/marked-unclosed" CM_LANG_OVERRIDE=en bash -c '
    source "$BODY"
    cm_lang_init
    mkdir -p "$HOME"
    B="# BEGIN Color Mint TEST"; E="# END Color Mint TEST"
    f="$HOME/managed.css"
    check() {
        cp "$f" "$f.before"
        must_fail cm_atomic_marked_replace "$f" "$B" "$E" "$B
new
$E" 2>"$HOME/err"
        grep -q "without its closing one" "$HOME/err"
        cmp "$f.before" "$f"
        must_print_nothing find "$HOME" -maxdepth 1 -name ".managed.css.build.*" -print -quit
    }
    printf "%s\n" before "$B" old "user line" > "$f"; check
    printf "%s\n" before "$B" old "$B" old2 "$E" after > "$f"; check
    printf "%s\n" before "$B" old "$E" after > "$f"
    cm_atomic_marked_replace "$f" "$B" "$E" "$B
new
$E"
    [ "$(cat "$f")" = "$(printf "%s\n" before after "$B" new "$E")" ]
    cm_atomic_marked_replace "$f" "$B" "$E" ""
    [ "$(cat "$f")" = "$(printf "%s\n" before after)" ]
'
pass "unclosed or nested managed block is refused and the file is left untouched"

# Managed blocks and generated CSS/font files use the atomic path.
GEN_CASE="$TMP/generated-case.sh"
cat > "$GEN_CASE" <<'CASE'
#!/usr/bin/env bash
set -euo pipefail
source "$BODY"
cm_lang_init
mkdir -p "$HOME"
printf "keep\n# BEGIN Color Mint TEST\nold\n# END Color Mint TEST\nend\n" >"$HOME/managed.css"
content=$(printf '%s\n' '# BEGIN Color Mint TEST' 'new' '# END Color Mint TEST')
cm_atomic_marked_replace "$HOME/managed.css" "# BEGIN Color Mint TEST" "# END Color Mint TEST" "$content"
grep -qx 'keep' "$HOME/managed.css"
grep -qx 'new' "$HOME/managed.css"
[ "$(grep -c '^# BEGIN Color Mint TEST$' "$HOME/managed.css")" -eq 1 ]
printf 'one\n' | cm_atomic_write "$CM_HOME/mode-check"
chmod 600 "$CM_HOME/mode-check"
printf 'two\n' | cm_atomic_write "$CM_HOME/mode-check"
[ "$(stat -c %a "$CM_HOME/mode-check")" = 600 ]
[ "$(cat "$CM_HOME/mode-check")" = two ]
cm_apply_font_rendering rgba slight
grep -q '<const>hints' "$HOME/.config/fontconfig/fonts.conf"
must_print_nothing find "$CM_HOME" "$HOME" -type f \( -name '.*.tmp.*' -o -name '.cm_tmp' \) -print -quit
CASE
chmod +x "$GEN_CASE"
HOME="$TMP/home-generated" CM_HOME="$TMP/generated" CM_LANG_OVERRIDE=en bash "$GEN_CASE"
pass "managed CSS and font configuration"

# A directory is fully staged before it becomes visible at its destination.
HOME="$TMP/home-dir" CM_HOME="$TMP/dir-state" CM_LANG_OVERRIDE=en bash -c '
    source "$BODY"; cm_lang_init
    mkdir -p "$HOME/.themes/source/cinnamon"
    printf css >"$HOME/.themes/source/cinnamon/cinnamon.css"
    printf meta >"$HOME/.themes/source/index.theme"
    cm_atomic_copy_dir_if_missing "$HOME/.themes/source" "$HOME/.themes/copy"
    cmp "$HOME/.themes/source/cinnamon/cinnamon.css" "$HOME/.themes/copy/cinnamon/cinnamon.css"
    [ "$(cat "$HOME/.themes/copy/index.theme")" = meta ]
    mkdir -p "$HOME/pkg/cinnamon"
    printf imported >"$HOME/pkg/cinnamon/cinnamon.css"
    dest=$(cm_import_theme "$HOME/pkg")
    [ -f "$dest/cinnamon/cinnamon.css" ]
    grep -q '^imported$' "$dest/cinnamon/cinnamon.css"
    must_print_nothing find "$HOME/.themes" -maxdepth 1 -name '.color-mint-*' -print -quit
'
pass "atomic directory publication and theme import"

# Simulate a partial directory copy: the staging tree must disappear on failure.
CPMOCK="$TMP/mock-cp"
mkdir -p "$CPMOCK"
cat > "$CPMOCK/cp" <<'MOCKCP'
#!/usr/bin/env bash
set -e
/usr/bin/cp -a -- "$@"
exit 1
MOCKCP
chmod +x "$CPMOCK/cp"
FAIL_CASE="$TMP/dir-failure-case.sh"
cat > "$FAIL_CASE" <<'CASE'
#!/usr/bin/env bash
set -euo pipefail
source "$BODY"
cm_lang_init
mkdir -p "$HOME/source/sub"
printf data >"$HOME/source/sub/file"
must_fail cm_atomic_install_dir "$HOME/source" "$HOME/target"
[ ! -e "$HOME/target" ]
[ -z "$(find "$HOME" -maxdepth 1 -name '.color-mint-import.*' -print -quit)" ]
CASE
chmod +x "$FAIL_CASE"
PATH="$CPMOCK:$PATH" HOME="$TMP/home-dir-failure" CM_HOME="$TMP/dir-failure-state" CM_LANG_OVERRIDE=en bash "$FAIL_CASE"
pass "failed directory publication cleanup"

# Bootstrap must propagate an atomic-write failure instead of reporting success.
BOOT_CASE="$TMP/bootstrap-failure-case.sh"
cat > "$BOOT_CASE" <<'CASE'
#!/usr/bin/env bash
set -euo pipefail
source "$BODY"
cm_lang_init
cm_atomic_write() { return 1; }
must_fail cm_bootstrap_presets
CASE
chmod +x "$BOOT_CASE"
HOME="$TMP/home-bootstrap-failure" CM_HOME="$TMP/bootstrap-failure-state" CM_LANG_OVERRIDE=en bash "$BOOT_CASE"
pass "preset bootstrap write failure"

# A look whose write fails half way: the looks made before it stay and are marked, the failed one is
# neither made nor marked, nothing temporary is left, and the next run makes the rest. A mv that fails for
# one target runs the real cm_atomic_write; the seeds are made first, so the failure is on a look.
LKHOME="$TMP/home-looks" LKCM="$TMP/looks-state" LKSHARE="$TMP/looks-share" LKEMPTY="$TMP/looks-empty" LKMOCK="$TMP/mock-mv"
mkdir -p "$LKHOME" "$LKEMPTY" "$LKSHARE/themes" "$LKSHARE/icons" "$LKMOCK"
for base in Mint-Y Mint-Y-Dark; do
    for color in '' -Aqua -Blue -Grey -Orange -Pink -Purple -Red -Sand -Teal; do
        mkdir -p "$LKSHARE/themes/$base$color/gtk-3.0" "$LKSHARE/themes/$base$color/cinnamon"
        : > "$LKSHARE/themes/$base$color/gtk-3.0/gtk.css"
    done
done
for color in '' -Aqua -Blue -Grey -Orange -Pink -Purple -Red -Sand -Teal; do
    mkdir -p "$LKSHARE/icons/Mint-Y$color"
    printf '[Icon Theme]\nDirectories=16x16/apps\n' > "$LKSHARE/icons/Mint-Y$color/index.theme"
done
mkdir -p "$LKSHARE/icons/Bibata-Modern-Classic/cursors" "$LKSHARE/icons/Bibata-Modern-Ice/cursors"
cat > "$LKMOCK/mv" <<'MOCKMV'
#!/usr/bin/env bash
for last; do :; done
if [ -n "${MV_FAIL:-}" ]; then case "$last" in *"/$MV_FAIL") exit 1 ;; esac; fi
exec /usr/bin/mv "$@"
MOCKMV
chmod +x "$LKMOCK/mv"
look_cm() {   # look_cm <themes folder> <snippet>: MV_FAIL names the file whose publication fails
    HOME="$LKHOME" CM_HOME="$LKCM" XDG_DATA_HOME="$LKHOME/.local/share" XDG_DATA_DIRS="$1" CM_LANG_OVERRIDE=en \
        PATH="$LKMOCK:$PATH" MV_FAIL="${MV_FAIL:-}" bash -c 'source "$BODY"; cm_lang_init; eval "$1"' bash "$2"
}
look_files() { find "$LKCM/presets" -maxdepth 1 -name 'mint-*.conf' -printf '%f\n' | sed 's/\.conf$//' | sort; }
look_marks() { look_cm "$LKEMPTY" 'cm_state_get SEEDED_LOOKS ""' | tr ' ' '\n' | sed '/^$/d' | sort; }
FIRST_LOOKS="$(printf '%s\n' mint-aqua mint-aqua-dark mint-green mint-green-dark)"

look_cm "$LKEMPTY" cm_bootstrap_presets || fail "looks: the seeds were not made"
[ -f "$LKCM/presets/default.conf" ] && [ -f "$LKCM/presets/nord-dark.conf" ] || fail "looks: the seeds are missing"
[ -z "$(look_files)" ] && [ -z "$(look_marks)" ] || fail "looks: a look was made or marked without its themes"

if MV_FAIL=mint-blue.conf look_cm "$LKSHARE" cm_bootstrap_presets 2>/dev/null; then
    fail "looks: a look that could not be written was reported as made"
fi
[ "$(look_files)" = "$FIRST_LOOKS" ] || fail "looks: the looks made before the failure were not kept: $(look_files | tr '\n' ' ')"
[ "$(look_marks)" = "$FIRST_LOOKS" ] || fail "looks: the marks are not exactly the looks made: $(look_marks | tr '\n' ' ')"
[ ! -e "$LKCM/presets/mint-blue.conf" ] || fail "looks: the look that failed was published"
[ -z "$(find "$LKCM" -name '.*.tmp.*' -print -quit)" ] || fail "looks: a temporary file was left"
cp -a "$LKCM/presets" "$TMP/looks-after-failure"

look_cm "$LKSHARE" cm_bootstrap_presets || fail "looks: the run after the failure did not complete"
[ "$(look_files | wc -l)" = 20 ] && [ "$(look_marks | wc -l)" = 20 ] || fail "looks: the next run did not make the rest"
[ -z "$(find "$LKCM" -name '.*.tmp.*' -print -quit)" ] || fail "looks: a temporary file was left after the next run"
for kept in $FIRST_LOOKS default nord-dark; do
    cmp -s "$TMP/looks-after-failure/$kept.conf" "$LKCM/presets/$kept.conf" || fail "looks: the next run rewrote $kept"
done
pass "look write failure keeps and marks the earlier looks, and the next run completes the rest"

# Mock dconf for backup/restore tests.
MOCKBIN="$TMP/mockbin"
mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/dconf" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
op="${1:-}"
case "$op" in
  dump)
    n=0
    [ -f "${DCONF_COUNT:?}" ] && n=$(cat "$DCONF_COUNT")
    n=$((n + 1)); printf '%s\n' "$n" >"$DCONF_COUNT"
    [ "${DCONF_FAIL_DUMP_AT:-0}" -ne "$n" ] || exit 9
    printf '[mock-%s]\nvalue=%s\n' "$2" "$n"
    ;;
  load)
    n=0
    [ -f "${DCONF_LOAD_COUNT:?}" ] && n=$(cat "$DCONF_LOAD_COUNT")
    n=$((n + 1)); printf '%s\n' "$n" >"$DCONF_LOAD_COUNT"
    cat >>"${DCONF_LOAD_LOG:?}"
    printf 'PATH=%s\n' "$2" >>"${DCONF_LOAD_LOG:?}"
    [ "${DCONF_FAIL_LOAD_AT:-0}" -ne "$n" ] || exit 9
    ;;
  *) exit 2 ;;
esac
MOCK
chmod +x "$MOCKBIN/dconf"

# Backup creation publishes one complete directory and cleans up on failure.
BKHOME="$TMP/home-backup" BKCM="$TMP/backup-state"
mkdir -p "$BKHOME/.themes/Original/cinnamon" "$BKHOME/.config/gtk-3.0" "$BKHOME/.config/fontconfig"
printf origcss >"$BKHOME/.themes/Original/cinnamon/cinnamon.css"
printf origgtk >"$BKHOME/.config/gtk-3.0/gtk.css"
printf origfont >"$BKHOME/.config/fontconfig/fonts.conf"
: >"$TMP/dump-count"
PATH="$MOCKBIN:$PATH" DCONF_COUNT="$TMP/dump-count" DCONF_LOAD_COUNT="$TMP/load-count" DCONF_LOAD_LOG="$TMP/load.log" HOME="$BKHOME" CM_HOME="$BKCM" CM_LANG_OVERRIDE=en DCONF_FAIL_DUMP_AT=3 bash -c 'source "$BODY"; cm_lang_init; ! cm_backup_current 2>/dev/null'
[ -z "$(find "$BKCM/backups" -mindepth 1 -maxdepth 1 -name 'backup_*' -print -quit)" ] || fail "partial backup published"
[ -z "$(find "$BKCM/backups" -mindepth 1 -maxdepth 1 -name '.backup.tmp.*' -print -quit)" ] || fail "backup temp leaked"
pass "failed backup cleanup"

rm -f "$TMP/dump-count" "$TMP/load-count" "$TMP/load.log"
export PATH="$MOCKBIN:$PATH" DCONF_COUNT="$TMP/dump-count" DCONF_LOAD_COUNT="$TMP/load-count" DCONF_LOAD_LOG="$TMP/load.log"
name=$(HOME="$BKHOME" CM_HOME="$BKCM" CM_LANG_OVERRIDE=en bash -c 'source "$BODY"; cm_lang_init; cm_backup_current')
[ -d "$BKCM/backups/$name" ] || fail "backup missing"
[ -f "$BKCM/backups/$name/manifest.txt" ] || fail "backup manifest missing"
[ -f "$BKCM/backups/$name/dconf_cinnamon.ini" ] || fail "backup dconf missing"
[ -f "$BKCM/backups/$name/themes_snapshot/Original/cinnamon/cinnamon.css" ] || fail "backup theme missing"
[ -f "$BKCM/backups/$name/gtk-3.0_snapshot/gtk.css" ] || fail "backup gtk snapshot missing"
[ -f "$BKCM/backups/$name/fonts.conf.snapshot" ] || fail "backup font snapshot missing"
[ -z "$(find "$BKCM/backups" -mindepth 1 -maxdepth 1 -name '.backup.tmp.*' -print -quit)" ] || fail "successful backup temp leaked"
pass "complete backup publication"

# Backup creation is serialized and timestamp collisions produce distinct complete entries.
rm -f "$TMP/dump-count" "$TMP/load-count" "$TMP/load.log"
for i in 1 2; do
    HOME="$BKHOME" CM_HOME="$BKCM" CM_LANG_OVERRIDE=en DCONF_COUNT="$TMP/dump-count" DCONF_LOAD_COUNT="$TMP/load-count" DCONF_LOAD_LOG="$TMP/load.log" bash -c 'source "$BODY"; cm_lang_init; cm_backup_current' >"$TMP/backup-$i" &
done
wait
bk_count=$(find "$BKCM/backups" -mindepth 1 -maxdepth 1 -type d -name 'backup_*' | wc -l)
[ "$bk_count" -eq 3 ] || fail "concurrent backup collision handling"
[ -z "$(find "$BKCM/backups" -mindepth 1 -maxdepth 1 -name '.backup.tmp.*' -print -quit)" ] || fail "concurrent backup temp leaked"
pass "concurrent backup publication"

# Successful restore replaces complete trees/files.
printf changed >"$BKHOME/.themes/Original/cinnamon/cinnamon.css"
printf changed >"$BKHOME/.config/gtk-3.0/gtk.css"
printf changed >"$BKHOME/.config/fontconfig/fonts.conf"
rm -f "$TMP/load-count" "$TMP/load.log" "$TMP/dump-count"
HOME="$BKHOME" CM_HOME="$BKCM" CM_LANG_OVERRIDE=en DCONF_FAIL_LOAD_AT=0 bash -c 'source "$BODY"; cm_lang_init; cm_restore_backup "$0"' "$name"
grep -qx origcss "$BKHOME/.themes/Original/cinnamon/cinnamon.css"
grep -qx origgtk "$BKHOME/.config/gtk-3.0/gtk.css"
grep -qx origfont "$BKHOME/.config/fontconfig/fonts.conf"
pass "successful complete restore"

# Restore failure must roll every changed file/tree back, including dconf.
printf changed >"$BKHOME/.themes/Original/cinnamon/cinnamon.css"
printf changed >"$BKHOME/.config/gtk-3.0/gtk.css"
printf changed >"$BKHOME/.config/fontconfig/fonts.conf"
rm -f "$TMP/load-count" "$TMP/load.log" "$TMP/dump-count"
HOME="$BKHOME" CM_HOME="$BKCM" CM_LANG_OVERRIDE=en DCONF_FAIL_LOAD_AT=2 bash -c 'source "$BODY"; cm_lang_init; ! cm_restore_backup "$0" 2>/dev/null' "$name"
grep -qx changed "$BKHOME/.themes/Original/cinnamon/cinnamon.css"
grep -qx changed "$BKHOME/.config/gtk-3.0/gtk.css"
grep -qx changed "$BKHOME/.config/fontconfig/fonts.conf"
[ -z "$(find "$BKCM/backups" -maxdepth 1 \( -name '.restore-rollback.*' -o -name '.color-mint-restore-*' \) -print -quit)" ] || fail "restore temp leaked"
pass "failed restore rollback"

# A failed restore must not recreate a theme tree that did not exist before it started.
theme_saved="$TMP/theme-current-saved"
mv "$BKHOME/.themes" "$theme_saved"
rm -f "$TMP/load-count" "$TMP/load.log" "$TMP/dump-count"
HOME="$BKHOME" CM_HOME="$BKCM" CM_LANG_OVERRIDE=en DCONF_FAIL_LOAD_AT=2 bash -c 'source "$BODY"; cm_lang_init; ! cm_restore_backup "$0" 2>/dev/null' "$name"
[ ! -e "$BKHOME/.themes" ] || fail "restore recreated absent theme tree"
mv "$theme_saved" "$BKHOME/.themes"
pass "failed restore preserves absent tree state"

# A failed restore must not recreate a font file that did not exist before it started.
rm -f "$BKHOME/.config/fontconfig/fonts.conf"
rm -f "$TMP/load-count" "$TMP/load.log" "$TMP/dump-count"
HOME="$BKHOME" CM_HOME="$BKCM" CM_LANG_OVERRIDE=en DCONF_FAIL_LOAD_AT=2 bash -c 'source "$BODY"; cm_lang_init; ! cm_restore_backup "$0" 2>/dev/null' "$name"
[ ! -e "$BKHOME/.config/fontconfig/fonts.conf" ] || fail "restore created font after rollback"
pass "failed restore preserves absent file state"

# Dotfile managers keep ~/.themes, ~/.config/gtk-3.0 and fonts.conf as links. A backup holds what they lead to as
# plain folders and files (links inside a folder stay links), a restore replaces what the link leads to and the link
# stays, and a link that cannot take the restore is named before anything changes.
LKH="$TMP/home-dotlinks" LKC="$TMP/dotlinks-state" DOT="$TMP/home-dotlinks/dotfiles"
mk_dotworld() {
    rm -rf "$LKH" "$LKC"
    mkdir -p "$DOT/themes/Foo" "$DOT/gtk-3.0" "$DOT/other-theme" "$LKH/.config/fontconfig"
    printf idx >"$DOT/themes/Foo/index.theme"
    printf origgtk >"$DOT/gtk-3.0/gtk.css"
    printf origfont >"$DOT/fonts.conf"
    ln -s ../other-theme "$DOT/themes/Inner"
    ln -s "$DOT/themes" "$LKH/.themes"
    ln -s ../dotfiles/gtk-3.0 "$LKH/.config/gtk-3.0"
    ln -s "$DOT/fonts.conf" "$LKH/.config/fontconfig/fonts.conf"
}
dl() { HOME="$LKH" CM_HOME="$LKC" CM_LANG_OVERRIDE=en bash -c 'source "$BODY"; cm_lang_init; "$@"' _ "$@"; }
sig() {   # type, link target or content hash of everything under a folder
    (cd "$1" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
        if [ -L "$p" ]; then printf 'l %s %s\n' "$p" "$(readlink "$p")"
        elif [ -d "$p" ]; then printf 'd %s\n' "$p"
        else printf 'f %s %s\n' "$p" "$(sha256sum <"$p" | cut -d' ' -f1)"; fi
    done)
}
change_dotworld() {
    printf changed >"$DOT/gtk-3.0/gtk.css"; printf changed >"$DOT/fonts.conf"
    mkdir -p "$DOT/themes/New"; printf changed >"$DOT/themes/Foo/index.theme"
}
dot_leftovers() { find "$LKH" "$LKC/backups" \( -name '.color-mint-restore-*' -o -name '.restore-rollback.*' -o -name '.backup.tmp.*' \) -print -quit; }

mk_dotworld
rm -f "$TMP/dump-count" "$TMP/load-count" "$TMP/load.log"
name=$(dl cm_backup_current) || fail "dotlinks: backup of linked dotfiles failed"
BK="$LKC/backups/$name"
for snap_dir in themes_snapshot gtk-3.0_snapshot; do
    [ -d "$BK/$snap_dir" ] && [ ! -L "$BK/$snap_dir" ] || fail "dotlinks: $snap_dir is not a plain folder"
done
[ -f "$BK/fonts.conf.snapshot" ] && [ ! -L "$BK/fonts.conf.snapshot" ] || fail "dotlinks: the fonts.conf snapshot is not a plain file"
[ "$(readlink "$BK/themes_snapshot/Inner")" = ../other-theme ] || fail "dotlinks: a link inside the themes folder was not kept as a link"
[ "$(cat "$BK/gtk-3.0_snapshot/gtk.css")" = origgtk ] && [ "$(cat "$BK/fonts.conf.snapshot")" = origfont ] || fail "dotlinks: the snapshot does not hold what the links lead to"
change_dotworld
[ "$(cat "$BK/gtk-3.0_snapshot/gtk.css")" = origgtk ] && [ ! -e "$BK/themes_snapshot/New" ] && [ "$(cat "$BK/themes_snapshot/Foo/index.theme")" = idx ] \
    || fail "dotlinks: the snapshot follows the live folder instead of being a copy"
pass "backup of dotfiles that are links is a plain copy of what they lead to"

DOT_LINKS="$(readlink "$LKH/.themes") $(readlink "$LKH/.config/gtk-3.0") $(readlink "$LKH/.config/fontconfig/fonts.conf")"
rm -f "$TMP/dump-count" "$TMP/load-count" "$TMP/load.log"
dl cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "dotlinks: restore failed: $(cat "$TMP/err")"
for link in "$LKH/.themes" "$LKH/.config/gtk-3.0" "$LKH/.config/fontconfig/fonts.conf"; do
    [ -L "$link" ] || fail "dotlinks: the restore replaced the link ${link#"$LKH"/}"
done
[ "$(readlink "$LKH/.themes") $(readlink "$LKH/.config/gtk-3.0") $(readlink "$LKH/.config/fontconfig/fonts.conf")" = "$DOT_LINKS" ] || fail "dotlinks: the restore changed where a link leads"
[ "$(cat "$DOT/gtk-3.0/gtk.css")" = origgtk ] && [ "$(cat "$DOT/fonts.conf")" = origfont ] || fail "dotlinks: the restore did not put the files back where the links lead"
[ "$(cat "$DOT/themes/Foo/index.theme")" = idx ] && [ ! -e "$DOT/themes/New" ] || fail "dotlinks: the restore did not put the themes folder back where the link leads"
[ "$(readlink "$DOT/themes/Inner")" = ../other-theme ] || fail "dotlinks: the restore did not put back the link inside the themes folder"
[ -z "$(dot_leftovers)" ] || fail "dotlinks: the restore left a temporary folder: $(dot_leftovers)"
pass "restore into dotfiles that are links puts the content back where the links lead and keeps the links"

# A link that cannot take the restore: broken, leading to the other kind of thing, or in a loop. Every one is named, the
# valid targets keep what they hold, and dconf is not touched (nothing changes before the check passes).
for refusal in themes-broken themes-file gtk-loop fonts-broken fonts-folder; do
    mk_dotworld
    rm -f "$TMP/dump-count" "$TMP/load-count" "$TMP/load.log"
    name=$(dl cm_backup_current) || fail "dotlinks: backup before $refusal failed"
    change_dotworld
    case "$refusal" in
        themes-broken) link="$LKH/.themes"; rm "$link"; ln -s "$LKH/gone" "$link" ;;
        themes-file)   link="$LKH/.themes"; rm "$link"; ln -s "$DOT/fonts.conf" "$link" ;;
        gtk-loop)      link="$LKH/.config/gtk-3.0"; rm "$link"; ln -s "$LKH/.config/loop-b" "$link"; ln -s "$link" "$LKH/.config/loop-b" ;;
        fonts-broken)  link="$LKH/.config/fontconfig/fonts.conf"; rm "$link"; ln -s "$LKH/gone" "$link" ;;
        fonts-folder)  link="$LKH/.config/fontconfig/fonts.conf"; rm "$link"; ln -s "$DOT/themes" "$link" ;;
    esac
    sig "$LKH" >"$TMP/dotsig.before"
    rm -f "$TMP/dump-count" "$TMP/load-count" "$TMP/load.log"
    dl cm_restore_backup "$name" >/dev/null 2>"$TMP/err" && fail "dotlinks: the restore went on with a link that $refusal"
    grep -qF "ERROR: $link is a link and what it points to cannot be written" "$TMP/err" || fail "dotlinks: $refusal: the link was not named: $(cat "$TMP/err")"
    grep -qF "ERROR: could not restore the backup completely" "$TMP/err" || fail "dotlinks: $refusal: the refusal was not summed up: $(cat "$TMP/err")"
    sig "$LKH" | diff "$TMP/dotsig.before" - >/dev/null || fail "dotlinks: $refusal: the restore changed something before it refused"
    [ ! -e "$TMP/load-count" ] || fail "dotlinks: $refusal: the restore reached dconf before it refused"
    [ -z "$(dot_leftovers)" ] || fail "dotlinks: $refusal: the restore left a temporary folder"
done
pass "a link that is broken, leads to the other kind of thing or loops is named and nothing changes"

# The same check with the permissions that matter (root can write anything, so only another user can show them).
if [ "$(id -u)" -eq 0 ]; then
    printf 'SKIP: a link whose target cannot be written needs a user who is not root\n'
else
    mk_dotworld
    name=$(dl cm_backup_current) || fail "dotlinks: backup before the permission cases failed"
    change_dotworld
    chmod a-w "$DOT/fonts.conf"
    sig "$LKH" >"$TMP/dotsig.before"
    dl cm_restore_backup "$name" >/dev/null 2>"$TMP/err" && fail "dotlinks: the restore went on with a fonts.conf link whose file is read-only"
    grep -qF "ERROR: $LKH/.config/fontconfig/fonts.conf is a link" "$TMP/err" || fail "dotlinks: the read-only fonts.conf link was not named: $(cat "$TMP/err")"
    sig "$LKH" | diff "$TMP/dotsig.before" - >/dev/null || fail "dotlinks: the restore changed something beside a read-only fonts.conf"
    chmod u+w "$DOT/fonts.conf"
    chmod a-w "$DOT"
    sig "$LKH" >"$TMP/dotsig.before"
    dl cm_restore_backup "$name" >/dev/null 2>"$TMP/err" && fail "dotlinks: the restore went on in a folder that cannot be written"
    for link in "$LKH/.themes" "$LKH/.config/gtk-3.0" "$LKH/.config/fontconfig/fonts.conf"; do
        grep -qF "ERROR: $link is a link" "$TMP/err" || fail "dotlinks: the link ${link#"$LKH"/} in a read-only folder was not named: $(cat "$TMP/err")"
    done
    sig "$LKH" | diff "$TMP/dotsig.before" - >/dev/null || fail "dotlinks: the restore changed something in a folder that cannot be written"
    chmod u+w "$DOT"
    pass "links whose files or folders cannot be written are named and nothing changes"
fi

# A restore that fails, wherever it fails, puts back what it had changed and touches nothing else.
RBH="$TMP/home-rollback" RBC="$TMP/rollback-state"
rb() { env HOME="$RBH" CM_HOME="$RBC" CM_LANG_OVERRIDE=en bash -c 'source "$BODY"; cm_lang_init; "$@"' _ "$@"; }
rb_dconf_reset() { rm -f "$TMP/dump-count" "$TMP/load-count" "$TMP/load.log"; }
rb_leftovers() { find "$RBH" "$RBC/backups" \( -name '.color-mint-restore-*' -o -name '.restore-rollback.*' -o -name '.backup.tmp.*' -o -name '*.restore-stage.*' \) -print -quit; }
mk_rbworld() {   # a themes folder and a gtk-3.0 folder, no fonts.conf
    rm -rf "$RBH" "$RBC"
    mkdir -p "$RBH/.themes/Foo" "$RBH/.config/gtk-3.0"
    printf orig >"$RBH/.themes/Foo/index.theme"; printf orig >"$RBH/.config/gtk-3.0/gtk.css"
}
rb_change() { printf changed >"$RBH/.themes/Foo/index.theme"; printf changed >"$RBH/.config/gtk-3.0/gtk.css"; }
rb_is() {   # rb_is <orig|changed>: both folders hold that
    [ "$(cat "$RBH/.themes/Foo/index.theme")" = "$1" ] && [ "$(cat "$RBH/.config/gtk-3.0/gtk.css")" = "$1" ]
}

# The backup holds no fonts.conf, the user makes one afterwards, and the restore fails at dconf. The rollback used
# to delete that file although the restore never touched it. The control restores without failing.
mk_rbworld; rb_dconf_reset
name=$(rb cm_backup_current) || fail "rollback: the backup failed"
[ ! -e "$RBC/backups/$name/fonts.conf.snapshot" ] || fail "rollback: the backup holds a fonts.conf it should not have"
mkdir -p "$RBH/.config/fontconfig"; printf userfont >"$RBH/.config/fontconfig/fonts.conf"
rb_change; rb_dconf_reset
DCONF_FAIL_LOAD_AT=2 rb must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "rollback: the restore did not fail at dconf"
grep -qF "ERROR: could not restore the backup completely" "$TMP/err" || fail "rollback: the failed restore did not say so: $(cat "$TMP/err")"
[ "$(cat "$RBH/.config/fontconfig/fonts.conf" 2>/dev/null)" = userfont ] || fail "rollback: a failed restore deleted a fonts.conf it never touched"
rb_is changed || fail "rollback: the failed restore did not put the folders back"
[ -z "$(rb_leftovers)" ] || fail "rollback: the failed restore left a temporary folder: $(rb_leftovers)"
rb_dconf_reset
rb cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "rollback: the control restore failed: $(cat "$TMP/err")"
rb_is orig || fail "rollback: the control restore did not put the folders back"
logline=$(rb eval "printf \"\$(cm_t backup_restored_log)\" \"$name\"")
grep -qF "$logline" "$RBC/logs/color-mint.log" || fail "rollback: a restore that worked was not logged"
[ "$(cat "$RBH/.config/fontconfig/fonts.conf")" = userfont ] || fail "rollback: the control restore touched a fonts.conf the backup does not cover"
pass "a failed restore does not delete a fonts.conf the backup does not cover"

# The second folder cannot be moved aside after the first has been replaced. The first used to stay restored while
# the command said it failed. The mv double fails only when asked to move that folder aside (MV_FAIL_SRC), to move a
# staged copy into place at one path (MV_FAIL_STAGE_DST) or to put a folder moved aside back at one path
# (MV_FAIL_BACK_DST), and logs its calls to MV_LOG; the mktemp double fails for the templates that contain MKTEMP_FAIL.
# MV_LOCK_PROBE names a file that gets "held" or "free" each time a folder moved aside is put back (MV_LOCK_PROBE_FILE is the
# lock file). The control lets everything through.
MVBIN="$TMP/mvbin"; mkdir -p "$MVBIN"
cat >"$MVBIN/mv" <<MV
#!/usr/bin/env bash
[ -z "\${MV_LOG:-}" ] || printf '%s\n' "\$*" >>"\$MV_LOG"
[ "\${MV_FAIL_SRC:-}" != "\${*: -2:1}" ] || exit 1
case "\${*: -2:1}" in
  *restore-stage*) [ "\${MV_FAIL_STAGE_DST:-}" != "\${*: -1}" ] || exit 1 ;;
  */.color-mint-restore-old.*/current)
    [ -z "\${MV_LOCK_PROBE:-}" ] || { ( flock -n 8 ) 8>>"\${MV_LOCK_PROBE_FILE:?}" && echo free || echo held; } >>"\$MV_LOCK_PROBE"
    [ "\${MV_FAIL_BACK_DST:-}" != "\${*: -1}" ] || exit 1 ;;
esac
exec $(command -v mv) "\$@"
MV
cat >"$MVBIN/mktemp" <<MKTEMP
#!/usr/bin/env bash
case "\$*" in *"\${MKTEMP_FAIL:-no-such-template}"*) exit 1 ;; esac
exec $(command -v mktemp) "\$@"
MKTEMP
chmod +x "$MVBIN/mv" "$MVBIN/mktemp"
mk_rbworld; rb_dconf_reset
name=$(rb cm_backup_current) || fail "rollback: the backup before the mv failure failed"
rb_change
sig "$RBH" >"$TMP/rbsig.before"
rb_dconf_reset
MV_FAIL_SRC="$RBH/.config/gtk-3.0" PATH="$MVBIN:$PATH" rb must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "rollback: the restore did not fail when gtk-3.0 could not be moved aside"
grep -qF "ERROR: could not restore the backup completely" "$TMP/err" || fail "rollback: the mv failure was not reported: $(cat "$TMP/err")"
rb_is changed || fail "rollback: ~/.themes stayed restored although the restore failed"
sig "$RBH" | diff "$TMP/rbsig.before" - >/dev/null || fail "rollback: the failed restore changed something"
[ ! -e "$TMP/load-count" ] || fail "rollback: the restore reached dconf after a step had failed"
[ -z "$(rb_leftovers)" ] || fail "rollback: the mv failure left a temporary folder: $(rb_leftovers)"
rb_dconf_reset
PATH="$MVBIN:$PATH" rb cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "rollback: the control with the mv double failed: $(cat "$TMP/err")"
rb_is orig || fail "rollback: the control with the mv double did not restore"
pass "a restore that cannot move the second folder aside puts the first back"

# The staged copy cannot be put in place after the old folder was moved aside: the old one comes back.
rb_change
sig "$RBH" >"$TMP/rbsig.before"
rb_dconf_reset
MV_FAIL_STAGE_DST="$RBH/.config/gtk-3.0" PATH="$MVBIN:$PATH" rb must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "rollback: the restore did not fail when a staged copy could not be put in place"
rb_is changed || fail "rollback: a staged copy that could not be put in place left the folders changed"
sig "$RBH" | diff "$TMP/rbsig.before" - >/dev/null || fail "rollback: the restore changed something when a staged copy could not be put in place"
[ -z "$(rb_leftovers)" ] || fail "rollback: a staged copy that could not be put in place left a temporary folder: $(rb_leftovers)"
pass "a staged copy that cannot be put in place leaves the old folder where it was"

# A restore that fails at dconf puts dconf back to the dump
# it took before starting, and without that dump it does not start. A copy that cannot be prepared stops it before
# anything changes. A folder moved aside that cannot be put back is kept and named (it is then the only copy), and no
# folder is moved to "/current" when the place for it cannot be made. The lock is free again once the restore ends.
K=$(rb eval 'echo ${#CM_DCONF_DUMPS[@]}')
[ "$K" -ge 2 ] || fail "dconf rollback: the programme dumps fewer than two dconf paths, so a failure at the second load cannot be tested"
mk_rbworld; rb_dconf_reset
name=$(rb cm_backup_current) || fail "dconf rollback: the backup failed"
rb_change; rb_dconf_reset; printf 100 >"$TMP/dump-count"
DCONF_FAIL_LOAD_AT=2 rb must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "dconf rollback: the restore did not fail at dconf"
[ "$(cat "$TMP/load-count")" -eq $((2 + K)) ] || fail "dconf rollback: dconf was not loaded back path by path after the failed load (loads: $(cat "$TMP/load-count"), expected $((2 + K)))"
for ((i = 1; i <= K; i++)); do
    grep -qx "value=$((100 + i))" "$TMP/load.log" || fail "dconf rollback: path $i did not go back to the dump taken before the restore"
done
rb_is changed || fail "dconf rollback: the folders were not put back"
[ -z "$(rb_leftovers)" ] || fail "dconf rollback: left a temporary folder: $(rb_leftovers)"
rb_dconf_reset
rb cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "dconf rollback: the control restore failed: $(cat "$TMP/err")"
{ [ "$(cat "$TMP/load-count")" -eq "$K" ] && ! grep -qx 'value=10[0-9]' "$TMP/load.log"; } || fail "dconf rollback: control: a restore that works loaded dconf back as well"
pass "a restore that fails at dconf puts every dconf path back to what it was before it started"

rb_change; sig "$RBH" >"$TMP/rbsig.before"; rb_dconf_reset
DCONF_FAIL_DUMP_AT=1 rb must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "dconf dump: the restore went on although dconf could not be dumped first"
grep -qF "ERROR: could not restore the backup completely" "$TMP/err" || fail "dconf dump: the failed restore did not say so: $(cat "$TMP/err")"
sig "$RBH" | diff "$TMP/rbsig.before" - >/dev/null || fail "dconf dump: the restore changed something before it had the dump"
[ ! -e "$TMP/load-count" ] || fail "dconf dump: the restore reached dconf without the dump"
[ -z "$(rb_leftovers)" ] || fail "dconf dump: left a temporary folder: $(rb_leftovers)"
pass "a restore that cannot dump dconf first does not start"

rb_change; sig "$RBH" >"$TMP/rbsig.before"; rb_dconf_reset
MKTEMP_FAIL="$RBH/.config/.color-mint-restore-stage" PATH="$MVBIN:$PATH" rb must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "staging: the restore went on although a folder could not be prepared"
sig "$RBH" | diff "$TMP/rbsig.before" - >/dev/null || fail "staging: the restore changed something although a folder could not be prepared"
[ ! -e "$TMP/load-count" ] || fail "staging: the restore reached dconf after a folder could not be prepared"
[ -z "$(rb_leftovers)" ] || fail "staging: a folder that could not be prepared left a temporary folder: $(rb_leftovers)"
mk_rbworld; mkdir -p "$RBH/.config/fontconfig"; printf origfont >"$RBH/.config/fontconfig/fonts.conf"; rb_dconf_reset
name=$(rb cm_backup_current) || fail "staging: the backup with a fonts.conf failed"
rb_change; printf changedfont >"$RBH/.config/fontconfig/fonts.conf"; sig "$RBH" >"$TMP/rbsig.before"; rb_dconf_reset
MKTEMP_FAIL=".fonts.conf.restore-stage" PATH="$MVBIN:$PATH" rb must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "staging: the restore went on although a file could not be prepared"
sig "$RBH" | diff "$TMP/rbsig.before" - >/dev/null || fail "staging: the restore changed something although a file could not be prepared"
[ ! -e "$TMP/load-count" ] || fail "staging: the restore reached dconf after a file could not be prepared"
[ -z "$(rb_leftovers)" ] || fail "staging: a file that could not be prepared left a temporary folder: $(rb_leftovers)"
rb_dconf_reset
PATH="$MVBIN:$PATH" rb cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "staging: the control restore failed: $(cat "$TMP/err")"
{ rb_is orig && [ "$(cat "$RBH/.config/fontconfig/fonts.conf")" = origfont ]; } || fail "staging: the control restore did not put everything back"
pass "a folder or a file that cannot be prepared stops the restore before anything changes"

mk_rbworld; rb_dconf_reset
name=$(rb cm_backup_current) || fail "only copy: the backup failed"
rb_change; rb_dconf_reset
MV_FAIL_STAGE_DST="$RBH/.config/gtk-3.0" MV_FAIL_BACK_DST="$RBH/.config/gtk-3.0" PATH="$MVBIN:$PATH" rb must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "only copy: the restore did not fail"
kept=$(find "$RBH/.config" -maxdepth 1 -name '.color-mint-restore-old.*' -print -quit)
{ [ -n "$kept" ] && [ "$(cat "$kept/current/gtk.css" 2>/dev/null)" = changed ]; } || fail "only copy: the folder that could not be put back was not kept"
grep -qF "it is kept at: $kept/current" "$TMP/err" || fail "only copy: the message does not say where the kept folder is: $(cat "$TMP/err")"
[ "$(cat "$RBH/.themes/Foo/index.theme")" = changed ] || fail "only copy: ~/.themes was not put back"
rm -rf "$kept"
[ -z "$(rb_leftovers)" ] || fail "only copy: left more than the kept folder: $(rb_leftovers)"
pass "a folder that cannot be put back is kept and named"

# The same holds while the restore is being undone. gtk-3.0 fails after ~/.themes was replaced, and ~/.themes cannot be
# put back: what was there is then the only copy, so it is kept and named and the other folder goes back. The control
# restores with the same mv double and nothing failing.
mk_rbworld; rb_dconf_reset
name=$(rb cm_backup_current) || fail "undo: the backup failed"
rb_change; rb_dconf_reset
PATH="$MVBIN:$PATH" rb cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "undo: the control restore failed: $(cat "$TMP/err")"
rb_is orig || fail "undo: the control restore did not put the folders back"
rb_change; rb_dconf_reset
MV_FAIL_STAGE_DST="$RBH/.config/gtk-3.0" MV_FAIL_BACK_DST="$RBH/.themes" PATH="$MVBIN:$PATH" rb must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "undo: the restore did not fail"
grep -qF "ERROR: could not restore the backup completely" "$TMP/err" || fail "undo: the failed restore did not say so: $(cat "$TMP/err")"
kept=$(find "$RBH" -maxdepth 1 -name '.color-mint-restore-old.*' -print -quit)
{ [ -n "$kept" ] && [ "$(cat "$kept/current/Foo/index.theme" 2>/dev/null)" = changed ]; } || fail "undo: the folder that could not be put back was not kept"
grep -qF "it is kept at: $kept/current" "$TMP/err" || fail "undo: the message does not say where the kept folder is: $(cat "$TMP/err")"
[ "$(grep -c 'it is kept at' "$TMP/err")" -eq 1 ] || fail "undo: more than the one folder that could not be put back was named: $(cat "$TMP/err")"
[ "$(cat "$RBH/.config/gtk-3.0/gtk.css")" = changed ] || fail "undo: gtk-3.0 was not put back"
rm -rf "$kept"
[ -z "$(rb_leftovers)" ] || fail "undo: left more than the kept folder: $(rb_leftovers)"
pass "a folder that cannot be put back while undoing is kept and named"

# The lock stays held until the restore has been
# undone (another Color Mint could write while folders are moved back): the mv double probes it when ~/.themes goes back.
# The control checks that the probe tells a free lock from a held one.
mk_rbworld; rb_dconf_reset
name=$(rb cm_backup_current) || fail "undo lock: the backup failed"
rb_change; rb_dconf_reset; rm -f "$TMP/lock-probe"
MV_LOCK_PROBE="$TMP/lock-probe" MV_LOCK_PROBE_FILE="$RBC/.lock" "$MVBIN/mv" -T -- "$RBH/.color-mint-restore-old.none/current" "$RBH/none" 2>/dev/null || true
[ "$(cat "$TMP/lock-probe" 2>/dev/null)" = free ] || fail "undo lock: control: the probe did not report a free lock"
rm -f "$TMP/lock-probe"
MV_FAIL_SRC="$RBH/.config/gtk-3.0" MV_LOCK_PROBE="$TMP/lock-probe" MV_LOCK_PROBE_FILE="$RBC/.lock" PATH="$MVBIN:$PATH" rb must_fail cm_restore_backup "$name" >/dev/null 2>&1 || fail "undo lock: the restore did not fail"
[ "$(cat "$TMP/lock-probe" 2>/dev/null)" = held ] || fail "undo lock: the lock was not held while ~/.themes was put back (probe: $(tr '\n' ' ' <"$TMP/lock-probe" 2>/dev/null))"
rb_is changed || fail "undo lock: the folders were not put back"
pass "the lock stays held while a failed restore is undone"

# A restore that cannot take the lock (its file is a link) does not start: nothing changes and nothing is written through the link.
mk_rbworld; rb_dconf_reset
name=$(rb cm_backup_current) || fail "lock refused: the backup failed"
rb_change; rm -f "$RBC/.lock"; : >"$TMP/lock-target"; ln -s "$TMP/lock-target" "$RBC/.lock"
sig "$RBH" >"$TMP/rbsig.before"; rb_dconf_reset
rb must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "lock refused: the restore went on without the lock"
grep -qF "ERROR: could not restore the backup completely" "$TMP/err" || fail "lock refused: the refusal was not reported: $(cat "$TMP/err")"
sig "$RBH" | diff "$TMP/rbsig.before" - >/dev/null || fail "lock refused: the restore changed something without the lock"
[ ! -e "$TMP/load-count" ] || fail "lock refused: the restore reached dconf without the lock"
[ ! -s "$TMP/lock-target" ] || fail "lock refused: something was written through the link"
rm -f "$RBC/.lock"; rb_dconf_reset
rb cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "lock refused: the control restore failed: $(cat "$TMP/err")"
rb_is orig || fail "lock refused: the control restore did not put the folders back"
pass "a restore that cannot take the lock does not start"

# A step with nothing before it (the user deleted fonts.conf after the backup) is undone without naming a kept folder: there
# is none. It fails two ways: its staged copy cannot be put in place, and dconf fails after it was. The control restores.
mk_rbworld; mkdir -p "$RBH/.config/fontconfig"; printf origfont >"$RBH/.config/fontconfig/fonts.conf"; rb_dconf_reset
name=$(rb cm_backup_current) || fail "new file: the backup failed"
rb_change; rm -f "$RBH/.config/fontconfig/fonts.conf"; sig "$RBH" >"$TMP/rbsig.before"; rb_dconf_reset
MV_FAIL_STAGE_DST="$RBH/.config/fontconfig/fonts.conf" PATH="$MVBIN:$PATH" rb must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "new file: the restore did not fail when the staged copy could not be put in place"
sig "$RBH" | diff "$TMP/rbsig.before" - >/dev/null || fail "new file: the restore changed something when the staged copy could not be put in place"
if grep -q 'it is kept at' "$TMP/err"; then fail "new file: a kept folder was named where nothing had been moved aside: $(cat "$TMP/err")"; fi
[ -z "$(rb_leftovers)" ] || fail "new file: left a temporary folder: $(rb_leftovers)"
rb_dconf_reset
DCONF_FAIL_LOAD_AT=2 rb must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "new file: the restore did not fail at dconf"
sig "$RBH" | diff "$TMP/rbsig.before" - >/dev/null || fail "new file: the failed restore did not undo every step"
if grep -q 'it is kept at' "$TMP/err"; then fail "new file: a kept folder was named where nothing had been moved aside (undo): $(cat "$TMP/err")"; fi
[ -z "$(rb_leftovers)" ] || fail "new file: the failed restore left a temporary folder: $(rb_leftovers)"
rb_dconf_reset
rb cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "new file: the control restore failed: $(cat "$TMP/err")"
{ rb_is orig && [ "$(cat "$RBH/.config/fontconfig/fonts.conf")" = origfont ]; } || fail "new file: the control restore did not put everything back"
pass "a step with nothing before it is undone without naming a kept folder"

mk_rbworld; rb_dconf_reset
name=$(rb cm_backup_current) || fail "no place: the backup failed"
rb_change; sig "$RBH" >"$TMP/rbsig.before"; rb_dconf_reset; rm -f "$TMP/mv.log"
MKTEMP_FAIL=".color-mint-restore-old" MV_LOG="$TMP/mv.log" PATH="$MVBIN:$PATH" rb must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "no place: the restore went on although the place to move a folder aside could not be made"
sig "$RBH" | diff "$TMP/rbsig.before" - >/dev/null || fail "no place: the restore changed something"
[ ! -f "$TMP/mv.log" ] || ! grep -q ' /current$' "$TMP/mv.log" || fail "no place: a folder was moved to /current"
[ -z "$(rb_leftovers)" ] || fail "no place: left a temporary folder: $(rb_leftovers)"
pass "a restore that cannot make the place to move a folder aside moves nothing"

rb_lock_state() {   # <backup> <load that fails, 0 for none>: restore, then say whether the lock file can be locked from elsewhere
    env HOME="$RBH" CM_HOME="$RBC" CM_LANG_OVERRIDE=en DCONF_FAIL_LOAD_AT="$2" bash -c 'source "$BODY"; cm_lang_init; cm_restore_backup "$0" >/dev/null 2>&1; ( flock -n 8 ) 8>>"$CM_LOCK_FILE" && echo free || echo held' "$1"
}
[ "$(rb eval 'cm_lock; ( flock -n 8 ) 8>>"$CM_LOCK_FILE" && echo free || echo held')" = held ] || fail "lock: control: a lock that is held was reported free"
rb_change; rb_dconf_reset
[ "$(rb_lock_state "$name" 0)" = free ] || fail "lock: the lock stayed held after a restore that worked"
rb_change; rb_dconf_reset
[ "$(rb_lock_state "$name" 2)" = free ] || fail "lock: the lock stayed held after a restore that failed"
pass "the lock is free again after a restore, whether it worked or failed"

# A restore that cannot make the folder for its dconf dump
# does not start: it says so, changes nothing and frees the lock. Cinnamon is reloaded once after a restore that works and
# not after one that fails. The name of the backup is checked before anything is read: a path in it, an empty name, one that
# does not exist and a backup that is a link are refused. Each control lets the same restore through.
mk_rbworld; rb_dconf_reset
name=$(rb cm_backup_current) || fail "no dump place: the backup failed"
rb_change; sig "$RBH" >"$TMP/rbsig.before"; rb_dconf_reset
MKTEMP_FAIL=".restore-rollback" PATH="$MVBIN:$PATH" rb must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "no dump place: the restore went on although the folder for the dconf dump could not be made"
grep -qF "ERROR: could not restore the backup completely" "$TMP/err" || fail "no dump place: the failed restore did not say so: $(cat "$TMP/err")"
sig "$RBH" | diff "$TMP/rbsig.before" - >/dev/null || fail "no dump place: the restore changed something"
{ [ ! -e "$TMP/dump-count" ] && [ ! -e "$TMP/load-count" ]; } || fail "no dump place: the restore reached dconf"
[ -z "$(rb_leftovers)" ] || fail "no dump place: left a temporary folder: $(rb_leftovers)"
[ "$(MKTEMP_FAIL=".restore-rollback" PATH="$MVBIN:$PATH" rb_lock_state "$name" 0)" = free ] || fail "no dump place: the lock stayed held"
rb_dconf_reset
PATH="$MVBIN:$PATH" rb cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "no dump place: the control restore failed: $(cat "$TMP/err")"
rb_is orig || fail "no dump place: the control restore did not put the folders back"
pass "a restore that cannot make the folder for its dconf dump does not start and frees the lock"

rb_reload() {   # rb_reload <backup> <load that fails, 0 for none>: restore with Cinnamon's reload recorded in $TMP/reloads
    rm -f "$TMP/reloads"
    DCONF_FAIL_LOAD_AT="$2" rb eval "cm_reload_cinnamon() { echo reload >>\"$TMP/reloads\"; }; cm_restore_backup \"$1\"" >/dev/null 2>&1
}
mk_rbworld; rb_dconf_reset
name=$(rb cm_backup_current) || fail "reload: the backup failed"
rb_change; rb_dconf_reset
rb_reload "$name" 0 || fail "reload: the restore failed"
rb_is orig || fail "reload: the restore did not put the folders back"
[ "$(cat "$TMP/reloads" 2>/dev/null)" = reload ] || fail "reload: Cinnamon was not reloaded exactly once after a restore that worked (reloads: $(wc -l <"$TMP/reloads" 2>/dev/null || echo 0))"
rb_change; rb_dconf_reset
rb_reload "$name" 2 && fail "reload: the restore did not fail at dconf"
[ ! -e "$TMP/reloads" ] || fail "reload: Cinnamon was reloaded after a restore that failed"
pass "Cinnamon is reloaded after a restore that worked and not after one that failed"

mk_rbworld; rb_dconf_reset
name=$(rb cm_backup_current) || fail "restore name: the backup failed"
ln -s "$name" "$RBC/backups/linked"
rb_change; sig "$RBH" >"$TMP/rbsig.before"; rb_dconf_reset
for bad in "../$name" "sub/$name" ".." "x..y" "" "no-such-backup" "linked"; do
    rb must_fail cm_restore_backup "$bad" >/dev/null 2>"$TMP/err" || fail "restore name: '$bad' was accepted"
    case "$bad" in
        *..*|*/*) wanted="a backup name cannot contain '/' or '..'" ;;
        "")       wanted="enter the backup name" ;;
        *)        wanted="Backup not found: $bad" ;;
    esac
    grep -qF "$wanted" "$TMP/err" || fail "restore name: '$bad' was refused with another message: $(cat "$TMP/err")"
    sig "$RBH" | diff "$TMP/rbsig.before" - >/dev/null || fail "restore name: '$bad' changed something"
    [ ! -e "$TMP/load-count" ] || fail "restore name: '$bad' reached dconf"
done
rb cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "restore name: the control restore failed: $(cat "$TMP/err")"
rb_is orig || fail "restore name: the control restore did not put the folders back"
pass "a backup name with a path, an empty or unknown name and a backup that is a link are refused before anything changes"

# A step that removes a file is staged as "-": a failed restore must never take that mark for a path. A file called - in the
# folder the restore was started from survives, and the file the step had removed comes back. The control restores for real.
mk_rbworld; rb_dconf_reset
name=$(rb cm_backup_current) || fail "marker: the backup failed"
mkdir -p "$RBH/.config/fontconfig" "$TMP/marker-cwd"
printf '<!-- Color Mint: generated file -->\n' >"$RBH/.config/fontconfig/fonts.conf"; printf keep >"$TMP/marker-cwd/-"
rb_change; rb_dconf_reset
( cd "$TMP/marker-cwd" && DCONF_FAIL_LOAD_AT=2 rb must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" ) || fail "marker: the restore did not fail at dconf"
[ "$(cat "$TMP/marker-cwd/-" 2>/dev/null)" = keep ] || fail "marker: a file called - in the working folder was deleted by the failed restore"
grep -qF 'Color Mint: generated file' "$RBH/.config/fontconfig/fonts.conf" 2>/dev/null || fail "marker: the fonts.conf the step had removed was not put back"
rb_dconf_reset
( cd "$TMP/marker-cwd" && rb cm_restore_backup "$name" >/dev/null 2>"$TMP/err" ) || fail "marker: the control restore failed: $(cat "$TMP/err")"
[ ! -e "$RBH/.config/fontconfig/fonts.conf" ] || fail "marker: the control restore did not remove the fonts.conf it should remove"
[ "$(cat "$TMP/marker-cwd/-" 2>/dev/null)" = keep ] || fail "marker: the control restore deleted a file called -"
pass "a failed restore never takes the remove mark for a file name"


# A backup also keeps what Color Mint writes in ~/.Xresources, gtk-3.0/gtk.css, gtk-4.0/gtk.css, fonts.conf and the
# environment.d file, and a restore puts it back: the Color Mint block (or the whole file), never the user's other lines.
# shellcheck source=lib/doubles.sh
. "$ROOT/tests/lib/doubles.sh"
CRH="$TMP/home-look" CRC="$TMP/look-state" CRDB="$TMP/look-db" CRBIN="$TMP/look-bin" CRD="$TMP/home-look/dotfiles"
cm_double_install "$CRBIN"
cl() { env HOME="$CRH" CM_HOME="$CRC" CM_LANG_OVERRIDE=en PATH="$CRBIN:$PATH" DCONF_DB="$CRDB" bash -c 'source "$BODY"; cm_lang_init; "$@"' _ "$@"; }
cl_leftovers() { find "$CRH" "$CRC/backups" \( -name '.color-mint-restore-*' -o -name '.restore-rollback.*' -o -name '.backup.tmp.*' -o -name '*.restore-stage.*' \) -print -quit; }
cl_db() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$CRDB"; }
CR_SIZE=/org/cinnamon/desktop/interface/cursor-size
mk_lookworld() {   # <with-files 0|1>: the user's own files (or none at all), and cursor-size 24 in the store
    rm -rf "$CRH" "$CRC" "$CRDB" "$CRDB".*
    mkdir -p "$CRH/.config"
    if [ "$1" = 1 ]; then
        mkdir -p "$CRH/.config/gtk-3.0" "$CRH/.config/gtk-4.0"
        printf 'Xft.dpi: 96\n' >"$CRH/.Xresources"
        printf 'user3\n' >"$CRH/.config/gtk-3.0/gtk.css"
        printf 'user4\n' >"$CRH/.config/gtk-4.0/gtk.css"
    fi
    cm_double_db_set "$CRDB" "$CR_SIZE" 24
}
look_use() {   # <cursor size> <accent> [rendering]: what the commands do to those files
    cl cm_apply_cursor_size "$1" 1 >/dev/null 2>"$TMP/err" || fail "look: cursor-size $1 failed: $(cat "$TMP/err")"
    cl cm_apply_gtk_accent_color "$2" >/dev/null 2>"$TMP/err" || fail "look: accent $2 failed: $(cat "$TMP/err")"
    [ -z "${3:-}" ] || cl cm_apply_font_rendering rgba slight >/dev/null 2>"$TMP/err" || fail "look: fonts rendering failed: $(cat "$TMP/err")"
}
look_restore() { cl cm_restore_backup "$1" >/dev/null 2>"$TMP/err" || fail "look: the restore failed: $(cat "$TMP/err")"; }
look_has() { grep -qxF "$2" "$1"; }

# The user's files, a backup, the programme's changes, one more line of the user's, and the restore.
mk_lookworld 1
name=$(cl cm_backup_current) || fail "look: the backup failed"
BK="$CRC/backups/$name"
[ "$(cat "$BK/look.txt")" = "$(printf 'xres=1\ngtk3css=1\ngtk4css=1\nfonts=0\nenvd=0')" ] || fail "look: look.txt does not state which files existed: $(cat "$BK/look.txt")"
[ "$(cl cm_look_files | cut -d'|' -f1 | sort | paste -sd,)" = "$(cut -d= -f1 "$BK/look.txt" | sort | paste -sd,)" ] || fail "look: a file Color Mint writes (cm_look_files) is missing from look.txt"
for part in xres gtk3css gtk4css; do
    [ -f "$BK/look_$part.part" ] && [ ! -s "$BK/look_$part.part" ] || fail "look: look_$part.part should exist and be empty (no block then)"
done
[ ! -e "$BK/look_envd.part" ] && [ ! -e "$BK/look_fonts.part" ] || fail "look: a file that did not exist left a part"
look_use 48 '#aa3366' rendering
printf 'Xft.rgba: rgb\n' >>"$CRH/.Xresources"
look_has "$CRH/.Xresources" 'Xcursor.size: 48' && look_has "$CRH/.config/gtk-3.0/gtk.css" '@define-color accent_color #aa3366;' \
    && look_has "$CRH/.config/gtk-4.0/gtk.css" '@define-color accent_color #aa3366;' && look_has "$CRH/.config/environment.d/60-color-mint-cursor.conf" XCURSOR_SIZE=48 \
    && grep -qF 'Color Mint: generated file' "$CRH/.config/fontconfig/fonts.conf" || fail "look: control: the commands did not write every file"
look_restore "$name"
[ "$(cat "$CRH/.Xresources")" = "$(printf 'Xft.dpi: 96\nXft.rgba: rgb')" ] || fail "look: .Xresources is not the user's lines (the later one kept, the block gone): $(cat "$CRH/.Xresources")"
[ "$(cat "$CRH/.config/gtk-3.0/gtk.css")" = user3 ] || fail "look: gtk-3.0/gtk.css is not what it was"
[ "$(cat "$CRH/.config/gtk-4.0/gtk.css")" = user4 ] || fail "look: gtk-4.0/gtk.css still has the accent block: $(cat "$CRH/.config/gtk-4.0/gtk.css")"
[ ! -e "$CRH/.config/environment.d/60-color-mint-cursor.conf" ] || fail "look: the environment.d file is still there"
[ ! -e "$CRH/.config/fontconfig/fonts.conf" ] || fail "look: a fonts.conf made after the backup is still there"
[ "$(cl_db "$CR_SIZE")" = 24 ] || fail "look: dconf did not go back to cursor-size 24"
[ -z "$(cl_leftovers)" ] || fail "look: the restore left a temporary file: $(cl_leftovers)"
pass "a restore puts back .Xresources, both gtk.css, the environment.d file and an absent fonts.conf, and keeps the user's later lines"

# The block was there when the backup was made: the restore puts back THAT block and keeps the user's later lines.
mk_lookworld 1
look_use 32 '#112233'
name=$(cl cm_backup_current) || fail "look: the backup with blocks failed"
BK="$CRC/backups/$name"
[ "$(cat "$BK/look.txt")" = "$(printf 'xres=1\ngtk3css=1\ngtk4css=1\nfonts=0\nenvd=1')" ] || fail "look: look.txt (blocks present): $(cat "$BK/look.txt")"
look_has "$BK/look_xres.part" 'Xcursor.size: 32' && look_has "$BK/look_gtk4css.part" '@define-color accent_color #112233;' && look_has "$BK/look_envd.part" XCURSOR_SIZE=32 \
    || fail "look: the parts do not hold the blocks and the file"
look_use 48 '#aa3366'
printf 'late\n' >>"$CRH/.config/gtk-4.0/gtk.css"
look_restore "$name"
look_has "$CRH/.Xresources" 'Xcursor.size: 32' && ! look_has "$CRH/.Xresources" 'Xcursor.size: 48' && look_has "$CRH/.Xresources" 'Xft.dpi: 96' || fail "look: .Xresources is not the backup's"
[ "$(grep -cxF '! >>> Color Mint: cursor (autogenerado, no editar a mano) >>>' "$CRH/.Xresources")" -eq 1 ] || fail "look: .Xresources holds the block twice or not at all"
[ "$(cat "$CRH/.config/environment.d/60-color-mint-cursor.conf")" = XCURSOR_SIZE=32 ] || fail "look: the environment.d file is not the backup's"
look_has "$CRH/.config/gtk-4.0/gtk.css" '@define-color accent_color #112233;' && ! look_has "$CRH/.config/gtk-4.0/gtk.css" '@define-color accent_color #aa3366;' \
    && look_has "$CRH/.config/gtk-4.0/gtk.css" user4 && look_has "$CRH/.config/gtk-4.0/gtk.css" late || fail "look: gtk-4.0/gtk.css is not the backup's block plus the user's lines"
[ "$(cl_db "$CR_SIZE")" = 32 ] || fail "look: dconf did not go back to cursor-size 32"
[ -z "$(cl_leftovers)" ] || fail "look: the restore with blocks left a temporary file"
pass "a restore puts back the block the backup had, not just removes it"

# Nothing existed when the backup was made: the files the commands created go, unless the user has written in them since.
mk_lookworld 0
name=$(cl cm_backup_current) || fail "look: the backup of an empty home failed"
[ "$(cat "$CRC/backups/$name/look.txt")" = "$(printf 'xres=0\ngtk3css=0\ngtk4css=0\nfonts=0\nenvd=0')" ] || fail "look: look.txt of an empty home: $(cat "$CRC/backups/$name/look.txt")"
look_use 48 '#aa3366' rendering
printf 'mine\n' >>"$CRH/.config/gtk-3.0/gtk.css"
sed -i '1i mine' "$CRH/.Xresources" && [ "$(head -n 1 "$CRH/.Xresources")" = mine ] || fail "look: control: could not add a user line"
look_restore "$name"
[ "$(cat "$CRH/.config/gtk-3.0/gtk.css")" = mine ] || fail "look: a gtk-3.0/gtk.css that held a user line after the backup was not kept as it is: $(cat "$CRH/.config/gtk-3.0/gtk.css")"
[ "$(cat "$CRH/.Xresources")" = mine ] || fail "look: .Xresources that held a user line after the backup is not just that line"
for gone in .config/gtk-4.0/gtk.css .config/environment.d/60-color-mint-cursor.conf .config/fontconfig/fonts.conf; do
    [ ! -e "$CRH/$gone" ] || fail "look: $gone, made after the backup, is still there"
done
[ -z "$(cl_leftovers)" ] || fail "look: the restore to an empty home left a temporary file"
mk_lookworld 0
name=$(cl cm_backup_current) || fail "look: the second backup of an empty home failed"
look_use 48 '#aa3366'
look_restore "$name"
[ ! -e "$CRH/.Xresources" ] && [ ! -e "$CRH/.config/gtk-3.0/gtk.css" ] && [ ! -e "$CRH/.config/gtk-4.0/gtk.css" ] || fail "look: files that held only Color Mint's block stayed"
pass "files made after the backup are removed unless the user wrote in them"

# A backup made before look.txt existed leaves those files alone (as before).
mk_lookworld 1
name=$(cl cm_backup_current) || fail "look: the backup for the old-format case failed"
look_use 48 '#aa3366' rendering
rm -f "$CRC/backups/$name/look.txt" "$CRC/backups/$name"/look_*.part
look_restore "$name"
look_has "$CRH/.Xresources" 'Xcursor.size: 48' && look_has "$CRH/.config/gtk-4.0/gtk.css" '@define-color accent_color #aa3366;' \
    && look_has "$CRH/.config/environment.d/60-color-mint-cursor.conf" XCURSOR_SIZE=48 && [ -f "$CRH/.config/fontconfig/fonts.conf" ] \
    || fail "look: a backup without look.txt touched the files it does not cover"
[ "$(cl_db "$CR_SIZE")" = 24 ] && [ "$(cat "$CRH/.config/gtk-3.0/gtk.css")" = user3 ] || fail "look: the old-format backup did not restore dconf and the gtk-3.0 folder"
pass "a backup without look.txt does not touch those files"

# What a backup cannot vouch for is left out of look.txt, and a restore uses only what it can vouch for.
mk_lookworld 1
look_use 32 '#112233'
grep -vxF '/* <<< Color Mint: acento GTK global <<< */' "$CRH/.config/gtk-4.0/gtk.css" >"$CRH/gtk4.cut"
mv "$CRH/gtk4.cut" "$CRH/.config/gtk-4.0/gtk.css"
printf 'after\n' >>"$CRH/.config/gtk-4.0/gtk.css"
rm -f "$CRH/.Xresources"; ln -s "$CRH/gone" "$CRH/.Xresources"
name=$(cl cm_backup_current) || fail "look: the backup with a block that is not closed and a broken link failed"
BK="$CRC/backups/$name"
grep -q '^gtk4css=' "$BK/look.txt" && fail "look: look.txt lists a file whose block is not closed"
grep -q '^xres=' "$BK/look.txt" && fail "look: look.txt lists a link that leads nowhere"
[ ! -e "$BK/look_gtk4css.part" ] && [ ! -e "$BK/look_xres.part" ] || fail "look: a file left out of look.txt left a part"
grep -q '^gtk3css=1$' "$BK/look.txt" || fail "look: control: look.txt lost a file that was fine"
cp "$CRH/.config/gtk-4.0/gtk.css" "$TMP/gtk4.before"
look_restore "$name"
cmp -s "$TMP/gtk4.before" "$CRH/.config/gtk-4.0/gtk.css" && [ "$(readlink "$CRH/.Xresources")" = "$CRH/gone" ] || fail "look: a restore touched a file the backup left out"
pass "a block that is not closed or a link that leads nowhere is left out of look.txt and the restore leaves that file alone"

# A backup that holds a link next to its snapshots (a look.txt or a part) is refused before anything changes, and a
# state that is not 0 or 1 is skipped (control: the same backup restores).
mk_lookworld 1
look_use 32 '#112233'
name=$(cl cm_backup_current) || fail "look: the backup for the link checks failed"
BK="$CRC/backups/$name"
cp "$BK/look.txt" "$CRH/look.copy"
look_use 48 '#aa3366'
printf 'Xcursor.size: 99\n' >"$CRH/decoy"
cp "$CRH/.config/gtk-4.0/gtk.css" "$TMP/gtk4.before"
sig "$CRH" >"$TMP/looksig.before"; cp "$CRDB" "$TMP/look-db.before"
mv "$BK/look_xres.part" "$TMP/part.saved"; ln -s "$CRH/decoy" "$BK/look_xres.part"
cl must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "look: the restore went on with a part that is a link"
sig "$CRH" | diff "$TMP/looksig.before" - >/dev/null && cmp -s "$CRDB" "$TMP/look-db.before" || fail "look: a restore refused for a part that is a link changed something"
rm "$BK/look_xres.part"; mv "$TMP/part.saved" "$BK/look_xres.part"
mv "$BK/look.txt" "$TMP/look.moved"; ln -s "$CRH/look.copy" "$BK/look.txt"
cl must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "look: the restore went on with a look.txt that is a link"
sig "$CRH" | diff "$TMP/looksig.before" - >/dev/null && cmp -s "$CRDB" "$TMP/look-db.before" || fail "look: a restore refused for a look.txt that is a link changed something"
rm "$BK/look.txt"; mv "$TMP/look.moved" "$BK/look.txt"
sed -i 's/^gtk4css=1$/gtk4css=x/' "$BK/look.txt"
look_restore "$name"
cmp -s "$TMP/gtk4.before" "$CRH/.config/gtk-4.0/gtk.css" || fail "look: a state that is not 0 or 1 was not skipped"
rm "$BK/look.txt"; cp "$CRH/look.copy" "$BK/look.txt"
look_restore "$name"
look_has "$CRH/.config/gtk-4.0/gtk.css" '@define-color accent_color #112233;' || fail "look: control: the same backup, with a state of 1, did not restore gtk-4.0/gtk.css"
pass "a backup with a link next to its snapshots is refused, and a state that is not 0 or 1 is skipped"

# The mode of a restored file is the one it had, a file the programme did not make is not removed, and a block that
# cannot be staged stops the restore before anything changes.
mk_lookworld 1
chmod 640 "$CRH/.Xresources"
name=$(cl cm_backup_current) || fail "look: the backup for the mode check failed"
look_use 48 '#aa3366'
look_restore "$name"
[ "$(stat -c %a "$CRH/.Xresources")" = 640 ] || fail "look: a restored .Xresources lost its mode: $(stat -c %a "$CRH/.Xresources")"
mk_lookworld 1
name=$(cl cm_backup_current) || fail "look: the backup for the user's own cursor file failed"
mkdir -p "$CRH/.config/environment.d"; printf 'FOO=bar\n' >"$CRH/.config/environment.d/60-color-mint-cursor.conf"
look_restore "$name"
[ "$(cat "$CRH/.config/environment.d/60-color-mint-cursor.conf")" = FOO=bar ] || fail "look: a restore removed an environment.d file that has no XCURSOR_SIZE"
mk_lookworld 1
name=$(cl cm_backup_current) || fail "look: the backup for the staging failure failed"
look_use 48 '#aa3366'
sig "$CRH" >"$TMP/looksig.before"; cp "$CRDB" "$TMP/look-db.before"
cl_stagefail() { env HOME="$CRH" CM_HOME="$CRC" CM_LANG_OVERRIDE=en PATH="$CRBIN:$PATH" DCONF_DB="$CRDB" bash -c 'source "$BODY"; cm_lang_init; cm_stage_restore_block() { return 1; }; "$@"' _ "$@"; }
cl_stagefail must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "look: the restore went on when a block could not be staged"
grep -qF "ERROR: could not restore the backup completely" "$TMP/err" || fail "look: a block that could not be staged was not reported: $(cat "$TMP/err")"
sig "$CRH" | diff "$TMP/looksig.before" - >/dev/null && cmp -s "$CRDB" "$TMP/look-db.before" || fail "look: a restore that could not stage a block changed something"
[ -z "$(cl_leftovers)" ] || fail "look: a restore that could not stage a block left a temporary file: $(cl_leftovers)"
look_restore "$name"
[ "$(cl_db "$CR_SIZE")" = 24 ] || fail "look: control: the restore after the staging failure did not restore"
pass "a restore keeps the mode, leaves an environment.d file that is not Color Mint's and stops when a block cannot be staged"

# Dotfile managers keep them as links: the content goes back where the link leads and the link stays.
mk_lookworld 1
mkdir -p "$CRD" "$CRH/.config/environment.d" "$CRH/.config/fontconfig"
mv "$CRH/.Xresources" "$CRD/Xresources"; ln -s "$CRD/Xresources" "$CRH/.Xresources"
mv "$CRH/.config/gtk-4.0/gtk.css" "$CRD/gtk4.css"; ln -s "$CRD/gtk4.css" "$CRH/.config/gtk-4.0/gtk.css"
printf 'XCURSOR_SIZE=24\n' >"$CRD/env.conf"; ln -s "$CRD/env.conf" "$CRH/.config/environment.d/60-color-mint-cursor.conf"
name=$(cl cm_backup_current) || fail "look: the backup of linked files failed"
look_use 48 '#aa3366'
printf '<!-- Color Mint: generated file -->\n' >"$CRD/fonts.conf"; ln -s "$CRD/fonts.conf" "$CRH/.config/fontconfig/fonts.conf"
LINKS="$(readlink "$CRH/.Xresources") $(readlink "$CRH/.config/gtk-4.0/gtk.css") $(readlink "$CRH/.config/environment.d/60-color-mint-cursor.conf") $(readlink "$CRH/.config/fontconfig/fonts.conf")"
cl cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "look: the restore into linked files failed: $(cat "$TMP/err")"
[ "$(readlink "$CRH/.Xresources") $(readlink "$CRH/.config/gtk-4.0/gtk.css") $(readlink "$CRH/.config/environment.d/60-color-mint-cursor.conf") $(readlink "$CRH/.config/fontconfig/fonts.conf")" = "$LINKS" ] \
    || fail "look: the restore replaced or removed a link"
[ "$(cat "$CRD/Xresources")" = 'Xft.dpi: 96' ] && [ "$(cat "$CRD/gtk4.css")" = user4 ] && [ "$(cat "$CRD/env.conf")" = XCURSOR_SIZE=24 ] \
    || fail "look: the restore did not put the content back where the links lead"
[ -f "$CRD/fonts.conf" ] || fail "look: the restore deleted the file a fonts.conf link leads to"
grep -qF "ERROR" "$TMP/err" && fail "look: the restore reported an error for linked files: $(cat "$TMP/err")"
grep -qF "Leaving $CRH/.config/fontconfig/fonts.conf: it is a link" "$TMP/err" || fail "look: a fonts.conf link that was left was not named: $(cat "$TMP/err")"
[ -z "$(cl_leftovers)" ] || fail "look: the restore into links left a temporary file"
pass "a restore into files that are links puts the content back where they lead, keeps the links and names a fonts.conf link it leaves"

# A restore that cannot be completed is refused before anything changes: a link that leads nowhere where the backup has
# a block, and a block that is not closed. The control restores once the file is right.
mk_lookworld 1
look_use 32 '#112233'
name=$(cl cm_backup_current) || fail "look: the backup before the refusals failed"
look_use 48 '#aa3366'
mv "$CRH/.Xresources" "$CRH/Xres.saved"; ln -s "$CRH/gone" "$CRH/.Xresources"
cp "$CRDB" "$TMP/look-db.before"; sig "$CRH" >"$TMP/looksig.before"
cl cm_restore_backup "$name" >/dev/null 2>"$TMP/err" && fail "look: the restore went on with a .Xresources link that leads nowhere"
grep -qF "ERROR: $CRH/.Xresources is a link and what it points to cannot be written" "$TMP/err" || fail "look: the broken link was not named: $(cat "$TMP/err")"
sig "$CRH" | diff "$TMP/looksig.before" - >/dev/null && cmp -s "$CRDB" "$TMP/look-db.before" || fail "look: the refused restore changed something"
[ -z "$(cl_leftovers)" ] || fail "look: the refused restore left a temporary file"
rm "$CRH/.Xresources"; mv "$CRH/Xres.saved" "$CRH/.Xresources"
grep -vxF '/* <<< Color Mint: acento GTK global <<< */' "$CRH/.config/gtk-4.0/gtk.css" >"$CRH/.config/gtk-4.0/gtk.css.cut"
mv "$CRH/.config/gtk-4.0/gtk.css.cut" "$CRH/.config/gtk-4.0/gtk.css"
cp "$CRDB" "$TMP/look-db.before"; sig "$CRH" >"$TMP/looksig.before"
cl cm_restore_backup "$name" >/dev/null 2>"$TMP/err" && fail "look: the restore went on with a block that is not closed"
grep -qF "ERROR: $CRH/.config/gtk-4.0/gtk.css has the opening marker of a Color Mint block without its closing one" "$TMP/err" || fail "look: the open block was not named: $(cat "$TMP/err")"
sig "$CRH" | diff "$TMP/looksig.before" - >/dev/null && cmp -s "$CRDB" "$TMP/look-db.before" || fail "look: the restore changed something before it refused an open block"
printf '/* <<< Color Mint: acento GTK global <<< */\n' >>"$CRH/.config/gtk-4.0/gtk.css"
look_restore "$name"
look_has "$CRH/.Xresources" 'Xcursor.size: 32' && look_has "$CRH/.config/gtk-4.0/gtk.css" '@define-color accent_color #112233;' || fail "look: the control restore after the refusals did not restore"
pass "a link that leads nowhere or a block that is not closed refuses the restore before anything changes"

# Wherever it fails, a restore puts every one of those files back, and dconf too.
mk_lookworld 1
name=$(cl cm_backup_current) || fail "look: the backup before the failures failed"
look_use 48 '#aa3366' rendering
printf 'Xft.rgba: rgb\n' >>"$CRH/.Xresources"
sig "$CRH" >"$TMP/looksig.before"; cp "$CRDB" "$TMP/look-db.before"
DCONF_FAIL_ONCE=load cl must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err" || fail "look: the restore did not fail at dconf"
grep -qF "ERROR: could not restore the backup completely" "$TMP/err" || fail "look: the dconf failure was not reported: $(cat "$TMP/err")"
sig "$CRH" | diff "$TMP/looksig.before" - >/dev/null || fail "look: a restore that failed at dconf left its files changed"
[ "$(cl_db "$CR_SIZE")" = 48 ] || fail "look: a restore that failed at dconf did not put dconf back"
[ -z "$(cl_leftovers)" ] || fail "look: a restore that failed at dconf left a temporary file: $(cl_leftovers)"
rm -f "$CRDB.failed"
for target in .Xresources .config/gtk-4.0/gtk.css .config/environment.d/60-color-mint-cursor.conf .config/fontconfig/fonts.conf; do
    for mode in MV_FAIL_SRC MV_FAIL_STAGE_DST; do
        # envd and fonts.conf are removed, not replaced: nothing is put in place there
        case "$mode:$target" in MV_FAIL_STAGE_DST:.config/environment.d/*|MV_FAIL_STAGE_DST:.config/fontconfig/*) continue ;; esac
        sig "$CRH" >"$TMP/looksig.before"
        (export "$mode=$CRH/$target"; PATH="$MVBIN:$PATH" cl must_fail cm_restore_backup "$name" >/dev/null 2>"$TMP/err") \
            || fail "look: the restore did not fail with $mode at $target"
        grep -qF "ERROR: could not restore the backup completely" "$TMP/err" || fail "look: $mode at $target was not reported: $(cat "$TMP/err")"
        sig "$CRH" | diff "$TMP/looksig.before" - >/dev/null || fail "look: a restore that failed ($mode) at $target left something changed"
        [ "$(cl_db "$CR_SIZE")" = 48 ] || fail "look: a restore that failed ($mode) at $target reached dconf"
        [ -z "$(cl_leftovers)" ] || fail "look: a restore that failed ($mode) at $target left a temporary file: $(cl_leftovers)"
    done
done
look_restore "$name"
[ "$(cat "$CRH/.config/gtk-4.0/gtk.css")" = user4 ] && [ ! -e "$CRH/.config/environment.d/60-color-mint-cursor.conf" ] && [ "$(cl_db "$CR_SIZE")" = 24 ] \
    || fail "look: the control restore after the failures did not restore"
pass "a restore that fails at dconf or at any of those files puts everything back"


# ~/.themes and ~/.icons are links too. An import lands in the folder the link leads to, the link stays and the
# copy is recorded for `uninstall`; a link that leads nowhere, to a file or in a loop is named and nothing is written.
IMP_SRC="$TMP/imp-src" IMP_TMP="$TMP/imp-tmp"
rm -rf "$IMP_SRC" "$IMP_TMP"
mkdir -p "$IMP_SRC/Linked-Theme/cinnamon" "$IMP_SRC/Linked-Theme/gtk-3.0" "$IMP_SRC/Linked-Cursor/cursors" "$IMP_SRC/Zipped-Theme/cinnamon" "$IMP_TMP"
printf css >"$IMP_SRC/Linked-Theme/cinnamon/cinnamon.css"; printf css >"$IMP_SRC/Linked-Theme/gtk-3.0/gtk.css"
printf '[Icon Theme]\nName=Linked-Cursor\n' >"$IMP_SRC/Linked-Cursor/index.theme"; printf cur >"$IMP_SRC/Linked-Cursor/cursors/left_ptr"
printf css >"$IMP_SRC/Zipped-Theme/cinnamon/cinnamon.css"
(cd "$IMP_SRC" && zip -qr Zipped-Theme.zip Zipped-Theme)
imp() { TMPDIR="$IMP_TMP" dl cm_import_theme "$@"; }
imp_leftovers() {
    find "$IMP_TMP" -mindepth 1 -print -quit
    find "$DOT/themes" "$DOT/icons" -name '.color-mint-import.*' -print -quit 2>/dev/null
}

mk_dotworld
mkdir -p "$DOT/icons"; ln -s "$DOT/icons" "$LKH/.icons"
THEMES_LINK=$(readlink "$LKH/.themes") ICONS_LINK=$(readlink "$LKH/.icons")
mkdir "$DOT/themes/.color-mint-import.control"; [ -n "$(imp_leftovers)" ] || fail "linked import: the leftover check sees nothing in a folder that has a leftover"; rmdir "$DOT/themes/.color-mint-import.control"
out=$(imp "$IMP_SRC/Linked-Theme" 2>"$TMP/err") || fail "linked import: a theme folder was refused: $(cat "$TMP/err")"
[ "$out" = "$LKH/.themes/Linked-Theme" ] && [ -f "$DOT/themes/Linked-Theme/cinnamon/cinnamon.css" ] || fail "linked import: the theme did not land where ~/.themes leads (got: $out)"
out=$(imp "$IMP_SRC/Zipped-Theme.zip" 2>"$TMP/err") || fail "linked import: a zip was refused: $(cat "$TMP/err")"
[ -f "$DOT/themes/Zipped-Theme/cinnamon/cinnamon.css" ] || fail "linked import: the zip did not land where ~/.themes leads (got: $out)"
out=$(imp "$IMP_SRC/Linked-Cursor" 2>"$TMP/err") || fail "linked import: a cursor theme was refused: $(cat "$TMP/err")"
[ -f "$DOT/icons/Linked-Cursor/cursors/left_ptr" ] || fail "linked import: the cursor theme did not land where ~/.icons leads (got: $out)"
[ -L "$LKH/.themes" ] && [ -L "$LKH/.icons" ] && [ "$(readlink "$LKH/.themes")" = "$THEMES_LINK" ] && [ "$(readlink "$LKH/.icons")" = "$ICONS_LINK" ] \
    || fail "linked import: ~/.themes or ~/.icons stopped being the same link"
for rec in themes/Linked-Theme themes/Zipped-Theme icons/Linked-Cursor; do
    grep -qxF "$rec" "$LKC/installed.txt" || fail "linked import: $rec is not in the install record"
done
[ -z "$(imp_leftovers)" ] || fail "linked import: a temporary folder was left: $(imp_leftovers)"
pass "an import into ~/.themes and ~/.icons that are links lands where they lead, keeps them and is recorded"

# A link that cannot take the theme: named, nothing written, no temporary folder.
for refusal in broken file loop; do
    mk_dotworld
    link="$LKH/.themes"; rm "$link"
    case "$refusal" in
        broken) ln -s "$LKH/gone" "$link" ;;
        file)   ln -s "$DOT/fonts.conf" "$link" ;;
        loop)   ln -s "$LKH/loop-b" "$link"; ln -s "$link" "$LKH/loop-b" ;;
    esac
    sig "$LKH" >"$TMP/dotsig.before"
    imp "$IMP_SRC/Linked-Theme" >/dev/null 2>"$TMP/err" && fail "linked import: a link that is $refusal was accepted"
    grep -qF "ERROR: $link is a link and what it points to cannot be written" "$TMP/err" || fail "linked import: $refusal: the link was not named: $(cat "$TMP/err")"
    sig "$LKH" | diff "$TMP/dotsig.before" - >/dev/null || fail "linked import: $refusal: something was written"
    [ ! -e "$LKC/installed.txt" ] && [ -z "$(imp_leftovers)" ] || fail "linked import: $refusal: it recorded or left something"
done
pass "an import through a link that is broken, leads to a file or loops is named and writes nothing"

if [ "$(id -u)" -eq 0 ]; then
    printf 'SKIP: an import into a folder that cannot be written needs a user who is not root\n'
else
    # The folder the link leads to must be writable; the folder that holds it does not have to be.
    mk_dotworld
    chmod a-w "$DOT/themes"
    sig "$LKH" >"$TMP/dotsig.before"
    imp "$IMP_SRC/Linked-Theme" >/dev/null 2>"$TMP/err" && fail "linked import: a themes folder that cannot be written was accepted"
    grep -qF "ERROR: $LKH/.themes is a link" "$TMP/err" || fail "linked import: the read-only themes folder was not named: $(cat "$TMP/err")"
    sig "$LKH" | diff "$TMP/dotsig.before" - >/dev/null || fail "linked import: something was written into a folder that cannot be written"
    chmod u+w "$DOT/themes"
    chmod a-w "$DOT"
    imp "$IMP_SRC/Linked-Theme" >/dev/null 2>"$TMP/err" || fail "linked import: a writable folder inside a read-only parent was refused: $(cat "$TMP/err")"
    [ -f "$DOT/themes/Linked-Theme/cinnamon/cinnamon.css" ] || fail "linked import: nothing landed in the writable folder inside a read-only parent"
    chmod u+w "$DOT"
    pass "an import needs the linked folder to be writable, not the folder that holds it"
fi

# Preset files are data only: shell syntax and unknown keys are rejected without execution.
PRESET_CASE="$TMP/preset-security-case.sh"
cat > "$PRESET_CASE" <<'CASE'
#!/usr/bin/env bash
set -euo pipefail
source "$BODY"
cm_lang_init
mkdir -p "$CM_PRESETS_DIR"
cm_apply_gtk_theme() { printf 'gtk:%s\n' "$1"; }
cm_reload_cinnamon() { :; }
cm_log() { :; }
mkdir -p "$HOME/.themes/Mint-Y/gtk-3.0"   # a preset is checked before it is applied: the theme must exist
printf '%s\n' 'GTK_THEME="Mint-Y"' > "$CM_PRESETS_DIR/good.conf"
cm_load_preset good | grep -qx 'gtk:Mint-Y'
printf '%s\n' 'GTK_THEME="$(touch "$HOME/pwned")"' > "$CM_PRESETS_DIR/inject.conf"
must_fail cm_load_preset inject >/dev/null 2>&1
[ ! -e "$HOME/pwned" ]
printf '%s\n' 'NO_SUCH_KEY="x"' > "$CM_PRESETS_DIR/unknown.conf"
must_fail cm_load_preset unknown >/dev/null 2>&1
CASE
chmod +x "$PRESET_CASE"
HOME="$TMP/home-preset-security" CM_HOME="$TMP/preset-security" CM_LANG_OVERRIDE=en bash "$PRESET_CASE"
pass "preset parser rejects shell injection and unknown keys"


# Strict font rendering rejects unsupported values instead of silently mapping them.
HOME="$TMP/home-render-validation" CM_HOME="$TMP/render-validation" CM_LANG_OVERRIDE=en bash -c '
    source "$BODY"; cm_lang_init
    must_fail cm_apply_font_rendering invalid slight >/dev/null 2>&1
    must_fail cm_apply_font_rendering rgba invalid >/dev/null 2>&1
'
pass "font-rendering value validation"

# Direct folder imports are staged from a stable copy and clean their temporary tree on rejection.
IMPORT_CASE="$TMP/import-cleanup-case.sh"
cat > "$IMPORT_CASE" <<'CASE'
#!/usr/bin/env bash
set -euo pipefail
source "$BODY"
cm_lang_init
mkdir -p "$CM_HOME/tmp" "$HOME/.themes" "$HOME/source-theme/cinnamon"
printf safe > "$HOME/source-theme/cinnamon/cinnamon.css"
ln -s "$HOME/outside" "$HOME/source-theme/cinnamon/link"
printf outside > "$HOME/outside"
TMPDIR="$CM_HOME/tmp"; export TMPDIR
before=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d -print | wc -l)
must_fail cm_import_theme "$HOME/source-theme" >/dev/null 2>&1
[ "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d -print | wc -l)" -eq "$before" ]
CASE
chmod +x "$IMPORT_CASE"
HOME="$TMP/home-import-cleanup" CM_HOME="$TMP/import-cleanup" CM_LANG_OVERRIDE=en bash "$IMPORT_CASE"
pass "rejected direct-theme import cleanup"

# Archive metadata rejects special entries before the extractor runs.
SPECIAL_CASE="$TMP/archive-special-case.sh"
cat > "$SPECIAL_CASE" <<'CASE'
#!/usr/bin/env bash
set -euo pipefail
source "$BODY"
cm_lang_init
mkdir -p "$HOME/.themes" "$HOME/pk"
mkfifo "$HOME/pk/fifo"
(cd "$HOME/pk" && tar -cf "$HOME/fifo.tar" fifo)
must_fail cm_import_theme "$HOME/fifo.tar" >/dev/null 2>&1
[ ! -e "$HOME/.themes/fifo" ]
rm -f "$HOME/pk/fifo"
printf safe > "$HOME/pk/file"
ln -s "$HOME/outside" "$HOME/pk/bad-link"
(cd "$HOME/pk" && zip -q -y "$HOME/bad-types.zip" file bad-link)
mkdir -p "$HOME/mockbin"
cat > "$HOME/mockbin/unzip" <<'MOCK'
#!/usr/bin/env bash
if [ "${1:-}" = -Z1 ]; then exec /usr/bin/unzip "$@"; fi
printf extracted >"$HOME/unzip-was-called"
exit 1
MOCK
chmod +x "$HOME/mockbin/unzip"
PATH="$HOME/mockbin:$PATH"
must_fail cm_import_theme "$HOME/bad-types.zip" >/dev/null 2>&1
[ ! -e "$HOME/unzip-was-called" ] || exit 1
CASE
chmod +x "$SPECIAL_CASE"
HOME="$TMP/home-archive-special" CM_HOME="$TMP/archive-special" CM_LANG_OVERRIDE=en bash "$SPECIAL_CASE"
pass "archive special-file pre-extraction validation"

# A backup root or managed snapshot containing symlinks is rejected before restore.
HOME="$TMP/home-backup-validation" CM_HOME="$TMP/backup-validation" CM_LANG_OVERRIDE=en bash -c '
    source "$BODY"; cm_lang_init
    mkdir -p "$CM_BACKUP_DIR/malicious"
    ln -s /etc "$CM_BACKUP_DIR/malicious/themes_snapshot"
    must_fail cm_restore_backup malicious >/dev/null 2>&1
    rm -rf "$CM_BACKUP_DIR/malicious"
    mkdir -p "$CM_BACKUP_DIR/malicious"
    ln -s /etc/passwd "$CM_BACKUP_DIR/malicious/dconf_cinnamon.ini"
    must_fail cm_restore_backup malicious >/dev/null 2>&1
'
pass "backup snapshot symlink validation"

# A backup may hold links only inside the two snapshot folders, never as them, beside them or as special files.
HOME="$TMP/home-backup-links" CM_HOME="$TMP/backup-links" CM_LANG_OVERRIDE=en bash -c '
    source "$BODY"; cm_lang_init
    b="$CM_BACKUP_DIR/links"
    fresh() { rm -rf "$b"; mkdir -p "$b/themes_snapshot/T/sub" "$b/gtk-3.0_snapshot" "$b/stray"; printf x >"$b/manifest.txt"; }
    fresh
    ln -s ../../dot/Foo "$b/themes_snapshot/T/sub/link"; ln -s /home/x/gtk.css "$b/gtk-3.0_snapshot/gtk.css"; ln -s /nowhere "$b/themes_snapshot/broken"
    cm_validate_extracted_tree "$b" themes_snapshot gtk-3.0_snapshot || { echo "links inside the snapshot folders were refused" >&2; exit 1; }
    must_fail cm_validate_extracted_tree "$b"
    fresh; ln -s /etc "$b/stray/x"
    must_fail cm_validate_extracted_tree "$b" themes_snapshot gtk-3.0_snapshot
    fresh; ln -s /etc/passwd "$b/fonts.conf.snapshot"
    must_fail cm_validate_extracted_tree "$b" themes_snapshot gtk-3.0_snapshot
    fresh; rmdir "$b/gtk-3.0_snapshot"; ln -s /etc "$b/gtk-3.0_snapshot"
    must_fail cm_validate_extracted_tree "$b" themes_snapshot gtk-3.0_snapshot
    fresh; mkfifo "$b/themes_snapshot/fifo"
    must_fail cm_validate_extracted_tree "$b" themes_snapshot gtk-3.0_snapshot
    printf -v nlname "bad\nname"; fresh; ln -s /etc "$b/themes_snapshot/$nlname"
    must_fail cm_validate_extracted_tree "$b" themes_snapshot gtk-3.0_snapshot
'
pass "backup validation accepts links only inside the snapshot folders"

# Theme/font names reject path traversal/control characters before any backend call.
HOME="$TMP/home-name-validation" CM_HOME="$TMP/name-validation" CM_LANG_OVERRIDE=en bash -c '
    source "$BODY"; cm_lang_init
    cm_gset() { return 99; }
    must_fail cm_apply_gtk_theme "../outside"
    must_fail cm_apply_icon_theme "theme/name"
    must_fail cm_apply_cursor_theme "bad..name"
    must_fail cm_apply_cinnamon_theme $'"'"'bad\\name'"'"'
    must_fail cm_apply_font_name $'"'"'Noto\\Sans'"'"'
    must_fail cm_apply_monospace_font $'"'"'bad\tfont'"'"'
'
pass "theme and font name validation"

# Incomplete hot-corner input must default missing positions instead of aborting under set -u.
HOME="$TMP/home-corners" CM_HOME="$TMP/corners" CM_LANG_OVERRIDE=en bash -c '
    source "$BODY"; cm_lang_init
    CM_TEST_GSET=""
    cm_gset() { CM_TEST_GSET="$3"; return 0; }
    cm_apply_hotcorners expo >/dev/null
    [ "$CM_TEST_GSET" = "['expo:true:0', 'expo:false:0', 'expo:false:0', 'expo:false:0']" ]
    must_fail cm_apply_hotcorners bogus >/dev/null 2>&1
'
pass "hot-corner argument validation"

# Archive paths are checked before extraction and extracted trees reject symlinks/special files.
ARCHIVE_CASE="$TMP/archive-security-case.sh"
cat > "$ARCHIVE_CASE" <<'CASE'
#!/usr/bin/env bash
set -euo pipefail
source "$BODY"
cm_lang_init
mkdir -p "$HOME/.themes"
mkdir -p "$HOME/ziproot" "$HOME/tarroot"
printf safe > "$HOME/ziproot/file"
printf outside > "$HOME/outside"
ln -s "$HOME/outside" "$HOME/ziproot/link"
(cd "$HOME/ziproot" && zip -q -y "$HOME/symlink.zip" file link)
mkdir -p "$HOME/evilzip"
(cd "$HOME/evilzip" && zip -q "$HOME/traversal.zip" ../outside)
must_fail cm_import_theme "$HOME/traversal.zip" >/dev/null 2>&1
grep -qx outside "$HOME/outside"
must_fail cm_import_theme "$HOME/symlink.zip" >/dev/null 2>&1
[ ! -e "$HOME/.themes/symlink" ]
mkdir -p "$HOME/tarpkg"
printf safe > "$HOME/tarpkg/file"
ln -s "$HOME/outside" "$HOME/tarpkg/link"
(cd "$HOME/tarpkg" && tar -cf "$HOME/symlink.tar" file link)
must_fail cm_import_theme "$HOME/symlink.tar" >/dev/null 2>&1
[ ! -e "$HOME/.themes/symlink" ]
mkdir -p "$HOME/direct/link-source"
ln -s "$HOME/outside" "$HOME/direct/link-source/outside-link"
must_fail cm_import_theme "$HOME/direct/link-source" >/dev/null 2>&1
CASE
chmod +x "$ARCHIVE_CASE"
HOME="$TMP/home-archive-security" CM_HOME="$TMP/archive-security" CM_LANG_OVERRIDE=en bash "$ARCHIVE_CASE"
pass "theme archive traversal and symlink protection"


# A restore returns every dconf path to its dump EXACTLY. "dconf load" alone keeps a key set after
# the dump (measured with dconf 1.40), so the keys the dump lacks must be reset. The double keeps state.
STATE_BIN="$TMP/state-bin"; mkdir -p "$STATE_BIN"
cat > "$STATE_BIN/dconf" <<'MOCK'
#!/usr/bin/env bash
# Keys live in $DCONF_DB as "full/path<TAB>value".
db="${DCONF_DB:?}"; touch "$db"
case "${1:-}" in
  dump)
    awk -F'\t' -v p="$2" 'index($1, p) == 1 { r = substr($1, length(p) + 1); n = split(r, a, "/")
        k = a[n]; s = (n > 1) ? substr(r, 1, length(r) - length(k) - 1) : "/"; print s "\t" k "\t" $2 }' "$db" |
        LC_ALL=C sort | awk -F'\t' '$1 != last { print "[" $1 "]"; last = $1 } { print $2 "=" $3 }'
    ;;
  load)
    awk -v p="$2" '/^\[/ { s = substr($0, 2, length($0) - 2); next }
        /=/ { k = $0; sub(/=.*/, "", k); v = $0; sub(/^[^=]*=/, "", v)
              print p (s == "/" ? "" : s "/") k "\t" v }' > "$db.new"
    awk -F'\t' 'NR == FNR { new[$1] = $2; next } !($1 in new) { print } END { for (k in new) print k "\t" new[k] }' \
        "$db.new" "$db" > "$db.out"
    mv "$db.out" "$db"; rm -f "$db.new"
    ;;
  reset)
    shift; [ "$1" = -f ] && shift
    awk -F'\t' -v p="$1" 'index($1, p) != 1 { print }' "$db" > "$db.out"; mv "$db.out" "$db"
    ;;
  write)
    awk -F'\t' -v k="$2" '$1 != k { print }' "$db" > "$db.out"; printf '%s\t%s\n' "$2" "$3" >> "$db.out"; mv "$db.out" "$db"
    ;;
  *) exit 2 ;;
esac
MOCK
chmod +x "$STATE_BIN/dconf"
RHOME="$TMP/home-reset" RCM="$TMP/reset-state" RDB="$TMP/reset.db"
mkdir -p "$RHOME"; : > "$RDB"
r() { PATH="$STATE_BIN:$PATH" DCONF_DB="$RDB" HOME="$RHOME" CM_HOME="$RCM" CM_LANG_OVERRIDE=en "$@"; }
r dconf write /org/cinnamon/desktop/interface/cursor-theme "'Orig'"
r dconf write /org/x/apps/portal/color-scheme "'prefer-light'"
r dconf write /org/cinnamon/desktop-effects "true"
name=$(r bash -c 'source "$BODY"; cm_lang_init; cm_backup_current')
[ -f "$RCM/backups/$name/dconf_xapp_portal.ini" ] || fail "backup lacks the portal dump"
grep -q "color-scheme='prefer-light'" "$RCM/backups/$name/dconf_xapp_portal.ini" || fail "portal dump lacks color-scheme"
r dconf write /org/cinnamon/desktop/interface/cursor-theme "'Changed'"
r dconf write /org/cinnamon/desktop/interface/cursor-size "48"
r dconf write /org/cinnamon/new-root-key "1"
r dconf write /org/x/apps/portal/color-scheme "'prefer-dark'"
r dconf write /org/nemo/desktop/show-desktop-icons "false"
r bash -c 'source "$BODY"; cm_lang_init; cm_restore_backup "$0"' "$name" >/dev/null
EXPECT_DB=$(printf '%s\n' '/org/cinnamon/desktop-effects	true' "/org/cinnamon/desktop/interface/cursor-theme	'Orig'" "/org/x/apps/portal/color-scheme	'prefer-light'")
[ "$(LC_ALL=C sort "$RDB")" = "$(printf '%s\n' "$EXPECT_DB" | LC_ALL=C sort)" ] || { cat "$RDB" >&2; fail "restore did not return dconf exactly to the backup"; }
# An old backup without the portal dump leaves the portal path alone.
rm -f "$RCM/backups/$name/dconf_xapp_portal.ini"
r dconf write /org/x/apps/portal/color-scheme "'prefer-dark'"
r bash -c 'source "$BODY"; cm_lang_init; cm_restore_backup "$0"' "$name" >/dev/null
grep -q "color-scheme	'prefer-dark'" "$RDB" || fail "restore touched a path its backup does not cover"
# A failing reset fails the restore and the rollback puts the earlier state back.
r dconf write /org/cinnamon/desktop/interface/cursor-size "48"
BADRESET="$TMP/bad-reset-bin"; mkdir -p "$BADRESET"
printf '#!/usr/bin/env bash\n[ "${1:-}" = reset ] && exit 1\nexec "%s/dconf" "$@"\n' "$STATE_BIN" > "$BADRESET/dconf"; chmod +x "$BADRESET/dconf"
cp "$RDB" "$TMP/reset.before"
PATH="$BADRESET:$STATE_BIN:$PATH" DCONF_DB="$RDB" HOME="$RHOME" CM_HOME="$RCM" CM_LANG_OVERRIDE=en bash -c 'source "$BODY"; cm_lang_init; must_fail cm_restore_backup "$0"' "$name" >/dev/null 2>&1
[ "$(LC_ALL=C sort "$RDB")" = "$(LC_ALL=C sort "$TMP/reset.before")" ] || fail "a failed reset left dconf half restored"
pass "restore returns dconf exactly (reset of newer keys, portal path, old backups, failed reset)"

# Locking must not truncate or follow a symlink to an unrelated file.
HOME="$TMP/home-lock-validation" CM_HOME="$TMP/lock-validation" CM_LANG_OVERRIDE=en bash -c '
    source "$BODY"; cm_lang_init
    mkdir -p "$CM_HOME"
    printf protected > "$CM_HOME/target"
    ln -s "$CM_HOME/target" "$CM_LOCK_FILE"
    must_fail cm_lock
    grep -qx protected "$CM_HOME/target"
    rm -f "$CM_LOCK_FILE" "$CM_HOME/target"
'
pass "lock symlink protection"

# The lock nests. A function that takes it while another holds it (a marked replace inside a restore) must not free
# the outer hold: another process stays locked out until the outermost unlock. Control: once released, it can lock.
HOME="$TMP/home-nested-lock" CM_HOME="$TMP/nested-lock" CM_LANG_OVERRIDE=en bash -c '
    source "$BODY"; cm_lang_init
    set -e   # the program runs without errexit, so a failing check would not stop this block
    mkdir -p "$HOME" "$CM_HOME"
    other_can_lock() { flock -n "$CM_LOCK_FILE" true; }
    other_can_lock
    cm_lock
    must_fail other_can_lock
    cm_lock; cm_unlock
    must_fail other_can_lock
    printf "%s\n" mine >"$HOME/f.css"
    cm_atomic_marked_replace "$HOME/f.css" "# B" "# E" "$(printf "# B\nx\n# E")"
    grep -qx x "$HOME/f.css"
    must_fail other_can_lock
    cm_unlock
    other_can_lock
    [ -z "$CM_LOCK_FD" ]
    [ "$CM_LOCK_DEPTH" -eq 0 ]
    cm_unlock
    [ "$CM_LOCK_DEPTH" -eq 0 ]
    other_can_lock
'
pass "the lock nests: an inner lock and unlock keep the outer hold until the outermost unlock"

# Static guard: the script must not reintroduce known unsafe primitives.
! grep -nE 'mktemp[[:space:]]+-u|^[[:space:]]*source[[:space:]]+|(^|[[:space:]])ls[[:space:]]+-1[[:space:]]+"\\$CM_BACKUP_DIR"' "$SCRIPT" >/dev/null
pass "no known unsafe primitive in the script"

printf '%s\n' 'All atomicity tests passed.'
