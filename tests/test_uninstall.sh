#!/usr/bin/env bash
# install / uninstall: the cycle leaves no trace, and the guards that keep uninstall from deleting what is not Color Mint's.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sandbox.sh
. "$ROOT/tests/lib/sandbox.sh"
# shellcheck source=lib/doubles.sh
. "$ROOT/tests/lib/doubles.sh"
SCRIPT="$ROOT/script/color-mint.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/color-mint-uninstall.XXXXXX")"
# A failed test may leave folders without write permission; they must not stop the cleanup.
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

BIN="$TMP/bin"
cm_double_install "$BIN"

# A world is a HOME that looks like a Cinnamon desktop, plus a dconf key store the doubles share.
# "minimal" has only what any desktop session creates (~/.config, ~/.local/share), so the folders Color Mint makes
# are really made by it. Nothing sets CM_HOME: the program keeps its folder in ~/.local/share/color-mint, so
# comparing the whole HOME before and after also proves that folder is gone. XDG_DATA_DIRS points nowhere: the
# machine's own themes stay out of it.
mkworld() {   # mkworld <id> [full|minimal]
    local w="$TMP/$1" h="$TMP/$1/home"
    rm -rf "$w"; mkdir -p "$h/.config" "$h/.local/share/themes/Mint-Y-Dark/cinnamon" "$h/.local/share/icons/FooCursors/cursors"
    printf '.panel { background-color: #111111; color: #eeeeee; }\n#panel { background-color: #222222; }\n' \
        > "$h/.local/share/themes/Mint-Y-Dark/cinnamon/cinnamon.css"
    if [ "${2:-full}" = full ]; then
        mkdir -p "$h/.config/gtk-3.0" "$h/.config/gtk-4.0" "$h/.local/bin" "$h/.local/share/applications" "$h/.icons/FooCursors/cursors" "$h/.themes" "$h/Documents"
        # An empty folder and an empty file that were there first must still be there at the end.
        : > "$h/.config/gtk-4.0/gtk.css"
        printf '/* mine */\n.user { color: red; }\n' > "$h/.config/gtk-3.0/gtk.css"
        printf 'Xft.dpi: 96\n' > "$h/.Xresources"
        printf 'keep me\n' > "$h/Documents/notes.txt"
        # A fonts.conf the user wrote and an environment.d of their own: Color Mint overwrites the first and joins the second.
        mkdir -p "$h/.config/fontconfig" "$h/.config/environment.d"
        printf '<?xml version="1.0"?>\n<fontconfig><!-- the user'"'"'s own --></fontconfig>\n' > "$h/.config/fontconfig/fonts.conf"
        printf 'EDITOR=nano\n' > "$h/.config/environment.d/10-mine.conf"
    fi
    cm_double_db_set "$w/db" /org/cinnamon/desktop/interface/cursor-size 24
    cm_double_db_set "$w/db" /org/cinnamon/desktop/interface/cursor-theme "'Adwaita'"
    cm_double_db_set "$w/db" /org/cinnamon/theme/name "'Mint-Y-Dark'"
    cm_double_db_set "$w/db" /org/cinnamon/desktop/background/picture-options "'zoom'"
    cm_double_db_set "$w/db" /org/gnome/desktop/interface/gtk-theme "'Mint-Y'"
    cm_double_db_set "$w/db" /org/nemo/preferences/show-hidden-files false
    cm_double_db_set "$w/db" /org/x/apps/portal/color-scheme "'prefer-light'"
}

# cm <world> <args...>: run the program there; RC, and the world's out and err files, hold the result.
# PROG picks the script (the clone by default, the installed copy to run uninstall the way a user does).
PROG="$SCRIPT"; LANGX=en; XENV=(CM_TEST_UNINSTALL=1)   # XENV: extra variables for one run
cm() {
    local w="$1"; shift
    RC=0
    env -u XDG_CURRENT_DESKTOP HOME="$w/home" PATH="$BIN:$PATH" DCONF_DB="$w/db" XDG_DATA_HOME="$w/home/.local/share" \
        XDG_DATA_DIRS="$TMP/no-system-data" CM_LANG_OVERRIDE="$LANGX" "${XENV[@]}" \
        bash "$PROG" "$@" >"$w/out" 2>"$w/err" </dev/null || RC=$?
}

# snap <home>: type, mode and content of everything under it (links by target), one line each.
snap() {
    (cd "$1" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
        if [ -L "$p" ]; then printf 'l %s -> %s\n' "$p" "$(readlink "$p")"
        elif [ -d "$p" ]; then printf 'd %s %s\n' "$(stat -c %a "$p")" "$p"
        else printf 'f %s %s %s\n' "$(stat -c %a "$p")" "$(sha256sum < "$p" | cut -d' ' -f1)" "$p"; fi
    done)
}
dbsnap() { LC_ALL=C sort "$1"; }

# A theme folder to import: a GTK theme has index.theme.
mktheme() { mkdir -p "$1/gtk-3.0"; printf '[Desktop Entry]\nName=Imported\n' > "$1/index.theme"; : > "$1/gtk-3.0/gtk.css"; }

# ---------------------------------------------------------------------------------------------------------------
# The cycle: install, use Color Mint on every kind of thing it writes, uninstall --restore-look.
# ---------------------------------------------------------------------------------------------------------------
mkworld cycle
W="$TMP/cycle"; H="$W/home"
snap "$H" > "$W/home.before"; dbsnap "$W/db" > "$W/db.before"

cm "$W" install
[ "$RC" -eq 0 ] || fail "install failed: $(cat "$W/err")"
[ -x "$H/.local/bin/color-mint" ] || fail 'install left no executable copy'
cmp -s "$SCRIPT" "$H/.local/bin/color-mint" || fail 'the installed copy is not the script'
grep -qx 'X-Color-Mint-Launcher=true' "$H/.local/share/applications/color-mint.desktop" || fail 'the launcher carries no mark'
grep -qx "Exec=\"$H/.local/bin/color-mint\" gui" "$H/.local/share/applications/color-mint.desktop" || fail 'the launcher does not run the installed copy'
grep -qx "Icon=$H/.local/share/color-mint/icon.png" "$H/.local/share/applications/color-mint.desktop" || fail 'the launcher icon is not the state icon'
[ -f "$H/.local/share/color-mint/icon.png" ] || fail 'the launcher icon does not exist'
# install is not read-only, so it makes the program's folder. It records a folder only when it had to create it:
# here ~/.local/bin and the applications folder existed, so there is no installed.txt.
skeleton="$(cd "$H/.local/share/color-mint" && find . -mindepth 1 -maxdepth 1 | LC_ALL=C sort | paste -sd' ')"
[ "$skeleton" = './.lock ./backups ./icon.png ./logs ./presets' ] || fail "the folder install makes changed: $skeleton"
[ -z "$(find "$H/.local/share/color-mint/backups" "$H/.local/share/color-mint/presets" -type f)" ] || fail 'install seeded backups or presets'
[ ! -e "$H/.local/share/color-mint/original" ] || fail 'install saved the original look although it changes nothing'
pass 'install writes a copy, a marked launcher and the folder skeleton, and does not touch the look'

