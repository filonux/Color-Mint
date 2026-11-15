#!/usr/bin/env bash
# Theme discovery and validation against a fake themes tree. Every place GTK and Cinnamon search
# (~/.themes, the XDG user folder, /usr/local/share and the system folders) is read; the lists hold
# what Cinnamon's own Themes panel holds (cs_themes.py: a gtk-3.* folder with gtk.css, an
# index.theme with Directories=, a cursors folder, a cinnamon folder, the hidden names, links that
# work); a theme that would not be found is refused before anything is written; and the editable
# copy of a Cinnamon theme can be made from any of those places. The lists cost the same number of
# processes with 30 themes as with 300.
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

# What Cinnamon's Themes panel requires of each kind of theme.
gtk_theme() { mkdir -p "$1/gtk-3.0"; : > "$1/gtk-3.0/gtk.css"; }
cinnamon_theme() { mkdir -p "$1/cinnamon"; : > "$1/cinnamon/cinnamon.css"; }
icon_theme() { mkdir -p "$1"; printf '[Icon Theme]\nName=%s\nDirectories=16x16/apps\n' "${1##*/}" > "$1/index.theme"; }
cursor_theme() { mkdir -p "$1/cursors"; }

# A system where themes live in all the places a community installer or a package may put them.
HOME_DIR="$TMP/home"
XDG_HOME="$TMP/xdg-home"
SYS_LOCAL="$TMP/usr-local-share"
SYS_DISTRO="$TMP/usr-share"
mkdir -p "$HOME_DIR" "$XDG_HOME" "$SYS_LOCAL" "$SYS_DISTRO"

gtk_theme "$HOME_DIR/.themes/Legacy-GTK"
gtk_theme "$XDG_HOME/themes/Modern-GTK"
cinnamon_theme "$XDG_HOME/themes/Modern-Cin"
gtk_theme "$XDG_HOME/themes/Mint-Y-Dark-Aqua"; cinnamon_theme "$XDG_HOME/themes/Mint-Y-Dark-Aqua"
gtk_theme "$XDG_HOME/themes/Mint-Y-Aqua"
gtk_theme "$XDG_HOME/themes/Mint-Y-Dark"
gtk_theme "$SYS_LOCAL/themes/Local-GTK"
gtk_theme "$SYS_DISTRO/themes/Distro-GTK"; cinnamon_theme "$SYS_DISTRO/themes/Distro-Cin"
gtk_theme "$SYS_DISTRO/themes/Modern-GTK"                                  # also in the XDG folder
mkdir -p "$SYS_DISTRO/themes/Versioned-GTK/gtk-3.20"; : > "$SYS_DISTRO/themes/Versioned-GTK/gtk-3.20/gtk.css"
gtk_theme "$SYS_DISTRO/themes/Spaced Name"
gtk_theme "$SYS_DISTRO/themes/Adwaita-Plus"                                # only the exact names are hidden
mkdir -p "$SYS_DISTRO/themes/Key-Theme/gtk-3.0"                            # a gtk key theme: no gtk.css
mkdir -p "$SYS_DISTRO/themes/Old-GTK2/gtk-2.0"; : > "$SYS_DISTRO/themes/Old-GTK2/gtk-2.0/gtkrc"
mkdir -p "$SYS_DISTRO/themes/Empty-Dir"
for hidden in Adwaita HighContrast Adwaita-dark; do gtk_theme "$SYS_DISTRO/themes/$hidden"; done
cinnamon_theme "$SYS_DISTRO/themes/Adwaita-dark"                           # the panel hides no Cinnamon theme
ln -s "$SYS_DISTRO/themes/Distro-GTK" "$XDG_HOME/themes/Linked-GTK"
ln -s "$TMP/missing-target" "$XDG_HOME/themes/Broken-GTK"
ln -s "$XDG_HOME/themes/Modern-Cin" "$SYS_LOCAL/themes/Linked-Cin"
ln -s "$TMP/missing-target" "$SYS_LOCAL/themes/Broken-Cin"

icon_theme "$HOME_DIR/.icons/Legacy-Icons"
icon_theme "$XDG_HOME/icons/Modern-Icons"
icon_theme "$XDG_HOME/icons/Mint-Y-Aqua"
icon_theme "$SYS_LOCAL/icons/Local-Icons"
icon_theme "$SYS_DISTRO/icons/Distro-Icons"
icon_theme "$SYS_DISTRO/icons/Modern-Icons"                                # also in the XDG folder
cursor_theme "$SYS_DISTRO/icons/Cursor-Only"                               # cursors only: no index.theme
icon_theme "$SYS_DISTRO/icons/Both-Theme"; cursor_theme "$SYS_DISTRO/icons/Both-Theme"
mkdir -p "$SYS_DISTRO/icons/Plain-Dir"
mkdir -p "$SYS_DISTRO/icons/No-Directories"
printf '[Icon Theme]\nName=No-Directories\nInherits=Distro-Icons\n' > "$SYS_DISTRO/icons/No-Directories/index.theme"
mkdir -p "$SYS_DISTRO/icons/Hidden-Icons"
printf '[Icon Theme]\nHidden=true\nDirectories=16x16/apps\n' > "$SYS_DISTRO/icons/Hidden-Icons/index.theme"
mkdir -p "$SYS_DISTRO/icons/Hidden-After-Directories"                      # the panel reads the first of the two
printf '[Icon Theme]\nDirectories=16x16/apps\nHidden=true\n' > "$SYS_DISTRO/icons/Hidden-After-Directories/index.theme"
mkdir -p "$SYS_DISTRO/icons/Crlf-Icons"
printf '[Icon Theme]\r\nName=Crlf-Icons\r\nDirectories=16x16/apps\r\n' > "$SYS_DISTRO/icons/Crlf-Icons/index.theme"
mkdir -p "$SYS_DISTRO/icons/Odd-Icons/index.theme"                         # index.theme is a folder
for hidden in hicolor gnome Humanity Adwaita; do icon_theme "$SYS_DISTRO/icons/$hidden"; cursor_theme "$SYS_DISTRO/icons/$hidden"; done
ln -s "$SYS_DISTRO/icons/Distro-Icons" "$XDG_HOME/icons/Linked-Icons"
ln -s "$SYS_DISTRO/icons/Cursor-Only" "$XDG_HOME/icons/Linked-Cursors"
icon_theme "$XDG_HOME/icons/Split-Theme"; cursor_theme "$SYS_DISTRO/icons/Split-Theme"   # icons in one folder, cursors in another
ln -s "$TMP/missing-target" "$XDG_HOME/icons/Broken-Icons"

mkdir -p "$TMP/bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${CM_TEST_LOG:?}"' '[ "${1:-}" = get ] && printf "%s\n" "'"''"'"' 'exit 0' > "$TMP/bin/gsettings"
for tool in xrdb gdbus dconf; do printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/$tool"; done
chmod 755 "$TMP/bin"/*

# run <case code>: the fake system is the whole environment of the program.
run() {
    : > "$TMP/calls.log"
    env HOME="$HOME_DIR" CM_HOME="$TMP/state" CM_LANG_OVERRIDE=en XDG_DATA_HOME="$XDG_HOME" \
        XDG_DATA_DIRS="$SYS_LOCAL:$SYS_DISTRO" PATH="$TMP/bin:$PATH" CM_TEST_LOG="$TMP/calls.log" \
        bash -c 'source "$1"; cm_lang_init; shift; eval "$*"' bash "$BODY" "$@"
}

# --- search order -------------------------------------------------------------------------------------
expected="$(printf '%s\n' "$HOME_DIR/.themes" "$XDG_HOME/themes" "$SYS_LOCAL/themes" "$SYS_DISTRO/themes")"
[ "$(run cm_data_dirs themes)" = "$expected" ] || fail 'theme folders or their order are wrong'
expected="$(printf '%s\n' "$HOME_DIR/.icons" "$XDG_HOME/icons" "$SYS_LOCAL/icons" "$SYS_DISTRO/icons")"
[ "$(run cm_data_dirs icons)" = "$expected" ] || fail 'icon folders or their order are wrong'
defaults="$(env -u XDG_DATA_HOME -u XDG_DATA_DIRS HOME="$HOME_DIR" CM_HOME="$TMP/state" CM_LANG_OVERRIDE=en \
    bash -c 'source "$1"; cm_data_dirs themes' bash "$BODY")"
expected="$(printf '%s\n' "$HOME_DIR/.themes" "$HOME_DIR/.local/share/themes" /usr/local/share/themes /usr/share/themes)"
[ "$defaults" = "$expected" ] || fail 'default XDG theme folders are wrong'
pass 'theme folders follow the GTK search order (legacy, XDG user, XDG system)'

# --- listings -----------------------------------------------------------------------------------------
same_set() { [ "$(printf '%s\n' "$1" | LC_ALL=C sort)" = "$(printf '%s\n' "$2" | LC_ALL=C sort)" ]; }
list_is() {
    local fn="$1" want="$2" got
    got="$(run "$fn")"
    same_set "$got" "$want" || fail "$fn lists: $(printf '%s' "$got" | tr '\n' ' ')| expected: $(printf '%s' "$want" | tr '\n' ' ')"
    [ -z "$got" ] || printf '%s\n' "$got" | sort -c || fail "$fn is not sorted"
    [ "$(printf '%s\n' "$got" | sort | uniq -d | wc -l)" -eq 0 ] || fail "$fn repeats a name"
}
list_is cm_list_gtk_themes "$(printf '%s\n' Adwaita-Plus Distro-GTK Legacy-GTK Linked-GTK Local-GTK Mint-Y-Aqua Mint-Y-Dark \
    Mint-Y-Dark-Aqua Modern-GTK 'Spaced Name' Versioned-GTK)"
pass 'GTK themes: gtk-3.* with gtk.css, versioned folders, links that work; key themes, GTK2, empty folders and hidden names out'

list_is cm_list_icon_themes "$(printf '%s\n' Both-Theme Crlf-Icons Distro-Icons Hidden-After-Directories Legacy-Icons Linked-Icons \
    Local-Icons Mint-Y-Aqua Modern-Icons Split-Theme)"
pass 'icon themes: index.theme with Directories=; Hidden=true before it, no index.theme, hicolor/gnome and broken links out'

list_is cm_list_cursor_themes "$(printf '%s\n' Both-Theme Cursor-Only Linked-Cursors Split-Theme)"
list_is cm_list_cinnamon_themes "$(printf '%s\n' Adwaita-dark Distro-Cin Linked-Cin Mint-Y-Dark-Aqua Modern-Cin)"
pass 'cursor themes need a cursors folder (Mint-Y has none); Cinnamon themes need a cinnamon folder and none is hidden'

[ "$(run cm_list_mint_y_colors Mint-Y-Dark)" = 'Aqua' ] || fail 'Mint-Y colour list must read the XDG folder too'
[ "$(run cm_list_mint_y_colors Mint-Y)" = 'Aqua' ] || fail 'Mint-Y-Dark is a theme of its own, not a colour of the light Mint-Y'
pass 'Mint-Y colours come from the XDG folder and never include Dark'

# --- cost: a fixed number of processes however many themes there are ---------------------------------
# Every external tool the lists could call once per folder is replaced by a counting double.
mkdir -p "$TMP/forkbin"
for tool in basename dirname grep sed awk cat head tail cut tr stat readlink find sort xargs ls; do
    real="$(command -v "$tool")" || continue
    printf '#!/usr/bin/env bash\nprintf x >> "${CM_FORK_LOG:?}"\nexec %q "$@"\n' "$real" > "$TMP/forkbin/$tool"
done
chmod 755 "$TMP/forkbin"/*
# cost_of <themes of each kind>: processes started by every list, and the seconds they took
cost_of() {
    local n="$1" i root
    root="$TMP/cost-$n"
    mkdir -p "$root/home" "$root/xdg" "$root/usr"
    for ((i = 0; i < n; i++)); do
        gtk_theme "$root/xdg/themes/Theme-$i"; cinnamon_theme "$root/xdg/themes/Theme-$i"
        icon_theme "$root/xdg/icons/Icons-$i"; cursor_theme "$root/xdg/icons/Cursor-$i"
    done
    : > "$TMP/forks.log"
    local started=$SECONDS
    env HOME="$root/home" CM_HOME="$TMP/state" CM_LANG_OVERRIDE=en XDG_DATA_HOME="$root/xdg" XDG_DATA_DIRS="$root/usr" \
        PATH="$TMP/forkbin:$TMP/bin:$PATH" CM_FORK_LOG="$TMP/forks.log" \
        bash -c 'source "$1"; cm_lang_init; cm_list_gtk_themes; cm_list_icon_themes; cm_list_cursor_themes; cm_list_cinnamon_themes; cm_list_mint_y_colors Mint-Y || true' \
        bash "$BODY" > "$TMP/cost-$n.out"
    COST_SECONDS=$((SECONDS - started))
    COST_FORKS="$(wc -c < "$TMP/forks.log" | tr -d '[:space:]')"
    COST_LINES="$(wc -l < "$TMP/cost-$n.out" | tr -d '[:space:]')"
}
cost_of 30;  small_forks="$COST_FORKS"; small_lines="$COST_LINES"
cost_of 300; large_forks="$COST_FORKS"; large_lines="$COST_LINES"
[ "$small_lines" -eq 120 ] && [ "$large_lines" -eq 1200 ] || fail "cost fixture is wrong: $small_lines and $large_lines names listed"
[ "$small_forks" -eq "$large_forks" ] || fail "the lists start more processes with more themes: $small_forks with 30, $large_forks with 300"
[ "$large_forks" -le 12 ] || fail "the lists start too many processes: $large_forks"
[ "$COST_SECONDS" -le 10 ] || fail "listing 300 themes of each kind took $COST_SECONDS s"
pass "the lists start $large_forks processes with 30 or with 300 themes of each kind (the last run took ${COST_SECONDS} s)"

# --- installed or not ---------------------------------------------------------------------------------
installed() { run "cm_theme_installed $1 $2" >/dev/null 2>&1; }
for name in Legacy-GTK Modern-GTK Local-GTK Distro-GTK Adwaita Adwaita-dark HighContrast; do
    installed themes "$name" || fail "GTK theme $name must count as installed"
done
installed themes Typo-GTK && fail 'a theme that does not exist must not count as installed'
for name in Legacy-Icons Modern-Icons Local-Icons Distro-Icons Cursor-Only; do
    installed icons "$name" || fail "icon theme $name must count as installed"
done
installed icons Typo-Icons && fail 'an icon theme that does not exist must not count as installed'
for name in Modern-Cin Distro-Cin cinnamon; do
    installed cinnamon "$name" || fail "Cinnamon theme $name must count as installed"
done
installed cinnamon Legacy-GTK && fail 'a theme without a cinnamon folder is not a Cinnamon theme'
pass 'theme existence follows the search folders and the built-in themes'

# A cursor theme is an icon folder with cursors/ in some search folder. An icon theme without one is another
# status than a missing theme (3 and 1), so a refusal can say which it is.
cursor_status() { local rc=0; run "cm_theme_installed cursors '$1'" >/dev/null 2>&1 || rc=$?; printf '%s\n' "$rc"; }
for name in Cursor-Only Both-Theme Linked-Cursors Split-Theme Adwaita; do
    [ "$(cursor_status "$name")" = 0 ] || fail "$name must count as an installed cursor theme"
done
for name in Legacy-Icons Modern-Icons Distro-Icons Linked-Icons Plain-Dir No-Directories; do
    [ "$(cursor_status "$name")" = 3 ] || fail "$name is an icon folder without cursors/: status 3 expected, got $(cursor_status "$name")"
done
for name in Typo-Cursor Broken-Icons Legacy-GTK; do
    [ "$(cursor_status "$name")" = 1 ] || fail "$name is not an icon folder at all: status 1 expected, got $(cursor_status "$name")"
done
while IFS= read -r name; do
    [ "$(cursor_status "$name")" = 0 ] || fail "the cursor list offers $name but it is not an installed cursor theme"
done < <(run cm_list_cursor_themes)
pass 'cursor themes: cursors/ in any search folder; an icon theme without it is status 3, a missing one status 1; the list and the status agree'

# --- applying: installed themes go through, unknown ones are refused before anything is written -------
accepts() {
    run "$1 '$2'" >/dev/null 2>&1 || fail "$1 refused the installed theme $2"
    grep -q "^set $3 $2\$" "$TMP/calls.log" || fail "$1 did not write $2: $(tr '\n' ';' < "$TMP/calls.log")"
}
refuses() {
    if run "$1 '$2'" >"$TMP/out" 2>"$TMP/err"; then fail "$1 accepted the missing theme $2"; fi
    grep -q 'is not installed on this system' "$TMP/err" || fail "$1: the refusal for $2 must say the theme is not installed"
    [ ! -s "$TMP/calls.log" ] || fail "$1 wrote settings for the missing theme $2: $(tr '\n' ';' < "$TMP/calls.log")"
}
accepts cm_apply_gtk_theme Modern-GTK 'org.cinnamon.desktop.interface gtk-theme'
accepts cm_apply_gtk_theme Distro-GTK 'org.cinnamon.desktop.interface gtk-theme'
accepts cm_apply_gtk_theme Adwaita 'org.cinnamon.desktop.interface gtk-theme'
accepts cm_apply_icon_theme Modern-Icons 'org.cinnamon.desktop.interface icon-theme'
accepts cm_apply_cursor_theme Cursor-Only 'org.cinnamon.desktop.interface cursor-theme'
accepts cm_apply_cinnamon_theme Modern-Cin 'org.cinnamon.theme name'
refuses cm_apply_gtk_theme Typo-GTK
refuses cm_apply_icon_theme Typo-Icons
refuses cm_apply_cursor_theme Typo-Cursor
refuses cm_apply_cinnamon_theme Legacy-GTK
pass 'installed themes are applied, missing ones are refused without touching the settings'

# --- the Mint-Y colour packs and the editable copy of a Cinnamon theme --------------------------------
run "cm_apply_mint_y_pack Aqua oscuro" >/dev/null 2>&1 || fail 'Mint-Y pack from the XDG folder was refused'
for setting in 'org.cinnamon.desktop.interface gtk-theme Mint-Y-Dark-Aqua' 'org.cinnamon.desktop.interface icon-theme Mint-Y-Aqua' 'org.cinnamon.theme name Mint-Y-Dark-Aqua'; do
    grep -q "^set $setting\$" "$TMP/calls.log" || fail "Mint-Y pack did not write: $setting"
done
if run "cm_apply_mint_y_pack Nope oscuro" >/dev/null 2>&1; then fail 'a missing Mint-Y colour must be refused'; fi
[ "$(run 'cm_panel_locate_base Modern-Cin')" = "$XDG_HOME/themes/Modern-Cin" ] || fail 'base theme in the XDG user folder not found'
[ "$(run 'cm_panel_locate_base Distro-Cin')" = "$SYS_DISTRO/themes/Distro-Cin" ] || fail 'base theme in the system folder not found'
if run 'cm_panel_locate_base Legacy-GTK' >/dev/null 2>&1; then fail 'a theme without a cinnamon folder cannot be a base theme'; fi
pass 'Mint-Y packs and the panel base theme are found wherever they are installed'

# --- libadwaita: the gtk-4.0 stylesheet of the GTK theme, imported from Color Mint's block -------------------------
# The block in ~/.config/gtk-4.0/gtk.css holds an optional @import and the accent lines; the file is the only record.
# The import line is written when `theme libadwaita on` runs and kept in step with the theme and the light/dark
# scheme that Color Mint changes; the accent writers keep it; nothing else touches it.
# shellcheck source=lib/doubles.sh
. "$ROOT/tests/lib/doubles.sh"
LA="$TMP/la"; LT="$LA/data/themes"; CSS="$LA/home/.config/gtk-4.0/gtk.css"
B='/* >>> Color Mint: acento GTK global (autogenerado, no editar a mano) >>> */'
E='/* <<< Color Mint: acento GTK global <<< */'
mkdir -p "$LA/home" "$LA/none" "$LT"
cm_double_install "$LA/bin"
la_theme() { mkdir -p "$1/gtk-3.0" "$1/gtk-4.0"; : > "$1/gtk-3.0/gtk.css"; }
la_theme "$LT/Ad-Both"
printf '@define-color accent_bg_color #26a269;\n' > "$LT/Ad-Both/gtk-4.0/gtk.css"
printf '@define-color accent_bg_color #1a5fb4;\n' > "$LT/Ad-Both/gtk-4.0/gtk-dark.css"
la_theme "$LT/Ad-Light"; : > "$LT/Ad-Light/gtk-4.0/gtk.css"
la_theme "$LT/Ad-Dark"; : > "$LT/Ad-Dark/gtk-4.0/gtk-dark.css"                  # a dark sheet and no light one
mkdir -p "$LT/Ad-None/gtk-3.0"; : > "$LT/Ad-None/gtk-3.0/gtk.css"                # no gtk-4.0 at all
la_theme "$LT/Ad-Dir"; mkdir "$LT/Ad-Dir/gtk-4.0/gtk.css"                       # gtk.css is a folder
la_theme "$LT/Ad-Broken"; ln -s "$LA/missing.css" "$LT/Ad-Broken/gtk-4.0/gtk.css"
la_theme "$LT/Ad-Linked"; printf 'x\n' > "$LA/real.css"; ln -s "$LA/real.css" "$LT/Ad-Linked/gtk-4.0/gtk.css"
la_theme "$LT/Ad-Quote \"q\" (x);}"; : > "$LT/Ad-Quote \"q\" (x);}/gtk-4.0/gtk.css"