# Use: one command per place Color Mint writes outside its own folder. Every one must have left its mark.
# use_all <world>: the whole set, after install.
use_all() {
    local w="$1" step
    mktheme "$w/src/Imported"
    mkdir -p "$w/src/ImportedIcons/cursors"
    for step in 'theme cursor-size 48' 'theme cursor FooCursors' 'panel gtk-accent #aa3366' 'panel accent #ff0000' \
                'fonts rendering rgba slight' 'desktop workspaces 4' "theme import $w/src/Imported" "theme import $w/src/ImportedIcons" 'backup create'; do
        # shellcheck disable=SC2086  # a command line, split on purpose
        cm "$w" $step
        [ "$RC" -eq 0 ] || fail "the step '$step' failed: $(cat "$w/err")"
    done
}
use_all "$W"
grep -qF '>>> Color Mint: cursor' "$H/.Xresources" || fail 'use left no cursor block in .Xresources'
grep -qF 'Color Mint: acento GTK global' "$H/.config/gtk-3.0/gtk.css" || fail 'use left no accent block in gtk-3.0/gtk.css'
grep -qF 'Color Mint: acento GTK global' "$H/.config/gtk-4.0/gtk.css" || fail 'use left no accent block in gtk-4.0/gtk.css'
grep -qF 'Color Mint: generated file' "$H/.config/fontconfig/fonts.conf" || fail 'use left no fonts.conf'
grep -qx 'XCURSOR_SIZE=48' "$H/.config/environment.d/60-color-mint-cursor.conf" || fail 'use left no environment.d file'
[ -d "$H/.themes/CM-Mint-Y-Dark" ] || fail 'use left no Cinnamon theme copy'
[ -d "$H/.themes/Imported" ] && [ -d "$H/.icons/ImportedIcons" ] || fail 'the imported themes are not in ~/.themes and ~/.icons'
grep -qx 'themes/CM-Mint-Y-Dark' "$H/.local/share/color-mint/installed.txt" || fail 'the Cinnamon copy is not on record'
grep -qx 'themes/Imported' "$H/.local/share/color-mint/installed.txt" && grep -qx 'icons/ImportedIcons' "$H/.local/share/color-mint/installed.txt" \
    || fail 'the imported themes are not on record'
[ -f "$H/.local/share/color-mint/original/manifest.txt" ] || fail 'the first change saved no original look'
grep -qx 'origin=first-change' "$H/.local/share/color-mint/original/manifest.txt" || fail 'the original look is not marked as the first change'
cmp -s "$W/db.before" <(dbsnap "$W/db") && fail 'control: the use did not change the desktop settings'
pass 'control: the use wrote every kind of file the uninstall has to take back'

# Uninstall the way a user does: with the copy that install made, which deletes itself.
PROG="$H/.local/bin/color-mint"
cm "$W" uninstall --restore-look --yes
PROG="$SCRIPT"
[ "$RC" -eq 0 ] || fail "uninstall failed ($RC): $(cat "$W/err")"
grep -q 'Color Mint uninstalled\.' "$W/out" || fail 'uninstall did not say it finished'
grep -q 'Log out and back in' "$W/out" || fail 'uninstall did not warn that cursor and fonts need a new session'
snap "$H" > "$W/home.after"
diff "$W/home.before" "$W/home.after" >"$W/home.diff" || fail "the home is not as it was: $(head -n 8 "$W/home.diff" | tr '\n' '|')"
diff <(dbsnap "$W/db.before") <(dbsnap "$W/db") >"$W/db.diff" || fail "the desktop settings are not as they were: $(head -n 8 "$W/db.diff" | tr '\n' '|')"
pass 'install, full use and uninstall --restore-look leave the home and the desktop settings exactly as they were'


# ---------------------------------------------------------------------------------------------------------------
# Without --restore-look the desktop keeps the look it has; --keep-config also keeps the program's folder.
# ---------------------------------------------------------------------------------------------------------------
mkworld keep
W="$TMP/keep"; H="$W/home"
cm "$W" install; use_all "$W"
snap "$H" > "$W/home.used"; dbsnap "$W/db" > "$W/db.used"
# The look: the files and folders Color Mint wrote outside its own folder.
look_only() { grep -vE ' \./\.local/(bin/color-mint|share/applications/color-mint\.desktop|share/color-mint)(/|$)'; }
cm "$W" uninstall --keep-config --yes
[ "$RC" -eq 0 ] || fail "uninstall --keep-config failed: $(cat "$W/err")"
[ ! -e "$H/.local/bin/color-mint" ] || fail '--keep-config left the program copy'
[ ! -e "$H/.local/share/applications/color-mint.desktop" ] || fail '--keep-config left the launcher'
[ -d "$H/.local/bin" ] && [ -d "$H/.local/share/applications" ] || fail 'uninstall removed folders that were there before'
grep -q "are kept in $H/.local/share/color-mint" "$W/out" || fail 'the plan did not say the configuration is kept'
diff <(look_only < "$W/home.used") <(snap "$H" | look_only) >/dev/null || fail '--keep-config changed the look'
for kept in backups presets original installed.txt state.conf icon.png; do
    [ -e "$H/.local/share/color-mint/$kept" ] || fail "--keep-config deleted $kept"
done
diff <(grep ' \./\.local/share/color-mint/' "$W/home.used" | grep -vE 'logs/color-mint\.log|\.lock') \
     <(snap "$H" | grep ' \./\.local/share/color-mint/' | grep -vE 'logs/color-mint\.log|\.lock') >/dev/null || fail '--keep-config changed what it keeps'
grep -q 'Color Mint uninstalled\.' "$H/.local/share/color-mint/logs/color-mint.log" || fail '--keep-config left no line in the log it keeps'
dbsnap "$W/db" | diff - "$W/db.used" >/dev/null || fail '--keep-config changed the desktop settings'
pass '--keep-config removes the launcher and the copy and keeps the look, the configuration and the settings'

cm "$W" uninstall --yes
[ "$RC" -eq 0 ] || fail "the second uninstall failed: $(cat "$W/err")"
[ ! -e "$H/.local/share/color-mint" ] || fail 'uninstall left the program folder'
diff <(look_only < "$W/home.used") <(snap "$H") >/dev/null || fail 'uninstall without --restore-look changed the look'
dbsnap "$W/db" | diff - "$W/db.used" >/dev/null || fail 'uninstall without --restore-look changed the desktop settings'
grep -qx 'Xft.dpi: 96' "$H/.Xresources" && grep -qF '>>> Color Mint: cursor' "$H/.Xresources" || fail 'the cursor block is gone although the look was to be kept'
grep -q 'keeps its current look' "$W/out" || fail 'the plan did not say the look is kept'
pass 'uninstall without --restore-look keeps the look and removes the program folder'

cm "$W" uninstall --yes
[ "$RC" -eq 0 ] || fail 'uninstall of nothing failed'
grep -q 'nothing of Color Mint to uninstall' "$W/out" || fail 'uninstall of nothing did not say so'
diff <(look_only < "$W/home.used") <(snap "$H") >/dev/null || fail 'uninstall of nothing changed the home'
[ ! -e "$H/.local/share/color-mint" ] || fail 'uninstall of nothing created the program folder'
pass 'a repeated uninstall finds nothing, changes nothing and creates nothing'

# ---------------------------------------------------------------------------------------------------------------
# A home that has only the base folders: every other folder is made by Color Mint and must go with it.
# ---------------------------------------------------------------------------------------------------------------
mkworld minimal minimal
W="$TMP/minimal"; H="$W/home"
snap "$H" > "$W/home.before"; dbsnap "$W/db" > "$W/db.before"
cm "$W" install
[ "$RC" -eq 0 ] || fail "install in a minimal home failed: $(cat "$W/err")"
for made in "$H/.local/bin" "$H/.local/share/applications"; do
    grep -qxF "dir/$made" "$H/.local/share/color-mint/installed.txt" || fail "install did not record the folder it made: $made"
done
use_all "$W"
grep -qx 'origin=first-change' "$H/.local/share/color-mint/original/manifest.txt" || fail 'the folders install recorded made the first change count as earlier use'
for made in .themes .icons .config/gtk-3.0 .config/gtk-4.0 .config/fontconfig .config/environment.d; do
    [ -d "$H/$made" ] || fail "control: the use did not make ~/$made"
done
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] || fail "uninstall in a minimal home failed: $(cat "$W/err")"
snap "$H" | diff "$W/home.before" - >"$W/home.diff" || fail "the minimal home is not as it was: $(head -n 8 "$W/home.diff" | tr '\n' '|')"
dbsnap "$W/db" | diff "$W/db.before" - >/dev/null || fail 'the minimal home: the desktop settings are not as they were'
pass 'folders that Color Mint made (launcher, bin, GTK, fonts, themes, icons) are removed again, and only those'