# la_at <XDG data home> <code>: the program's functions on that fake system, in the current folder $LA (LA_LANG=es for Spanish).
la_at() {
    local xdg="$1"; shift
    ( cd "$LA" && env HOME="$LA/home" CM_HOME="$LA/state" CM_LANG_OVERRIDE="${LA_LANG:-en}" XDG_DATA_HOME="$xdg" XDG_DATA_DIRS="$LA/none" \
        PATH="$LA/bin:$PATH" DCONF_DB="$LA/db" bash -c 'source "$1"; cm_lang_init; shift; eval "$*"' bash "$BODY" "$@" )
}
la() { la_at "$LA/data" "$@"; }
la_gtk() { cm_double_db_set "$LA/db" /org/cinnamon/desktop/interface/gtk-theme "'$1'"; }
la_scheme() { cm_double_db_set "$LA/db" /org/x/apps/portal/color-scheme "'$1'"; }
la_fresh() { rm -rf "$LA/home/.config" "$LA/state"; }
la_imports() { grep -c '^@import' "$CSS" || true; }
# import_is <sheet>: the one @import in the block points at that file of Ad-Both.
import_is() { [ "$(grep '^@import' "$CSS")" = "@import \"$LT/Ad-Both/gtk-4.0/$1\";" ]; }
la_sum() { sha256sum < "$CSS" | cut -d' ' -f1; }
ACCENT_CALL="cm_apply_gtk_accent_color '#e91e63'"

# nothing to do: off and status create nothing, and on without a readable theme fails without writing
la_fresh
[ "$(la cm_apply_libadwaita status)" = 'libadwaita is not importing a theme. Turn it on with: theme libadwaita on' ] || fail 'status with no import must say so'
[ "$(la cm_apply_libadwaita off)" = 'libadwaita was not importing a theme.' ] || fail 'off with no import must say so'
[ ! -e "$LA/home/.config/gtk-4.0" ] || fail 'status and off created ~/.config/gtk-4.0'
if la cm_apply_libadwaita on >"$TMP/o" 2>"$TMP/e"; then fail 'on with no readable GTK theme must fail'; fi
grep -q 'could not read the active GTK theme' "$TMP/e" || fail "on without a GTK theme must say why: $(cat "$TMP/e")"
[ ! -e "$LA/home/.config/gtk-4.0" ] || fail 'a failed on created ~/.config/gtk-4.0'
pass 'libadwaita: status and off write nothing, on without an active theme fails without writing'

# on: the import goes in the block, below the user's own lines, light stylesheet while the scheme is unset
la_fresh; mkdir -p "$LA/home/.config/gtk-4.0"
printf '/* mine */\n.user { color: red; }\n' > "$CSS"
la_gtk Ad-Both
la cm_apply_libadwaita on >"$TMP/o" 2>"$TMP/e" || fail "libadwaita on failed: $(cat "$TMP/e")"
want="$(printf '%s\n' '/* mine */' '.user { color: red; }' "$B" "@import \"$LT/Ad-Both/gtk-4.0/gtk.css\";" "$E")"
[ "$(cat "$CSS")" = "$want" ] || fail "libadwaita on wrote the wrong block: $(cat "$CSS")"
grep -q 'gtk-4.0 style of the theme Ad-Both' "$TMP/o" || fail "on must say which theme it imported: $(cat "$TMP/o")"
[ "$(la cm_apply_libadwaita status)" = "libadwaita imports: $LT/Ad-Both/gtk-4.0/gtk.css" ] || fail 'status must print the imported file'
la cm_apply_libadwaita on >/dev/null 2>&1 || fail 'a second on failed'
[ "$(la_imports)" -eq 1 ] && [ "$(grep -cF "$B" "$CSS")" -eq 1 ] || fail 'repeating on duplicated the import or the block'
pass 'libadwaita on writes one import inside the block, under the user lines, and repeating it changes nothing'

# the light/dark scheme: the stylesheet is chosen when it is written and follows the scheme Color Mint sets
la_scheme default
la cm_apply_color_scheme prefer-dark >/dev/null 2>&1 || fail 'prefer-dark failed'
import_is gtk-dark.css || fail "prefer-dark must import gtk-dark.css: $(cat "$CSS")"
la cm_apply_color_scheme prefer-light >/dev/null 2>&1; import_is gtk.css || fail 'prefer-light must import gtk.css'
la cm_apply_color_scheme prefer-dark >/dev/null 2>&1; la cm_apply_color_scheme default >/dev/null 2>&1
import_is gtk.css || fail 'default must import gtk.css (libadwaita paints light with no scheme)'
la cm_apply_color_scheme prefer-dark >/dev/null 2>&1
la_scheme prefer-dark; la cm_apply_libadwaita on >/dev/null 2>&1; import_is gtk-dark.css || fail 'on must follow the scheme the portal holds'
pass 'libadwaita follows the light/dark scheme: gtk-dark.css for prefer-dark, gtk.css for the rest'

# the accent keeps the import and goes under it; reset and off each take away only their own part
la "$ACCENT_CALL" >/dev/null 2>&1 || fail 'accent failed with an import in the block'
import_is gtk-dark.css || fail 'the accent dropped the import'
[ "$(grep -c '^@define-color' "$CSS")" -eq 5 ] && [ "$(grep -cF "$B" "$CSS")" -eq 1 ] || fail 'the accent must add its five names once, in one block'
[ "$(grep -n '^@import' "$CSS" | cut -d: -f1)" -lt "$(grep -n '^@define-color' "$CSS" | head -n1 | cut -d: -f1)" ] || fail 'the import must come before the accent lines, or the imported theme wins'
[ "$(head -n 2 "$CSS")" = "$(printf '%s\n%s' '/* mine */' '.user { color: red; }')" ] || fail 'the accent changed the user lines'
la cm_reset_gtk_accent_color >"$TMP/o" 2>&1 || fail "reset failed: $(cat "$TMP/o")"
[ "$(cat "$CSS")" = "$(printf '%s\n' '/* mine */' '.user { color: red; }' "$B" "@import \"$LT/Ad-Both/gtk-4.0/gtk-dark.css\";" "$E")" ] || fail "reset must leave the import and no accent: $(cat "$CSS")"
if la cm_reset_gtk_accent_color >/dev/null 2>&1; then fail 'a second reset, with no accent left, must report that there is none'; fi
import_is gtk-dark.css || fail 'a reset with no accent changed the import'
la "$ACCENT_CALL" >/dev/null 2>&1
la cm_apply_libadwaita off >"$TMP/o" 2>&1 || fail 'off failed'
[ "$(la_imports)" -eq 0 ] && [ "$(grep -c '^@define-color' "$CSS")" -eq 5 ] || fail "off must remove the import and keep the accent: $(cat "$CSS")"
la cm_reset_gtk_accent_color >/dev/null 2>&1 || fail 'reset after off failed'
[ "$(cat "$CSS")" = "$(printf '%s\n%s' '/* mine */' '.user { color: red; }')" ] || fail "with import and accent gone the file must be what the user wrote: $(cat "$CSS")"
la "$ACCENT_CALL" >/dev/null 2>&1; [ "$(la_imports)" -eq 0 ] || fail 'an accent applied with the import off must not bring one back'
la cm_reset_gtk_accent_color >/dev/null 2>&1
pass 'the accent keeps the import above it; reset removes only the accent and off only the import; both gone leaves the user file'

# a GTK theme change keeps the import in step; one with no gtk-4.0 takes it away; with it off nothing is written
la_fresh; mkdir -p "$LA/home/.config/gtk-4.0"; la_gtk Ad-Both; la_scheme prefer-dark
la cm_apply_libadwaita on >/dev/null 2>&1; la "$ACCENT_CALL" >/dev/null 2>&1
la 'cm_apply_gtk_theme Ad-Light' >"$TMP/o" 2>"$TMP/e" || fail 'applying Ad-Light failed'
[ "$(grep '^@import' "$CSS")" = "@import \"$LT/Ad-Light/gtk-4.0/gtk.css\";" ] || fail "a theme change must move the import: $(cat "$CSS")"
grep -q 'WARNING: the theme Ad-Light has no gtk-4.0/gtk-dark.css' "$TMP/e" || fail "a theme with no dark sheet on the dark scheme must warn: $(cat "$TMP/e")"
grep -q 'if that style is light, the colors mix' "$TMP/e" || fail "the warning must not claim that the sheet is light, which Color Mint cannot know: $(cat "$TMP/e")"
grep -qi 'its light' "$TMP/e" && fail 'the warning calls the sheet light'
es="$(env HOME="$LA/home" CM_HOME="$LA/state" CM_LANG_OVERRIDE=es XDG_DATA_HOME="$LA/data" XDG_DATA_DIRS="$LA/none" PATH="$LA/bin:$PATH" DCONF_DB="$LA/db" \
    bash -c 'source "$1"; cm_lang_init; cm_libadwaita_write Ad-Light prefer-dark' bash "$BODY" 2>&1 >/dev/null)"
[ "$es" = 'ADVERTENCIA: el tema Ad-Light no trae gtk-4.0/gtk-dark.css: se importa su gtk.css con el esquema oscuro; si ese estilo es claro, los colores se mezclan.' ] || fail "the Spanish warning is wrong: $es"
[ "$(sed -n 1p "$TMP/o")" = 'GTK theme applied: Ad-Light' ] || fail 'the first line of the setter output changed'
la 'cm_apply_gtk_theme Ad-Dark' >"$TMP/o" 2>"$TMP/e"
[ "$(grep '^@import' "$CSS")" = "@import \"$LT/Ad-Dark/gtk-4.0/gtk-dark.css\";" ] || fail 'a dark-only theme must import its gtk-dark.css'
[ ! -s "$TMP/e" ] || fail "a dark sheet on the dark scheme must not warn: $(cat "$TMP/e")"
la cm_apply_color_scheme prefer-light >"$TMP/o" 2>&1
[ "$(la_imports)" -eq 0 ] && grep -q 'The theme Ad-Dark has no gtk-4.0 style' "$TMP/o" || fail "a dark-only theme on a light scheme has nothing to import: it must be dropped and say so: $(cat "$TMP/o")"
la_scheme prefer-dark; la 'cm_apply_gtk_theme Ad-Both' >/dev/null 2>&1; la cm_apply_libadwaita off >/dev/null 2>&1; la cm_apply_libadwaita on >/dev/null 2>&1
la 'cm_apply_gtk_theme Ad-None' >"$TMP/o" 2>"$TMP/e" || fail 'applying Ad-None failed'
[ "$(la_imports)" -eq 0 ] || fail 'a theme without gtk-4.0 must take the import away'
grep -q 'The theme Ad-None has no gtk-4.0 style: libadwaita stops importing a theme' "$TMP/o" || fail "dropping the import must be said: $(cat "$TMP/o")"
[ "$(grep -c '^@define-color' "$CSS")" -eq 5 ] || fail 'dropping the import must keep the accent'
sum="$(la_sum)"
la 'cm_apply_gtk_theme Ad-Both' >"$TMP/o" 2>"$TMP/e"; la cm_apply_color_scheme prefer-light >/dev/null 2>&1; la cm_apply_color_scheme prefer-dark >/dev/null 2>&1
[ "$(la_sum)" = "$sum" ] || fail 'with the import off, a theme or scheme change rewrote gtk.css'
[ "$(cat "$TMP/o")" = 'GTK theme applied: Ad-Both' ] || fail "with the import off the setter prints nothing more: $(cat "$TMP/o")"
pass 'a theme or scheme change moves, keeps or drops the import (with a warning or a notice); with it off, gtk.css is left alone'

# refused: a theme with no stylesheet, a stylesheet that is not a file, a path that cannot be imported
la_fresh; la_scheme default
for t in Ad-None Ad-Dir Ad-Broken Ghost; do
    la_gtk "$t"
    if la cm_apply_libadwaita on >"$TMP/o" 2>"$TMP/e"; then fail "on accepted $t"; fi
    grep -q "the theme $t is not installed or has no gtk-4.0/gtk.css; nothing was changed" "$TMP/e" || fail "on must refuse $t and say why: $(cat "$TMP/e")"
    [ ! -e "$LA/home/.config/gtk-4.0" ] || fail "the refusal for $t created ~/.config/gtk-4.0"
done
la_gtk Ad-Linked; la cm_apply_libadwaita on >/dev/null 2>&1 || fail 'a stylesheet that is a link to a file must be accepted'
[ "$(grep '^@import' "$CSS")" = "@import \"$LT/Ad-Linked/gtk-4.0/gtk.css\";" ] || fail 'the import must name the stylesheet as GTK finds it, not the link target'
la_fresh; la_gtk Ad-Both
mkdir -p "$LA/rel/themes"; cp -r "$LT/Ad-Both" "$LA/rel/themes/"
if la_at rel 'cm_apply_libadwaita on' >"$TMP/o" 2>"$TMP/e"; then fail 'a relative data folder must be refused'; fi
grep -q 'cannot be imported (not absolute or has control characters)' "$TMP/e" || fail "a relative path must be refused with its reason: $(cat "$TMP/e")"
TAB="$LA/data"$'\t'"x"; mkdir -p "$TAB/themes"; cp -r "$LT/Ad-Both" "$TAB/themes/"
if la_at "$TAB" 'cm_apply_libadwaita on' >"$TMP/o" 2>"$TMP/e"; then fail 'a path with a control character must be refused'; fi
grep -q 'cannot be imported (not absolute or has control characters)' "$TMP/e" || fail "a control character must be refused with its reason: $(cat "$TMP/e")"
[ ! -e "$LA/home/.config/gtk-4.0" ] || fail 'a refused path created ~/.config/gtk-4.0'
pass 'libadwaita refuses a missing theme, a stylesheet that is not a file and an unusable path, and writes nothing'

# A stylesheet that @imports a bundled resource (Yaru: @import url("resource:///…") next to a gtk.gresource) cannot be
# imported from a user's gtk.css: GTK registers the resource only when the theme is chosen by name (measured: GTK 4.14.5)
RES='@import url("resource:///com/ubuntu/themes/Yaru/4.0/gtk.css");'
la_sheet() { la_theme "$LT/$1"; printf '%s\n' "$3" > "$LT/$1/gtk-4.0/$2"; }
la_sheet Ad-Bundled gtk.css "$RES"; printf '%s\n' "$RES" > "$LT/Ad-Bundled/gtk-4.0/gtk-dark.css"
la_sheet Ad-BundledDark gtk.css '@define-color accent_bg_color #26a269;'; printf '%s\n' "$RES" > "$LT/Ad-BundledDark/gtk-4.0/gtk-dark.css"
la_sheet Ad-Mixed gtk.css "$(printf '%s\n' '@define-color accent_bg_color #26a269;' "$RES")"
la_sheet Ad-Commented gtk.css "$(printf '%s\n' "/* was: $RES */" '@define-color accent_bg_color #26a269;')"
la_sheet Ad-Relative gtk.css '@import url("colors.css");'; printf '@define-color accent_bg_color #26a269;\n' > "$LT/Ad-Relative/gtk-4.0/colors.css"