# ---------------------------------------------------------------------------------------------------------------
# install: repeatable, and it never overwrites what is not Color Mint's.
# ---------------------------------------------------------------------------------------------------------------
mkworld inst minimal
W="$TMP/inst"; H="$W/home"
cm "$W" install; [ "$RC" -eq 0 ] || fail 'first install failed'
sha256sum "$H/.local/bin/color-mint" "$H/.local/share/applications/color-mint.desktop" "$H/.local/share/color-mint/installed.txt" > "$W/sums"
cm "$W" install
[ "$RC" -eq 0 ] || fail "a second install failed: $(cat "$W/err")"
sha256sum --check --quiet "$W/sums" >/dev/null 2>&1 || fail 'a second install changed what the first wrote'
[ "$(grep -c . "$H/.local/share/color-mint/installed.txt")" -eq 2 ] || fail 'a second install recorded the folders again'
pass 'install twice writes the same files and records each folder once'

mkworld foreign minimal
W="$TMP/foreign"; H="$W/home"
mkdir -p "$H/.local/bin" "$H/.local/share/applications"
printf '[Desktop Entry]\nName=Mine\n' > "$H/.local/share/applications/color-mint.desktop"
printf '#!/bin/sh\necho mine\n' > "$H/.local/bin/color-mint"; chmod 755 "$H/.local/bin/color-mint"
snap "$H" | grep -v 'color-mint$' > "$W/home.before"
sha256sum "$H/.local/share/applications/color-mint.desktop" "$H/.local/bin/color-mint" > "$W/sums"
cm "$W" install
[ "$RC" -ne 0 ] || fail 'install overwrote a copy that is not Color Mint'
grep -q "already exists and is not Color Mint's" "$W/err" || fail 'install did not say why it refused'
sha256sum --check --quiet "$W/sums" >/dev/null 2>&1 || fail 'install changed a file that is not Color Mint'"'"'s'
rm -f "$H/.local/bin/color-mint"
cm "$W" install
[ "$RC" -ne 0 ] || fail 'install overwrote a launcher that is not Color Mint'"'"'s'
[ ! -e "$H/.local/bin/color-mint" ] || fail 'install wrote the copy although the launcher was refused'
pass 'install refuses a launcher or a copy that is not its own, and says so'

cm "$W" uninstall --yes
[ "$RC" -eq 0 ] || fail "uninstall beside a foreign launcher failed: $(cat "$W/err")"
grep -q 'did not record it as its own' "$W/err" || fail 'uninstall did not name the launcher it left'
grep -qx 'Name=Mine' "$H/.local/share/applications/color-mint.desktop" || fail 'uninstall deleted a launcher that is not Color Mint'"'"'s'
pass 'uninstall leaves a launcher that is not its own and names it'

# The same refusal with only the copy in the way: nothing is written, not even the launcher.
mkworld foreigncopy minimal
W="$TMP/foreigncopy"; H="$W/home"
mkdir -p "$H/.local/bin"
printf '#!/bin/sh\necho mine\n' > "$H/.local/bin/color-mint"; chmod 755 "$H/.local/bin/color-mint"
sha256sum "$H/.local/bin/color-mint" > "$W/sums"
cm "$W" install
[ "$RC" -ne 0 ] || fail 'install overwrote a copy that is not Color Mint'"'"'s although no launcher was in the way'
grep -q "already exists and is not Color Mint's" "$W/err" || fail 'install did not say why it refused the copy'
sha256sum --check --quiet "$W/sums" >/dev/null 2>&1 || fail 'install changed a copy that is not Color Mint'"'"'s'
[ ! -e "$H/.local/share/applications/color-mint.desktop" ] || fail 'install wrote the launcher although the copy was refused'
pass 'install refuses a program copy that is not its own even when nothing else is in the way, and writes no launcher'

# ---------------------------------------------------------------------------------------------------------------
# --restore-look with no saved original look: it says so and changes nothing but what uninstall always removes.
# ---------------------------------------------------------------------------------------------------------------
mkworld nochange
W="$TMP/nochange"; H="$W/home"
snap "$H" > "$W/home.before"; dbsnap "$W/db" > "$W/db.before"
cm "$W" install
[ "$RC" -eq 0 ] || fail 'install failed'
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] || fail "uninstall --restore-look after install alone failed: $(cat "$W/err")"
grep -q 'has not changed the desktop: there is no look to restore' "$W/out" || fail 'the plan did not say there is nothing to restore'
snap "$H" | diff "$W/home.before" - >/dev/null || fail 'install + uninstall --restore-look left a trace'
pass 'install followed by uninstall --restore-look leaves nothing and says there was no look to restore'

# A first change of the look is what saves the original; a backup made before it means Color Mint was used first.
mkworld prior
W="$TMP/prior"; H="$W/home"
cm "$W" install; cm "$W" backup create
[ "$RC" -eq 0 ] || fail 'backup create failed'
[ ! -e "$H/.local/share/color-mint/original" ] || fail 'a backup saved an original look'
cm "$W" uninstall --restore-look --yes --keep-config
grep -q 'used before the original look could be saved' "$W/out" || fail 'the plan did not warn that nothing can be restored after prior use'
cm "$W" theme cursor-size 48
[ "$RC" -eq 0 ] || fail 'theme cursor-size failed'
grep -qx 'origin=prior-use' "$H/.local/share/color-mint/original/manifest.txt" || fail 'the original look does not say it was saved after earlier use'
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] || fail "uninstall of a prior-use original failed: $(cat "$W/err")"
grep -q 'may not be the factory one' "$W/out" || fail 'the plan did not warn that the saved look may not be the factory one'
dbsnap "$W/db" | grep -qx "$(printf '/org/cinnamon/desktop/interface/cursor-size\t24')" || fail 'the saved look was not restored'
# The other two traces of earlier use: a setting in the state file, a theme on the install record.
for seed in state record; do
    mkworld "prior-$seed" minimal; W="$TMP/prior-$seed"; H="$W/home"
    cm "$W" install
    case "$seed" in
        state)  printf 'ACCENT_COLOR="#ff0000"\n' >> "$H/.local/share/color-mint/state.conf" ;;
        record) printf 'themes/Old\n' >> "$H/.local/share/color-mint/installed.txt" ;;
    esac
    cm "$W" theme cursor-size 48
    [ "$RC" -eq 0 ] || fail "theme cursor-size failed after a $seed from before: $(cat "$W/err")"
    grep -qx 'origin=prior-use' "$H/.local/share/color-mint/original/manifest.txt" || fail "a $seed from before is not counted as earlier use"
done
pass 'a backup, a setting or a theme from before mark the saved look as earlier use; it is restored and the plan warns it may not be the factory one'

# ---------------------------------------------------------------------------------------------------------------
# Asking: with no terminal it refuses without --yes; on a terminal only y/s goes ahead.
# ---------------------------------------------------------------------------------------------------------------
cm_tty() {   # cm_tty <world> <answer> <args...>: the program on a pseudo-terminal that types <answer>
    local w="$1" answer="$2"; shift 2
    RC=0
    printf '%s\n' "$answer" | env -u XDG_CURRENT_DESKTOP HOME="$w/home" PATH="$BIN:$PATH" DCONF_DB="$w/db" \
        XDG_DATA_HOME="$w/home/.local/share" XDG_DATA_DIRS="$TMP/no-system-data" CM_LANG_OVERRIDE="$LANGX" \
        python3 -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' bash "$PROG" "$@" \
        >"$w/out" 2>"$w/err" || RC=$?
}
mkworld ask
W="$TMP/ask"; H="$W/home"
cm "$W" install; snap "$H" > "$W/home.installed"
cm "$W" uninstall
[ "$RC" -ne 0 ] || fail 'uninstall went ahead with no terminal and no --yes'
grep -q 'there is no terminal to ask on' "$W/err" || fail 'uninstall did not say it needs --yes'
snap "$H" | diff "$W/home.installed" - >/dev/null || fail 'a refused uninstall changed the home'
for answer in n N '' x yes sure; do
    cm_tty "$W" "$answer" uninstall
    [ "$RC" -ne 0 ] || fail "uninstall went ahead on the answer '$answer'"
    grep -q 'Cancelled: nothing was changed' "$W/out" || fail "uninstall did not say it cancelled on '$answer'"
    snap "$H" | diff "$W/home.installed" - >/dev/null || fail "a cancelled uninstall changed the home ('$answer')"