# the detector, case by case: the file name says what it must answer
mkdir -p "$LA/css"
mkcss() { printf '%s' "$2" > "$LA/css/$1.css"; }
mkcss yes_double "$RES"
mkcss yes_single "@import url('resource:///a/b.css');"
mkcss yes_string '@import "resource:///a/b.css";'
mkcss yes_bare '@import url(resource:///a/b.css);'
mkcss yes_upper '@IMPORT URL("RESOURCE:///a/b.css");'
mkcss yes_split $'@import\n   url("resource:///a/b.css");'
mkcss yes_after_rules $'.x { color: red; }\n@import url("resource:///a");\n.y { color: blue; }'
mkcss yes_between_comments '/* c */ @import url("resource:///a"); /* d */'
mkcss yes_after_comment_lines $'/* a */\n/* b */ @import url("resource:///x");'
mkcss no_comment '/* @import url("resource:///a/b.css"); */'
mkcss no_multiline_comment $'/* old:\n@import url("resource:///a");\n*/\n@define-color x #fff;'
mkcss no_unclosed_comment $'/* open\n@import url("resource:///x");'
mkcss no_file_import '@import url("colors.css");'
mkcss no_colors '@define-color window_bg_color #ffeedd;'
mkcss no_class '.resource { color: red; }'
mkcss no_path_with_resource '@import "/home/u/.themes/resource:x/gtk.css";'
: > "$LA/css/no_empty.css"
got="$(la "for f in '$LA'/css/*.css; do if cm_css_imports_resource \"\$f\"; then echo \"yes \${f##*/}\"; else echo \"no \${f##*/}\"; fi; done")"
[ "$(grep -c . <<< "$got")" -eq 17 ] || fail "the detector must answer for all 17 files: $got"
while read -r answer name; do
    case "$name" in "${answer}_"*) ;; *) fail "the resource detector answered $answer for $name" ;; esac
done <<< "$got"
pass 'the resource detector finds an @import of resource:// in any spelling and ignores comments, other imports and look-alikes'

# on: refused, with the reason and nothing written, for a sheet that is bundled or only partly so; the sheet that would
# be imported decides (gtk-dark.css on the dark scheme)
for t in Ad-Bundled Ad-Mixed; do
    la_fresh; la_scheme default; la_gtk "$t"
    if la cm_apply_libadwaita on >"$TMP/o" 2>"$TMP/e"; then fail "on accepted the bundled theme $t"; fi
    grep -qF "ERROR: the theme $t ships its gtk-4.0 style as a bundled resource (resource://), which GTK loads only when the theme is chosen by name: libadwaita cannot import it. Nothing was changed." "$TMP/e" \
        || fail "on must refuse $t and say why: $(cat "$TMP/e")"
    [ ! -s "$TMP/o" ] && [ ! -e "$LA/home/.config/gtk-4.0" ] || fail "the refusal for $t printed to stdout or created ~/.config/gtk-4.0"
done
la_fresh; la_scheme prefer-dark; la_gtk Ad-Bundled
if la cm_apply_libadwaita on >/dev/null 2>"$TMP/e"; then fail 'on accepted a bundled gtk-dark.css'; fi
grep -qF 'ships its gtk-4.0 style as a bundled resource' "$TMP/e" || fail 'the dark sheet of a bundled theme must be refused with the same reason'
la_fresh; la_scheme default; la_gtk Ad-BundledDark
la cm_apply_libadwaita on >/dev/null 2>&1 || fail 'a theme whose gtk.css is plain must be accepted on the light scheme'
[ "$(grep '^@import' "$CSS")" = "@import \"$LT/Ad-BundledDark/gtk-4.0/gtk.css\";" ] || fail 'the plain gtk.css must be the one imported'
la_fresh; la_scheme prefer-dark; la_gtk Ad-BundledDark
if la cm_apply_libadwaita on >/dev/null 2>&1; then fail 'on accepted a theme whose gtk-dark.css is bundled on the dark scheme'; fi
for t in Ad-Commented Ad-Relative; do                                                   # controls: these must go through
    la_fresh; la_scheme default; la_gtk "$t"
    la cm_apply_libadwaita on >"$TMP/o" 2>"$TMP/e" || fail "on refused $t, which imports no bundled resource: $(cat "$TMP/e")"
    [ "$(grep '^@import' "$CSS")" = "@import \"$LT/$t/gtk-4.0/gtk.css\";" ] || fail "on must import $t"
done
pass 'libadwaita on refuses a bundled style, the one that would be imported decides, and writes nothing; a comment or a relative import passes'

# a change that lands on a bundled theme takes the import away and says why; the accent stays
la_fresh; la_scheme default; la_gtk Ad-Both; la cm_apply_libadwaita on >/dev/null 2>&1; la "$ACCENT_CALL" >/dev/null 2>&1
la 'cm_apply_gtk_theme Ad-Bundled' >"$TMP/o" 2>"$TMP/e" || fail "applying a bundled theme failed: $(cat "$TMP/e")"
[ "$(la_imports)" -eq 0 ] || fail 'a bundled theme must take the import away'
[ "$(grep -c '^@define-color' "$CSS")" -eq 5 ] || fail 'dropping the import must keep the accent'
grep -qF 'The theme Ad-Bundled ships its gtk-4.0 style as a bundled resource (resource://), which libadwaita cannot import: it stops importing a theme (the global GTK accent stays).' "$TMP/o" \
    || fail "dropping the import must say that the style is bundled: $(cat "$TMP/o")"
grep -qF 'has no gtk-4.0 style' "$TMP/o" && fail 'a bundled theme was reported as having no gtk-4.0 style'
# the same two messages in Spanish
la_fresh; la_gtk Ad-Both; la cm_apply_libadwaita on >/dev/null 2>&1
LA_LANG=es la 'cm_apply_gtk_theme Ad-Bundled' >"$TMP/o" 2>&1 || fail 'applying a bundled theme failed in Spanish'
grep -qF 'El tema Ad-Bundled lleva su estilo gtk-4.0 como recurso empaquetado (resource://), que libadwaita no puede importar: deja de importar un tema (el acento GTK global se conserva).' "$TMP/o" \
    || fail "the Spanish notice is wrong: $(cat "$TMP/o")"
la_fresh; la_gtk Ad-Bundled
if LA_LANG=es la cm_apply_libadwaita on >/dev/null 2>"$TMP/e"; then fail 'on accepted a bundled theme in Spanish'; fi
[ "$(cat "$TMP/e")" = 'ERROR: el tema Ad-Bundled lleva su estilo gtk-4.0 como recurso empaquetado (resource://), que GTK solo carga al elegir el tema por su nombre: libadwaita no puede importarlo. No se ha cambiado nada.' ] \
    || fail "the Spanish refusal is wrong: $(cat "$TMP/e")"
# a look on a bundled theme goes through the held refresh and ends the same way
la_fresh; mkdir -p "$LA/state/presets"; la_scheme prefer-light; la_gtk Ad-Both; la cm_apply_libadwaita on >/dev/null 2>&1
printf '%s\n' 'GTK_THEME="Ad-Bundled"' 'COLOR_SCHEME="prefer-light"' > "$LA/state/presets/lk3.conf"
la 'cm_load_preset lk3' >"$TMP/o" 2>"$TMP/e" || fail "loading a look on a bundled theme failed: $(cat "$TMP/o") $(cat "$TMP/e")"
[ "$(la_imports)" -eq 0 ] && grep -qF 'ships its gtk-4.0 style as a bundled resource' "$TMP/o" || fail "a look on a bundled theme must drop the import and say why: $(cat "$TMP/o")"
pass 'a theme or a look that lands on a bundled style takes the import away and says why, in English and Spanish; the accent stays'

# the path goes in a double-quoted string: " and \ are escaped and nothing else, and status reads it back
la_fresh; la_gtk 'Ad-Quote "q" (x);}'
la cm_apply_libadwaita on >"$TMP/o" 2>"$TMP/e" || fail "a theme name with quotes, brackets and ;} failed: $(cat "$TMP/e")"
[ "$(grep '^@import' "$CSS")" = "@import \"$LT/Ad-Quote \\\"q\\\" (x);}/gtk-4.0/gtk.css\";" ] || fail "quotes must be escaped with a backslash: $(grep '^@import' "$CSS")"
[ "$(la cm_apply_libadwaita status)" = "libadwaita imports: $LT/Ad-Quote \"q\" (x);}/gtk-4.0/gtk.css" ] || fail 'status must undo the escaping'
BS="$LA/data\\bs"; mkdir -p "$BS/themes"; cp -r "$LT/Ad-Both" "$BS/themes/"
la_fresh; la_gtk Ad-Both
la_at "$BS" 'cm_apply_libadwaita on' >/dev/null 2>&1 || fail 'a data folder with a backslash failed'
esc="${BS//\\/\\\\}"
[ "$(grep '^@import' "$CSS")" = "@import \"$esc/themes/Ad-Both/gtk-4.0/gtk.css\";" ] || fail "a backslash must be doubled: $(grep '^@import' "$CSS")"
[ "$(la_at "$BS" cm_apply_libadwaita status)" = "libadwaita imports: $BS/themes/Ad-Both/gtk-4.0/gtk.css" ] || fail 'status must undo the doubled backslash'
pass 'the import path is a double-quoted string with only " and \ escaped, and status reads it back'

# a theme that was removed: status says so, the next change fixes it, off removes it
la_fresh; la_gtk Ad-Both; la cm_apply_libadwaita on >/dev/null 2>&1
mv "$LT/Ad-Both" "$LA/Ad-Both.away"
la cm_apply_libadwaita status >"$TMP/o" 2>&1
grep -q 'imports a file that no longer exists' "$TMP/o" && grep -q 'theme libadwaita off' "$TMP/o" || fail "status must flag a removed theme: $(cat "$TMP/o")"
la cm_apply_libadwaita off >/dev/null 2>&1; [ "$(la_imports)" -eq 0 ] || fail 'off must remove an import whose theme is gone'
mv "$LA/Ad-Both.away" "$LT/Ad-Both"
pass 'an import whose theme was removed is reported by status and removed by off'

# gtk.css is a link: the write goes through it and the link stays; an unclosed block is refused and left as it is
la_fresh; mkdir -p "$LA/home/.config/gtk-4.0" "$LA/dot"
printf '.user { color: blue; }\n' > "$LA/dot/gtk4.css"; ln -s "$LA/dot/gtk4.css" "$CSS"
la_gtk Ad-Both; la cm_apply_libadwaita on >/dev/null 2>&1 || fail 'on through a link failed'
[ -L "$CSS" ] && [ "$(readlink "$CSS")" = "$LA/dot/gtk4.css" ] || fail 'on replaced the link'
grep -qF "@import \"$LT/Ad-Both/gtk-4.0/gtk.css\";" "$LA/dot/gtk4.css" && grep -qF '.user { color: blue; }' "$LA/dot/gtk4.css" || fail 'on must write to what the link points to'
rm -f "$CSS" "$LA/dot/gtk4.css"
printf '%s\n%s\n' '.user { color: green; }' "$B" > "$CSS"
sum="$(la_sum)"
if la cm_apply_libadwaita on >"$TMP/o" 2>"$TMP/e"; then fail 'on must refuse an unclosed block'; fi
[ "$(la_sum)" = "$sum" ] || fail 'a refused on changed an unclosed block'
grep -q 'opening marker of a Color Mint block without its closing one' "$TMP/e" || fail "an unclosed block must be named: $(cat "$TMP/e")"
pass 'libadwaita writes through a gtk.css link without replacing it and leaves an unclosed block alone'

# a look: loading a preset applies the theme and then the scheme, so the import ends on the look's stylesheet
la_fresh; mkdir -p "$LA/state/presets"; la_gtk Ad-Light; la_scheme prefer-light
la cm_apply_libadwaita on >/dev/null 2>&1
printf '%s\n' 'GTK_THEME="Ad-Both"' 'COLOR_SCHEME="prefer-dark"' > "$LA/state/presets/lk.conf"
la 'cm_load_preset lk' >"$TMP/o" 2>"$TMP/e" || fail "loading the look failed: $(cat "$TMP/o") $(cat "$TMP/e")"
import_is gtk-dark.css || fail "a look with prefer-dark must end on the dark stylesheet of its theme: $(cat "$CSS")"
printf '%s\n' 'GTK_THEME="Ad-None"' 'COLOR_SCHEME="prefer-light"' > "$LA/state/presets/lk2.conf"
la 'cm_load_preset lk2' >/dev/null 2>&1 || fail 'loading the second look failed'
[ "$(la_imports)" -eq 0 ] || fail 'a look whose theme has no gtk-4.0 must take the import away'
pass 'loading a look keeps the import on the theme and scheme of the look, or drops it when the theme has no gtk-4.0'

# a look or a pack sets the theme and then the scheme: the import is written once, for the pair, and the pair is
# what the warning judges (going from a dark scheme to a light look used to warn about a light sheet on a dark scheme)
count_writes='eval "$(declare -f cm_libadwaita_write | sed "1s/^cm_libadwaita_write/cm_libadwaita_write_real/")"; cm_libadwaita_write() { printf "w\n" >> writes; cm_libadwaita_write_real "$@"; };'
la_fresh; rm -f "$LA/writes"; mkdir -p "$LA/state/presets"; la_gtk Ad-Both; la_scheme prefer-dark
la cm_apply_libadwaita on >/dev/null 2>&1
printf '%s\n' 'GTK_THEME="Ad-Light"' 'COLOR_SCHEME="prefer-light"' > "$LA/state/presets/lk3.conf"
la "$count_writes cm_load_preset lk3" >"$TMP/o" 2>"$TMP/e" || fail "loading a light look from the dark scheme failed: $(cat "$TMP/e")"
[ "$(grep '^@import' "$CSS")" = "@import \"$LT/Ad-Light/gtk-4.0/gtk.css\";" ] || fail "the light look must end on the light sheet: $(cat "$CSS")"
[ ! -s "$TMP/e" ] || fail "a look that goes from dark to light must not warn about the dark scheme: $(cat "$TMP/e")"
[ "$(wc -l < "$LA/writes")" -eq 1 ] || fail "a look must write the import once, not once per setting: $(wc -l < "$LA/writes")"
la_fresh; la_gtk Ad-Both; la_scheme prefer-dark; la cm_apply_libadwaita on >/dev/null 2>&1
printf '%s\n' 'GTK_THEME="Ad-Light"' 'COLOR_SCHEME="prefer-dark"' > "$LA/state/presets/lk4.conf"
la 'cm_load_preset lk4' >"$TMP/o" 2>"$TMP/e" || fail 'loading a look that stays dark failed'
grep -q 'WARNING: the theme Ad-Light has no gtk-4.0/gtk-dark.css' "$TMP/e" || fail "a dark look on a theme with only gtk.css must still warn (control): $(cat "$TMP/e")"
mkdir -p "$LT/Mint-Y-Aqua/cinnamon" "$LT/Mint-Y-Dark-Aqua/cinnamon"
la_theme "$LT/Mint-Y-Aqua"; : > "$LT/Mint-Y-Aqua/gtk-4.0/gtk.css"; : > "$LT/Mint-Y-Aqua/cinnamon/cinnamon.css"
la_theme "$LT/Mint-Y-Dark-Aqua"; : > "$LT/Mint-Y-Dark-Aqua/gtk-4.0/gtk-dark.css"; : > "$LT/Mint-Y-Dark-Aqua/cinnamon/cinnamon.css"
la_fresh; rm -f "$LA/writes"; la_gtk Mint-Y-Dark-Aqua; la_scheme prefer-dark; la cm_apply_libadwaita on >/dev/null 2>&1
la "$count_writes cm_apply_mint_y_pack Aqua claro" >"$TMP/o" 2>"$TMP/e" || fail "the light pack failed: $(cat "$TMP/o") $(cat "$TMP/e")"
[ "$(grep '^@import' "$CSS")" = "@import \"$LT/Mint-Y-Aqua/gtk-4.0/gtk.css\";" ] || fail "the light pack must end on its light sheet: $(cat "$CSS")"
[ ! -s "$TMP/e" ] || fail "a pack that goes from dark to light must not warn about the dark scheme: $(cat "$TMP/e")"
[ "$(wc -l < "$LA/writes")" -eq 1 ] || fail "a pack must write the import once: $(wc -l < "$LA/writes")"
la cm_apply_mint_y_pack Aqua oscuro >"$TMP/o" 2>"$TMP/e" || fail "the dark pack failed: $(cat "$TMP/e")"
[ "$(grep '^@import' "$CSS")" = "@import \"$LT/Mint-Y-Dark-Aqua/gtk-4.0/gtk-dark.css\";" ] || fail "the dark pack must end on its dark sheet: $(cat "$CSS")"
# cm_libadwaita_hold: a command that stops halfway still leaves the import on what it changed, and its status stays
la_fresh; la_gtk Ad-Both; la_scheme prefer-dark; la cm_apply_libadwaita on >/dev/null 2>&1
rc=0; la 'half() { cm_apply_gtk_theme Ad-Light >/dev/null 2>&1; return 7; }; cm_libadwaita_hold half' >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 7 ] || fail "cm_libadwaita_hold must return the status of its command (7), not $rc"
[ "$(grep '^@import' "$CSS")" = "@import \"$LT/Ad-Light/gtk-4.0/gtk.css\";" ] || fail "a command that stops halfway must leave the import on its theme: $(cat "$CSS")"
la_fresh; mkdir -p "$LA/home/.config/gtk-4.0"; la_gtk Ad-Both; la cm_apply_libadwaita on >/dev/null 2>&1
printf '%s\n' "$B" >> "$CSS"
rc=0; la 'cm_libadwaita_hold true' >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "a held command that succeeds and a refresh that fails must return 1, not $rc"
pass 'a pack or a look writes the libadwaita import once, for the theme and the scheme it ends on, with no warning for the pair in between'

# the command line: the three words, anything else is an error, the help lists it, and it counts as a look change
if env HOME="$LA/home" CM_HOME="$LA/state" CM_LANG_OVERRIDE=en PATH="$LA/bin:$PATH" DCONF_DB="$LA/db" bash "$SCRIPT" theme libadwaita bogus >"$TMP/o" 2>"$TMP/e"; then fail 'theme libadwaita bogus must fail'; fi
grep -q "Unrecognized option for 'theme': libadwaita bogus" "$TMP/e" || fail "an unknown word must be named: $(cat "$TMP/e")"
env HOME="$LA/home" CM_HOME="$LA/state" CM_LANG_OVERRIDE=en PATH="$LA/bin:$PATH" DCONF_DB="$LA/db" bash "$SCRIPT" theme libadwaita >"$TMP/o" 2>&1 \
    || fail 'theme libadwaita with no word is status and must succeed'