done
# One letter, as in the dependency prompt: y or Y in English, s or S in Spanish.
for answer in y Y s S; do
    mkworld "ask-$answer" minimal; W="$TMP/ask-$answer"; H="$W/home"
    cm "$W" install
    case "$answer" in [sS]) LANGX=es ;; esac
    cm_tty "$W" "$answer" uninstall; LANGX=en
    [ "$RC" -eq 0 ] || fail "uninstall did not go ahead on '$answer': $(cat "$W/err")"
    [ ! -e "$H/.local/share/color-mint" ] && [ ! -e "$H/.local/bin/color-mint" ] || fail "the answer '$answer' did not uninstall"
done
grep -q 'Se va a desinstalar Color Mint' "$W/out" || fail 'the Spanish plan is not shown'
pass 'uninstall asks first: no terminal needs --yes, only one letter (y, Y, s, S) goes ahead, and the plan is shown in both languages'

cm "$W" uninstall --bogus
[ "$RC" -ne 0 ] || fail 'uninstall accepted an unknown option'
grep -q "Unrecognized option for 'uninstall': --bogus" "$W/err" || fail 'uninstall did not name the unknown option'
pass 'an unknown uninstall option is refused by name'

# ---------------------------------------------------------------------------------------------------------------
# The guards. Each one keeps uninstall from deleting something that is not Color Mint's.
# fresh_used <id> [kind]: a world after install and the full use, in W and H.
# ---------------------------------------------------------------------------------------------------------------
fresh_used() {
    mkworld "$1" "${2:-full}"; W="$TMP/$1"; H="$W/home"
    cm "$W" install; [ "$RC" -eq 0 ] || fail "install failed in $1: $(cat "$W/err")"
    use_all "$W"
}
GTK_END='/* <<< Color Mint: acento GTK global <<< */'
GTK_BEGIN='/* >>> Color Mint: acento GTK global (autogenerado, no editar a mano) >>> */'

# A block with no closing marker, or one opened twice. The strip would delete from the opening line to the end
# of the file, the user's own lines included. The file is left exactly as it is, named, and the rest still goes back.
fresh_used g56
grep -vxF "$GTK_END" "$H/.config/gtk-3.0/gtk.css" > "$W/open.css"
printf 'a line the user wrote below the block\n' >> "$W/open.css"
cp "$W/open.css" "$H/.config/gtk-3.0/gtk.css"
{ printf 'user first\n%s\none\n' "$GTK_BEGIN"; printf '%s\ntwo\n%s\n' "$GTK_BEGIN" "$GTK_END"; printf 'user last\n'; } > "$H/.config/gtk-4.0/gtk.css"
cp "$H/.config/gtk-4.0/gtk.css" "$W/nested.css"
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] || fail "uninstall stopped at an unclosed block ($RC): $(cat "$W/err")"
cmp -s "$W/open.css" "$H/.config/gtk-3.0/gtk.css" || fail 'uninstall rewrote a file whose block has no closing marker'
cmp -s "$W/nested.css" "$H/.config/gtk-4.0/gtk.css" || fail 'uninstall rewrote a file whose block is opened twice'
grep -q "Leaving $H/.config/gtk-3.0/gtk.css: a Color Mint block has no closing marker" "$W/err" || fail 'the unclosed block was not named'
grep -q "Leaving $H/.config/gtk-4.0/gtk.css: a Color Mint block has no closing marker" "$W/err" || fail 'the doubled block was not named'
grep -qF '>>> Color Mint: cursor' "$H/.Xresources" && fail 'the files with a sound block were not restored after the unclosed one'
cmp -s "$H/.config/fontconfig/fonts.conf" <(printf '<?xml version="1.0"?>\n<fontconfig><!-- the user'"'"'s own --></fontconfig>\n') || fail 'the fonts.conf the user had was not restored'
pass 'a Color Mint block with no closing marker (or opened twice) is left as it is, named, and nothing else is held back'

# Only what Color Mint can show to be its own is deleted. A record in installed.txt is a claim, not a proof.
fresh_used g57
printf '<fontconfig><!-- replaced by the user --></fontconfig>\n' > "$H/.config/fontconfig/fonts.conf"
sed -i '/X-Color-Mint-Launcher=true/d' "$H/.local/share/applications/color-mint.desktop"
printf '#!/bin/sh\necho my own color-mint\n' > "$H/.local/bin/color-mint"
mkdir -p "$H/Documents/mytheme"; printf 'mine\n' > "$H/Documents/mytheme/file"
rm -rf "$H/.themes/Imported"; ln -s "$H/Documents/mytheme" "$H/.themes/Imported"
mkdir -p "$H/.themes/CM-Old"
printf 'themes/../Documents\nicons/a/b\nthemes/.\n' >> "$H/.local/share/color-mint/installed.txt"
cp "$H/.config/fontconfig/fonts.conf" "$W/fonts.user"; cp "$H/.local/bin/color-mint" "$W/copy.user"; cp "$H/.local/share/applications/color-mint.desktop" "$W/launcher.user"
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] || fail "uninstall failed beside files that are not its own ($RC): $(cat "$W/err")"
cmp -s "$W/fonts.user" "$H/.config/fontconfig/fonts.conf" || fail 'uninstall touched a fonts.conf that Color Mint no longer owns'
cmp -s "$W/copy.user" "$H/.local/bin/color-mint" || fail 'uninstall deleted a program copy that is not Color Mint'"'"'s'
cmp -s "$W/launcher.user" "$H/.local/share/applications/color-mint.desktop" || fail 'uninstall deleted a launcher that is not Color Mint'"'"'s'
[ -L "$H/.themes/Imported" ] && [ -f "$H/Documents/mytheme/file" ] || fail 'uninstall deleted a recorded theme that is now a link to the user'"'"'s folder'
[ -d "$H/.themes/CM-Old" ] || fail 'uninstall deleted a theme copy it never recorded'
[ -f "$H/Documents/notes.txt" ] || fail 'a traversal name in installed.txt reached the user'"'"'s Documents'
for named in "$H/.config/fontconfig/fonts.conf" "$H/.local/bin/color-mint" "$H/.local/share/applications/color-mint.desktop" "$H/.themes/Imported" "$H/.themes/CM-Old"; do
    grep -qF "Leaving $named: Color Mint did not record it as its own" "$W/err" || fail "uninstall did not name what it left: $named"
done
[ -d "$H/.icons/ImportedIcons" ] && fail 'the recorded icon theme was left although it is Color Mint'"'"'s'
[ -d "$H/.themes/CM-Mint-Y-Dark" ] && fail 'the recorded Cinnamon copy was left although it is Color Mint'"'"'s'
pass 'what is not Color Mint'"'"'s (an edited fonts.conf, another launcher or copy, a link, an unrecorded copy, a bad record) is left and named'

# A program copy that is a link is never deleted. A fonts.conf that is a link: when the user had a file before Color
# Mint, the saved copy goes into the file the link points to and the link stays; when Color Mint made the file, a link
# that appeared since is the user's and is left and named.
fresh_used g57b
mv "$H/.config/fontconfig/fonts.conf" "$H/Documents/fonts-kept.conf"; ln -s "$H/Documents/fonts-kept.conf" "$H/.config/fontconfig/fonts.conf"
cp "$SCRIPT" "$H/Documents/copy-kept"; rm -f "$H/.local/bin/color-mint"; ln -s "$H/Documents/copy-kept" "$H/.local/bin/color-mint"
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] || fail "uninstall failed beside links: $(cat "$W/err")"
[ "$(readlink "$H/.config/fontconfig/fonts.conf")" = "$H/Documents/fonts-kept.conf" ] || fail 'uninstall replaced a fonts.conf that is a link'
cmp -s "$H/Documents/fonts-kept.conf" <(printf '<?xml version="1.0"?>\n<fontconfig><!-- the user'"'"'s own --></fontconfig>\n') || fail 'uninstall did not put the saved fonts.conf into the file the link points to'
[ -L "$H/.local/bin/color-mint" ] && [ -f "$H/Documents/copy-kept" ] || fail 'uninstall deleted a program copy that is a link, although what it points to is a copy of Color Mint'
pass 'a fonts.conf that is a link gets the saved copy through the link, and a program copy that is a link is left alone'

mkworld g57f minimal; W="$TMP/g57f"; H="$W/home"
mkdir -p "$H/.config/fontconfig"
cm "$W" install; cm "$W" fonts rendering rgba slight
[ "$RC" -eq 0 ] || fail "fonts rendering failed: $(cat "$W/err")"
mv "$H/.config/fontconfig/fonts.conf" "$H/fonts-new.conf"; ln -s "$H/fonts-new.conf" "$H/.config/fontconfig/fonts.conf"
cp "$H/fonts-new.conf" "$W/fonts.kept"
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] || fail "uninstall beside a fonts.conf link that appeared later failed: $(cat "$W/err")"
[ -L "$H/.config/fontconfig/fonts.conf" ] && cmp -s "$W/fonts.kept" "$H/fonts-new.conf" || fail 'uninstall touched a fonts.conf link that appeared after Color Mint made the file'
grep -qF "Leaving $H/.config/fontconfig/fonts.conf: Color Mint did not record it as its own" "$W/err" || fail 'that fonts.conf link was not named'
pass 'a fonts.conf link that appeared after Color Mint made the file is left and named'

# A look file that is a link is the file it points to: the block goes from there, what else it holds stays, and the
# link stays. A link to a file with no block is not touched and not named.
fresh_used g57e
mv "$H/.config/gtk-3.0/gtk.css" "$H/Documents/gtk3-kept.css"; ln -s "$H/Documents/gtk3-kept.css" "$H/.config/gtk-3.0/gtk.css"
rm -f "$H/.config/gtk-4.0/gtk.css"; printf 'plain\n' > "$H/Documents/gtk4-plain.css"; ln -s "$H/Documents/gtk4-plain.css" "$H/.config/gtk-4.0/gtk.css"
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] || fail "uninstall failed beside look files that are links: $(cat "$W/err")"
[ -L "$H/.config/gtk-3.0/gtk.css" ] && [ -L "$H/.config/gtk-4.0/gtk.css" ] || fail 'uninstall replaced a look file that is a link'
cmp -s "$H/Documents/gtk3-kept.css" <(printf '/* mine */\n.user { color: red; }\n') || fail 'uninstall did not take the block out of the file that a link points to'
[ "$(cat "$H/Documents/gtk4-plain.css")" = plain ] || fail 'uninstall rewrote the plain file that a link points to'
if grep -qF "gtk.css" "$W/err"; then fail "uninstall named a look file it had nothing to say about: $(cat "$W/err")"; fi
pass 'a look file that is a link loses the block from the file it points to, and the link stays'

# fonts.conf: the copy saved with the original look is gone, so what the user had cannot be put back. The generated
# file stays, named; deleting it would leave the user with neither.
mkworld g57c; W="$TMP/g57c"; H="$W/home"
cm "$W" install; cm "$W" fonts rendering rgba slight
[ "$RC" -eq 0 ] || fail "fonts rendering failed: $(cat "$W/err")"
rm -f "$H/.local/share/color-mint/original/fonts.conf"
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] || fail "uninstall without the saved fonts.conf failed: $(cat "$W/err")"
grep -qF 'Color Mint: generated file' "$H/.config/fontconfig/fonts.conf" || fail 'uninstall replaced a fonts.conf it had no saved original for'
grep -qF "Leaving $H/.config/fontconfig/fonts.conf: Color Mint did not record it as its own" "$W/err" || fail 'the fonts.conf it could not restore was not named'
pass 'a fonts.conf with no saved original is left, named, and the uninstall still finishes'

# A file Color Mint made and the user then added to: its block goes, the lines the user added and the file stay.
mkworld g57d minimal; W="$TMP/g57d"; H="$W/home"
cm "$W" install; cm "$W" panel gtk-accent '#aa3366'
[ "$RC" -eq 0 ] || fail "panel gtk-accent failed: $(cat "$W/err")"
printf 'a line the user added\n' >> "$H/.config/gtk-3.0/gtk.css"
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] || fail "uninstall beside a line the user added failed: $(cat "$W/err")"
[ "$(cat "$H/.config/gtk-3.0/gtk.css" 2>/dev/null)" = 'a line the user added' ] || fail 'uninstall did not leave exactly the line the user added'
[ ! -e "$H/.config/gtk-4.0/gtk.css" ] || fail 'uninstall kept a file that only held Color Mint'"'"'s block'
pass 'a file Color Mint made keeps the lines the user added to it, and goes when nothing else is in it'

# The program's own folder: only what Color Mint keeps there is deleted, and only inside the home folder.
fresh_used g58
printf 'not Color Mint'"'"'s\n' > "$H/.local/share/color-mint/my-notes.txt"
cm "$W" uninstall --yes
[ "$RC" -eq 0 ] || fail "uninstall beside a foreign file in its folder failed: $(cat "$W/err")"
[ "$(cat "$H/.local/share/color-mint/my-notes.txt" 2>/dev/null)" = "not Color Mint's" ] || fail 'uninstall deleted a file in its folder that it did not create'
[ -z "$(find "$H/.local/share/color-mint" -mindepth 1 ! -name my-notes.txt -print -quit)" ] || fail 'uninstall left its own files beside the foreign one'
grep -q "Keeping $H/.local/share/color-mint: it holds files Color Mint did not create" "$W/err" || fail 'uninstall did not say it kept the folder'
pass 'a foreign file in the program folder is kept with the folder; everything of Color Mint'"'"'s beside it goes'

mkworld g58b; W="$TMP/g58b"; H="$W/home"; OUT="$W/outside/color-mint"
XENV=(CM_HOME="$OUT")
cm "$W" install; use_all "$W"
snap "$W/outside" > "$W/outside.used"
cm "$W" uninstall --yes
XENV=(CM_TEST_UNINSTALL=1)
[ "$RC" -eq 0 ] || fail "uninstall with a program folder outside the home failed: $(cat "$W/err")"
snap "$W/outside" | diff "$W/outside.used" - >/dev/null || fail 'uninstall deleted from a program folder outside the home folder'
grep -q "Keeping $OUT: it holds files Color Mint did not create, or it is outside your home folder" "$W/err" || fail 'uninstall did not say it kept the outside folder'
pass 'a program folder outside the home folder is never emptied'

# The folders install recorded: removed only while empty, deepest first, and only inside the home folder.
mkworld dirs minimal; W="$TMP/dirs"; H="$W/home"
cm "$W" install; [ "$RC" -eq 0 ] || fail "install failed: $(cat "$W/err")"
mkdir -p "$H/Documents/e1/e2" "$W/elsewhere/empty"
printf 'dir/%s\ndir/%s\ndir/%s\n' "$H/Documents/e1" "$H/Documents/e1/e2" "$W/elsewhere/empty" >> "$H/.local/share/color-mint/installed.txt"
printf 'mine\n' > "$H/.local/bin/other-tool"
cm "$W" uninstall --yes
[ "$RC" -eq 0 ] || fail "uninstall with recorded folders failed: $(cat "$W/err")"
[ ! -e "$H/Documents/e1" ] || fail 'a recorded folder that holds another recorded folder was not removed (deepest first)'
[ -d "$W/elsewhere/empty" ] || fail 'uninstall removed a recorded folder outside the home folder'
[ "$(cat "$H/.local/bin/other-tool" 2>/dev/null)" = mine ] || fail 'uninstall emptied a recorded folder that holds a file of the user'
[ ! -e "$H/.local/share/applications" ] || fail 'uninstall kept an empty folder that install had made'
pass 'recorded folders go only while empty, deepest first, and never outside the home folder'