grep -q 'libadwaita' "$TMP/o" || fail 'theme libadwaita with no word must print the status'
for lang in en es; do
    helptext="$(env HOME="$LA/home" CM_HOME="$LA/state" CM_LANG_OVERRIDE=$lang PATH="$LA/bin:$PATH" DCONF_DB="$LA/db" bash "$SCRIPT" --help 2>&1)"
    grep -q 'theme libadwaita <on|off|status>' <<< "$helptext" || fail "the help must list theme libadwaita ($lang)"
done
la 'cm_changes_look theme libadwaita on' || fail 'libadwaita on changes the look: the original must be saved first'
la 'cm_changes_look theme libadwaita off' || fail 'libadwaita off changes the look: the original must be saved first'
must_fail la 'cm_changes_look theme libadwaita status'
must_fail la 'cm_changes_look theme libadwaita'
pass 'theme libadwaita takes on, off and status, names anything else, is in both helps and saves the original look first'

# --- the Advanced tab's box «Que usen el estilo gtk-4.0 del tema GTK» (the GUI of 12.5) --------------------------------
# The box shows what is in force (an import that points at a file that exists) and Apply acts only on a change of it, so
# Apply pressed untouched writes nothing. The writer is the same cm_apply_libadwaita; checked here are the decision, the
# form that carries the box and what the user is told.
cat > "$LA/stubs.sh" <<'STUBS'
cm_backup_current() { return 0; }
cm_reload_cinnamon() { :; }
cm_apply_hotcorners() { :; }
yad() { :; }
cm_notify_applied() { printf '%s\n' "$@" > notice; }
STUBS
cat > "$LA/rec.sh" <<'REC'
cm_apply_libadwaita() { printf '%s\n' "$1" >> calls; }
REC
# box_state <none|on|stale>: the block as the form finds it (stale: the imported theme has been removed since)
box_state() {
    la_fresh; la_gtk Ad-Both; la_scheme default; rm -f "$LA/calls" "$LA/notice"
    [ "$1" = none ] || la cm_apply_libadwaita on >/dev/null 2>&1 || fail "box_state $1: on failed"
    [ "$1" != stale ] || mv "$LT/Ad-Both" "$LT/Ad-Both.gone"
}
box_end() { [ ! -e "$LT/Ad-Both.gone" ] || mv "$LT/Ad-Both.gone" "$LT/Ad-Both"; }
# box_apply <value of the box> [rec]: the Apply button of the tab; rec records the call instead of making it
box_apply() {
    local pre=". ./stubs.sh;"
    [ "${2:-}" != rec ] || pre+=" . ./rec.sh;"
    la "$pre cm_ui_apply_advanced_apply '' '' '' '' '' '$1'"
}
# expect_calls <state> <value of the box> <the calls the button makes>
expect_calls() {
    local got=""
    box_state "$1"
    box_apply "$2" rec >/dev/null 2>&1 || { box_end; fail "Apply advanced failed (state $1, box '$2')"; }
    box_end
    [ ! -e "$LA/calls" ] || got="$(tr '\n' ' ' < "$LA/calls")"
    [ "${got% }" = "$3" ] || fail "state $1, box '$2': expected the calls '$3', got '${got% }'"
}
expect_calls none TRUE on
expect_calls none FALSE ''
expect_calls none '' ''
expect_calls none maybe ''
expect_calls on FALSE off
expect_calls on TRUE ''
expect_calls on '' ''
expect_calls stale TRUE on
expect_calls stale FALSE ''
pass 'Apply advanced calls libadwaita on or off only when the box differs from what is in force; an import to a removed theme counts as off'

# for real: checking the box writes the import of the active theme and the notice names it; unchecking removes only it
box_state none
box_apply TRUE >/dev/null 2>"$TMP/e" || fail "Apply advanced with the box checked failed: $(cat "$TMP/e")"
import_is gtk.css || fail "the box must import the stylesheet of the active theme: $(cat "$CSS" 2>/dev/null)"
grep -qxF "libadwaita style: the GTK theme's gtk-4.0" "$LA/notice" || fail "the notice must say what was applied: $(cat "$LA/notice")"
must_fail grep -q '⚠' "$LA/notice"
sum_before="$(la_sum)"; rm -f "$LA/writes"
la "$count_writes . ./stubs.sh; cm_ui_apply_advanced_apply '' '' '' '' '' TRUE" >/dev/null 2>&1 || fail 'Apply advanced with the box as found failed'
[ "$(la_sum)" = "$sum_before" ] && [ ! -e "$LA/writes" ] || fail 'Apply advanced with the box as found must write nothing'
must_fail grep -q 'libadwaita' "$LA/notice"
la "$ACCENT_CALL" >/dev/null 2>&1
box_apply FALSE >/dev/null 2>"$TMP/e" || fail "Apply advanced with the box unchecked failed: $(cat "$TMP/e")"
[ "$(la_imports)" -eq 0 ] && [ "$(grep -c '^@define-color' "$CSS")" -eq 5 ] || fail "unchecking must remove the import and keep the accent: $(cat "$CSS")"
grep -qxF "libadwaita style: libadwaita's own" "$LA/notice" || fail "the notice must say what was applied: $(cat "$LA/notice")"
pass 'the box checked imports the active theme and the notice says so; as found, nothing is written; unchecked it removes only the import'

# the same in Spanish (both lines of the notice), and an uncheck whose write fails: the button fails and says why
box_state none
LA_LANG=es box_apply TRUE >/dev/null 2>"$TMP/e" || fail "Apply advanced with the box checked failed (Spanish): $(cat "$TMP/e")"
grep -qxF 'Estilo libadwaita: el gtk-4.0 del tema GTK' "$LA/notice" || fail "the Spanish notice must say what was applied: $(cat "$LA/notice")"
LA_LANG=es box_apply FALSE >/dev/null 2>"$TMP/e" || fail "Apply advanced with the box unchecked failed (Spanish): $(cat "$TMP/e")"
grep -qxF 'Estilo libadwaita: el propio de libadwaita' "$LA/notice" || fail "the Spanish notice must say what was applied: $(cat "$LA/notice")"
box_state on
rc=0; la ". ./stubs.sh; cm_gtk4_block_set() { printf 'ERROR: disk full\\n' >&2; return 1; }; cm_ui_apply_advanced_apply '' '' '' '' '' FALSE" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'an unchecked box whose write fails must fail Apply advanced'
grep -qxF '⚠ libadwaita style was not applied — disk full' "$LA/notice" || fail "the notice must give the reason of the failed write: $(cat "$LA/notice")"
import_is gtk.css || fail 'a failed write must leave the import as it was'
pass 'the notice of the box in Spanish, both ways; an unchecked box whose write fails fails Apply advanced and says why'

# when it cannot: the button fails, nothing is written and the notice names the reason, in both languages
box_state none; la_gtk Ad-None
rc=0; box_apply TRUE >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'a box that cannot be applied must fail Apply advanced'
[ ! -e "$LA/home/.config/gtk-4.0" ] || fail 'a refused box wrote ~/.config/gtk-4.0'
grep -qxF '⚠ libadwaita style was not applied — the theme Ad-None is not installed or has no gtk-4.0/gtk.css; nothing was changed.' "$LA/notice" \
    || fail "the notice must give the reason: $(cat "$LA/notice")"
rc=0; LA_LANG=es box_apply TRUE >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'a box that cannot be applied must fail Apply advanced (Spanish)'
grep -qxF '⚠ Estilo libadwaita no se pudo aplicar — el tema Ad-None no está instalado o no tiene gtk-4.0/gtk.css; no se ha cambiado nada.' "$LA/notice" \
    || fail "the Spanish notice must give the reason: $(cat "$LA/notice")"
pass 'a box that cannot be applied fails Apply advanced, writes nothing and gives the reason in English and Spanish'

# a warning of a box that did apply is shown too (it was dropped: cm_report kept the output of a command only if it failed)
box_state none; la_gtk Ad-Light; la_scheme prefer-dark
box_apply TRUE >/dev/null 2>"$TMP/e" || fail "Apply advanced on the dark scheme failed: $(cat "$TMP/e")"
grep -qxF "libadwaita style: the GTK theme's gtk-4.0" "$LA/notice" || fail 'the box applied: its line must stay in the notice'
grep -qxF '⚠ the theme Ad-Light has no gtk-4.0/gtk-dark.css: its gtk.css is imported on the dark scheme; if that style is light, the colors mix.' "$LA/notice" \
    || fail "the warning of a dark scheme with a light-only theme must reach the notice: $(cat "$LA/notice")"
box_state none; la_gtk Ad-Light
box_apply TRUE >/dev/null 2>&1 || fail 'Apply advanced on the light scheme failed'
must_fail grep -q '⚠' "$LA/notice"
box_state none; la_gtk Ad-Light; la_scheme prefer-dark
LA_LANG=es box_apply TRUE >/dev/null 2>&1 || fail 'Apply advanced on the dark scheme failed (Spanish)'
grep -qxF '⚠ el tema Ad-Light no trae gtk-4.0/gtk-dark.css: se importa su gtk.css con el esquema oscuro; si ese estilo es claro, los colores se mezclan.' "$LA/notice" \
    || fail "the Spanish warning must reach the notice: $(cat "$LA/notice")"