# --restore-look with --keep-config: the look goes back, and the snapshot and the install record, which describe a look
# that is no longer there, go with it, so that a later --restore-look cannot put an old look over a newer one.
fresh_used g58c
cm "$W" uninstall --restore-look --keep-config --yes
[ "$RC" -eq 0 ] || fail "uninstall --restore-look --keep-config failed: $(cat "$W/err")"
for gone in original installed.txt; do
    [ ! -e "$H/.local/share/color-mint/$gone" ] || fail "--restore-look --keep-config kept the used $gone"
done
for kept in backups presets state.conf icon.png; do
    [ -e "$H/.local/share/color-mint/$kept" ] || fail "--restore-look --keep-config deleted $kept"
done
pass '--restore-look with --keep-config drops the snapshot and the record it has used, and keeps the rest'

# The desktop settings cannot be put back. Nothing else is removed, so the same command can be repeated.
mkworld g59ref; snap "$TMP/g59ref/home" > "$TMP/g59ref/home.before"
fresh_used g59
XENV=(DCONF_FAIL_ALWAYS=load)
cm "$W" uninstall --restore-look --yes
XENV=(CM_TEST_UNINSTALL=1)
[ "$RC" -ne 0 ] || fail 'uninstall reported success although the desktop settings could not be restored'
grep -q 'could not restore the desktop settings; nothing else was removed' "$W/err" || fail 'uninstall did not explain the dconf failure'
[ -f "$H/.local/bin/color-mint" ] && [ -f "$H/.local/share/applications/color-mint.desktop" ] || fail 'uninstall removed the program after a failed restore'
[ -f "$H/.local/share/color-mint/original/manifest.txt" ] && [ -f "$H/.local/share/color-mint/installed.txt" ] || fail 'uninstall deleted the saved original look after a failed restore'
grep -qF '>>> Color Mint: cursor' "$H/.Xresources" || fail 'uninstall restored files although the desktop settings were not restored'
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] || fail "the repeated uninstall failed: $(cat "$W/err")"
[ ! -e "$H/.local/share/color-mint" ] || fail 'the repeated uninstall left the program folder'
snap "$H" | diff "$TMP/g59ref/home.before" - >/dev/null || fail 'the repeated uninstall did not return the home'
dbsnap "$W/db" | diff <(dbsnap "$TMP/g59ref/db") - >/dev/null || fail 'the repeated uninstall did not return the desktop settings'
pass 'a failed dconf restore stops before anything else is removed, and the repeated command finishes the job'

# A removal that fails (a double for rm: as root nothing fails for want of permissions). The same rule: the record
# and the program folder stay, so that the repeated command can finish.
RMBIN="$TMP/bin-rm"; mkdir -p "$RMBIN"
cat > "$RMBIN/rm" <<EOF
#!/usr/bin/env bash
[ -z "\${RM_FAIL:-}" ] || for a in "\$@"; do [ "\$a" != "\$RM_FAIL" ] || { echo "rm: cannot remove '\$a'" >&2; exit 1; }; done
exec $(command -v rm) "\$@"
EOF
chmod +x "$RMBIN/rm"
mkworld g59c minimal; W="$TMP/g59c"; H="$W/home"; LAUNCHER="$H/.local/share/applications/color-mint.desktop"
snap "$H" > "$W/home.before"; dbsnap "$W/db" > "$W/db.before"
cm "$W" install; cm "$W" theme cursor-size 48
[ "$RC" -eq 0 ] || fail "theme cursor-size failed: $(cat "$W/err")"
XENV=(CM_TEST_UNINSTALL=1 PATH="$RMBIN:$BIN:$PATH" RM_FAIL="$LAUNCHER")
cm "$W" uninstall --restore-look --yes
XENV=(CM_TEST_UNINSTALL=1)
[ "$RC" -ne 0 ] || fail 'uninstall reported success although it could not remove the launcher'
[ -f "$LAUNCHER" ] || fail 'control: the double did not keep the launcher'
grep -q "ERROR: could not remove $LAUNCHER" "$W/err" || fail 'the launcher it could not remove was not named'
grep -q 'The uninstall did not finish; repeat the command to complete it' "$W/err" || fail 'uninstall did not say it is incomplete'
[ -f "$H/.local/share/color-mint/original/manifest.txt" ] && [ -f "$H/.local/share/color-mint/installed.txt" ] || fail 'uninstall deleted the saved original look and the install record after a failed removal'
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] || fail "the repeated uninstall failed: $(cat "$W/err")"
snap "$H" | diff "$W/home.before" - >/dev/null || fail 'the repeated uninstall did not return the home'
dbsnap "$W/db" | diff "$W/db.before" - >/dev/null || fail 'the repeated uninstall did not return the desktop settings'
pass 'a removal that fails leaves the record and the program folder, and the repeated command finishes the job'

# Without dconf when the original look was saved, only files can be restored, and the uninstall says so.
mkworld g59b; W="$TMP/g59b"; H="$W/home"
cm "$W" install
XENV=(DCONF_FAIL_ALWAYS=dump)
cm "$W" theme cursor-size 48
XENV=(CM_TEST_UNINSTALL=1)
[ "$RC" -eq 0 ] || fail "theme cursor-size failed without dconf dump: $(cat "$W/err")"
grep -qx 'dconf=no' "$H/.local/share/color-mint/original/manifest.txt" || fail 'the original look was saved as having dconf'
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] || fail "uninstall of a files-only original failed: $(cat "$W/err")"
grep -q 'dconf was not available when the original look was saved' "$W/err" || fail 'uninstall did not warn that only files are restored'
[ ! -e "$H/.config/environment.d/60-color-mint-cursor.conf" ] && ! grep -qF '>>> Color Mint: cursor' "$H/.Xresources" 2>/dev/null || fail 'the files were not restored'
pass 'an original look saved without dconf restores the files and says the settings stay'

# The apt note names only well-formed package names: it is a command the user will paste.
mkworld apt
W="$TMP/apt"; H="$W/home"
cm "$W" install
printf 'apt/arc-theme\napt/bad;touch pwned\napt/-rf\napt/mint-y-icons\n' >> "$H/.local/share/color-mint/installed.txt"
cm "$W" uninstall --yes
[ "$RC" -eq 0 ] || fail "uninstall with packages on record failed: $(cat "$W/err")"
grep -qx 'To remove them: sudo apt-get remove arc-theme mint-y-icons' "$W/out" || fail 'the apt note is not the list of valid package names'
if grep -qF 'pwned' "$W/out"; then fail 'a malformed package name reached the apt note'; fi
pass 'the apt note lists only valid package names'

# ---------------------------------------------------------------------------------------------------------------
# Dotfiles that are links. A dotfile manager keeps ~/.themes, ~/.icons, gtk-3.0 and some of the
# look files as links into its own folder. Color Mint writes through them and leaves them where they are, and uninstall
# puts the content back where they lead.
# ---------------------------------------------------------------------------------------------------------------
# mklinks <id>: the full world with the dotfiles kept in ~/dotfiles. ~/.themes, ~/.icons and gtk-3.0 (a relative link,
# as stow makes it) are folder links; ~/.Xresources, gtk-4.0/gtk.css and fonts.conf are file links. The environment.d
# file is Color Mint's own, so nothing links to it.
LINKS='.themes .icons .config/gtk-3.0 .Xresources .config/gtk-4.0/gtk.css .config/fontconfig/fonts.conf'
mklinks() {
    mkworld "$1"
    local h="$TMP/$1/home" d="$TMP/$1/home/dotfiles"
    mkdir -p "$d"
    mv "$h/.themes" "$d/themes";                          ln -s "$d/themes" "$h/.themes"
    mv "$h/.icons" "$d/icons";                            ln -s "$d/icons" "$h/.icons"
    mv "$h/.config/gtk-3.0" "$d/gtk-3.0";                 ln -s ../dotfiles/gtk-3.0 "$h/.config/gtk-3.0"
    mv "$h/.Xresources" "$d/Xresources";                  ln -s "$d/Xresources" "$h/.Xresources"
    mv "$h/.config/gtk-4.0/gtk.css" "$d/gtk4.css";        ln -s "$d/gtk4.css" "$h/.config/gtk-4.0/gtk.css"
    mv "$h/.config/fontconfig/fonts.conf" "$d/fonts.conf"; ln -s "$d/fonts.conf" "$h/.config/fontconfig/fonts.conf"
}
# links_of <home>: the links of the look, by target.
links_of() { local l; for l in $LINKS; do printf '%s -> %s\n' "$l" "$(readlink "$1/$l")"; done; }

# The cycle with links: nothing in the home or in the desktop settings may differ at the end, links included.
mklinks linkcycle; W="$TMP/linkcycle"; H="$W/home"
snap "$H" > "$W/home.before"; dbsnap "$W/db" > "$W/db.before"; links_of "$H" > "$W/links.before"
[ "$(grep -c '^l ' "$W/home.before")" -eq 6 ] || fail "control: the world does not hold the six links: $(grep '^l ' "$W/home.before" | tr '\n' '|')"
cm "$W" install
[ "$RC" -eq 0 ] || fail "install beside linked dotfiles failed: $(cat "$W/err")"
use_all "$W"
links_of "$H" | diff "$W/links.before" - >/dev/null || fail 'the use replaced a link or moved where it leads'
grep -qF '>>> Color Mint: cursor' "$H/dotfiles/Xresources" || fail 'the cursor block did not go into the file ~/.Xresources leads to'
grep -qF 'Color Mint: acento GTK global' "$H/dotfiles/gtk-3.0/gtk.css" && grep -qF 'Color Mint: acento GTK global' "$H/dotfiles/gtk4.css" \
    || fail 'the accent blocks did not go into the files the gtk.css links lead to'
grep -qF 'Color Mint: generated file' "$H/dotfiles/fonts.conf" || fail 'fonts.conf did not go into the file the link leads to'
[ -d "$H/dotfiles/themes/Imported" ] && [ -d "$H/dotfiles/themes/CM-Mint-Y-Dark" ] && [ -d "$H/dotfiles/icons/ImportedIcons" ] \
    || fail 'the imported themes and the Cinnamon copy did not go into the folders ~/.themes and ~/.icons lead to'
PROG="$H/.local/bin/color-mint"
cm "$W" uninstall --restore-look --yes
PROG="$SCRIPT"
[ "$RC" -eq 0 ] || fail "uninstall beside linked dotfiles failed ($RC): $(cat "$W/err")"
snap "$H" > "$W/home.after"
diff "$W/home.before" "$W/home.after" >"$W/home.diff" || fail "the home is not as it was: $(head -n 8 "$W/home.diff" | tr '\n' '|')"
diff <(dbsnap "$W/db.before") <(dbsnap "$W/db") >"$W/db.diff" || fail "the desktop settings are not as they were: $(head -n 8 "$W/db.diff" | tr '\n' '|')"
pass 'with dotfiles that are links, install, full use and uninstall --restore-look leave the links, the files behind them and the settings as they were'

# cm_uninstall_envd. The file is Color Mint's by name: it goes when it did not exist before, unless it is a link (never
# deleted; named only when its file holds the cursor size Color Mint wrote). One that was there first is not deleted.
ENVF='.config/environment.d/60-color-mint-cursor.conf'
fresh_used env1
mv "$H/$ENVF" "$H/Documents/cursor-kept.conf"; ln -s "$H/Documents/cursor-kept.conf" "$H/$ENVF"
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] || fail "uninstall beside an environment.d link failed: $(cat "$W/err")"
[ "$(readlink "$H/$ENVF")" = "$H/Documents/cursor-kept.conf" ] && grep -qx 'XCURSOR_SIZE=48' "$H/Documents/cursor-kept.conf" || fail 'uninstall deleted or rewrote an environment.d file that is a link'
grep -qF "Leaving $H/$ENVF: it is a link, and the file it points to still holds what Color Mint wrote" "$W/err" || fail 'the environment.d link that holds the cursor size was not named'
fresh_used env2
mv "$H/$ENVF" "$H/Documents/other.conf"; printf 'EDITOR=vim\n' > "$H/Documents/other.conf"; ln -s "$H/Documents/other.conf" "$H/$ENVF"
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] && [ "$(readlink "$H/$ENVF")" = "$H/Documents/other.conf" ] && [ "$(cat "$H/Documents/other.conf")" = 'EDITOR=vim' ] || fail "uninstall touched an environment.d link to a file that is the user's: $(cat "$W/err")"
if grep -qF "$ENVF" "$W/err"; then fail "uninstall named an environment.d link whose file holds nothing of Color Mint's: $(cat "$W/err")"; fi
fresh_used env3
rm -f "$H/$ENVF"; ln -s "$H/nowhere" "$H/$ENVF"
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] && [ "$(readlink "$H/$ENVF")" = "$H/nowhere" ] || fail "uninstall deleted or followed an environment.d link that leads nowhere: $(cat "$W/err")"
mkworld env4; W="$TMP/env4"; H="$W/home"
cm "$W" install
printf 'XCURSOR_SIZE=32\n' > "$H/$ENVF"
use_all "$W"
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] || fail "uninstall beside an environment.d file that was there first failed: $(cat "$W/err")"
[ -f "$H/$ENVF" ] || fail 'uninstall deleted an environment.d file that existed before Color Mint'
pass 'the environment.d file goes only when Color Mint made it: a link is kept (named when it holds the cursor size) and a file that was there first stays'

# A link whose file or folder cannot be written keeps what Color Mint wrote there and is named; the uninstall goes on
# with the rest and finishes. (root can write anything, so only another user can show it.)
if [ "$(id -u)" -eq 0 ]; then
    printf 'SKIP: a link whose file cannot be written needs a user who is not root\n'
else
    for case_id in file folder; do
        fresh_used "nw-$case_id"
        mv "$H/.config/gtk-3.0/gtk.css" "$H/gtk3.tmp"; rm -rf "$H/.config/gtk-3.0"   # a plain gtk-3.0: only gtk-4.0 and the others are links
        mkdir -p "$H/.config/gtk-3.0"; mv "$H/gtk3.tmp" "$H/.config/gtk-3.0/gtk.css"
        mkdir -p "$H/dotfiles"
        mv "$H/.config/gtk-4.0/gtk.css" "$H/dotfiles/gtk4.css";  ln -s "$H/dotfiles/gtk4.css" "$H/.config/gtk-4.0/gtk.css"
        mv "$H/.Xresources" "$H/dotfiles/Xresources";            ln -s "$H/dotfiles/Xresources" "$H/.Xresources"
        mv "$H/.config/fontconfig/fonts.conf" "$H/dotfiles/fonts.conf"; ln -s "$H/dotfiles/fonts.conf" "$H/.config/fontconfig/fonts.conf"
        if [ "$case_id" = file ]; then
            chmod a-w "$H/dotfiles/gtk4.css"; named=("$H/.config/gtk-4.0/gtk.css")
        else
            chmod a-w "$H/dotfiles"; named=("$H/.config/gtk-4.0/gtk.css" "$H/.Xresources" "$H/.config/fontconfig/fonts.conf")
        fi
        cm "$W" uninstall --restore-look --yes
        [ "$RC" -eq 0 ] || fail "nw-$case_id: uninstall stopped at a link that cannot be written ($RC): $(cat "$W/err")"
        for l in "${named[@]}"; do
            grep -qF "Leaving $l: it is a link, and the file it points to still holds what Color Mint wrote" "$W/err" || fail "nw-$case_id: $l was not named: $(cat "$W/err")"
            [ -L "$l" ] || fail "nw-$case_id: the link $l was not left in place"
        done
        grep -qF 'Color Mint: acento GTK global' "$H/dotfiles/gtk4.css" || fail "nw-$case_id: the accent block was taken out of a file that cannot be written"
        if [ "$case_id" = folder ]; then
            grep -qF '>>> Color Mint: cursor' "$H/dotfiles/Xresources" && grep -qF 'Color Mint: generated file' "$H/dotfiles/fonts.conf" \
                || fail 'nw-folder: what Color Mint wrote was taken out of files in a folder that cannot be written'
        else
            grep -qF '>>> Color Mint: cursor' "$H/dotfiles/Xresources" && fail 'nw-file: the cursor block stayed although its file can be written'
            grep -qF 'Color Mint: generated file' "$H/dotfiles/fonts.conf" && fail 'nw-file: fonts.conf was not put back although its file can be written'
        fi
        grep -qF 'Color Mint: acento GTK global' "$H/.config/gtk-3.0/gtk.css" && fail "nw-$case_id: the accent block stayed in the file that can be written"
        [ ! -e "$H/.local/share/color-mint" ] || fail "nw-$case_id: the uninstall did not go on to remove the program's folder"
        chmod -R u+w "$W"
    done
    pass 'a link whose file or folder cannot be written keeps what Color Mint wrote, is named, and the uninstall still finishes'