pass 'the warning of a box that applied (a light-only theme on the dark scheme) reaches the notice; with the light scheme there is none'

# the form: the box is the tenth field, between its heading and its note, it starts as what is in force, and the button passes it
adv_fields() {
    la 'rm -f adv.flag adv.args; cm_tab_alive() { [ ! -e adv.flag ] || return 1; : > adv.flag; }
        yad() { [ "${1:-}" = --version ] || printf "%s\0" "$@" > adv.args; }; cm_tab_advanced K 4' >/dev/null 2>&1 || return 1
    local -a a; local i n=0
    mapfile -d '' -t a < "$LA/adv.args"
    for ((i = 0; i < ${#a[@]}; i++)); do
        case "${a[i]}" in --field=*) n=$((n + 1)); printf '%s\t%s\t%s\n' "$n" "${a[i]#--field=}" "${a[i + 1]}" ;; esac
    done
}
field() { sed -n "${1}p" | cut -f2,3 | tr '\t' '|'; }
box_state none
[ "$(adv_fields | wc -l)" -eq 12 ] || fail "the Advanced form must have 12 fields, not $(adv_fields | wc -l)"
adv_fields | field 9 | grep -q ':LBL|$' || fail "field 9 must be the heading of the box: $(adv_fields | field 9)"
[ "$(adv_fields | field 10)" = "Let them use the GTK theme's gtk-4.0 style:CHK|FALSE" ] || fail "field 10 must be the box, unchecked with no import: $(adv_fields | field 10)"
adv_fields | field 11 | grep -q ':LBL|$' || fail "field 11 must be the note of the box: $(adv_fields | field 11)"
adv_fields | field 12 | grep -q ' %2 %3 %4 %5 %7 %10$' || fail "the button must pass the fields 2 3 4 5 7 and the box (10): $(adv_fields | field 12)"
[ "$(LA_LANG=es adv_fields | field 10)" = 'Que usen el estilo gtk-4.0 del tema GTK:CHK|FALSE' ] || fail "field 10 in Spanish: $(LA_LANG=es adv_fields | field 10)"
box_state on
[ "$(adv_fields | field 10)" = "Let them use the GTK theme's gtk-4.0 style:CHK|TRUE" ] || fail "the box must start checked while the import is in force: $(adv_fields | field 10)"
box_end
box_state stale
[ "$(adv_fields | field 10)" = "Let them use the GTK theme's gtk-4.0 style:CHK|FALSE" ] || fail "an import to a removed theme must leave the box unchecked: $(adv_fields | field 10)"
box_end
pass 'the Advanced form carries the box as its tenth field, starts as what is in force, and its button passes it'

# --- names with an apostrophe ------------------------------------------------------------------------------------
# `gsettings get` prints Bob's Theme as "Bob's Theme", in double quotes; reading it with `tr -d "'"` gave "Bobs Theme".
# Every reader of a string key goes through cm_gs_string, which decodes the GVariant text.
export APOS="Bob's Theme" ACUR="Bob's Cursors"
la_fresh; la_scheme default; la_theme "$LT/$APOS"
printf '@define-color accent_bg_color #26a269;\n' > "$LT/$APOS/gtk-4.0/gtk.css"
la 'cm_apply_gtk_theme "$APOS"' >"$TMP/o" 2>"$TMP/e" || fail "applying a theme with an apostrophe failed: $(cat \"$TMP/e\")"
[ "$(awk -F'\t' '$1 == "/org/cinnamon/desktop/interface/gtk-theme" { print $2 }' "$LA/db")" = "\"$APOS\"" ] || fail "the double must hold the name the way GLib prints it (control): $(grep gtk-theme "$LA/db")"
[ "$(la cm_current_gtk_theme)" = "$APOS" ] || fail "the active theme must read back as $APOS: $(la cm_current_gtk_theme)"
la cm_apply_libadwaita on >"$TMP/o" 2>"$TMP/e" || fail "libadwaita on with an apostrophe in the theme name failed: $(cat "$TMP/e")"
[ "$(grep '^@import' "$CSS")" = "@import \"$LT/$APOS/gtk-4.0/gtk.css\";" ] || fail "the import must name the theme as it is: $(cat "$CSS")"
[ "$(la cm_apply_libadwaita status)" = "libadwaita imports: $LT/$APOS/gtk-4.0/gtk.css" ] || fail 'status must print the theme with its apostrophe'
pass 'a GTK theme with an apostrophe is read back whole, and libadwaita imports it'

# a preset saves the name as it is and loads it again
la 'cm_save_preset apos' >"$TMP/o" 2>"$TMP/e" || fail "saving a preset with an apostrophe in the theme failed: $(cat "$TMP/e")"
grep -qxF "GTK_THEME=\"$APOS\"" "$LA/state/presets/apos.conf" || fail "the preset must hold the theme name as it is: $(grep GTK_THEME "$LA/state/presets/apos.conf")"
la_gtk Ad-Both
printf '%s\n' "GTK_THEME=\"$APOS\"" > "$LA/state/presets/apos-min.conf"
la 'cm_load_preset apos-min' >"$TMP/o" 2>"$TMP/e" || fail "loading a preset with an apostrophe failed: $(cat "$TMP/o") $(cat "$TMP/e")"
[ "$(la cm_current_gtk_theme)" = "$APOS" ] || fail 'the preset must put the theme with the apostrophe back'
pass 'a preset keeps a theme name with an apostrophe through save and load'

# the cursor refresh puts the cursor theme back by the name it read: a wrong name reached the desktop and ~/.Xresources
cm_double_db_set "$LA/db" /org/cinnamon/desktop/interface/cursor-theme "\"$ACUR\""
cm_double_db_set "$LA/db" /org/cinnamon/desktop/interface/cursor-size 24
rm -f "$LA/home/.Xresources"
la 'cm_refresh_cursor 1' >"$TMP/o" 2>"$TMP/e" || fail "the cursor refresh failed: $(cat "$TMP/e")"
for key in /org/cinnamon/desktop/interface/cursor-theme /org/gnome/desktop/interface/cursor-theme; do
    [ "$(awk -F'\t' -v k="$key" '$1 == k { print $2 }' "$LA/db")" = "\"$ACUR\"" ] || fail "the refresh changed the cursor theme at $key: $(grep "$key" "$LA/db")"
done
grep -qxF "Xcursor.theme: $ACUR" "$LA/home/.Xresources" || fail ".Xresources must name the cursor theme as it is: $(cat "$LA/home/.Xresources")"
pass 'the cursor refresh keeps a cursor theme with an apostrophe, on the desktop and in ~/.Xresources'

# cm_gs_string against the real gsettings and GLib's own printer (private schema, file backend); skipped without them
if command -v gsettings >/dev/null 2>&1 && command -v glib-compile-schemas >/dev/null 2>&1; then
    GS="$TMP/gs"; mkdir -p "$GS/schemas" "$GS/config"
    cat > "$GS/schemas/org.colormint.test.gschema.xml" <<'XML'
<schemalist>
  <schema id="org.colormint.test" path="/org/colormint/test/">
    <key name="name" type="s"><default>'Default'</default></key>
  </schema>
</schemalist>
XML
    glib-compile-schemas "$GS/schemas" || fail 'could not compile the private schema'
    real_gs() { env GSETTINGS_SCHEMA_DIR="$GS/schemas" GSETTINGS_BACKEND=keyfile XDG_CONFIG_HOME="$GS/config" "$@"; }
    gs_read() { real_gs bash -c 'source "$1"; cm_gs_string org.colormint.test name' bash "$BODY"; }
    real_gs gsettings set org.colormint.test name "$APOS"
    [ "$(real_gs gsettings get org.colormint.test name)" = "\"$APOS\"" ] || fail "this GLib no longer prints an apostrophe in double quotes: re-measure the apostrophe handling (got $(real_gs gsettings get org.colormint.test name))"
    for v in 'Green' "$APOS" 'Q"uote' "a'b\"c" 'back\slash' 'tail\' 'a\\b' "it's 'x'" 'Ñandú (x)' 'two  spaces' ''; do
        real_gs gsettings set org.colormint.test name "$v"
        [ "$(gs_read)" = "$v" ] || fail "cm_gs_string read [$(gs_read)] for [$v], which GLib printed as $(real_gs gsettings get org.colormint.test name)"
        # the double the other suites rely on prints the same text, so what they check is what GLib does
        [ "$(env PATH="$LA/bin:$PATH" DCONF_DB="$LA/db" bash -c 'gsettings set org.colormint.test name "$1" && gsettings get org.colormint.test name' bash "$v")" = "$(real_gs gsettings get org.colormint.test name)" ] \
            || fail "the gsettings double prints [$v] differently from GLib: $(real_gs gsettings get org.colormint.test name)"
    done
    must_print_nothing real_gs bash -c 'source "$1"; cm_gs_string org.colormint.test missing' bash "$BODY"
    if real_gs bash -c 'source "$1"; cm_gs_string org.colormint.test missing' bash "$BODY" >/dev/null 2>&1; then fail 'an unreadable key must fail, as the pipelines it replaced did'; fi
    pass 'cm_gs_string decodes what the real gsettings prints (apostrophes, double quotes, backslashes, accents, empty), and the double prints the same'
else
    printf 'SKIP: cm_gs_string against the real gsettings needs gsettings and glib-compile-schemas\n'
fi