fi

# A command that writes several look files checks all of them first: a link that cannot be written stops it before any
# of the files, or the setting, changes. A link that leads nowhere is enough to show it, so this needs no other user.
# linkworld <id>: linked dotfiles, installed, with the first change made (so the original look is already saved).
linkworld() {
    mklinks "$1"; W="$TMP/$1"; H="$W/home"
    cm "$W" install
    cm "$W" desktop workspaces 4
    [ "$RC" -eq 0 ] || fail "linkworld $1: the first change failed: $(cat "$W/err")"
}
for refused in xres:.Xresources envd:"$ENVF"; do
    for command_line in 'theme cursor-size 48' 'theme cursor FooCursors'; do
        linkworld "pre-${refused%%:*}"
        link="$H/${refused#*:}"; rm -f "$link"; ln -s "$H/nowhere" "$link"
        snap "$H" > "$W/home.before"; dbsnap "$W/db" > "$W/db.before"
        # shellcheck disable=SC2086  # a command line, split on purpose
        cm "$W" $command_line
        [ "$RC" -ne 0 ] || fail "'$command_line' went on with $link leading nowhere"
        grep -qF "ERROR: $link is a link and what it points to cannot be written" "$W/err" || fail "'$command_line': $link was not named: $(cat "$W/err")"
        snap "$H" | diff "$W/home.before" - >/dev/null || fail "'$command_line' changed a file before it refused at $link"
        diff "$W/db.before" <(dbsnap "$W/db") >/dev/null || fail "'$command_line' changed a setting before it refused at $link"
    done
done
for refused in .config/gtk-3.0/gtk.css .config/gtk-4.0/gtk.css; do
    linkworld pre-accent
    link="$H/$refused"; rm -f "$link"; ln -s "$H/nowhere" "$link"
    snap "$H" > "$W/home.before"
    cm "$W" panel gtk-accent '#aa3366'
    [ "$RC" -ne 0 ] || fail "the accent went on with $link leading nowhere"
    grep -qF "ERROR: $link is a link and what it points to cannot be written" "$W/err" || fail "the accent: $link was not named: $(cat "$W/err")"
    snap "$H" | diff "$W/home.before" - >/dev/null || fail "the accent changed a file before it refused at $link"
done
pass 'cursor, cursor size and GTK accent check every look file first: a link that leads nowhere is named and nothing changes'

# Reset: a block that cannot be removed is named and the command fails; the other block, and the Cinnamon theme, still go back.
if [ "$(id -u)" -eq 0 ]; then
    printf 'SKIP: a reset whose target cannot be written needs a user who is not root\n'
else
    linkworld reset-fail
    cm "$W" panel accent '#ff0000'; [ "$RC" -eq 0 ] || fail "panel accent failed: $(cat "$W/err")"
    cm "$W" panel gtk-accent '#aa3366'; [ "$RC" -eq 0 ] || fail "panel gtk-accent failed: $(cat "$W/err")"
    theme_now=$(grep -F '/org/cinnamon/theme/name' "$W/db" | cut -f2)
    [ "$theme_now" = "'CM-Mint-Y-Dark'" ] || fail "control: the accent did not activate the copy ($theme_now)"
    chmod a-w "$H/dotfiles/gtk4.css"
    cm "$W" panel reset-colors
    [ "$RC" -ne 0 ] || fail 'a reset that left a block behind said it succeeded'
    grep -qF "ERROR: $H/.config/gtk-4.0/gtk.css is a link and what it points to cannot be written" "$W/err" || fail "the reset did not name the link that cannot be written: $(cat "$W/err")"
    grep -qF 'Color Mint: acento GTK global' "$H/dotfiles/gtk4.css" || fail 'the reset took the block out of a file that cannot be written'
    grep -qF 'Color Mint: acento GTK global' "$H/dotfiles/gtk-3.0/gtk.css" && fail 'the reset held back the block that could be removed'
    [ "$(grep -F '/org/cinnamon/theme/name' "$W/db" | cut -f2)" = "'Mint-Y-Dark'" ] || fail 'the reset did not put the Cinnamon theme back'
    chmod u+w "$H/dotfiles/gtk4.css"
    cm "$W" panel reset-colors
    [ "$RC" -eq 0 ] || fail "the repeated reset failed: $(cat "$W/err")"
    grep -qF 'Color Mint: acento GTK global' "$H/dotfiles/gtk4.css" && fail 'the repeated reset left the block'
    pass 'a reset with a target that cannot be written names it, fails, still resets the rest, and the repeated command finishes'
fi

# The environment.d file is Color Mint's by name, but a link already there is the user's: the cursor size goes to the
# file it leads to and the link stays.
mkworld envlink; W="$TMP/envlink"; H="$W/home"
mkdir -p "$H/.config/environment.d" "$H/dotfiles"
printf 'XCURSOR_SIZE=24\n' > "$H/dotfiles/cursor.conf"
ln -s "$H/dotfiles/cursor.conf" "$H/$ENVF"
cm "$W" install
[ "$RC" -eq 0 ] || fail "install beside an environment.d link failed: $(cat "$W/err")"
cm "$W" theme cursor-size 48
[ "$RC" -eq 0 ] || fail "theme cursor-size beside an environment.d link failed: $(cat "$W/err")"
[ "$(readlink "$H/$ENVF")" = "$H/dotfiles/cursor.conf" ] || fail 'the cursor size replaced the environment.d link'
grep -qx 'XCURSOR_SIZE=48' "$H/dotfiles/cursor.conf" || fail 'the cursor size did not go into the file the environment.d link leads to'
pass 'the cursor size is written to the file an environment.d link leads to, and the link stays'

# A file Color Mint made and the user then replaced by a link: the block goes from the file the link leads to, and the
# link stays even when that file is left empty (a link is never deleted).
mkworld xlink minimal; W="$TMP/xlink"; H="$W/home"
cm "$W" install
cm "$W" theme cursor-size 48
[ "$RC" -eq 0 ] || fail "theme cursor-size failed in a world without .Xresources: $(cat "$W/err")"
[ -f "$H/.Xresources" ] && [ ! -L "$H/.Xresources" ] || fail 'control: Color Mint did not make a plain .Xresources'
mkdir -p "$H/dotfiles"; mv "$H/.Xresources" "$H/dotfiles/Xresources"; ln -s "$H/dotfiles/Xresources" "$H/.Xresources"
cm "$W" uninstall --restore-look --yes
[ "$RC" -eq 0 ] || fail "uninstall beside a link made after Color Mint's file failed: $(cat "$W/err")"
[ "$(readlink "$H/.Xresources")" = "$H/dotfiles/Xresources" ] && [ -f "$H/dotfiles/Xresources" ] || fail 'uninstall deleted a link whose file it left empty'
grep -qF '>>> Color Mint: cursor' "$H/dotfiles/Xresources" && fail 'the cursor block stayed in the file the link leads to'
pass 'a link that replaced a file Color Mint made loses the block but is never deleted, even when its file is left empty'
