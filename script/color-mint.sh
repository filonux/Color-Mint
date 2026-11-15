#!/usr/bin/env bash
# MENU: Color Mint
# DESCRIPTION: Advanced visual customization for Linux Mint Cinnamon
# CONFIRM: false
# TERMINAL: false
# SUDO: false
# ICON: ../assets/icon.png
# ==============================================================================
#  Color Mint — advanced visual customization for Linux Mint 22.3 Cinnamon
#  Author: Filonux
#
#  Copyright (C) 2026 Filonux
#  License: GNU General Public License v3 (GPLv3). See LICENSE.txt.
#
#  Single-file program. It runs without sudo and installs a package only when you
#  agree: the GUI mode offers to install missing dependencies, and `theme install`
#  installs one package of the verified theme list.
#
#  Usage:
#    color-mint.sh            open the graphical interface (same as "gui")
#    color-mint.sh --help     list every command-line option
#
#  Data, backups, presets and logs live in ~/.local/share/color-mint.
#
#  Maintainer notes (YAD/Cinnamon quirks behind non-obvious code):
#   - Cinnamon reads its own copy of gtk-theme, icon-theme, cursor-theme,
#     cursor-size, font-name and text-scaling-factor under
#     org.cinnamon.desktop.interface, not org.gnome.desktop.interface (that
#     schema exists but is not watched). monospace-font-name is the exception:
#     it only exists under org.gnome.desktop.interface. button-layout, theme
#     and titlebar-font live under org.cinnamon.desktop.wm.preferences.
#   - The light/dark preference that libadwaita apps follow is color-scheme in org.x.apps.portal
#     (XApp), not in an interface schema; without that schema there is nothing to write.
#   - The default gnome-terminal profile is org.gnome.Terminal.ProfilesList,
#     key "default"; org.gnome.terminal.legacy.profile-manager does not exist.
#   - A yad :NUM field takes its range as "value!min..max!step"; :SCL ignores
#     any range and always spans 0..100.
#   - Changing cursor-size does not always re-emit XSETTINGS live (a known
#     cinnamon-settings-daemon limitation). cm_refresh_cursor applies several
#     best-effort mitigations; logging out always applies the new size.
#   - Each GUI tab is an independent "yad --plug" process embedded in the main
#     "yad --notebook --key" (the key must be an integer; $$ is used). Tabs run
#     in an endless loop so they can redraw after every apply.
#   - YAD drops the --button bar of a dialog embedded with --plug, so each tab
#     defines its buttons as :FBTN form fields instead.
#   - Each FBTN runs this script as "__apply <mode> ..." with the other fields
#     passed through %N (YAD substitutes each one already quoted as a single
#     argument; see cm_fbtn_apply). A plugged form never emits its output on
#     SIGUSR1 (confirmed with YAD 0.40.0), so collecting results on close
#     cannot work. YAD also splits an FBTN command into words and runs the
#     first one literally, which is why it is always wrapped in bash -c '...'.
#   - "Name!Tooltip:TYPE" does not work in YAD 0.40.0 (Mint 22.3): the text
#     after "!" is shown as part of the label. Tabs use a short --text= and
#     :LBL fields (empty, or bold group headings) instead of tooltips.
# ==============================================================================

# Oldest supported Bash: 4.4. This runs first and uses plain POSIX syntax, so an older shell stops with a readable
# message instead of "unbound variable" (empty arrays under set -u) or "bad substitution" halfway through a task.
case "${BASH_VERSION:-}" in
    4.[4-9]*|4.[1-9][0-9]*|[5-9].*|[1-9][0-9].*) ;;
    *)
        case "${CM_LANG_OVERRIDE:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}" in
            es|es_*|es-*)
                printf 'Color Mint necesita Bash 4.4 o superior (versión detectada: %s).\n' "${BASH_VERSION:-ninguna}" >&2 ;;
            *)
                printf 'Color Mint needs Bash 4.4 or newer (detected: %s).\n' "${BASH_VERSION:-none}" >&2 ;;
        esac
        exit 1
        ;;
esac

set -uo pipefail

CM_VERSION="3.1.0"

# The GUI writes gtk.css, fonts.conf and .Xresources, so it refuses a desktop that is not Cinnamon.
# An unset XDG_CURRENT_DESKTOP is not a refusal: a bare session may still be Cinnamon.
cm_desktop_refused() {
    case "${XDG_CURRENT_DESKTOP:-}" in
        ''|*[Cc]innamon*) return 1 ;;
    esac
}

# Help, uninstall and a refused desktop leave no trace of their own: no state folder, no persisted language.
CM_READ_ONLY_CLI=0
case "${1:-gui}" in
    -h|--help|uninstall) CM_READ_ONLY_CLI=1 ;;
    --version)
        printf 'Color Mint %s\n' "$CM_VERSION"
        exit 0
        ;;
    gui) if cm_desktop_refused; then CM_READ_ONLY_CLI=1; fi ;;
esac

# ============================================================================
# Paths and general configuration
# ============================================================================
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

# Ensure the script is executable so both "bash script.sh" and a double click
# in Nemo work when __tab re-invokes it. Silent on read-only filesystems.
[ -f "$SCRIPT_PATH" ] && [ ! -x "$SCRIPT_PATH" ] && chmod +x "$SCRIPT_PATH" 2>/dev/null

CM_HOME="${CM_HOME:-$HOME/.local/share/color-mint}"
CM_BACKUP_DIR="$CM_HOME/backups"
CM_PRESETS_DIR="$CM_HOME/presets"
CM_LOG_DIR="$CM_HOME/logs"
CM_LOG_FILE="$CM_LOG_DIR/color-mint.log"
CM_ICON_FILE="$CM_HOME/icon.png"
CM_STATE_FILE="$CM_HOME/state.conf"
CM_ORIGINAL_DIR="$CM_HOME/original"
CM_INSTALLED_FILE="$CM_HOME/installed.txt"
CM_LOCK_FILE="$CM_HOME/.lock"
CM_THEME_PREFIX="CM"
CM_AUTHOR="Filonux"
CM_LOCK_FD=""
CM_LOCK_DEPTH=0

if [ "$CM_READ_ONLY_CLI" -eq 0 ]; then
    mkdir -p "$CM_BACKUP_DIR" "$CM_PRESETS_DIR" "$CM_LOG_DIR"
fi

# ============================================================================
# utils — locking, atomic writes, logging and helpers
# ============================================================================
# The lock nests: a function that holds it may call another that takes and releases it (a look writer inside a restore)
# without freeing the outer hold. Only the outermost cm_unlock releases.
cm_lock() {
    if [ -n "${CM_LOCK_FD:-}" ]; then
        CM_LOCK_DEPTH=$((CM_LOCK_DEPTH + 1))
        return 0
    fi
    command -v flock >/dev/null 2>&1 || return 1
    [ ! -L "$CM_LOCK_FILE" ] || return 1
    exec 9>>"$CM_LOCK_FILE" || return 1
    if ! flock -x 9 2>/dev/null; then
        exec 9>&- || true
        return 1
    fi
    CM_LOCK_FD=9
    CM_LOCK_DEPTH=1
}

cm_unlock() {
    [ -n "${CM_LOCK_FD:-}" ] || return 0
    CM_LOCK_DEPTH=$((CM_LOCK_DEPTH - 1))
    [ "$CM_LOCK_DEPTH" -le 0 ] || return 0
    flock -u 9 2>/dev/null || true
    exec 9>&- || true
    CM_LOCK_FD=""
    CM_LOCK_DEPTH=0
}

# Read stdin to a same-directory temporary file, set its mode, then rename it.
cm_atomic_write() {
    local target="$1" mode="${2:-}" dir base tmp old_mode status=0
    [ -n "$target" ] || return 1
    dir="${target%/*}"; [ "$dir" = "$target" ] && dir="."
    base="${target##*/}"
    [ -d "$dir" ] || mkdir -p -- "$dir" 2>/dev/null || return 1
    old_mode=""
    [ -e "$target" ] && old_mode=$(stat -L -c '%a' -- "$target" 2>/dev/null || true)
    tmp=$(mktemp "$dir/.${base}.tmp.XXXXXX") || return 1
    if ! cat > "$tmp"; then
        rm -f -- "$tmp" 2>/dev/null || true
        return 1
    fi
    if [ -n "$mode" ]; then
        chmod "$mode" "$tmp" 2>/dev/null || status=$?
    elif [ -n "$old_mode" ]; then
        chmod "$old_mode" "$tmp" 2>/dev/null || status=$?
    else
        chmod 0644 "$tmp" 2>/dev/null || status=$?
    fi
    if [ "$status" -ne 0 ]; then
        rm -f -- "$tmp" 2>/dev/null || true
        return "$status"
    fi
    if ! mv -f -- "$tmp" "$target" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null || true
        return 1
    fi
}

cm_atomic_write_locked() {
    cm_lock || return 1
    cm_atomic_write "$@"
    local status=$?
    cm_unlock
    return "$status"
}

# Apply sed output through the same atomic replacement path.
cm_atomic_sed() {
    local target="$1"; shift
    local dir base tmp old_mode status=0
    [ -f "$target" ] || return 1
    dir="${target%/*}"; [ "$dir" = "$target" ] && dir="."
    base="${target##*/}"
    old_mode=$(stat -L -c '%a' -- "$target" 2>/dev/null || true)
    tmp=$(mktemp "$dir/.${base}.tmp.XXXXXX") || return 1
    if ! sed "$@" "$target" > "$tmp" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null || true
        return 1
    fi
    if [ -n "$old_mode" ] && ! chmod "$old_mode" "$tmp" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null || true
        return 1
    fi
    if ! mv -f -- "$tmp" "$target" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null || true
        return 1
    fi
}

cm_atomic_sed_locked() {
    cm_lock || return 1
    cm_atomic_sed "$@"
    local status=$?
    cm_unlock
    return "$status"
}

# Copy a directory into a hidden sibling and publish it with one directory rename.
# Return 0 when the destination already exists so callers can safely reuse it.
cm_atomic_copy_dir_if_missing() {
    local source="$1" target="$2" parent base stage
    [ -d "$source" ] && [ ! -L "$source" ] || return 1
    parent="${target%/*}"; [ "$parent" = "$target" ] && parent="."
    base="${target##*/}"
    [ -d "$parent" ] && [ ! -L "$parent" ] || mkdir -p -- "$parent" 2>/dev/null || return 1

    cm_lock || return 1
    if [ -e "$target" ] || [ -L "$target" ]; then
        cm_unlock
        return 0
    fi

    stage=$(mktemp -d "$parent/.${base}.tmp.XXXXXX") || { cm_unlock; return 1; }
    if ! cp -a -- "$source/." "$stage/" 2>/dev/null; then
        rm -rf -- "$stage" 2>/dev/null || true
        cm_unlock
        return 1
    fi
    if ! mv -T -- "$stage" "$target" 2>/dev/null; then
        rm -rf -- "$stage" 2>/dev/null || true
        cm_unlock
        return 1
    fi
    cm_unlock
}

# Install a complete directory atomically. Return 2 when the destination exists.
cm_atomic_install_dir() {
    local source="$1" target="$2" parent stage
    [ -d "$source" ] && [ ! -L "$source" ] || return 1
    parent="${target%/*}"; [ "$parent" = "$target" ] && parent="."
    [ -d "$parent" ] && [ ! -L "$parent" ] || mkdir -p -- "$parent" 2>/dev/null || return 1

    cm_lock || return 1
    if [ -e "$target" ] || [ -L "$target" ]; then
        cm_unlock
        return 2
    fi

    stage=$(mktemp -d "$parent/.color-mint-import.XXXXXX") || { cm_unlock; return 1; }
    if ! cp -a -- "$source/." "$stage/" 2>/dev/null; then
        rm -rf -- "$stage" 2>/dev/null || true
        cm_unlock
        return 1
    fi
    if ! mv -T -- "$stage" "$target" 2>/dev/null; then
        rm -rf -- "$stage" 2>/dev/null || true
        cm_unlock
        return 1
    fi
    cm_unlock
}

# cm_marked_block_ok <file> <begin> <end>: 0 when the file has no block or every begin line is closed by an end line.
# An unclosed block makes the strip below drop everything to the end of the file, user lines included.
cm_marked_block_ok() {
    [ -f "$1" ] || return 0
    awk -v b="$2" -v e="$3" '
        $0 == b { if (open) bad = 1; open = 1; next }
        $0 == e { open = 0; next }
        END { exit (open || bad) ? 1 : 0 }' "$1"
}

# Strip one managed block, append content, and commit the complete file atomically.
# It refuses (and leaves the file as it is) when a block is not closed.
cm_atomic_marked_replace() {
    local file="$1" begin="$2" end="$3" content="${4:-}"
    local mode="0644" dir base tmp
    [ -f "$file" ] && mode=$(stat -L -c '%a' -- "$file" 2>/dev/null || echo 0644)
    [ -f "$file" ] || [ -n "$content" ] || return 0
    dir="${file%/*}"; [ "$dir" = "$file" ] && dir="."
    base="${file##*/}"
    cm_lock || return 1
    if ! cm_marked_block_ok "$file" "$begin" "$end"; then
        printf '%s\n' "$(printf "$(cm_t marked_block_open)" "$file")" >&2
        cm_unlock
        return 1
    fi
    tmp=$(mktemp "$dir/.${base}.build.XXXXXX") || { cm_unlock; return 1; }
    if [ -f "$file" ] && ! awk -v b="$begin" -v e="$end" '
        $0==b {skip=1; next}
        $0==e {skip=0; next}
        skip!=1 {print}
    ' "$file" > "$tmp" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null || true
        cm_unlock
        return 1
    fi
    if [ -n "$content" ] && ! printf '%s\n' "$content" >> "$tmp"; then
        rm -f -- "$tmp" 2>/dev/null || true
        cm_unlock
        return 1
    fi
    if ! cm_atomic_write "$file" "$mode" < "$tmp"; then
        rm -f -- "$tmp" 2>/dev/null || true
        cm_unlock
        return 1
    fi
    rm -f -- "$tmp" 2>/dev/null || true
    cm_unlock
    return 0
}

# Look files (~/.Xresources, gtk.css, fonts.conf and the environment.d file) are the user's, and dotfile managers keep
# them as links. cm_atomic_write and cm_atomic_marked_replace replace whatever is at the path, which is right for Color
# Mint's own files and its theme copies; the cm_look_* writers below write to the file a link points to and leave the
# link where it is.

# cm_resolve_look <path> [d]: the file (with d, the folder) a write to <path> has to replace, silently. A link must
# lead to one that can be written, in a folder that can be written (the replacement is made beside it); a link that
# leads nowhere, to the other kind, in a loop or to something that cannot be written fails, so it is never followed
# into creating what the user did not name.
cm_resolve_look() {
    local path="$1" kind="${2:-f}" real=""
    if [ ! -L "$path" ]; then
        printf '%s\n' "$path"
        return 0
    fi
    real=$(readlink -f -- "$path" 2>/dev/null) || real=""
    [ -n "$real" ] || return 1
    if [ "$kind" = d ]; then
        [ -d "$real" ] || return 1
    else
        [ -f "$real" ] || return 1
    fi
    if [ ! -w "$real" ] || [ ! -w "${real%/*}" ]; then
        return 1
    fi
    printf '%s\n' "$real"
}

# cm_real_file <path> [d]: cm_resolve_look, naming the link on stderr when it is refused.
cm_real_file() {
    local real
    if ! real=$(cm_resolve_look "$@"); then
        printf '%s\n' "$(printf "$(cm_t link_refused)" "$1")" >&2
        return 1
    fi
    printf '%s\n' "$real"
}

# cm_real_dir <path>: cm_real_file for a folder.
cm_real_dir() {
    cm_real_file "$1" d
}

# cm_look_targets_ok <path>...: succeeds when every path can be written, naming each one that cannot. A command that
# writes several look files calls it first, so a refusal at the last one does not leave the others already changed.
cm_look_targets_ok() {
    local path status=0
    for path in "$@"; do
        cm_real_file "$path" >/dev/null || status=1
    done
    return "$status"
}

# cm_look_write <path> [mode], content on stdin: cm_atomic_write for a look file.
cm_look_write() {
    local real
    real=$(cm_real_file "$1") || return 1
    shift
    cm_atomic_write "$real" "$@"
}

cm_look_write_locked() {
    cm_lock || return 1
    cm_look_write "$@"
    local status=$?
    cm_unlock
    return "$status"
}

# cm_look_marked_replace <file> <begin> <end> [content]: cm_atomic_marked_replace for a look file.
cm_look_marked_replace() {
    local real
    real=$(cm_real_file "$1") || return 1
    shift
    cm_atomic_marked_replace "$real" "$@"
}

cm_log() {
    local level="$1"; shift
    local msg="$*" line tmp
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $msg"
    if cm_lock; then
        tmp=$(mktemp "${CM_LOG_FILE%/*}/.${CM_LOG_FILE##*/}.build.XXXXXX") || { cm_unlock; return 0; }
        if [ -f "$CM_LOG_FILE" ] && ! cat "$CM_LOG_FILE" > "$tmp"; then
            rm -f -- "$tmp" 2>/dev/null || true
            cm_unlock
            return 0
        fi
        if ! printf '%s\n' "$line" >> "$tmp" || ! cm_atomic_write "$CM_LOG_FILE" < "$tmp"; then
            rm -f -- "$tmp" 2>/dev/null || true
            cm_unlock
            return 0
        fi
        rm -f -- "$tmp" 2>/dev/null || true
        cm_unlock
    fi
    return 0
}

# The program icon travels inside this script (base64 comment block at the end of the file), so a
# single copied file is still complete. It is written to the state directory for yad windows and
# notifications, and rewritten only when its content differs.
cm_icon_install() {
    local data
    [ -r "$SCRIPT_PATH" ] || return 1
    data=$(sed -n '/^# ---- BEGIN EMBEDDED ICON/,/^# ---- END EMBEDDED ICON/{//!p;}' "$SCRIPT_PATH" | sed 's/^# //')
    [ -n "$data" ] || return 1
    mkdir -p "$CM_HOME" || return 1
    if [ -f "$CM_ICON_FILE" ] && printf '%s\n' "$data" | base64 -d 2>/dev/null | cmp -s - "$CM_ICON_FILE"; then
        return 0
    fi
    printf '%s\n' "$data" | base64 -d | cm_atomic_write "$CM_ICON_FILE" 644
}

# Path of the installed icon, or the closest theme icon when it is not there.
cm_icon_path() {
    if [ -f "$CM_ICON_FILE" ]; then printf '%s' "$CM_ICON_FILE"; else printf '%s' 'preferences-desktop-theme'; fi
}

cm_notify() {
    local title="$1" body="$2" icon="${3:-preferences-desktop-theme}"
    [ "$icon" != "preferences-desktop-theme" ] || icon=$(cm_icon_path)
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -i "$icon" "$title" "$body" 2>/dev/null
    fi
    cm_log "INFO" "$title: $body"
}

# Escape & < > in dynamic text (preset/backup names, system error messages)
# before it goes into Pango markup: yad parses --text as markup by default.
_pango_escape() {
    local s="$1"
    # The replacement '&' must be written '\&'; unescaped, bash expands it to the
    # matched text (as sed does).
    s="${s//&/\&amp;}"
    s="${s//</\&lt;}"
    printf '%s' "${s//>/\&gt;}"
}

# cm_notify_applied <title> <summary> [line1] [line2] ...
# Desktop notifications are easy to miss, so also show a dialog the user must
# dismiss, with the details actually applied. If any item starts with "⚠"
# (added by cm_report on a real failure), the dialog switches to a warning
# icon, title and header color, and both end in "with warnings". A caller whose
# summary already says that it failed sets CM_NOTIFY_SUFFIX to the empty string
# for the call, and gets the warning without that tail.
cm_notify_applied() {
    local title="$1" summary="$2"; shift 2
    local -a items=("$@")
    local it has_warning=0
    for it in "${items[@]}"; do
        case "$it" in ⚠*) has_warning=1; break ;; esac
    done

    local head dlg_title icon suffix
    local -a dlg_type=(--info)
    if [ "$has_warning" -eq 1 ]; then
        suffix="${CM_NOTIFY_SUFFIX-$(cm_t warning_suffix)}"
        [ -z "$suffix" ] || suffix=" — $suffix"
        head="<span size='large' weight='bold' foreground='#bf616a'>⚠ $(_pango_escape "$summary")${suffix}</span>"
        dlg_title="⚠ ${title}${suffix}"
        icon="dialog-warning"
        dlg_type=(--warning)
    else
        head="<span size='large' weight='bold' foreground='#a3be8c'>✔ $(_pango_escape "$summary")</span>"
        dlg_title="$title"
        icon="preferences-desktop-theme"
    fi

    local body="$head"
    if [ ${#items[@]} -gt 0 ]; then
        body="${body}"$'\n\n'
        local esc
        for it in "${items[@]}"; do
            esc=$(_pango_escape "$it")
            case "$it" in
                ⚠*) body="${body}  <span foreground='#bf616a'>${esc}</span>"$'\n' ;;
                *)  body="${body}  ${esc}"$'\n' ;;
            esac
        done
    fi
    cm_notify "$title" "$summary" "$icon"
    if command -v yad >/dev/null 2>&1; then
        yad "${dlg_type[@]}" --image="$icon" --title="$dlg_title" \
            --text="$body" --width=420 --button="$(cm_t 'done'):0" 2>/dev/null
    fi
}

# cm_report <success-label> <cm_apply_* function> [args...]
# Run an apply function and append either its success label or a warning with
# its real error to the caller's "applied" array. Centralizes the
# capture-output-and-check-status pattern so no failure goes unreported.
cm_report() {
    local ok_label="$1"; shift
    local _m _clean _line
    if _m=$("$@" 2>&1); then
        applied+=("$ok_label")
        # A warning from a command that worked (a style that may mix palettes) is still shown.
        while IFS= read -r _line; do
            case "$_line" in
                "ADVERTENCIA: "*|"WARNING: "*) applied+=("⚠ ${_line#*: }") ;;
            esac
        done <<< "$_m"
        return 0
    else
        _clean="${_m#ERROR: }"; _clean="${_clean#ADVERTENCIA: }"; _clean="${_clean#WARNING: }"
        applied+=("⚠ ${ok_label%%:*} $(cm_t report_failed) — ${_clean}")
        return 1
    fi
}

# cm_gset <schema> <key> <value> — like "gsettings set", but checks the exit
# status and reports the error in the current language.
cm_gset() {
    local schema="$1" key="$2" out
    if ! out=$(gsettings set "$@" 2>&1); then
        cm_log "ERROR" "gsettings set ${schema} ${key} -> ${out}"
        printf '%s\n' "$(printf "$(cm_t gsettings_set_failed)" "${schema} ${key}" "${out:-$(cm_t unknown_failure)}")" >&2
        return 1
    fi
    return 0
}

# cm_gs_string <schema> <key>: the text of a string key. `gsettings get` prints a GVariant: 'text', or "text" when the
# text holds an apostrophe, with \" and \\ escaped (measured, GLib 2.80.0). `tr -d "'"` turned Bob's Theme into
# "Bobs Theme". Prints nothing and fails when the key cannot be read, as the pipelines it replaces did under pipefail.
cm_gs_string() {
    local raw q out=""
    raw=$(gsettings get "$1" "$2" 2>/dev/null) || return 1
    q=${raw:0:1}
    if [ "$q" = "'" ] || [ "$q" = '"' ]; then
        raw=${raw:1}
        raw=${raw%"$q"}
        while [[ "$raw" == *\\* ]]; do
            out+=${raw%%\\*}
            raw=${raw#*\\}
            case "${raw:0:1}" in
                \\|\'|\") out+=${raw:0:1}; raw=${raw:1} ;;
                *) out+=\\ ;;
            esac
        done
        raw=$out$raw
    fi
    printf '%s\n' "$raw"
}

# cm_dwrite <dconf-path> <gvariant-value> — like "dconf write", with the same
# exit-status check as cm_gset.
cm_dwrite() {
    local path="$1" value="$2" out
    if ! out=$(dconf write "$path" "$value" 2>&1); then
        cm_log "ERROR" "dconf write ${path} ${value} -> ${out}"
        printf '%s\n' "$(printf "$(cm_t dconf_write_failed)" "${path}" "${out:-$(cm_t unknown_failure)}")" >&2
        return 1
    fi
    return 0
}

cm_is_valid_hex() {
    [[ "$1" =~ ^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})$ ]]
}

# cm_int_in_range <value> <min> <max>: plain decimal digits within the range. The digit cap keeps
# `[ -lt ]` from failing on a number above 64 bits, which the former inline checks let through.
cm_int_in_range() {
    [[ "${1:-}" =~ ^[0-9]{1,9}$ ]] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

cm_is_valid_name() {
    local value="${1:-}"
    [ -n "$value" ] || return 1
    [[ "$value" != */* && "$value" != *"\\"* && "$value" != *..* ]] || return 1
    [[ "$value" != *[[:cntrl:]]* ]] || return 1
}

# Strip leading and trailing whitespace from the variable named by $1, without a subshell
# and without the quote/backslash interpretation that xargs applies.
cm_trim_var() {
    local _cm_v="${!1}"
    _cm_v="${_cm_v#"${_cm_v%%[![:space:]]*}"}"
    _cm_v="${_cm_v%"${_cm_v##*[![:space:]]}"}"
    printf -v "$1" '%s' "$_cm_v"
}

# Text colour for an accent background: whichever of black or white has the higher WCAG contrast
# ratio. The former luma threshold left 28% of the sampled accents below the AA 4.5:1 minimum.
cm_accent_fg() {
    local hex="$1" r g b
    r=$((16#${hex:1:2})); g=$((16#${hex:3:2})); b=$((16#${hex:5:2}))
    awk -v r="$r" -v g="$g" -v b="$b" '
        function lin(c) { c = c / 255; return (c <= 0.03928) ? c / 12.92 : exp(2.4 * log((c + 0.055) / 1.055)) }
        BEGIN {
            l = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
            print ((1.05 / (l + 0.05)) >= ((l + 0.05) / 0.05)) ? "#ffffff" : "#000000"
        }'
}

cm_validate_theme_name() { cm_is_valid_name "${1:-}"; }
cm_validate_font_name() { cm_is_valid_name "${1:-}"; }

# yad :CLR fields may return "#RRGGBB", "#RRGGBBAA" or "rgb(r,g,b)" depending
# on the installed version; normalize to "#RRGGBB".
cm_normalize_hex() {
    local input="$1"
    if [[ "$input" =~ ^rgb\(([0-9]+),[[:space:]]*([0-9]+),[[:space:]]*([0-9]+)\)$ ]]; then
        printf '#%02X%02X%02X\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    elif [[ "$input" =~ ^#[0-9A-Fa-f]{8}$ ]]; then
        echo "${input:0:7}"
    elif [[ "$input" =~ ^#[0-9A-Fa-f]{6}$ ]]; then
        echo "$input"
    else
        echo "$input"
    fi
}

# yad :NUM fields format the number with the active locale: "32.000000" in
# C/en_US but "32,000000" in es_ES/es_CO/es_MX. Trimming with "${var%%.*}" misses
# the comma form, and the numeric validation in every cm_apply_* then drops the
# change silently. Keep only the leading digits, whatever the separator.
cm_num_int() {
    local raw="${1:-}"
    [[ "$raw" =~ ^[[:space:]]*(-?[0-9]+) ]] && echo "${BASH_REMATCH[1]}" || echo ""
}

# Restart Cinnamon in place (no logout) to refresh panel, menus and themes.
cm_reload_cinnamon() {
    cm_log "INFO" "$(cm_t cinnamon_reload_request)"
    if command -v gdbus >/dev/null 2>&1; then
        if gdbus call --session --dest org.Cinnamon --object-path /org/Cinnamon \
             --method org.Cinnamon.Restart >/dev/null 2>&1; then
            return 0
        fi
        if gdbus call --session --dest org.Cinnamon --object-path /org/Cinnamon \
             --method org.Cinnamon.RestartCinnamon boolean:false >/dev/null 2>&1; then
            return 0
        fi
        cm_log "WARN" "$(cm_t cinnamon_reload_dbus_fail)"
    fi
    if [ -n "${DISPLAY:-}" ] && command -v cinnamon >/dev/null 2>&1; then
        nohup cinnamon --replace >/dev/null 2>&1 &
        disown 2>/dev/null || true
        return 0
    fi
    cm_log "WARN" "$(cm_t cinnamon_reload_fail)"
    return 1
}

cm_confirm() {
    local msg="$1"
    yad --question --text="$msg" --title="$(cm_t confirm_title)" \
        --button="$(cm_t yes):0" --button="$(cm_t no):1" 2>/dev/null
}

# ============================================================================
# state — key=value store for the LAST applied value of settings that cannot
# be read back reliably from gsettings/dconf (accent, panel opacity, terminal
# palette). Used by cm_save_preset and to preload the GUI fields.
# ============================================================================
cm_state_set() {
    local key="$1" value="$2" tmp status
    cm_lock || return 1
    tmp=$(mktemp "${CM_STATE_FILE%/*}/.${CM_STATE_FILE##*/}.build.XXXXXX") || { cm_unlock; return 1; }
    if [ -f "$CM_STATE_FILE" ] && ! awk -v key="$key" 'index($0, key "=") != 1 { print }' "$CM_STATE_FILE" > "$tmp" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null || true
        cm_unlock
        return 1
    fi
    if ! printf '%s="%s"\n' "$key" "$value" >> "$tmp" || ! cm_atomic_write "$CM_STATE_FILE" < "$tmp"; then
        status=1
    else
        status=0
    fi
    rm -f -- "$tmp" 2>/dev/null || true
    cm_unlock
    return "$status"
}

# cm_state_get <key> <default>
cm_state_get() {
    local key="$1" default="${2:-}" line val
    [ -f "$CM_STATE_FILE" ] || { echo "$default"; return 0; }
    line=$(grep "^${key}=" "$CM_STATE_FILE" 2>/dev/null | tail -n1)
    if [ -z "$line" ]; then
        echo "$default"
        return 0
    fi
    val="${line#*=}"
    val="${val%\"}"
    val="${val#\"}"
    echo "$val"
}

cm_lang_init() {
    local detected
    if [[ "${CM_LANG_OVERRIDE:-}" == "es" || "${CM_LANG_OVERRIDE:-}" == "en" ]]; then
        CM_LANG="$CM_LANG_OVERRIDE"
    else
        CM_LANG=$(cm_state_get "LANGUAGE" "")
        if [[ "$CM_LANG" != "es" && "$CM_LANG" != "en" ]]; then
            detected="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
            case "${detected,,}" in
                es|es_*|es-*) CM_LANG="es" ;;
                *)            CM_LANG="en" ;;
            esac
            [ "$CM_READ_ONLY_CLI" -eq 1 ] || cm_state_set "LANGUAGE" "$CM_LANG"
        fi
    fi
    cm_apply_language_labels
}

cm_lang_toggle() {
    if [ "$CM_LANG" = "es" ]; then CM_LANG="en"; else CM_LANG="es"; fi
    cm_state_set "LANGUAGE" "$CM_LANG"
    cm_apply_language_labels
}

cm_t() {
    local key="$1" value=""
    if [ "$CM_LANG" = "en" ]; then
        value="${CM_TEXT_EN[$key]:-}"
    else
        value="${CM_TEXT_ES[$key]:-}"
    fi
    [ -n "$value" ] && printf '%s' "$value" || printf '%s' "$key"
}

# UI translations only; internal values remain language-neutral.
declare -A CM_TEXT_ES=(
    [confirm_title]="Confirmar" [yes]="Sí" [no]="No" [done]="Entendido"
    [lang_button]="Idioma: ES/EN" [exit]="Salir" [lang_switched_es]="Idioma cambiado a español" [lang_switched_en]="Idioma cambiado a inglés"
    [gsettings_set_failed]="ERROR: no se pudo aplicar '%s': %s" [dconf_write_failed]="ERROR: no se pudo escribir '%s': %s"
    [missing_deps_tty]="Faltan las siguientes dependencias: %s" [install_prompt]="¿Instalar automáticamente con apt (requiere sudo)? [s/N]: " [install_terminal_close]="Pulsa Enter para cerrar..."
    [missing_deps_gui]="Faltan las siguientes dependencias:\n%s\n\n¿Instalar automáticamente con apt?\nSe abrirá una terminal para pedir la contraseña de sudo."
    [deps_installing]="Instalando dependencias (%s)... esto puede tardar unos minutos."
    [deps_timeout]="La instalación está tardando más de lo esperado; revisa la ventana de terminal abierta y vuelve a lanzar Color Mint cuando termine."
    [no_terminal_install]="No se encontró una terminal para instalar. Ejecuta manualmente: sudo apt install %s"
    [deps_continue_fail]="No es posible continuar sin: %s"
    [deps_failed]="No se pudieron instalar todas las dependencias (%s). Instálalas manualmente con: sudo apt install %s"
    [missing_deps_notify]="Faltan dependencias (%s) y no hay terminal ni yad disponibles para preguntar. Instálalas manualmente con: sudo apt install %s"
    [backup_name_required]="ERROR: indica el nombre de un backup (usa 'backup list' para verlos)."
    [backup_name_invalid]="ERROR: el nombre del backup no puede contener '/' ni '..'."
    [backup_create_failed]="ERROR: no se pudo crear el backup completo"
    [backup_restore_failed]="ERROR: no se pudo restaurar el backup completo"
    [backup_restore_kept]="Tu carpeta anterior no se pudo devolver a su sitio; se conserva en: %s"
    [reset_failed]="ERROR: no se pudo restablecer los colores del panel."
    [backup_not_found]="Backup no encontrado: %s"
    [mint_color_required]="ERROR: indica un color (usa 'theme list-mint-y-colors claro|oscuro')."
    [theme_not_found]="ERROR: no se encontró el tema '%s' instalado en este sistema."
    [mint_pack_applied]="Paquete de color oficial Mint-Y aplicado: %s (iconos: %s)"
    [gtk_name_required]="ERROR: indica el nombre de un tema GTK." [theme_name_invalid]="ERROR: el nombre no puede contener rutas, '..' ni caracteres de control."
    [gtk_applied]="Tema GTK aplicado: %s"
    [icon_name_required]="ERROR: indica el nombre de un tema de iconos."
    [icon_applied]="Tema de iconos aplicado: %s"
    [cursor_name_required]="ERROR: indica el nombre de un tema de cursor."
    [cursor_applied]="Tema de cursor aplicado: %s"
    [cursor_size_invalid]="ERROR: el tamaño de cursor debe ser un número entero entre 16 y 96."
    [cursor_size_verify]="ERROR: gsettings aceptó el cambio pero al releerlo el valor guardado es '%s', no %s. Revisa el log."
    [cursor_size_saved]="Tamaño de cursor guardado y verificado en %spx. Nota: Cinnamon tiene un fallo conocido (no es de este script) por el que el puntero visible no siempre se refresca en caliente en ventanas ya abiertas; si no lo notas, cierra sesión y vuelve a entrar — el tamaño ya ha quedado guardado para entonces."
    [cinnamon_name_required]="ERROR: indica el nombre de un tema de Cinnamon."
    [cinnamon_applied]="Tema de Cinnamon aplicado: %s"
    [color_scheme_invalid]="ERROR: el esquema de color '%s' no es válido (usa default, prefer-dark o prefer-light)."
    [color_scheme_applied]="Esquema claro/oscuro aplicado: %s"
    [color_scheme_skipped]="Esquema claro/oscuro omitido: este sistema no tiene org.x.apps.portal."
    [libadwaita_on]="Apps libadwaita con el estilo gtk-4.0 del tema %s (las que ya están abiertas lo recogen al reabrirlas)"
    [libadwaita_off]="libadwaita ya no importa ningún tema (el acento GTK global se conserva)"
    [libadwaita_already_off]="libadwaita no importaba ningún tema."
    [libadwaita_no_theme]="ERROR: no se pudo leer el tema GTK activo."
    [libadwaita_no_gtk4]="ERROR: el tema %s no está instalado o no tiene gtk-4.0/gtk.css; no se ha cambiado nada."
    [libadwaita_path_invalid]="ERROR: la ruta del tema %s no se puede importar (no es absoluta o lleva caracteres de control); no se ha cambiado nada."
    [libadwaita_no_dark_sheet]="ADVERTENCIA: el tema %s no trae gtk-4.0/gtk-dark.css: se importa su gtk.css con el esquema oscuro; si ese estilo es claro, los colores se mezclan."
    [libadwaita_dropped]="El tema %s no tiene estilo gtk-4.0: libadwaita deja de importar un tema (el acento GTK global se conserva)."
    [libadwaita_bundled]="ERROR: el tema %s lleva su estilo gtk-4.0 como recurso empaquetado (resource://), que GTK solo carga al elegir el tema por su nombre: libadwaita no puede importarlo. No se ha cambiado nada."
    [libadwaita_dropped_bundled]="El tema %s lleva su estilo gtk-4.0 como recurso empaquetado (resource://), que libadwaita no puede importar: deja de importar un tema (el acento GTK global se conserva)."
    [libadwaita_status_off]="libadwaita no importa ningún tema. Actívalo con: theme libadwaita on"
    [libadwaita_status_on]="libadwaita importa: %s"
    [libadwaita_status_stale]="libadwaita importa un archivo que ya no existe: %s\nVuelve a aplicar el tema GTK o usa: theme libadwaita off"
    [import_source_required]="ERROR: indica un archivo de tema (.zip/.tar.gz/.tar.xz/.tar.bz2) o una carpeta ya descomprimida."
    [path_not_found]="ERROR: no existe la ruta '%s'"
    [tempdir_failed]="ERROR: no se pudo crear un directorio temporal"
    [deps_manual_cmd]="Faltan dependencias: %s\nInstálalas con tu gestor de paquetes, por ejemplo:\n  %s\ny vuelve a abrir Color Mint." [deps_manual_unknown]="Faltan dependencias: %s\nInstálalas con tu gestor de paquetes y vuelve a abrir Color Mint."
    [gui_locale_missing]="ERROR: la interfaz gráfica necesita una configuración regional UTF-8 y no se encontró ninguna.\nInstala una (por ejemplo: sudo locale-gen en_US.UTF-8) y ábrelo de nuevo."
    [gui_path_unsafe]="ERROR: la interfaz gráfica no puede ejecutarse desde esta ruta:\n%s\n\nLa ruta contiene comillas, barras invertidas, signos de dólar, acentos graves, un %% seguido de un dígito o caracteres de control.\nMueve el script a una carpeta con un nombre sencillo (por ejemplo ~/color-mint) y ábrelo de nuevo."
    [unzip_missing]="ERROR: falta 'unzip' para abrir archivos .zip. Instálalo con: sudo apt install unzip"
    [zip_extract_failed]="ERROR: no se pudo extraer el .zip (¿archivo corrupto?)"
    [tgz_extract_failed]="ERROR: no se pudo extraer el .tar.gz (¿archivo corrupto?)"
    [txz_extract_failed]="ERROR: no se pudo extraer el .tar.xz (¿falta xz-utils?)"
    [tbz_extract_failed]="ERROR: no se pudo extraer el .tar.bz2 (¿falta bzip2?)"
    [tar_extract_failed]="ERROR: no se pudo extraer el .tar"
    [format_unsupported]="ERROR: formato no soportado ('%s'). Usa .zip, .tar.gz, .tar.xz, .tar.bz2/.tbz2, .tar o una carpeta ya descomprimida."
    [theme_unsafe]="ERROR: tema rechazado, no se instaló nada: el archivo está dañado o contiene enlaces, archivos especiales o rutas fuera de la carpeta del tema (solo se aceptan archivos y carpetas normales)."
    [unpacked_too_big]="ERROR: '%s' ocupa más de %s MB descomprimido o tiene más de %s archivos, o no se pudo medir su tamaño, y se ha descartado. No se instaló nada."
    [theme_not_a_theme]="ERROR: esto no es un tema: no tiene gtk-3.0/, gtk-2.0/, cinnamon/, cursors/ ni index.theme. No se instaló nada."
    [theme_read_failed]="ERROR: no se pudo leer la carpeta del tema '%s'"
    [theme_copy_failed]="ERROR: no se pudo copiar el tema a '%s'"
    [fetch_name_required]="ERROR: indica el nombre exacto de un tema de Cinnamon Spices, el UUID que aparece en su página (por ejemplo: theme fetch CBlue)."
    [fetch_name_invalid]="ERROR: '%s' no es un nombre de tema de Spices (solo letras, números, punto, guion y guion bajo; hasta 64 caracteres). Usa el UUID que aparece en la página del tema, no su título."
    [fetch_curl_missing]="ERROR: falta 'curl' para descargar temas. Instálalo con tu gestor de paquetes (en Linux Mint: sudo apt install curl)."
    [fetch_already]="El tema '%s' ya está en %s: no se ha descargado nada. Para descargarlo de nuevo, borra esa carpeta y repite el comando."
    [fetch_failed]="ERROR: no se pudo descargar '%s' de Cinnamon Spices (¿el nombre es exacto, con sus mayúsculas? ¿hay conexión?). No se instaló nada."
    [fetch_too_big]="ERROR: la descarga de '%s' supera los %s MB y se ha descartado. No se instaló nada."
    [fetch_unpacked_big]="ERROR: el .zip de '%s' declara más de %s MB descomprimidos o más de %s archivos, o no se puede leer su tamaño, y se ha descartado. No se instaló nada."
    [fetch_not_zip]="ERROR: lo que devolvió Spices para '%s' no es un archivo .zip. No se instaló nada."
    [fetch_structure]="ERROR: el .zip de '%s' no trae el tema dentro de una carpeta con ese nombre, como lo publica Spices. No se instaló nada. Si lo descargas a mano, usa «theme import»."
    [fetch_apply_hint]="Para usarlo: %s (o la pestaña Temas)"
    [theme_fetched_log]="Tema descargado de Cinnamon Spices: %s → %s"
    [u_theme_fetch]="Descarga un tema de Cinnamon Spices por su UUID (solo HTTPS) y lo instala"
    [package_installing]="Instalando %s... esto puede tardar unos minutos."
    [pkg_list_header]="Paquetes de temas verificados (comprobados en Ubuntu 24.04, la base de Linux Mint 22; son paquetes de apt).\nInstala uno con: %s theme install <paquete>"
    [pkg_kind_gtk_cin]="GTK + Cinnamon" [pkg_kind_gtk]="GTK" [pkg_kind_icons]="Iconos" [pkg_kind_cursors]="Cursor"
    [pkg_installed_mark]="(instalado)"
    [package_required]="ERROR: indica el paquete (la lista está en «theme list-packages»)."
    [package_unknown]="ERROR: '%s' no está en la lista verificada («theme list-packages»). Solo se instalan los paquetes de esa lista."
    [package_apt_only]="ERROR: la lista verificada es de paquetes de apt (Linux Mint, Ubuntu, Debian) y este sistema usa otro gestor. Busca el tema en tu gestor de paquetes, o usa «theme fetch» o «theme import»."
    [package_already]="El paquete '%s' ya está instalado."
    [package_failed]="ERROR: '%s' no quedó instalado. No se cambió nada más."
    [package_done]="Instalado: %s. Ya sale en las listas de temas (pestaña Temas o «theme list-*»)."
    [theme_package_log]="Paquete de temas instalado: %s"
    [u_theme_list_packages]="Lista corta de paquetes de temas verificados (apt)"
    [u_theme_install]="Instala uno de esos paquetes con apt (pide la contraseña de sudo)"
    [file_manager_missing]="No se encontró un gestor de archivos (xdg-open/nemo/nautilus). Ruta: %s/.themes"
    [base_theme_not_found]="ERROR: no se encontró el tema base '%s'"
    [custom_theme_activation_failed]="ERROR: el color se guardó en el tema personalizado pero Cinnamon no pudo activarlo. Prueba 'Restaurar último backup' o revisa el log."
    [color_required]="ERROR: indica un color en formato #RRGGBB."
    [hex_invalid]="ERROR: '%s' no es un color hexadecimal válido (usa #RRGGBB)."
    [css_not_found]="ERROR: cinnamon.css no encontrado en %s"
    [accent_warning]="ADVERTENCIA: no se detectó un color de acento dominante; no se aplicó ningún cambio."
    [accent_applied]="Acento aplicado: %s -> %s (tema: %s)"
    [panel_bg_applied]="Fondo del panel: %s -> %s (tema: %s)"
    [panel_fg_applied]="Texto/iconos del panel: %s -> %s (tema: %s)"
    [menu_bg_applied]="Fondo de menús: %s -> %s (tema: %s)"
    [menu_fg_applied]="Texto de menús: %s -> %s (tema: %s)"
    [tooltip_bg_applied]="Fondo de tooltips: %s -> %s (tema: %s)"
    [tooltip_fg_applied]="Texto de tooltips: %s -> %s (tema: %s)"
    [color_reset_none]="No hay ninguna personalización de color que restablecer todavía."
    [minty_none]="Ninguno (usar el camino manual de abajo)"
    [gtk_accent_applied]="Acento GTK global aplicado: %s (afecta a las apps GTK3 y libadwaita que abras desde ahora; las que ya están abiertas lo recogen al reabrirlas)"
    [gtk_accent_reset]="Acento GTK global restablecido (quitado el override de Color Mint)"
    [gtk_accent_none]="No hay ningún acento GTK global aplicado por Color Mint."
    [opacity_invalid]="ERROR: la opacidad debe ser un número entero entre 0 y 100."
    [opacity_applied]="Opacidad del panel ajustada a %s%%"
    [opacity_warning]="ADVERTENCIA: no se encontró ningún fondo (rgba(...) ni hexadecimal plano) en el bloque del panel de este tema; la opacidad podría no haber cambiado visualmente."
    [height_invalid]="ERROR: el alto del panel debe ser un número entero entre 16 y 100."
    [height_applied]="Alto del panel ajustado a %spx"
    [buttons_empty]="ERROR: layout de botones vacío"
    [buttons_applied]="Botones de ventana aplicados: %s"
    [corners_applied]="Esquinas activas actualizadas" [corners_invalid]="ERROR: esquina activa no válida: %s"
    [effects_invalid]="ERROR: valor no válido ('%s'). Usa 'on' u 'off'."
    [window_effects_on]="Efectos de ventana activados" [window_effects_off]="Efectos de ventana desactivados"
    [menu_effects_on]="Efectos de menús activados" [menu_effects_off]="Efectos de menús desactivados"
    [workspaces_invalid]="ERROR: el número de espacios de trabajo debe ser un entero entre 1 y 20."
    [workspaces_applied]="Espacios de trabajo ajustados a %s"
    [workspaces_dynamic]="ADVERTENCIA: los espacios de trabajo dinámicos están activados, así que este número no se nota. Desactívalos con: gsettings set org.cinnamon.muffin dynamic-workspaces false"
    [icons_shown]="Iconos de escritorio mostrados" [icons_hidden]="Iconos de escritorio ocultos"
    [icons_invalid]="ERROR: valor no válido ('%s'). Usa 'show' u 'hide'."
    [desktop_bg_applied]="Fondo de escritorio: color sólido %s (imagen de fondo quitada)"
    [desktop_bg_kept]="Fondo de escritorio: color de respaldo %s (la imagen actual se mantiene)"
    [palette_name_required]="ERROR: indica el nombre de una paleta (usa 'terminal list' para ver las disponibles)."
    [palette_unknown]="Paleta desconocida: %s"
    [terminal_profile_missing]="No se encontró un perfil por defecto de gnome-terminal. Abre el Terminal una vez y vuelve a intentarlo."
    [palette_applied]="Paleta '%s' aplicada al perfil de terminal por defecto."
    [terminal_color_invalid]="ERROR: '%s' no es un color de fondo válido (usa #RRGGBB)."
    [terminal_fg_invalid]="ERROR: '%s' no es un color de texto válido (usa #RRGGBB)."
    [terminal_color_required]="ERROR: indica al menos un color (fondo o texto)."
    [terminal_custom_applied]="Colores personalizados de terminal aplicados%s%s"
    [font_required]="ERROR: indica el nombre de una fuente (p.ej. 'Noto Sans 10')." [font_name_invalid]="ERROR: el nombre de fuente no puede contener rutas, '..' ni caracteres de control."
    [font_applied]="Fuente de interfaz aplicada: %s"
    [mono_required]="ERROR: indica el nombre de una fuente monoespaciada."
    [mono_applied]="Fuente monoespaciada aplicada: %s"
    [rendering_invalid]="ERROR: indica antialiasing <rgba|grayscale|none> e hinting <slight|medium|full|none>."
    [fonts_conf_failed]="ERROR: no se pudo escribir %s/.config/fontconfig/fonts.conf" [file_write_failed]="ERROR: no se pudo escribir '%s'" [link_refused]="ERROR: %s es un enlace y no se puede escribir lo que señala (o no lleva a ninguna parte); no se ha tocado."
    [rendering_applied]="Renderizado de fuentes aplicado: antialiasing=%s, hinting=%s (algunas apps ya abiertas pueden necesitar reabrirse para verlo)"
    [scaling_invalid]="ERROR: la escala de texto debe ser un número entero entre 50 y 200 (%)."
    [scaling_applied]="Escala de texto ajustada a %s%% (factor %s)"
    [preset_name_required]="ERROR: indica un nombre para el preset." [preset_invalid]="ERROR: el preset contiene un formato o valor no permitido." [preset_save_failed]="ERROR: no se pudo guardar el preset." [preset_load_failed]="ERROR: no se pudo aplicar el preset."
    [preset_bad_line]="ERROR: la línea %s del preset no tiene el formato CLAVE=\"valor\"." [preset_unknown_key]="ERROR: la línea %s del preset usa una clave desconocida: %s" [preset_bad_chars]="ERROR: la línea %s del preset contiene caracteres no permitidos."
    [preset_rejected]="ERROR: el preset '%s' no se aplicó y no se cambió nada:" [preset_problem_value]="  - %s: '%s' no es un valor válido" [preset_problem_theme]="  - %s: '%s' no está instalado" [preset_problem_cursor]="  - %s: '%s' no es un tema de cursor (sin carpeta cursors/)" [preset_problem_group]="  - %s van juntos: indica todos o ninguno"
    [preset_notes]="Avisos sobre el preset '%s':" [preset_not_copied]="ERROR: el preset '%s' tiene problemas y no se ha copiado:" [cursor_inherited]="Aviso: '%s' no tiene cursores propios; el puntero será el que herede o el predeterminado del sistema."
    [preset_file_required]="ERROR: indica el archivo del preset." [preset_file_missing]="ERROR: no se puede leer el preset '%s' (debe ser un archivo normal)." [preset_exists]="ERROR: ya existe '%s'; no se sobrescribe." [preset_too_big]="ERROR: el preset supera los 64 KB."
    [preset_exported]="Preset exportado: %s" [preset_imported]="Preset importado como '%s'. Aplícalo con: preset load %s" [preset_imported_log]="Preset importado: %s"
    [preset_stopped]="ERROR: el preset se detuvo en %s; los ajustes anteriores ya estaban aplicados (restaura el último backup para deshacerlos)."
    [preset_name_invalid]="ERROR: el nombre del preset no puede contener '/' ni '..'."
    [preset_not_found]="Preset no encontrado: %s"
    [ui_theme_file_required]="Elige un archivo de tema o una carpeta ya descomprimida para importar."
    [ui_theme_import_error]="No se pudo importar el tema.\nRevisa que el archivo tenga un formato soportado (.zip, .tar.gz, .tar.xz, .tar.bz2)\ny una estructura de tema válida (gtk-3.0/, cinnamon/, cursors/ o index.theme)."
    [ui_import_done]="Ya aparece preseleccionado en su desplegable — pulsa «Aplicar temas» para usarlo"
    [ui_terminal_required]="Elige una paleta o marca «Usar estos colores personalizados» antes de pulsar «Aplicar terminal»."
    [ui_preset_name_required]="Escribe un nombre antes de pulsar «Guardar preset»."
    [ui_preset_choose]="Elige un preset de la lista antes de pulsar «Cargar preset»."
    [ui_backup_choose]="Elige un backup de la lista antes de pulsar «Restaurar backup»."
    [ui_backup_none]="Todavía no hay ningún backup que restaurar.\nSe crea uno automáticamente antes de cada cambio que aplicas desde esta ventana."
    [ui_backup_empty_entry]="(Aún no hay backups)"
    [ui_backup_confirm]="¿Restaurar el backup '%s'?\nSe sobreescribirá la configuración actual y se ELIMINARÁN\nlos temas y ajustes de gtk-3.0 añadidos después de ese backup\n(no solo se revierten los cambios)."
    [panel_position_applied]="Panel principal movido a: %s" [theme_no_match]="(sin coincidencia en el tema, aplicado como override)" [theme_restore_failed]="(⚠ no se pudo reactivar el tema original: %s)" [ui_panel_reset_confirm]="¿Restablecer el panel al tema original, quitando la personalización de color\n(acento/fondo/texto) aplicada hasta ahora?\nLa opacidad y el alto del panel, que son ajustes independientes, no se ven afectados." [ui_backup_confirm_last]="¿Restaurar el último backup (%s)?\nSe sobreescribirá la configuración actual y se ELIMINARÁN\nlos temas y ajustes de gtk-3.0 añadidos después de ese backup\n(no solo se revierten los cambios)."
    [position_invalid]="ERROR: posición no válida ('%s'). Usa 'top' o 'bottom'."
    [report_failed]="no se pudo aplicar" [warning_suffix]="con avisos"
    [keep_custom_layout]="Mantener el diseño a medida actual (pestaña Avanzado)" [official_mint_color]="Color oficial Mint-Y: %s (%s)" [report_gtk_theme]="Tema GTK: %s" [report_icon_theme]="Tema de iconos: %s" [report_cinnamon_theme]="Tema de Cinnamon: %s" [report_cursor_theme]="Tema de cursor: %s" [report_panel_position]="Posición del panel: %s" [report_opacity]="Opacidad: %s%%" [report_height]="Alto: %spx" [report_desktop_bg]="Fondo de escritorio: %s (%s)" [report_window_buttons]="Botones de ventana: %s" [report_window_effects]="Efectos de ventana: %s" [report_menu_effects]="Efectos en menús: %s" [report_workspaces]="Espacios de trabajo: %s" [report_desktop_icons]="Iconos de escritorio: %s" [report_hotcorners]="Esquinas activas: %s / %s / %s / %s" [report_custom_buttons]="Botones de ventana (a medida): %s" [report_libadwaita_on]="Estilo libadwaita: el gtk-4.0 del tema GTK" [report_libadwaita_off]="Estilo libadwaita: el propio de libadwaita" [report_palette]="Paleta de color: %s" [report_terminal_custom]="Colores personalizados de terminal" [report_font]="Fuente de interfaz: %s" [report_mono]="Fuente monoespaciada: %s" [report_rendering]="Renderizado: %s / %s" [report_scaling]="Escala de texto: %s%%"
    [backup_restore_done]="Backup restaurado: %s"
    [cinnamon_reload_request]="Solicitando reinicio de Cinnamon" [cinnamon_reload_dbus_fail]="Ninguna llamada D-Bus de reinicio funcionó; probando 'cinnamon --replace'" [cinnamon_reload_fail]="No se pudo reiniciar Cinnamon por ningún método (¿sesión no-Cinnamon?)" [backup_created]="Backup creado en %s" [backup_restored_log]="Backup restaurado: %s" [theme_imported_log]="Tema importado: %s -> %s" [preset_saved_log]="Preset guardado: %s" [preset_loaded_log]="Preset cargado: %s" [app_started]="Iniciando Color Mint" [app_closed]="Color Mint cerrado"
    [light_mode]="Claro" [dark_mode]="Oscuro" [cursor_size_report]="Tamaño de cursor: %spx (si no se ve al momento, puede necesitar cerrar sesión — ver nota)"
    [theme_imported]="Tema importado" [path_detail]="Ruta: %s" [applied_themes]="Temas aplicados" [panel_updated]="Panel actualizado" [colors_reset]="Colores del panel restablecidos" [backup_restored]="Backup restaurado"
    [reset_colors_summary]="Colores restablecidos" [reset_colors_original_theme]=" (tema original: %s)" [reset_colors_gtk_included]=", acento GTK global incluido" [desktop_updated]="Escritorio actualizado" [advanced_updated]="Ajustes avanzados actualizados" [terminal_updated]="Terminal actualizado" [fonts_updated]="Tipografía actualizada" [preset_saved]="Preset guardado" [preset_loaded]="Preset cargado" [backup_name_detail]="Nombre: %s" [file_detail]="Archivo: %s" [preset_load_detail]="Se aplicaron temas, colores, panel, escritorio, terminal y fuentes guardados en ese preset."
    [apply_themes]="Aplicar temas" [import_theme]="Importar tema" [ui_themes_text]="<span size='x-large' weight='bold'>Cambia el aspecto de tu escritorio</span>\nDos caminos para cambiar el aspecto — usa uno u otro, no hace falta rellenar los dos.\nEl fácil manda si lo rellenas." [ui_themes_easy]="<b>✅  Camino fácil — color oficial de Mint</b> (recomendado)" [ui_official_color]="Color oficial" [ui_light_dark]="Claro u oscuro" [ui_themes_manual]="<b>🔧  Camino manual</b> — elige cada pieza (opcional)" [ui_gtk_theme]="Tema GTK" [ui_icons]="Iconos" [ui_cinnamon]="Cinnamon (panel y menús)" [ui_cursor_always]="<b>🖱️  Cursor</b> — se aplica siempre, con cualquiera de los dos caminos" [ui_cursor]="Cursor" [ui_cursor_size]="Tamaño de cursor (px)" [ui_import_theme]="<b>📁  Más temas</b> (opcional)" [ui_theme_file]="Archivo (.zip/.tar.gz/.tar.xz/.tar.bz2)" [ui_theme_dir]="O carpeta ya descomprimida"
    [more_themes]="Conseguir más temas..." [cancel]="Cancelar"
    [ui_more_title]="Conseguir más temas"
    [ui_more_text]="Instala un paquete de temas desde las fuentes de software del sistema\n(pide tu contraseña) o descarga uno de Cinnamon Spices escribiendo\nsu nombre: el final de la dirección de su página, con mayúsculas,\ncomo en .../themes/view/<b>Nocturne</b>"
    [ui_more_text_web]="Descarga un tema de Cinnamon Spices escribiendo su nombre:\nel final de la dirección de su página, con mayúsculas,\ncomo en .../themes/view/<b>Nocturne</b>"
    [ui_more_pack]="Paquete de temas" [ui_more_none]="Ninguno" [ui_more_spices]="Nombre en Cinnamon Spices" [ui_more_get]="Conseguir"
    [ui_more_nothing]="Elige un paquete de temas o escribe un nombre de Cinnamon Spices."
    [ui_more_wait]="Descargando %s de Cinnamon Spices...\nEsta ventana se cierra sola."
    [ui_more_failed]="No se pudo conseguir el tema" [ui_more_fetched]="Tema descargado" [ui_more_installed]="Paquete de temas instalado"
    [ui_more_package]="Paquete: %s" [ui_more_in_lists]="Ya sale en los desplegables — elígelo y pulsa «Aplicar temas»"
    [apply_panel]="Aplicar panel" [reset_colors]="Restablecer colores" [restore_last_backup]="Restaurar último backup" [ui_panel_text]="<span size='x-large' weight='bold'>Colorea el panel y los menús</span>\n1) Elige qué parte colorear.\n2) Un color rápido o el tuyo.\n3) «Aplicar panel». Repite para colorear otra parte." [ui_panel_target]="¿Qué parte quieres colorear?" [ui_quick_color]="Color rápido (opcional)" [ui_custom_color]="O tu propio color" [ui_panel_size]="<b>📐  Tamaño del panel</b>" [ui_opacity]="Opacidad (%)" [ui_height]="Alto (px)"
    [apply_desktop]="Aplicar escritorio" [ui_desktop_text]="<span size='x-large' weight='bold'>Ajusta el escritorio a tu gusto</span>\nLo más usado: panel, botones de ventana, efectos, espacios de trabajo y fondo.\nEsquinas activas y botones a medida están en «Avanzado»." [ui_desktop_panel_buttons]="<b>🪟  Panel y botones de ventana</b>" [ui_panel_position]="Posición del panel" [ui_window_buttons]="Botones de ventana" [ui_effects_workspaces]="<b>✨  Efectos y espacios de trabajo</b>" [ui_window_effects]="Efectos de ventana" [ui_menu_effects]="Efectos en menús" [ui_workspaces]="Espacios de trabajo" [ui_desktop_icons]="Iconos de escritorio" [ui_desktop_bg]="<b>🎨  Fondo de escritorio</b>" [ui_bg_color]="Color de fondo" [ui_mode]="Modo"
    [apply_advanced]="Aplicar avanzado" [ui_advanced_text]="<span size='x-large' weight='bold'>Ajustes más finos</span>\nEsquinas activas, botones a medida y apps libadwaita. Para lo más común, usa la pestaña «Escritorio»." [ui_hotcorners]="<b>🖱️  Esquinas activas</b> — mueve el ratón a una esquina para activar la acción" [ui_top_left]="Sup. izquierda" [ui_top_right]="Sup. derecha" [ui_bottom_left]="Inf. izquierda" [ui_bottom_right]="Inf. derecha" [ui_custom_buttons]="<b>🔘  Botones de ventana a medida</b> (opcional)" [ui_custom_string]="Cadena personalizada:" [ui_button_values]="Valores: close, minimize, maximize, spacer, menu, stick, above, lower, shade  ·  \":\" separa izquierda/derecha" [ui_libadwaita]="<b>🔗  Apps libadwaita</b> — las apps nuevas de GNOME" [ui_libadwaita_use]="Que usen el estilo gtk-4.0 del tema GTK" [ui_libadwaita_hint]="💡 Estas apps ignoran el tema GTK. Si el tema trae estilo gtk-4.0, la casilla se lo da.\nLas que ya están abiertas lo recogen al reabrirlas."
    [apply_terminal]="Aplicar terminal" [ui_terminal_text]="<span size='x-large' weight='bold'>Dale color a tu terminal</span>\nElige una paleta lista para usar, o define tus propios colores de fondo y texto." [ui_palette]="Paleta de colores" [ui_terminal_custom]="<b>🎨  Personalizado</b> (opcional, anula la paleta de arriba)" [ui_background]="Fondo" [ui_text_color]="Texto" [ui_use_custom]="Usar estos colores personalizados" [ui_color_hint]="💡 El selector de color siempre trae un tono de fábrica: marca la casilla de arriba solo si quieres aplicar Fondo/Texto."
    [apply_fonts]="Aplicar fuentes" [ui_fonts_text]="<span size='x-large' weight='bold'>Elige cómo se lee el texto</span>\nTipografía de interfaz y monoespaciada, renderizado y escala de texto." [ui_typography]="<b>🔤  Tipografía</b>" [ui_interface]="Interfaz" [ui_monospace]="Monoespaciada" [ui_rendering]="<b>🖌️  Renderizado</b>" [ui_antialias]="Antialiasing" [ui_hinting]="Hinting" [ui_font_hint]="💡 Se guarda en ~/.config/fontconfig/fonts.conf. Apps ya abiertas pueden necesitar reabrirse." [ui_scaling]="<b>🔍  Escala</b>" [ui_text_scaling]="Escala de texto (%)"
    [save]="Guardar" [load]="Cargar" [restore]="Restaurar" [ui_profiles_text]="<span size='x-large' weight='bold'>Guarda y recupera tu configuración</span>\nGuarda el estado actual como preset, carga uno guardado, o restaura un backup automático anterior." [ui_save_preset]="<b>💾  Guardar preset</b>" [ui_new_name]="Nombre nuevo:" [default_preset_name]="mi-preset" [ui_load_preset]="<b>📂  Cargar preset</b>" [ui_saved_preset]="Preset guardado" [ui_restore_backup]="<b>♻️  Restaurar backup</b>" [ui_available_backup]="Backup disponible"
    [gui_tab_themes]="🎨  Temas" [gui_tab_panel]="🖥️  Panel" [gui_tab_desktop]="🪟  Escritorio" [gui_tab_advanced]="🧩  Avanzado" [gui_tab_terminal]="⌨️  Terminal" [gui_tab_fonts]="🔤  Fuentes" [gui_tab_profiles]="💾  Perfiles"
    [usage_title]="Color Mint v%s — personalización estética avanzada para Linux Mint 22.3 Cinnamon (por %s)" [usage_graphical]="MODO GRÁFICO (recomendado)" [usage_graphical_desc]="Abre la interfaz gráfica" [usage_same_gui]="Igual que sin argumentos" [usage_terminal]="MODO TERMINAL — un comando por ajuste, sin abrir la interfaz gráfica" [usage_language]="🌐 Idioma" [usage_language_desc]="Cambia entre español e inglés y guarda la elección" [usage_themes]="🎨 Temas" [usage_panel]="🖥️ Panel" [usage_desktop]="🪟 Escritorio" [usage_terminal_section]="⌨️ Terminal" [usage_fonts]="🔤 Fuentes" [usage_backups]="💾 Backups y presets" [usage_data]="Datos, backups, presets y logs viven en:"
    [u_theme_mint]="Forma rápida: paquete oficial Mint-Y" [u_theme_gtk]="Tema GTK" [u_theme_icon]="Tema de iconos" [u_theme_cursor]="Tema de cursor" [u_theme_cursor_size]="Tamaño del cursor, en píxeles" [u_theme_cinnamon]="Tema de Cinnamon (panel y menús)" [u_theme_libadwaita]="Apps libadwaita con el estilo gtk-4.0 del tema GTK" [u_theme_import]="Instala un tema descargado (.zip/.tar.gz/.tar.xz/.tar.bz2)" [u_theme_folder]="Abre la carpeta de temas" [u_theme_list_gtk]="Temas GTK instalados" [u_theme_list_icon]="Temas de iconos instalados" [u_theme_list_cursor]="Temas de cursor instalados" [u_theme_list_cinnamon]="Temas de Cinnamon instalados" [u_theme_list_mint]="Colores oficiales Mint-Y disponibles"
    [u_panel_part]="Colorea una parte del panel — <parte> es una de:" [u_panel_keys1]="accent (acento), bg (fondo), fg (texto), menu-bg, menu-fg," [u_panel_keys2]="tooltip-bg, tooltip-fg, gtk-accent (acento en apps GTK3/libadwaita)" [u_panel_opacity]="Opacidad del panel, en %" [u_panel_height]="Alto del panel, en píxeles" [u_panel_reset]="Quita la personalización de color del panel"
    [u_desktop_position]="Panel arriba o abajo" [u_desktop_buttons]="Botones de la ventana" [u_desktop_list_buttons]="Lista los presets de botones" [u_desktop_hotcorners]="Esquina activa: none, expo, scale o desktop" [u_desktop_effects]="Efectos al abrir/cerrar ventanas" [u_desktop_menu_effects]="Efectos al abrir menús" [u_desktop_workspaces]="Número de espacios de trabajo" [u_desktop_icons]="Iconos del escritorio" [u_desktop_bg]="Color de fondo (mantener = conserva la imagen actual, solo_color = solo color sólido)"
    [u_terminal_apply]="Aplica una paleta de color lista para usar" [u_terminal_list]="Lista las paletas disponibles" [u_terminal_custom]="Colores a medida (cualquiera puede ir vacío: \"\")"
    [u_fonts_font]="Fuente de la interfaz" [u_fonts_mono]="Fuente monoespaciada (terminal, editores)" [u_fonts_rendering]="Antialiasing e hinting" [u_fonts_scaling]="Escala del texto, en %"
    [u_backup_create]="Crea un backup ahora" [u_backup_list]="Lista los backups" [u_backup_restore]="Restaura un backup" [u_preset_save]="Guarda el estado actual como preset" [u_preset_list]="Lista los presets guardados" [u_preset_load]="Aplica un preset guardado" [u_preset_export]="Exporta un preset a un archivo" [u_preset_import]="Importa un preset (no lo aplica)"
    [unknown_tab]="Pestaña interna desconocida: %s" [unknown_apply]="Modo de aplicación interno desconocido: %s"
    [cinnamon_env_warning]="Aviso: no se detecta variable XDG_CURRENT_DESKTOP. Si no estás en una sesión Cinnamon algunas opciones no tendrán efecto."
    [not_cinnamon_session]="ERROR: Color Mint solo funciona en una sesión de Cinnamon y esta es «%s».\nNo se ha cambiado nada."
    [unknown_command]="Comando desconocido: %s" [unknown_option]="Opción no reconocida en '%s': %s" [help_hint]="Ver '%s --help' → sección %s."
    [unknown_failure]="fallo desconocido" [value_empty]="vacío" [terminal_bg_part]=" — fondo: %s" [terminal_fg_part]=" — texto: %s"
    [original_failed]="ERROR: no se pudo guardar el aspecto original del escritorio; no se ha cambiado nada." [original_logged]="Aspecto original guardado en %s"
    [usage_install]="📦 Instalación" [u_install]="Añade Color Mint al menú de aplicaciones (copia el script en ~/.local/bin y crea el lanzador)" [launcher_comment]="Personalización estética avanzada para Linux Mint Cinnamon"
    [install_done]="Color Mint instalado en %s\nLanzador del menú: %s" [install_path_hint]="Aviso: %s no está en PATH; se añade al abrir una sesión nueva." [install_unsafe_home]="ERROR: la ruta '%s' tiene caracteres que un lanzador no admite (comillas, \$, %%, barra invertida o de control)."
    [install_failed]="ERROR: no se pudo instalar %s" [install_script_unreadable]="ERROR: no se puede leer el script '%s'." [install_foreign]="ERROR: '%s' ya existe y no es de Color Mint; no se sobrescribe."
    [uninstall_nothing]="No hay nada de Color Mint que desinstalar." [uninstall_plan]="Se va a desinstalar Color Mint:" [uninstall_plan_menu]="  - Se quitan el lanzador del menú y la copia del programa."
    [uninstall_plan_keep_look]="  - El escritorio conserva su aspecto actual." [uninstall_plan_restore]="  - El escritorio vuelve al aspecto que tenía antes del primer cambio de Color Mint." [uninstall_plan_prior]="  - Aviso: Color Mint ya se había usado antes de guardarlo, así que puede no ser el de fábrica."
    [uninstall_plan_no_original]="  - Color Mint no ha cambiado el escritorio: no hay aspecto que restaurar."
    [marked_block_open]="ERROR: %s tiene el marcador de apertura de un bloque de Color Mint sin su cierre; no se ha tocado. Bórralo a mano: esa línea y lo que Color Mint escribió debajo."
    [uninstall_block_open]="Se deja %s: un bloque de Color Mint no tiene su marcador de cierre. Bórralo a mano: la línea de apertura y lo que Color Mint escribió debajo."
    [uninstall_plan_no_original_prior]="  - Color Mint se usó antes de guardar el aspecto original: no hay nada que restaurar y el escritorio conserva el actual. Para volver atrás, usa antes 'backup restore' (ver 'backup list')." [uninstall_plan_keep_config]="  - Se conservan presets, backups y ajustes en %s." [uninstall_plan_drop_config]="  - Se borran presets, backups, registros y ajustes de %s."
    [uninstall_prompt]="¿Continuar? [s/N]: " [uninstall_need_yes]="ERROR: no hay terminal para preguntar; repite el comando con --yes." [uninstall_cancelled]="Cancelado: no se ha cambiado nada."
    [uninstall_dconf_failed]="ERROR: no se pudo restaurar la configuración del escritorio; no se ha quitado nada más. Repite el comando cuando se resuelva." [uninstall_no_dconf]="Aviso: al guardar el aspecto original no había dconf; solo se restauran archivos." [uninstall_failed_item]="ERROR: no se pudo quitar %s."
    [uninstall_kept_other]="Se deja %s: Color Mint no lo registró como suyo; bórralo a mano si no lo quieres."
    [uninstall_kept_link]="Se deja %s: es un enlace y el archivo al que apunta aún guarda lo que Color Mint escribió; borra esas líneas a mano si no las quieres." [uninstall_kept_home]="Se conserva %s: contiene archivos que Color Mint no creó o está fuera de tu carpeta personal."
    [uninstall_apt_note]="Paquetes que Color Mint instaló con apt (no se quitan solos): %s\nPara quitarlos: sudo apt-get remove %s" [uninstall_relogin]="Cierra la sesión y vuelve a entrar para que el cursor y las fuentes terminen de cambiar." [uninstall_done]="Color Mint desinstalado." [uninstall_incomplete]="La desinstalación no ha terminado; repite el comando para completarla."
    [u_uninstall]="Quita el lanzador y la copia. --restore-look: vuelve al aspecto original; --keep-config: conserva presets y backups; --yes: sin preguntar"
)

declare -A CM_TEXT_EN=(
    [confirm_title]="Confirm" [yes]="Yes" [no]="No" [done]="OK"
    [lang_button]="Language: ES/EN" [exit]="Exit" [lang_switched_es]="Language switched to Spanish" [lang_switched_en]="Language switched to English"
    [gsettings_set_failed]="ERROR: could not apply '%s': %s" [dconf_write_failed]="ERROR: could not write '%s': %s"
    [missing_deps_tty]="The following dependencies are missing: %s" [install_prompt]="Install them automatically with apt (requires sudo)? [y/N]: " [install_terminal_close]="Press Enter to close..."
    [missing_deps_gui]="The following dependencies are missing:\n%s\n\nInstall them automatically with apt?\nA terminal will open to ask for the sudo password."
    [deps_installing]="Installing dependencies (%s)... this may take a few minutes."
    [deps_timeout]="The installation is taking longer than expected; check the open terminal and run Color Mint again when it finishes."
    [no_terminal_install]="No terminal was found for installation. Run manually: sudo apt install %s"
    [deps_continue_fail]="Cannot continue without: %s"
    [deps_failed]="Not all dependencies could be installed (%s). Install them manually with: sudo apt install %s"
    [missing_deps_notify]="Missing dependencies (%s), and neither a terminal nor yad is available to ask. Install them manually with: sudo apt install %s"
    [backup_name_required]="ERROR: enter the backup name (use 'backup list' to see them)." [backup_create_failed]="ERROR: could not create the complete backup" [backup_restore_failed]="ERROR: could not restore the backup completely" [backup_restore_kept]="Your previous folder could not be put back; it is kept at: %s" [reset_failed]="ERROR: could not reset the panel colors."
    [backup_name_invalid]="ERROR: a backup name cannot contain '/' or '..'."
    [backup_not_found]="Backup not found: %s"
    [mint_color_required]="ERROR: enter a color (see 'theme list-mint-y-colors claro|oscuro'; claro = light, oscuro = dark)."
    [theme_not_found]="ERROR: the theme '%s' is not installed on this system."
    [mint_pack_applied]="Official Mint-Y color pack applied: %s (icons: %s)"
    [gtk_name_required]="ERROR: enter the name of a GTK theme." [theme_name_invalid]="ERROR: the name must not contain path separators, '..', or control characters."
    [gtk_applied]="GTK theme applied: %s"
    [icon_name_required]="ERROR: enter the name of an icon theme."
    [icon_applied]="Icon theme applied: %s"
    [cursor_name_required]="ERROR: enter the name of a cursor theme."
    [cursor_applied]="Cursor theme applied: %s"
    [cursor_size_invalid]="ERROR: cursor size must be an integer between 16 and 96."
    [cursor_size_verify]="ERROR: gsettings accepted the change, but the saved value is '%s' when read back, not %s. Check the log."
    [cursor_size_saved]="Cursor size saved and verified as %spx. Note: Cinnamon has a known issue (not caused by this script) where the visible pointer does not always refresh live in already-open windows; if you do not see it, log out and back in — the saved size will be applied then."
    [cinnamon_name_required]="ERROR: enter the name of a Cinnamon theme."
    [cinnamon_applied]="Cinnamon theme applied: %s"
    [color_scheme_invalid]="ERROR: the color scheme '%s' is not valid (use default, prefer-dark or prefer-light)."
    [color_scheme_applied]="Light/dark scheme applied: %s"
    [color_scheme_skipped]="Light/dark scheme skipped: this system has no org.x.apps.portal."
    [libadwaita_on]="libadwaita apps use the gtk-4.0 style of the theme %s (apps that are already open pick it up when reopened)"
    [libadwaita_off]="libadwaita no longer imports a theme (the global GTK accent stays)"
    [libadwaita_already_off]="libadwaita was not importing a theme."
    [libadwaita_no_theme]="ERROR: could not read the active GTK theme."
    [libadwaita_no_gtk4]="ERROR: the theme %s is not installed or has no gtk-4.0/gtk.css; nothing was changed."
    [libadwaita_path_invalid]="ERROR: the path of the theme %s cannot be imported (not absolute or has control characters); nothing was changed."
    [libadwaita_no_dark_sheet]="WARNING: the theme %s has no gtk-4.0/gtk-dark.css: its gtk.css is imported on the dark scheme; if that style is light, the colors mix."
    [libadwaita_dropped]="The theme %s has no gtk-4.0 style: libadwaita stops importing a theme (the global GTK accent stays)."
    [libadwaita_bundled]="ERROR: the theme %s ships its gtk-4.0 style as a bundled resource (resource://), which GTK loads only when the theme is chosen by name: libadwaita cannot import it. Nothing was changed."
    [libadwaita_dropped_bundled]="The theme %s ships its gtk-4.0 style as a bundled resource (resource://), which libadwaita cannot import: it stops importing a theme (the global GTK accent stays)."
    [libadwaita_status_off]="libadwaita is not importing a theme. Turn it on with: theme libadwaita on"
    [libadwaita_status_on]="libadwaita imports: %s"
    [libadwaita_status_stale]="libadwaita imports a file that no longer exists: %s\nApply the GTK theme again or use: theme libadwaita off"
    [import_source_required]="ERROR: enter a theme file (.zip/.tar.gz/.tar.xz/.tar.bz2) or an already extracted folder."
    [path_not_found]="ERROR: path '%s' does not exist"
    [tempdir_failed]="ERROR: could not create a temporary directory"
    [deps_manual_cmd]="Missing dependencies: %s\nInstall them with your package manager, for example:\n  %s\nand open Color Mint again." [deps_manual_unknown]="Missing dependencies: %s\nInstall them with your package manager and open Color Mint again."
    [gui_locale_missing]="ERROR: the graphical interface needs a UTF-8 locale and none was found.\nInstall one (for example: sudo locale-gen en_US.UTF-8) and open it again."
    [gui_path_unsafe]="ERROR: the graphical interface cannot run from this path:\n%s\n\nThe path contains quotes, backslashes, dollar signs, backticks, a %% followed by a digit, or control characters.\nMove the script to a folder with a simple name (for example ~/color-mint) and open it again."
    [unzip_missing]="ERROR: 'unzip' is required to open .zip files. Install it with: sudo apt install unzip"
    [zip_extract_failed]="ERROR: could not extract the .zip (corrupt file?)"
    [tgz_extract_failed]="ERROR: could not extract the .tar.gz (corrupt file?)"
    [txz_extract_failed]="ERROR: could not extract the .tar.xz (missing xz-utils?)"
    [tbz_extract_failed]="ERROR: could not extract the .tar.bz2 (missing bzip2?)"
    [tar_extract_failed]="ERROR: could not extract the .tar"
    [format_unsupported]="ERROR: unsupported format ('%s'). Use .zip, .tar.gz, .tar.xz, .tar.bz2/.tbz2, .tar, or an already extracted folder."
    [theme_unsafe]="ERROR: theme rejected, nothing was installed: the file is damaged, or it contains links, special files or paths outside the theme folder (only plain files and folders are accepted)."
    [unpacked_too_big]="ERROR: '%s' unpacks to more than %s MB or holds more than %s files, or its size could not be measured, and it was discarded. Nothing was installed."
    [theme_not_a_theme]="ERROR: this is not a theme: it has no gtk-3.0/, gtk-2.0/, cinnamon/, cursors/ or index.theme. Nothing was installed."
    [theme_read_failed]="ERROR: could not read the theme folder '%s'"
    [theme_copy_failed]="ERROR: could not copy the theme to '%s'"
    [fetch_name_required]="ERROR: enter the exact name of a Cinnamon Spices theme, the UUID shown on its page (for example: theme fetch CBlue)."
    [fetch_name_invalid]="ERROR: '%s' is not a Spices theme name (only letters, digits, dot, hyphen and underscore; up to 64 characters). Use the UUID shown on the theme's page, not its title."
    [fetch_curl_missing]="ERROR: 'curl' is required to download themes. Install it with your package manager (on Linux Mint: sudo apt install curl)."
    [fetch_already]="The theme '%s' is already at %s: nothing was downloaded. To download it again, delete that folder and repeat the command."
    [fetch_failed]="ERROR: could not download '%s' from Cinnamon Spices (is the name exact, capitals included? is there a connection?). Nothing was installed."
    [fetch_too_big]="ERROR: the download of '%s' is larger than %s MB and was discarded. Nothing was installed."
    [fetch_unpacked_big]="ERROR: the .zip of '%s' declares more than %s MB unpacked or more than %s files, or its size cannot be read, and it was discarded. Nothing was installed."
    [fetch_not_zip]="ERROR: what Spices returned for '%s' is not a .zip file. Nothing was installed."
    [fetch_structure]="ERROR: the .zip of '%s' does not hold the theme in a folder of that name, as Spices publishes it. Nothing was installed. If you download it by hand, use \"theme import\"."
    [fetch_apply_hint]="To use it: %s (or the Themes tab)"
    [theme_fetched_log]="Theme downloaded from Cinnamon Spices: %s → %s"
    [u_theme_fetch]="Download a Cinnamon Spices theme by its UUID (HTTPS only) and install it"
    [package_installing]="Installing %s... this may take a few minutes."
    [pkg_list_header]="Verified theme packages (checked on Ubuntu 24.04, the base of Linux Mint 22; they are apt packages).\nInstall one with: %s theme install <package>"
    [pkg_kind_gtk_cin]="GTK + Cinnamon" [pkg_kind_gtk]="GTK" [pkg_kind_icons]="Icons" [pkg_kind_cursors]="Cursor"
    [pkg_installed_mark]="(installed)"
    [package_required]="ERROR: enter the package (the list is in 'theme list-packages')."
    [package_unknown]="ERROR: '%s' is not in the verified list ('theme list-packages'). Only the packages of that list are installed."
    [package_apt_only]="ERROR: the verified list holds apt packages (Linux Mint, Ubuntu, Debian) and this system uses another manager. Look for the theme in your package manager, or use 'theme fetch' or 'theme import'."
    [package_already]="The package '%s' is already installed."
    [package_failed]="ERROR: '%s' was not installed. Nothing else was changed."
    [package_done]="Installed: %s. It now shows in the theme lists (Themes tab or 'theme list-*')."
    [theme_package_log]="Theme package installed: %s"
    [u_theme_list_packages]="Short list of verified theme packages (apt)"
    [u_theme_install]="Install one of those packages with apt (it asks for your sudo password)"
    [file_manager_missing]="No file manager was found (xdg-open/nemo/nautilus). Path: %s/.themes"
    [base_theme_not_found]="ERROR: base theme '%s' not found"
    [custom_theme_activation_failed]="ERROR: the color was saved to the custom theme, but Cinnamon could not activate it. Try 'Restore last backup' or check the log."
    [color_required]="ERROR: enter a color in #RRGGBB format."
    [hex_invalid]="ERROR: '%s' is not a valid hexadecimal color (use #RRGGBB)."
    [css_not_found]="ERROR: cinnamon.css not found in %s"
    [accent_warning]="WARNING: no dominant accent color was detected; no change was applied."
    [accent_applied]="Accent applied: %s -> %s (theme: %s)"
    [panel_bg_applied]="Panel background: %s -> %s (theme: %s)"
    [panel_fg_applied]="Panel text/icons: %s -> %s (theme: %s)"
    [menu_bg_applied]="Menu background: %s -> %s (theme: %s)"
    [menu_fg_applied]="Menu text: %s -> %s (theme: %s)"
    [tooltip_bg_applied]="Tooltip background: %s -> %s (theme: %s)"
    [tooltip_fg_applied]="Tooltip text: %s -> %s (theme: %s)"
    [color_reset_none]="No color customization is available to reset yet."
    [minty_none]="None (use the manual path below)"
    [gtk_accent_applied]="Global GTK accent applied: %s (affects GTK3 and libadwaita apps opened from now on; apps that are already open pick it up when reopened)"
    [gtk_accent_reset]="Global GTK accent reset (Color Mint override removed)"
    [gtk_accent_none]="No global GTK accent has been applied by Color Mint."
    [opacity_invalid]="ERROR: panel opacity must be an integer between 0 and 100."
    [opacity_applied]="Panel opacity set to %s%%"
    [opacity_warning]="WARNING: no background (rgba(...) or plain hexadecimal) was found in this theme's panel block; opacity may not have changed visually."
    [height_invalid]="ERROR: panel height must be an integer between 16 and 100."
    [height_applied]="Panel height set to %spx"
    [buttons_empty]="ERROR: window button layout is empty"
    [buttons_applied]="Window buttons applied: %s"
    [corners_applied]="Hot corners updated" [corners_invalid]="ERROR: invalid hot corner: %s"
    [effects_invalid]="ERROR: invalid value ('%s'). Use 'on' or 'off'."
    [window_effects_on]="Window effects enabled" [window_effects_off]="Window effects disabled"
    [menu_effects_on]="Menu effects enabled" [menu_effects_off]="Menu effects disabled"
    [workspaces_invalid]="ERROR: workspace count must be an integer between 1 and 20."
    [workspaces_applied]="Workspaces set to %s"
    [workspaces_dynamic]="WARNING: dynamic workspaces are on, so this number has no visible effect. Turn them off with: gsettings set org.cinnamon.muffin dynamic-workspaces false"
    [icons_shown]="Desktop icons shown" [icons_hidden]="Desktop icons hidden"
    [icons_invalid]="ERROR: invalid value ('%s'). Use 'show' or 'hide'."
    [desktop_bg_applied]="Desktop background: solid color %s (background image removed)"
    [desktop_bg_kept]="Desktop background: fallback color %s (current image kept)"
    [palette_name_required]="ERROR: enter the name of a palette (use 'terminal list' to see the available ones)."
    [palette_unknown]="Unknown palette: %s"
    [terminal_profile_missing]="No default gnome-terminal profile was found. Open Terminal once and try again."
    [palette_applied]="Palette '%s' applied to the default terminal profile."
    [terminal_color_invalid]="ERROR: '%s' is not a valid background color (use #RRGGBB)."
    [terminal_fg_invalid]="ERROR: '%s' is not a valid text color (use #RRGGBB)."
    [terminal_color_required]="ERROR: enter at least one color (background or text)."
    [terminal_custom_applied]="Custom terminal colors applied%s%s"
    [font_required]="ERROR: enter a font name (e.g. 'Noto Sans 10')." [font_name_invalid]="ERROR: the font name must not contain path separators, '..', or control characters."
    [font_applied]="Interface font applied: %s"
    [mono_required]="ERROR: enter the name of a monospace font."
    [mono_applied]="Monospace font applied: %s"
    [rendering_invalid]="ERROR: specify antialiasing <rgba|grayscale|none> and hinting <slight|medium|full|none>."
    [fonts_conf_failed]="ERROR: could not write %s/.config/fontconfig/fonts.conf" [file_write_failed]="ERROR: could not write '%s'" [link_refused]="ERROR: %s is a link and what it points to cannot be written (or it leads nowhere); it was left untouched."
    [rendering_applied]="Font rendering applied: antialiasing=%s, hinting=%s (some already-open apps may need to be reopened to see it)"
    [scaling_invalid]="ERROR: text scaling must be an integer between 50 and 200 (%)."
    [scaling_applied]="Text scaling set to %s%% (factor %s)"
    [preset_name_required]="ERROR: enter a preset name." [preset_invalid]="ERROR: the preset contains a disallowed format or value." [preset_save_failed]="ERROR: could not save the preset." [preset_load_failed]="ERROR: could not apply the preset."
    [preset_bad_line]="ERROR: line %s of the preset is not in the KEY=\"value\" format." [preset_unknown_key]="ERROR: line %s of the preset uses an unknown key: %s" [preset_bad_chars]="ERROR: line %s of the preset contains disallowed characters."
    [preset_rejected]="ERROR: the preset '%s' was not applied and nothing was changed:" [preset_problem_value]="  - %s: '%s' is not a valid value" [preset_problem_theme]="  - %s: '%s' is not installed" [preset_problem_cursor]="  - %s: '%s' is not a cursor theme (no cursors/ folder)" [preset_problem_group]="  - %s go together: set all of them or none"
    [preset_notes]="Notes on the preset '%s':" [preset_not_copied]="ERROR: the preset '%s' has problems and was not copied:" [cursor_inherited]="Notice: '%s' has no cursors of its own; the pointer will be the one it inherits or the system default."
    [preset_file_required]="ERROR: enter the preset file." [preset_file_missing]="ERROR: cannot read the preset '%s' (it must be a regular file)." [preset_exists]="ERROR: '%s' already exists; it is not overwritten." [preset_too_big]="ERROR: the preset is larger than 64 KB."
    [preset_exported]="Preset exported: %s" [preset_imported]="Preset imported as '%s'. Apply it with: preset load %s" [preset_imported_log]="Preset imported: %s"
    [preset_stopped]="ERROR: the preset stopped at %s; the earlier settings were already applied (restore the last backup to undo them)."
    [preset_name_invalid]="ERROR: a preset name cannot contain '/' or '..'."
    [preset_not_found]="Preset not found: %s"
    [ui_theme_file_required]="Choose a theme file or an already extracted folder to import."
    [ui_theme_import_error]="The theme could not be imported.\nCheck that the file uses a supported format (.zip, .tar.gz, .tar.xz, .tar.bz2)\nand has a valid theme structure (gtk-3.0/, cinnamon/, cursors/ or index.theme)."
    [ui_import_done]="It is now preselected in its dropdown — click \"Apply themes\" to use it"
    [ui_terminal_required]="Choose a palette or enable \"Use these custom colors\" before clicking \"Apply terminal\"."
    [ui_preset_name_required]="Enter a name before clicking \"Save preset\"."
    [ui_preset_choose]="Choose a preset from the list before clicking \"Load preset\"."
    [ui_backup_choose]="Choose a backup from the list before clicking \"Restore backup\"."
    [ui_backup_none]="There is no backup to restore yet.\nOne is created automatically before each change you apply from this window."
    [ui_backup_empty_entry]="(No backups yet)"
    [ui_backup_confirm]="Restore backup '%s'?\nThe current configuration will be overwritten, and any themes or\ngtk-3.0 settings added after that backup will be DELETED\n(not merely reverted)."
    [panel_position_applied]="Main panel moved to: %s" [theme_no_match]="(no match found in the theme; applied as an override)" [theme_restore_failed]="(⚠ could not reactivate the original theme: %s)" [ui_panel_reset_confirm]="Reset the panel to the original theme, removing the color customization\n(accent/background/text) applied so far?\nPanel opacity and height, which are independent settings, are not affected." [ui_backup_confirm_last]="Restore the latest backup (%s)?\nThe current configuration will be overwritten, and any themes or\ngtk-3.0 settings added after that backup will be DELETED\n(not merely reverted)."
    [position_invalid]="ERROR: invalid position ('%s'). Use 'top' or 'bottom'."
    [report_failed]="was not applied" [warning_suffix]="with warnings"
    [keep_custom_layout]="Keep current custom layout (Advanced tab)" [official_mint_color]="Official Mint-Y color: %s (%s)" [report_gtk_theme]="GTK theme: %s" [report_icon_theme]="Icon theme: %s" [report_cinnamon_theme]="Cinnamon theme: %s" [report_cursor_theme]="Cursor theme: %s" [report_panel_position]="Panel position: %s" [report_opacity]="Opacity: %s%%" [report_height]="Height: %spx" [report_desktop_bg]="Desktop background: %s (%s)" [report_window_buttons]="Window buttons: %s" [report_window_effects]="Window effects: %s" [report_menu_effects]="Menu effects: %s" [report_workspaces]="Workspaces: %s" [report_desktop_icons]="Desktop icons: %s" [report_hotcorners]="Hot corners: %s / %s / %s / %s" [report_custom_buttons]="Window buttons (custom): %s" [report_libadwaita_on]="libadwaita style: the GTK theme's gtk-4.0" [report_libadwaita_off]="libadwaita style: libadwaita's own" [report_palette]="Color palette: %s" [report_terminal_custom]="Custom terminal colors" [report_font]="Interface font: %s" [report_mono]="Monospace font: %s" [report_rendering]="Rendering: %s / %s" [report_scaling]="Text scaling: %s%%"
    [backup_restore_done]="Backup restored: %s"
    [reset_colors_summary]="Colors reset" [reset_colors_original_theme]=" (original theme: %s)" [reset_colors_gtk_included]=", global GTK accent included"
    [cinnamon_reload_request]="Requesting Cinnamon restart" [cinnamon_reload_dbus_fail]="No D-Bus restart call worked; trying 'cinnamon --replace'" [cinnamon_reload_fail]="Could not restart Cinnamon by any method (non-Cinnamon session?)" [backup_created]="Backup created at %s" [backup_restored_log]="Backup restored: %s" [theme_imported_log]="Theme imported: %s -> %s" [preset_saved_log]="Preset saved: %s" [preset_loaded_log]="Preset loaded: %s" [app_started]="Starting Color Mint" [app_closed]="Color Mint closed"
    [light_mode]="Light" [dark_mode]="Dark" [cursor_size_report]="Cursor size: %spx (if the change is not visible immediately, you may need to log out — see note)"
    [theme_imported]="Theme imported" [path_detail]="Path: %s" [applied_themes]="Themes applied" [panel_updated]="Panel updated" [colors_reset]="Panel colors reset" [backup_restored]="Backup restored" [desktop_updated]="Desktop updated" [advanced_updated]="Advanced settings updated" [terminal_updated]="Terminal updated" [fonts_updated]="Font settings updated" [preset_saved]="Preset saved" [preset_loaded]="Preset loaded" [backup_name_detail]="Name: %s" [file_detail]="File: %s" [preset_load_detail]="Themes, colors, panel, desktop, terminal and font settings saved in that preset were applied."
    [apply_themes]="Apply themes" [import_theme]="Import theme" [ui_themes_text]="<span size='x-large' weight='bold'>Change how your desktop looks</span>\nTwo ways to change the look — use one or the other; you do not need to fill both.\nThe easy path takes precedence when provided." [ui_themes_easy]="<b>✅  Easy path — official Mint color</b> (recommended)" [ui_official_color]="Official color" [ui_light_dark]="Light or dark" [ui_themes_manual]="<b>🔧  Manual path</b> — choose each piece (optional)" [ui_gtk_theme]="GTK theme" [ui_icons]="Icons" [ui_cinnamon]="Cinnamon (panel and menus)" [ui_cursor_always]="<b>🖱️  Cursor</b> — always applied with either path" [ui_cursor]="Cursor" [ui_cursor_size]="Cursor size (px)" [ui_import_theme]="<b>📁  More themes</b> (optional)" [ui_theme_file]="File (.zip/.tar.gz/.tar.xz/.tar.bz2)" [ui_theme_dir]="Or an already extracted folder"
    [more_themes]="Get more themes..." [cancel]="Cancel"
    [ui_more_title]="Get more themes"
    [ui_more_text]="Install a theme pack from your system's software sources\n(it asks for your password), or download one from Cinnamon Spices\nby typing its name: the end of its page address, capitals included,\nas in .../themes/view/<b>Nocturne</b>"
    [ui_more_text_web]="Download a theme from Cinnamon Spices by typing its name:\nthe end of its page address, capitals included,\nas in .../themes/view/<b>Nocturne</b>"
    [ui_more_pack]="Theme pack" [ui_more_none]="None" [ui_more_spices]="Cinnamon Spices name" [ui_more_get]="Get"
    [ui_more_nothing]="Choose a theme pack or type a Cinnamon Spices name first."
    [ui_more_wait]="Downloading %s from Cinnamon Spices...\nThis window closes by itself."
    [ui_more_failed]="The theme could not be obtained" [ui_more_fetched]="Theme downloaded" [ui_more_installed]="Theme pack installed"
    [ui_more_package]="Package: %s" [ui_more_in_lists]="It now shows in the dropdowns — choose it and click \"Apply themes\""
    [apply_panel]="Apply panel" [reset_colors]="Reset colors" [restore_last_backup]="Restore last backup" [ui_panel_text]="<span size='x-large' weight='bold'>Color the panel and menus</span>\n1) Choose what to color.\n2) Pick a quick color or your own.\n3) \"Apply panel\". Repeat for another part." [ui_panel_target]="What do you want to color?" [ui_quick_color]="Quick color (optional)" [ui_custom_color]="Or your own color" [ui_panel_size]="<b>📐  Panel size</b>" [ui_opacity]="Opacity (%)" [ui_height]="Height (px)"
    [apply_desktop]="Apply desktop" [ui_desktop_text]="<span size='x-large' weight='bold'>Set the desktop up your way</span>\nThe most common settings: panel, window buttons, effects, workspaces and background.\nHot corners and custom buttons are in \"Advanced\"." [ui_desktop_panel_buttons]="<b>🪟  Panel and window buttons</b>" [ui_panel_position]="Panel position" [ui_window_buttons]="Window buttons" [ui_effects_workspaces]="<b>✨  Effects and workspaces</b>" [ui_window_effects]="Window effects" [ui_menu_effects]="Menu effects" [ui_workspaces]="Workspaces" [ui_desktop_icons]="Desktop icons" [ui_desktop_bg]="<b>🎨  Desktop background</b>" [ui_bg_color]="Background color" [ui_mode]="Mode"
    [apply_advanced]="Apply advanced" [ui_advanced_text]="<span size='x-large' weight='bold'>Finer adjustments</span>\nHot corners, custom buttons and libadwaita apps. For common settings, use the \"Desktop\" tab." [ui_hotcorners]="<b>🖱️  Hot corners</b> — move the pointer to a corner to trigger the action" [ui_top_left]="Top left" [ui_top_right]="Top right" [ui_bottom_left]="Bottom left" [ui_bottom_right]="Bottom right" [ui_custom_buttons]="<b>🔘  Custom window buttons</b> (optional)" [ui_custom_string]="Custom string:" [ui_button_values]="Values: close, minimize, maximize, spacer, menu, stick, above, lower, shade  ·  \":\" separates left/right" [ui_libadwaita]="<b>🔗  libadwaita apps</b> — newer GNOME apps" [ui_libadwaita_use]="Let them use the GTK theme's gtk-4.0 style" [ui_libadwaita_hint]="💡 These apps ignore the GTK theme. If the theme has a gtk-4.0 style, the box gives it to them.\nApps that are already open pick it up when reopened."
    [apply_terminal]="Apply terminal" [ui_terminal_text]="<span size='x-large' weight='bold'>Give your terminal some color</span>\nChoose a ready-made palette, or define your own background and text colors." [ui_palette]="Color palette" [ui_terminal_custom]="<b>🎨  Custom</b> (optional, overrides the palette above)" [ui_background]="Background" [ui_text_color]="Text" [ui_use_custom]="Use these custom colors" [ui_color_hint]="💡 The color picker always starts with a default color: enable the checkbox above only if you want to apply Background/Text."
    [apply_fonts]="Apply fonts" [ui_fonts_text]="<span size='x-large' weight='bold'>Choose how text reads</span>\nInterface and monospace fonts, rendering and text scaling." [ui_typography]="<b>🔤  Typography</b>" [ui_interface]="Interface" [ui_monospace]="Monospace" [ui_rendering]="<b>🖌️  Rendering</b>" [ui_antialias]="Antialiasing" [ui_hinting]="Hinting" [ui_font_hint]="💡 Saved to ~/.config/fontconfig/fonts.conf. Already-open apps may need to be reopened." [ui_scaling]="<b>🔍  Scaling</b>" [ui_text_scaling]="Text scaling (%)"
    [save]="Save" [load]="Load" [restore]="Restore" [ui_profiles_text]="<span size='x-large' weight='bold'>Save and restore your setup</span>\nSave the current state as a named preset, load a saved one, or restore an automatic backup." [ui_save_preset]="<b>💾  Save preset</b>" [ui_new_name]="New name:" [default_preset_name]="my-preset" [ui_load_preset]="<b>📂  Load preset</b>" [ui_saved_preset]="Saved preset" [ui_restore_backup]="<b>♻️  Restore backup</b>" [ui_available_backup]="Available backup"
    [gui_tab_themes]="🎨  Themes" [gui_tab_panel]="🖥️  Panel" [gui_tab_desktop]="🪟  Desktop" [gui_tab_advanced]="🧩  Advanced" [gui_tab_terminal]="⌨️  Terminal" [gui_tab_fonts]="🔤  Fonts" [gui_tab_profiles]="💾  Profiles"
    [usage_title]="Color Mint v%s — advanced visual customization for Linux Mint 22.3 Cinnamon (by %s)" [usage_graphical]="GRAPHICAL MODE (recommended)" [usage_graphical_desc]="Open the graphical interface" [usage_same_gui]="Same as running without arguments" [usage_terminal]="TERMINAL MODE — one command per setting, without opening the graphical interface" [usage_language]="🌐 Language" [usage_language_desc]="Switch between Spanish and English and save the choice" [usage_themes]="🎨 Themes" [usage_panel]="🖥️ Panel" [usage_desktop]="🪟 Desktop" [usage_terminal_section]="⌨️ Terminal" [usage_fonts]="🔤 Fonts" [usage_backups]="💾 Backups and presets" [usage_data]="Data, backups, presets and logs live in:"
    [u_theme_mint]="Quick path: official Mint-Y package (claro = light, oscuro = dark)" [u_theme_gtk]="GTK theme" [u_theme_icon]="Icon theme" [u_theme_cursor]="Cursor theme" [u_theme_cursor_size]="Cursor size, in pixels" [u_theme_cinnamon]="Cinnamon theme (panel and menus)" [u_theme_libadwaita]="libadwaita apps use the GTK theme's gtk-4.0 style" [u_theme_import]="Install a downloaded theme (.zip/.tar.gz/.tar.xz/.tar.bz2)" [u_theme_folder]="Open the themes folder" [u_theme_list_gtk]="Installed GTK themes" [u_theme_list_icon]="Installed icon themes" [u_theme_list_cursor]="Installed cursor themes" [u_theme_list_cinnamon]="Installed Cinnamon themes" [u_theme_list_mint]="Available official Mint-Y colors (claro = light, oscuro = dark)"
    [u_panel_part]="Color a panel part — <part> is one of:" [u_panel_keys1]="accent, bg, fg, menu-bg, menu-fg," [u_panel_keys2]="tooltip-bg, tooltip-fg, gtk-accent (accent in GTK3/libadwaita apps)" [u_panel_opacity]="Panel opacity, in %" [u_panel_height]="Panel height, in pixels" [u_panel_reset]="Remove panel color customization"
    [u_desktop_position]="Panel at the top or bottom" [u_desktop_buttons]="Window buttons" [u_desktop_list_buttons]="List button presets" [u_desktop_hotcorners]="Hot corner: none, expo, scale or desktop" [u_desktop_effects]="Effects when opening/closing windows" [u_desktop_menu_effects]="Effects when opening menus" [u_desktop_workspaces]="Number of workspaces" [u_desktop_icons]="Desktop icons" [u_desktop_bg]="Background color (mantener = keep the current image, solo_color = solid color only)"
    [u_terminal_apply]="Apply a ready-made color palette" [u_terminal_list]="List available palettes" [u_terminal_custom]="Custom colors (either can be empty: \"\")"
    [u_fonts_font]="Interface font" [u_fonts_mono]="Monospace font (terminal, editors)" [u_fonts_rendering]="Antialiasing and hinting" [u_fonts_scaling]="Text scaling, in %"
    [u_backup_create]="Create a backup now" [u_backup_list]="List backups" [u_backup_restore]="Restore a backup" [u_preset_save]="Save the current state as a preset" [u_preset_list]="List saved presets" [u_preset_load]="Apply a saved preset" [u_preset_export]="Export a preset to a file" [u_preset_import]="Import a preset (does not apply it)"
    [unknown_tab]="Unknown internal tab: %s" [unknown_apply]="Unknown internal application mode: %s"
    [cinnamon_env_warning]="Notice: XDG_CURRENT_DESKTOP is not set. If you are not in a Cinnamon session, some options will have no effect."
    [not_cinnamon_session]="ERROR: Color Mint only works in a Cinnamon session, and this one is \"%s\".\nNothing was changed."
    [unknown_command]="Unknown command: %s" [unknown_option]="Unrecognized option for '%s': %s" [help_hint]="See '%s --help' → section %s."
    [unknown_failure]="unknown failure" [value_empty]="empty" [terminal_bg_part]=" — background: %s" [terminal_fg_part]=" — text: %s"
    [original_failed]="ERROR: could not save the original look of the desktop; nothing was changed." [original_logged]="Original look saved in %s"
    [usage_install]="📦 Installation" [u_install]="Add Color Mint to the applications menu (copies the script to ~/.local/bin and creates the launcher)" [launcher_comment]="Advanced visual customization for Linux Mint Cinnamon"
    [install_done]="Color Mint installed in %s\nMenu launcher: %s" [install_path_hint]="Note: %s is not in PATH; it is added when you open a new session." [install_unsafe_home]="ERROR: the path '%s' has characters a launcher cannot hold (quotes, \$, %%, backslash or control characters)."
    [install_failed]="ERROR: could not install %s" [install_script_unreadable]="ERROR: cannot read the script '%s'." [install_foreign]="ERROR: '%s' already exists and is not Color Mint's; it is not overwritten."
    [uninstall_nothing]="There is nothing of Color Mint to uninstall." [uninstall_plan]="Color Mint will be uninstalled:" [uninstall_plan_menu]="  - The menu launcher and the program copy are removed."
    [uninstall_plan_keep_look]="  - The desktop keeps its current look." [uninstall_plan_restore]="  - The desktop goes back to the look it had before Color Mint's first change." [uninstall_plan_prior]="  - Note: Color Mint had been used before that look was saved, so it may not be the factory one."
    [uninstall_plan_no_original]="  - Color Mint has not changed the desktop: there is no look to restore."
    [marked_block_open]="ERROR: %s has the opening marker of a Color Mint block without its closing one, so it was left untouched. Delete it by hand: that line and what Color Mint wrote under it."
    [uninstall_block_open]="Leaving %s: a Color Mint block has no closing marker. Delete it by hand: the opening line and what Color Mint wrote under it."
    [uninstall_plan_no_original_prior]="  - Color Mint was used before the original look could be saved: there is nothing to restore and the desktop keeps its current look. To go back, use 'backup restore' first (see 'backup list')." [uninstall_plan_keep_config]="  - Presets, backups and settings are kept in %s." [uninstall_plan_drop_config]="  - Presets, backups, logs and settings in %s are deleted."
    [uninstall_prompt]="Continue? [y/N]: " [uninstall_need_yes]="ERROR: there is no terminal to ask on; repeat the command with --yes." [uninstall_cancelled]="Cancelled: nothing was changed."
    [uninstall_dconf_failed]="ERROR: could not restore the desktop settings; nothing else was removed. Repeat the command once that is solved." [uninstall_no_dconf]="Note: dconf was not available when the original look was saved; only files are restored." [uninstall_failed_item]="ERROR: could not remove %s."
    [uninstall_kept_other]="Leaving %s: Color Mint did not record it as its own; delete it by hand if you do not want it."
    [uninstall_kept_link]="Leaving %s: it is a link, and the file it points to still holds what Color Mint wrote there; delete those lines by hand if you do not want them." [uninstall_kept_home]="Keeping %s: it holds files Color Mint did not create, or it is outside your home folder."
    [uninstall_apt_note]="Packages Color Mint installed with apt (not removed automatically): %s\nTo remove them: sudo apt-get remove %s" [uninstall_relogin]="Log out and back in so the cursor and the fonts finish changing." [uninstall_done]="Color Mint uninstalled." [uninstall_incomplete]="The uninstall did not finish; repeat the command to complete it."
    [u_uninstall]="Remove the launcher and the copy. --restore-look: back to the original look; --keep-config: keep presets and backups; --yes: do not ask"
)

cm_apply_language_labels() {
    CM_MINTY_NONE_LABEL="$(cm_t minty_none)"
    if [ "$CM_LANG" = "en" ]; then
        CM_ACCENT_PRESET_LABELS=(
            [custom]="Custom (use the color picker)" [nord]="Nord Frost" [mint]="Mint Green"
            [dracula]="Dracula Purple" [gruvbox]="Gruvbox Amber" [solarized]="Solarized Blue"
            [rose-pine]="Rosé Pine" [crimson]="Crimson" [forest]="Forest"
            [catppuccin]="Catppuccin Mocha" [tokyo-night]="Tokyo Night" [one-dark]="One Dark"
            [monokai]="Monokai" [cyberpunk]="Cyberpunk Neon" [sakura]="Sakura Pink"
            [lavender]="Pastel Lavender" [amber]="Warm Amber" [turquoise]="Turquoise" [emerald]="Emerald"
        )
        CM_COLOR_TARGET_LABELS=([accent]="Accent (highlights, checkboxes and links)" [bg]="Panel background" [fg]="Panel text and icons" [menu_bg]="Menu background" [menu_fg]="Menu text" [tooltip_bg]="Tooltip background" [tooltip_fg]="Tooltip text" [gtk_accent]="Accent in GTK3/libadwaita apps (not only the panel)")
        CM_BUTTON_PRESET_LABELS=([derecha]="Right: minimize, maximize, close" [izquierda]="Left: close, maximize, minimize" [gnome]="Close only (GNOME style)" [mac-clasico]="Classic Mac (close on the left)" [compacto]="Compact: minimize and close (no maximize)" [menu-izquierda]="Menu on the left + minimize/maximize/close" [solo-cerrar-izquierda]="Close only (on the left)")
        CM_CORNER_LABELS=([none]="None (disabled)" [expo]="Workspace overview (Expo)" [scale]="Window overview (Scale)" [desktop]="Show desktop")
        CM_BGMODE_LABELS=([mantener]="Keep current image" [solo_color]="Solid color only")
        CM_PANELPOS_LABELS=([bottom]="Bottom" [top]="Top")
        CM_ONOFF_LABELS=([on]="Enabled" [off]="Disabled")
        CM_SHOWHIDE_LABELS=([show]="Show" [hide]="Hide")
        CM_PALETTE_LABELS=([nord]="Nord" [dracula]="Dracula" [gruvbox]="Gruvbox" [solarized-dark]="Solarized Dark" [solarized-light]="Solarized Light" [monokai]="Monokai" [one-dark]="One Dark" [tokyo-night]="Tokyo Night" [catppuccin-mocha]="Catppuccin Mocha")
        CM_ANTIALIAS_LABELS=([rgba]="RGBA" [grayscale]="Grayscale" [none]="None")
        CM_HINTING_LABELS=([slight]="Slight" [medium]="Medium" [full]="Full" [none]="None")
    else
        CM_ACCENT_PRESET_LABELS=(
            [custom]="Personalizado (usa el selector de color)" [nord]="Nord Frost" [mint]="Mint Verde"
            [dracula]="Dracula Púrpura" [gruvbox]="Gruvbox Ámbar" [solarized]="Solarized Azul"
            [rose-pine]="Rosé Pine" [crimson]="Carmesí" [forest]="Bosque"
            [catppuccin]="Catppuccin Mocha" [tokyo-night]="Tokyo Night" [one-dark]="One Dark"
            [monokai]="Monokai" [cyberpunk]="Cyberpunk Neón" [sakura]="Sakura Rosa"
            [lavender]="Lavanda Pastel" [amber]="Ámbar Cálido" [turquoise]="Turquesa"
            [emerald]="Esmeralda"
        )
        CM_COLOR_TARGET_LABELS=([accent]="Acento (resaltados, casillas y enlaces)" [bg]="Fondo del panel" [fg]="Texto e iconos del panel" [menu_bg]="Fondo de los menús" [menu_fg]="Texto de los menús" [tooltip_bg]="Fondo de los globos de ayuda" [tooltip_fg]="Texto de los globos de ayuda" [gtk_accent]="Acento en apps GTK3/libadwaita (no solo el panel)")
        CM_BUTTON_PRESET_LABELS=([derecha]="Derecha: minimizar, maximizar, cerrar" [izquierda]="Izquierda: cerrar, maximizar, minimizar" [gnome]="Solo cerrar (estilo GNOME)" [mac-clasico]="Mac clásico (cerrar a la izquierda)" [compacto]="Compacto: minimizar y cerrar (sin maximizar)" [menu-izquierda]="Menú a la izquierda + minimizar/maximizar/cerrar" [solo-cerrar-izquierda]="Solo cerrar (a la izquierda)")
        CM_CORNER_LABELS=([none]="Ninguna (desactivada)" [expo]="Vista de espacios de trabajo (Expo)" [scale]="Vista de ventanas (Scale)" [desktop]="Mostrar escritorio")
        CM_BGMODE_LABELS=([mantener]="Mantener imagen actual" [solo_color]="Solo color sólido")
        CM_PANELPOS_LABELS=([bottom]="Abajo" [top]="Arriba")
        CM_ONOFF_LABELS=([on]="Activados" [off]="Desactivados")
        CM_SHOWHIDE_LABELS=([show]="Mostrar" [hide]="Ocultar")
        CM_PALETTE_LABELS=([nord]="Nord" [dracula]="Dracula" [gruvbox]="Gruvbox" [solarized-dark]="Solarized Oscuro" [solarized-light]="Solarized Claro" [monokai]="Monokai" [one-dark]="One Dark" [tokyo-night]="Tokyo Night" [catppuccin-mocha]="Catppuccin Mocha")
        CM_ANTIALIAS_LABELS=([rgba]="RGBA" [grayscale]="Escala de grises" [none]="Ninguno")
        CM_HINTING_LABELS=([slight]="Leve" [medium]="Medio" [full]="Completo" [none]="Ninguno")
    fi
    local k
    for k in "${!CM_ACCENT_PRESET_HEX[@]}"; do
        CM_ACCENT_PRESET_LABELS[$k]+=" — ${CM_ACCENT_PRESET_HEX[$k]}"
    done
}

# Reorder a list so "$1" (the value currently applied) comes first, because
# YAD preselects the first item of a :CB. A non-empty "$1" is prepended even if
# it is not in the list, to reflect the real system value.
cm_reorder_current_first() {
    local current="$1"; shift
    local -a rest=()
    local it
    for it in "$@"; do
        [ "$it" = "$current" ] && continue
        rest+=("$it")
    done
    if [ -n "$current" ]; then
        printf '%s\n' "$current" "${rest[@]}"
    else
        printf '%s\n' "${rest[@]}"
    fi
}

# ============================================================================
# deps — dependency check and installation (GUI mode only)
# ============================================================================
# Package manager of the running system. Only apt installs from here (the flow below); on the
# others the exact command is shown for the user to run, since the package names are distro-specific.
cm_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then printf 'apt'
    elif command -v dnf >/dev/null 2>&1; then printf 'dnf'
    elif command -v pacman >/dev/null 2>&1; then printf 'pacman'
    elif command -v zypper >/dev/null 2>&1; then printf 'zypper'
    fi
}

# cm_pkg_name <manager> <command>: package that provides a command this program needs.
cm_pkg_name() {
    case "$2" in
        dconf)            case "$1" in apt) printf 'dconf-cli' ;; *) printf 'dconf' ;; esac ;;
        gsettings|gdbus)  case "$1" in apt) printf 'libglib2.0-bin' ;; zypper) printf 'glib2-tools' ;; *) printf 'glib2' ;; esac ;;
        *)                printf '%s' "$2" ;;
    esac
}

# cm_pkg_install_line <manager> <package>...: the command that installs them.
cm_pkg_install_line() {
    local pm="$1"; shift
    case "$pm" in
        apt)    printf 'sudo apt-get update && sudo apt-get install -y %s' "$*" ;;
        dnf)    printf 'sudo dnf install -y %s' "$*" ;;
        pacman) printf 'sudo pacman -S --needed %s' "$*" ;;
        zypper) printf 'sudo zypper install %s' "$*" ;;
    esac
}

# Missing dependencies on a system where this program does not install them: say exactly what to run.
cm_deps_manual() {
    local pm="$1" msg cmd pkg; shift
    local -a pkgs=()
    if [ -n "$pm" ]; then
        for cmd in "$@"; do pkgs+=("$(cm_pkg_name "$pm" "$cmd")"); done
        mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)
        pkg=$(cm_pkg_install_line "$pm" "${pkgs[@]}")
        msg=$(printf "$(cm_t deps_manual_cmd)" "$*" "$pkg")
    else
        msg=$(printf "$(cm_t deps_manual_unknown)" "$*")
    fi
    if [ -t 0 ]; then
        printf '%s\n' "$msg" >&2
    elif command -v yad >/dev/null 2>&1; then
        yad --error --no-markup --title="Color Mint" --text="$msg" --button="$(cm_t 'done'):0" 2>/dev/null
    else
        cm_notify "Color Mint" "$msg"
    fi
}

# cm_apt_install_run <yes: 1|0> <notice> <package>...: sudo apt-get update, then install, in this terminal when there
# is one and otherwise in a terminal window that reports how it went through a file. One flow for the dependencies
# of the GUI (yes = 1) and for the theme packages (yes = 0: apt shows what it will install and asks first).
# Exit status: 0 apt succeeded, 1 apt failed, 2 no work folder, 3 no terminal to run it in, 4 gave up waiting.
cm_apt_install_run() {
    local yes="$1" notice="$2" cmd sentinel sentinel_dir install_rc waited=0 max_wait="${CM_INSTALL_MAX_WAIT:-600}"
    shift 2
    # shellcheck disable=SC2016  # the command is text for a bash that expands "$@" itself
    cmd='sudo apt-get update && sudo apt-get install "$@"'
    # shellcheck disable=SC2016
    [ "$yes" -eq 1 ] && cmd='sudo apt-get update && sudo apt-get install -y "$@"'
    if [ -t 0 ]; then
        bash -c "$cmd" bash "$@" && return 0
        return 1
    fi
    command -v x-terminal-emulator >/dev/null 2>&1 || return 3
    sentinel_dir=$(mktemp -d "${CM_HOME:-/tmp}/.install-wait.XXXXXX") || return 2
    sentinel="$sentinel_dir/status"
    cm_notify "Color Mint" "$notice"
    CM_INSTALL_SENTINEL="$sentinel" CM_INSTALL_CLOSE="$(cm_t install_terminal_close)" x-terminal-emulator -e bash -c \
        "$cmd"'; rc=$?; printf "%s\n" "$rc" > "$CM_INSTALL_SENTINEL"; echo; read -rp "$CM_INSTALL_CLOSE"' \
        bash "$@" &
    while [ ! -f "$sentinel" ] && [ "$waited" -lt "$max_wait" ]; do   # 10-minute cap
        sleep 1
        waited=$((waited + 1))
    done
    if [ ! -f "$sentinel" ]; then
        rm -rf -- "$sentinel_dir" 2>/dev/null || true
        return 4
    fi
    install_rc=$(cat "$sentinel" 2>/dev/null || echo 1)
    [[ "$install_rc" =~ ^[0-9]+$ ]] || install_rc=1
    rm -rf -- "$sentinel_dir" 2>/dev/null || true
    [ "$install_rc" -eq 0 ]
}

cm_check_dependencies() {
    local missing=() cmd m
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        return 0
    fi

    local pm
    pm=$(cm_pkg_manager)
    if [ "$pm" != apt ]; then
        cm_deps_manual "$pm" "${missing[@]}"
        exit 1
    fi

    local resp=""
    if [ -t 0 ]; then
        printf '%s\n' "$(printf "$(cm_t missing_deps_tty)" "${missing[*]}")"
        read -rp "$(cm_t install_prompt)" resp
    elif command -v yad >/dev/null 2>&1; then
        if yad --question --title="Color Mint" \
             --text="$(printf "$(cm_t missing_deps_gui)" "${missing[*]}")" \
             --button="$(cm_t yes):0" --button="$(cm_t no):1" 2>/dev/null; then
            resp="s"
        fi
    else
        cm_notify "Color Mint" "$(printf "$(cm_t missing_deps_notify)" "${missing[*]}" "${missing[*]}")"
        exit 1
    fi

    if [[ "$resp" =~ ^[sSyY]$ ]]; then
        local pkgs=()
        for m in "${missing[@]}"; do
            pkgs+=("$(cm_pkg_name apt "$m")")
        done
        mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)

        local install_rc=0
        cm_apt_install_run 1 "$(printf "$(cm_t deps_installing)" "${pkgs[*]}")" "${pkgs[@]}" || install_rc=$?
        case "$install_rc" in
            2) cm_notify "Color Mint" "$(cm_t tempdir_failed)"; exit 1 ;;
            3) cm_notify "Color Mint" "$(printf "$(cm_t no_terminal_install)" "${pkgs[*]}")"; exit 1 ;;
            4) cm_notify "Color Mint" "$(cm_t deps_timeout)"; exit 1 ;;
        esac
    else
        if [ -t 0 ]; then
            printf '%s\n' "$(printf "$(cm_t deps_continue_fail)" "${missing[*]}")"
        fi
        exit 1
    fi

    local still_missing=()
    for cmd in "${missing[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || still_missing+=("$cmd")
    done
    if [ ${#still_missing[@]} -gt 0 ]; then
        cm_notify "Color Mint" "$(printf "$(cm_t deps_failed)" "${still_missing[*]}" "${still_missing[*]}")"
        exit 1
    fi

    return 0
}

# ============================================================================
# backup — backup and restore
#
# Only the Apply buttons of the GUI (cm_ui_backup_before_apply) and `backup create` call cm_backup_current;
# the CLI setters do not. A backup dumps the dconf paths in CM_DCONF_DUMPS and copies ~/.themes,
# ~/.config/gtk-3.0 and fonts.conf. For the other files Color Mint writes (cm_look_files) it records in look.txt
# whether each existed and keeps in look_<tag>.part the Color Mint block of ~/.Xresources and the two gtk.css files,
# or the whole environment.d file: a restore puts back that block or file and leaves the user's other lines alone. A
# backup made before look.txt existed does not touch them. It does not copy ~/.icons, and the folders a restore may
# have created (gtk-4.0, environment.d) stay, empty if need be.
# ============================================================================
# Stage a directory snapshot under the target parent without touching the target.
cm_stage_restore_dir() {
    local snapshot="$1" target="$2" parent stage
    [ -d "$snapshot" ] || return 0
    parent="${target%/*}"; [ "$parent" = "$target" ] && parent="."
    mkdir -p -- "$parent" 2>/dev/null || return 1
    stage=$(mktemp -d "$parent/.color-mint-restore-stage.XXXXXX") || return 1
    if ! cp -a -- "$snapshot/." "$stage/" 2>/dev/null; then
        rm -rf -- "$stage" 2>/dev/null || true
        return 1
    fi
    printf '%s' "$stage"
}

cm_stage_restore_file() {
    local snapshot="$1" target="$2" parent base stage mode
    [ -f "$snapshot" ] || return 0
    parent="${target%/*}"; [ "$parent" = "$target" ] && parent="."
    base="${target##*/}"
    mkdir -p -- "$parent" 2>/dev/null || return 1
    mode=$(stat -c '%a' -- "$snapshot" 2>/dev/null || echo 0644)
    stage=$(mktemp "$parent/.${base}.restore-stage.XXXXXX") || return 1
    if ! cm_atomic_write "$stage" "$mode" < "$snapshot"; then
        rm -f -- "$stage" 2>/dev/null || true
        return 1
    fi
    printf '%s' "$stage"
}

# The dconf paths Color Mint can change, each with the file that holds its dump in a backup and in the
# original snapshot. A backup made before a path was listed has no file for it, and that path is skipped.
CM_DCONF_DUMPS=(
    "/org/cinnamon/|dconf_cinnamon.ini"
    "/org/gnome/desktop/interface/|dconf_gnome_interface.ini"
    "/org/gnome/terminal/|dconf_gnome_terminal.ini"
    "/org/nemo/|dconf_nemo.ini"
    "/org/x/apps/portal/|dconf_xapp_portal.ini"
)

# cm_dconf_dump_all <dir>: one dump file per path.
cm_dconf_dump_all() {
    local dir="$1" item
    for item in "${CM_DCONF_DUMPS[@]}"; do
        dconf dump "${item%%|*}" | cm_atomic_write "$dir/${item#*|}" || return 1
    done
}

# "section/key" for each key of a dconf dump read from stdin (the root section is "[/]").
cm_dconf_dump_keys() {
    awk '/^\[/ { s = substr($0, 2, length($0) - 2); next }
         /^[^=[:space:]][^=]*=/ { k = $0; sub(/=.*/, "", k); print (s == "/" ? "" : s "/") k }'
}

# cm_dconf_load_all <dir>: put every path that has a dump in <dir> back exactly as dumped. "dconf load"
# only writes the keys in the dump (measured with dconf 1.40: a key set afterwards stays), so the keys
# the dump lacks are reset first, one by one: no moment with the whole path at its defaults.
cm_dconf_load_all() {
    local dir="$1" item path file now key
    for item in "${CM_DCONF_DUMPS[@]}"; do
        path="${item%%|*}"; file="$dir/${item#*|}"
        [ -f "$file" ] || continue
        now=$(dconf dump "$path") || return 1
        while IFS= read -r key; do
            dconf reset "$path$key" 2>/dev/null || return 1
        done < <(comm -13 <(cm_dconf_dump_keys < "$file" | LC_ALL=C sort -u) \
                          <(printf '%s\n' "$now" | cm_dconf_dump_keys | LC_ALL=C sort -u))
        dconf load "$path" < "$file" 2>/dev/null || return 1
    done
}

# cm_snapshot_dir <source> <dest>: copy the contents of a folder into a new plain folder. "cp -a <folder> <dest>" copies a
# folder that is a link (a dotfile manager's) as a link, and the snapshot would then follow the live folder; with
# "<folder>/." the link is followed once and the links inside the folder stay links.
cm_snapshot_dir() {
    mkdir -- "$2" 2>/dev/null && cp -a -- "$1/." "$2/" 2>/dev/null
}

# cm_block_extract <file> <begin> <end>: the lines from the begin marker to the end marker, both included.
cm_block_extract() {
    awk -v b="$2" -v e="$3" '$0 == b { on = 1 } on { print } $0 == e { on = 0 }' "$1"
}

# cm_backup_look <dir>: write look.txt ("<tag>=0|1", whether the file existed) and, for each file that did, look_<tag>.part
# (see the header above). A file that is neither absent nor a readable file (a broken link), or whose block is not
# closed, is left out of look.txt, and a restore leaves it alone. fonts.conf is saved by the caller; only its state is here.
cm_backup_look() {
    local dir="$1" tag path begin end
    while IFS='|' read -r tag path; do
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then
            printf '%s=0\n' "$tag"
            continue
        fi
        [ -f "$path" ] || continue
        case "$tag" in
            fonts) ;;
            envd)  cp -- "$path" "$dir/look_$tag.part" || return 1 ;;
            *)
                { IFS= read -r begin; IFS= read -r end; } < <(cm_look_block_marks "$tag")
                cm_marked_block_ok "$path" "$begin" "$end" || continue
                cm_block_extract "$path" "$begin" "$end" > "$dir/look_$tag.part" || return 1
                ;;
        esac
        printf '%s=1\n' "$tag"
    done < <(cm_look_files) | cm_atomic_write "$dir/look.txt"
}

cm_backup_current() {
    mkdir -p "$CM_BACKUP_DIR"
    cm_lock || { printf '%s\n' "$(cm_t backup_create_failed)" >&2; return 1; }

    local ts dest work
    ts="$(date '+%Y%m%d_%H%M%S')"
    dest="$CM_BACKUP_DIR/backup_$ts"
    local suffix=1
    while [ -e "$dest" ]; do
        dest="$CM_BACKUP_DIR/backup_${ts}_$suffix"
        suffix=$((suffix + 1))
    done

    work=$(mktemp -d "$CM_BACKUP_DIR/.backup.tmp.XXXXXX") || {
        cm_unlock
        printf '%s\n' "$(cm_t tempdir_failed)" >&2
        return 1
    }

    if ! cm_dconf_dump_all "$work"; then
        rm -rf -- "$work" 2>/dev/null || true
        cm_unlock
        printf '%s\n' "$(cm_t backup_create_failed)" >&2
        return 1
    fi

    if [ -d "$HOME/.themes" ] && ! cm_snapshot_dir "$HOME/.themes" "$work/themes_snapshot"; then
        rm -rf -- "$work" 2>/dev/null || true
        cm_unlock
        printf '%s\n' "$(cm_t backup_create_failed)" >&2
        return 1
    fi
    if [ -d "$HOME/.config/gtk-3.0" ] && ! cm_snapshot_dir "$HOME/.config/gtk-3.0" "$work/gtk-3.0_snapshot"; then
        rm -rf -- "$work" 2>/dev/null || true
        cm_unlock
        printf '%s\n' "$(cm_t backup_create_failed)" >&2
        return 1
    fi
    if [ -f "$HOME/.config/fontconfig/fonts.conf" ] && ! cp -- "$HOME/.config/fontconfig/fonts.conf" "$work/fonts.conf.snapshot" 2>/dev/null; then
        rm -rf -- "$work" 2>/dev/null || true
        cm_unlock
        printf '%s\n' "$(cm_t backup_create_failed)" >&2
        return 1
    fi
    if ! cm_backup_look "$work"; then
        rm -rf -- "$work" 2>/dev/null || true
        cm_unlock
        printf '%s\n' "$(cm_t backup_create_failed)" >&2
        return 1
    fi

    if ! printf '%s\n' "$ts" | cm_atomic_write "$work/manifest.txt"; then
        rm -rf -- "$work" 2>/dev/null || true
        cm_unlock
        printf '%s\n' "$(cm_t backup_create_failed)" >&2
        return 1
    fi
    if ! mv -T -- "$work" "$dest" 2>/dev/null; then
        rm -rf -- "$work" 2>/dev/null || true
        cm_unlock
        printf '%s\n' "$(cm_t backup_create_failed)" >&2
        return 1
    fi
    work=""
    cm_unlock
    cm_log "INFO" "$(printf "$(cm_t backup_created)" "$dest")"
    basename "$dest"
}

cm_list_backups() {
    mkdir -p "$CM_BACKUP_DIR"
    local entry
    for entry in "$CM_BACKUP_DIR"/*; do
        [ -d "$entry" ] || continue
        basename "$entry"
    done | sort -r
}

# A restore replaces several things and must leave every one as it was when any step fails. cm_restore_plan lists the
# steps and checks every target before anything changes; each replaced target is then moved aside, its staged copy is
# moved into place, and every failing way out of cm_restore_backup goes through cm_restore_abort, which undoes the steps
# in reverse order. The state is global because the staging helpers run in command substitutions; the lock keeps two
# restores from sharing it.
CM_RB_KIND=()      # the steps: dir, file, whole (a file put back as it was), block (a Color Mint block put back) or remove
CM_RB_SRC=()       # for each, the backup's copy ("" for remove)
CM_RB_DST=()       # for each, the target (a link already resolved to what it leads to)
CM_RB_TAG=()       # for a block, "<tag>:<1 if the file existed when the backup was made, else 0>"
CM_RB_STAGES=()    # for each, its staged copy: a path, "-" (remove the target) or "" (nothing to change)
CM_RB_TARGETS=()   # what has been replaced so far
CM_RB_OLDS=()      # for each of those, the folder that holds what was there as "current" ("" when nothing was)
CM_RB_ROOT=""      # the dconf dump taken before the restore

cm_restore_reset() {
    CM_RB_KIND=(); CM_RB_SRC=(); CM_RB_DST=(); CM_RB_TAG=()
    CM_RB_STAGES=(); CM_RB_TARGETS=(); CM_RB_OLDS=(); CM_RB_ROOT=""
}

# cm_restore_plan_add <kind> <backup copy> <target> [tag]
cm_restore_plan_add() {
    CM_RB_KIND+=("$1"); CM_RB_SRC+=("$2"); CM_RB_DST+=("$3"); CM_RB_TAG+=("${4:-}")
}

# cm_restore_plan_remove <fonts|envd> <path>: the backup was made when the file did not exist, so one that still carries
# Color Mint's mark is removed. Anything else is the user's and stays; a link is never deleted, and one whose file
# holds what Color Mint wrote is named.
cm_restore_plan_remove() {
    local tag="$1" path="$2" ours=0
    [ -e "$path" ] || [ -L "$path" ] || return 0
    case "$tag" in
        fonts) grep -qF 'Color Mint: generated file' "$path" 2>/dev/null && ours=1 ;;
        envd)  grep -q '^XCURSOR_SIZE=' "$path" 2>/dev/null && ours=1 ;;
    esac
    [ "$ours" -eq 1 ] || return 0
    if [ -L "$path" ]; then
        printf '%s\n' "$(printf "$(cm_t uninstall_kept_link)" "$path")" >&2
        return 0
    fi
    cm_restore_plan_add remove "" "$path"
}

# cm_restore_plan_whole <path> <part>: put back a file Color Mint writes whole, unless it already is as it was.
cm_restore_plan_whole() {
    local path="$1" part="$2" target
    [ -f "$part" ] && [ ! -L "$part" ] || return 0
    if [ -f "$path" ] && cmp -s -- "$part" "$path"; then return 0; fi
    target=$(cm_real_file "$path") || return 1
    cm_restore_plan_add whole "$part" "$target"
}

# cm_restore_plan_block <tag> <path> <existed 0|1> <part>: put back the block Color Mint keeps in a file (<part> is
# /dev/null when the file did not exist: no block), unless it already is as it was. A block that is not closed refuses
# the restore: replacing it would drop the user's lines.
cm_restore_plan_block() {
    local tag="$1" path="$2" existed="$3" part="$4" begin end target
    if [ "$part" != /dev/null ]; then [ -f "$part" ] && [ ! -L "$part" ] || return 0; fi
    { IFS= read -r begin; IFS= read -r end; } < <(cm_look_block_marks "$tag")
    if [ -f "$path" ]; then
        if ! cm_marked_block_ok "$path" "$begin" "$end"; then
            printf '%s\n' "$(printf "$(cm_t marked_block_open)" "$path")" >&2
            return 1
        fi
        if cm_block_extract "$path" "$begin" "$end" | cmp -s -- - "$part"; then return 0; fi
    elif [ ! -s "$part" ]; then
        return 0
    fi
    target=$(cm_real_file "$path") || return 1
    cm_restore_plan_add block "$part" "$target" "$tag:$existed"
}

# cm_restore_plan_look <backup>: the steps for the files recorded in look.txt. A backup without it (or a file it does
# not list) is not touched.
cm_restore_plan_look() {
    local src="$1" tag path state part status=0
    [ -f "$src/look.txt" ] && [ ! -L "$src/look.txt" ] || return 0
    while IFS='|' read -r tag path; do
        state=$(awk -F= -v t="$tag" '$1 == t { print $2; exit }' "$src/look.txt")
        case "$state" in 0|1) ;; *) continue ;; esac
        part="$src/look_$tag.part"
        [ "$state" = 1 ] || part=/dev/null
        case "$tag:$state" in
            fonts:1)        ;;   # the snapshot is restored with the folders
            fonts:0|envd:0) cm_restore_plan_remove "$tag" "$path" ;;
            envd:1)         cm_restore_plan_whole "$path" "$part" || status=1 ;;
            gtk3css:*)      # the gtk-3.0 snapshot, when there is one, already holds its gtk.css
                            [ -d "$src/gtk-3.0_snapshot" ] || cm_restore_plan_block "$tag" "$path" "$state" "$part" || status=1 ;;
            xres:*|gtk4css:*) cm_restore_plan_block "$tag" "$path" "$state" "$part" || status=1 ;;
        esac
    done < <(cm_look_files)
    return "$status"
}

# cm_restore_plan <backup>: every step the backup calls for. A target that is a link (a dotfile manager's) is replaced
# where the link leads and the link stays. A link that cannot take it, or a block that is not closed, is named and
# refuses the whole restore before anything changes.
cm_restore_plan() {
    local src="$1" target refused=0
    cm_restore_reset
    if [ -d "$src/themes_snapshot" ]; then
        if target=$(cm_real_dir "$HOME/.themes"); then cm_restore_plan_add dir "$src/themes_snapshot" "$target"; else refused=1; fi
    fi
    if [ -d "$src/gtk-3.0_snapshot" ]; then
        if target=$(cm_real_dir "$HOME/.config/gtk-3.0"); then cm_restore_plan_add dir "$src/gtk-3.0_snapshot" "$target"; else refused=1; fi
    fi
    if [ -f "$src/fonts.conf.snapshot" ]; then
        if target=$(cm_real_file "$HOME/.config/fontconfig/fonts.conf"); then cm_restore_plan_add file "$src/fonts.conf.snapshot" "$target"; else refused=1; fi
    fi
    cm_restore_plan_look "$src" || refused=1
    return "$refused"
}

# cm_stage_restore_block <target> <tag:existed> <part>: stage the target as it is now with its Color Mint block replaced
# by the one in <part> (none when empty). Prints the staged file; "-" when the file did not exist and nothing else is
# left in it, so it goes; nothing when it already is as it should be.
cm_stage_restore_block() {
    local target="$1" tag="${2%%:*}" existed="${2#*:}" part="$3" parent base stage mode=0644 begin end
    { IFS= read -r begin; IFS= read -r end; } < <(cm_look_block_marks "$tag")
    parent="${target%/*}"; [ "$parent" = "$target" ] && parent="."
    base="${target##*/}"
    mkdir -p -- "$parent" 2>/dev/null || return 1
    stage=$(mktemp "$parent/.${base}.restore-stage.XXXXXX") || return 1
    if [ -f "$target" ]; then
        mode=$(stat -c '%a' -- "$target" 2>/dev/null || echo 0644)
        if ! awk -v b="$begin" -v e="$end" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } skip != 1 { print }' \
            "$target" > "$stage" 2>/dev/null; then
            rm -f -- "$stage" 2>/dev/null || true
            return 1
        fi
    fi
    if ! cat -- "$part" >> "$stage" || ! chmod "$mode" "$stage" 2>/dev/null; then
        rm -f -- "$stage" 2>/dev/null || true
        return 1
    fi
    if [ -f "$target" ] && cmp -s -- "$stage" "$target"; then
        rm -f -- "$stage"
    elif [ "$existed" = 0 ] && ! grep -q '[^[:space:]]' "$stage"; then
        rm -f -- "$stage"
        printf '%s' -
    else
        printf '%s' "$stage"
    fi
}

# cm_restore_swap <target> <stage>: move what is at <target> aside and put <stage> there ("-": put nothing).
cm_restore_swap() {
    local target="$1" stage="$2" old=""
    if [ -e "$target" ] || [ -L "$target" ]; then
        old=$(mktemp -d "${target%/*}/.color-mint-restore-old.XXXXXX") || return 1
        if ! mv -T -- "$target" "$old/current" 2>/dev/null; then
            rm -rf -- "$old"
            return 1
        fi
    fi
    if [ "$stage" != - ] && ! mv -T -- "$stage" "$target" 2>/dev/null; then
        # A folder that cannot be put back is the only copy left: keep it and say where it is.
        if [ -n "$old" ]; then
            if mv -T -- "$old/current" "$target" 2>/dev/null; then
                rm -rf -- "$old"
            else
                printf '%s\n' "$(printf "$(cm_t backup_restore_kept)" "$old/current")" >&2
            fi
        fi
        return 1
    fi
    CM_RB_TARGETS+=("$target"); CM_RB_OLDS+=("$old")
}

# cm_restore_abort [dconf]: undo the steps in reverse order, drop what is staged and fail. With "dconf" the dconf paths
# go back first to the dump taken before the restore.
cm_restore_abort() {
    local i
    if [ "${1:-}" = dconf ]; then cm_dconf_load_all "$CM_RB_ROOT" || true; fi
    for ((i = ${#CM_RB_TARGETS[@]} - 1; i >= 0; i--)); do
        rm -rf -- "${CM_RB_TARGETS[i]}" 2>/dev/null || true
        [ -n "${CM_RB_OLDS[i]}" ] || continue
        if mv -T -- "${CM_RB_OLDS[i]}/current" "${CM_RB_TARGETS[i]}" 2>/dev/null; then
            rm -rf -- "${CM_RB_OLDS[i]}"
        else
            printf '%s\n' "$(printf "$(cm_t backup_restore_kept)" "${CM_RB_OLDS[i]}/current")" >&2
        fi
    done
    for ((i = 0; i < ${#CM_RB_STAGES[@]}; i++)); do
        case "${CM_RB_STAGES[i]}" in ""|-) ;; *) rm -rf -- "${CM_RB_STAGES[i]}" ;; esac
    done
    [ -z "$CM_RB_ROOT" ] || rm -rf -- "$CM_RB_ROOT"
    cm_restore_reset
    cm_unlock
    printf '%s\n' "$(cm_t backup_restore_failed)" >&2
    return 1
}

cm_restore_backup() {
    local name="${1:-}"
    [ -z "$name" ] && { printf '%s\n' "$(cm_t backup_name_required)" >&2; return 1; }
    case "$name" in */*|*..*) printf '%s\n' "$(cm_t backup_name_invalid)" >&2; return 1 ;; esac
    local src="$CM_BACKUP_DIR/$name"
    [ -d "$src" ] && [ ! -L "$src" ] || { printf '%s\n' "$(printf "$(cm_t backup_not_found)" "$name")" >&2; return 1; }
    cm_validate_extracted_tree "$src" themes_snapshot gtk-3.0_snapshot || { printf '%s\n' "$(cm_t backup_restore_failed)" >&2; return 1; }

    cm_restore_plan "$src" || { cm_restore_reset; printf '%s\n' "$(cm_t backup_restore_failed)" >&2; return 1; }

    cm_lock || { cm_restore_reset; printf '%s\n' "$(cm_t backup_restore_failed)" >&2; return 1; }
    CM_RB_ROOT=$(mktemp -d "$CM_BACKUP_DIR/.restore-rollback.XXXXXX") || { CM_RB_ROOT=""; cm_restore_abort; return 1; }
    cm_dconf_dump_all "$CM_RB_ROOT" || { cm_restore_abort; return 1; }

    # Stage everything first, so a failure while staging changes nothing; then swap each target in.
    local i stage
    for ((i = 0; i < ${#CM_RB_KIND[@]}; i++)); do
        case "${CM_RB_KIND[i]}" in
            dir)         stage=$(cm_stage_restore_dir "${CM_RB_SRC[i]}" "${CM_RB_DST[i]}") || { cm_restore_abort; return 1; } ;;
            file|whole)  stage=$(cm_stage_restore_file "${CM_RB_SRC[i]}" "${CM_RB_DST[i]}") || { cm_restore_abort; return 1; } ;;
            block)       stage=$(cm_stage_restore_block "${CM_RB_DST[i]}" "${CM_RB_TAG[i]}" "${CM_RB_SRC[i]}") || { cm_restore_abort; return 1; } ;;
            remove)      stage=- ;;
        esac
        CM_RB_STAGES+=("$stage")
    done
    for ((i = 0; i < ${#CM_RB_KIND[@]}; i++)); do
        [ -n "${CM_RB_STAGES[i]}" ] || continue
        cm_restore_swap "${CM_RB_DST[i]}" "${CM_RB_STAGES[i]}" || { cm_restore_abort; return 1; }
    done

    cm_dconf_load_all "$src" || { cm_restore_abort dconf; return 1; }

    for ((i = 0; i < ${#CM_RB_OLDS[@]}; i++)); do
        [ -z "${CM_RB_OLDS[i]}" ] || rm -rf -- "${CM_RB_OLDS[i]}"
    done
    rm -rf -- "$CM_RB_ROOT"
    cm_restore_reset
    cm_unlock
    cm_reload_cinnamon
    cm_log "INFO" "$(printf "$(cm_t backup_restored_log)" "$name")"
}

# ============================================================================
# themes — list and apply GTK / icon / cursor / Cinnamon themes
# ============================================================================
# Directories where GTK and Cinnamon look for themes ("themes") and for icon and cursor themes
# ("icons"), in search order: the legacy per-user folder, the XDG user folder, then the XDG system
# folders. Themes installed by modern installers land in ~/.local/share, and distro or local
# packages in /usr/local/share, so all of them have to be searched.
cm_data_dirs() {
    local kind="$1" d
    local IFS=:
    printf '%s\n' "$HOME/.$kind" "${XDG_DATA_HOME:-$HOME/.local/share}/$kind"
    # shellcheck disable=SC2086  # splitting on ":" is the point
    for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do
        printf '%s\n' "${d%/}/$kind"
    done
}

# cm_find_theme_dir <themes|icons> <name>: the first folder that holds that theme.
cm_find_theme_dir() {
    local d
    while IFS= read -r d; do
        [ -d "$d/$2" ] && { printf '%s\n' "$d/$2"; return 0; }
    done < <(cm_data_dirs "$1")
    return 1
}

# cm_theme_installed <themes|icons|cursors|cinnamon> <name>: would GTK/Cinnamon find it? The themes GTK and
# Cinnamon carry inside themselves count as installed. A cursor theme needs a cursors/ folder in some search
# folder (libXcursor finds no pointer in an icon theme without one, as with a missing theme): status 1 = no
# folder of that name, 3 = the folder exists but none has cursors/.
cm_theme_installed() {
    local kind="$1" name="$2" d found=1
    case "$kind:$name" in
        themes:Adwaita|themes:Adwaita-dark|themes:HighContrast|themes:HighContrastInverse|cinnamon:cinnamon) return 0 ;;
    esac
    if [ "$kind" = cinnamon ]; then
        while IFS= read -r d; do
            [ -d "$d/$name/cinnamon" ] && return 0
        done < <(cm_data_dirs themes)
        return 1
    fi
    if [ "$kind" = cursors ]; then
        while IFS= read -r d; do
            cm_is_cursor_theme_dir "$d/$name" && return 0
            [ -d "$d/$name" ] && found=3
        done < <(cm_data_dirs icons)
        return "$found"
    fi
    cm_find_theme_dir "$kind" "$name" >/dev/null
}

# The lists offer what Cinnamon's own Themes panel offers (cs_themes.py, the same from Cinnamon 6.4 to master):
# a GTK theme needs a gtk-3.*/gtk.css; an icon theme an index.theme with a Directories= line that no
# Hidden=true line precedes; a cursor theme a cursors/ folder; a Cinnamon theme a cinnamon/ folder. Linked
# folders count and broken links do not. The panel also never offers the names below (not meant as themes,
# or incomplete outside GNOME); the setters still accept them by name. Plain Bash tests, no process per folder.
cm_theme_hidden() {
    case "${1,,}" in
        gnome|hicolor|adwaita|adwaita-dark|adwaitalegacy|highcontrast|epapirus|epapirus-dark) return 0 ;;
        ubuntu-mono|ubuntu-mono-dark|ubuntu-mono-light|loginicons|humanity|humanity-dark) return 0 ;;
    esac
    return 1
}

cm_is_gtk_theme_dir() {
    local sub
    for sub in "$1"/gtk-3.*; do
        [ -e "$sub/gtk.css" ] && return 0
    done
    return 1
}

cm_is_icon_theme_dir() {
    local file="$1/index.theme" line
    [ -f "$file" ] && [ -r "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            Hidden=true*) return 1 ;;
            Directories=*) return 0 ;;
        esac
    done < "$file"
    return 1
}

cm_is_cursor_theme_dir() { [ -d "$1/cursors" ]; }

# cm_theme_has_cursors <name>: has the installed icon theme <name> cursors of its own?
cm_theme_has_cursors() {
    local dir
    dir=$(cm_find_theme_dir icons "$1") || return 1
    cm_is_cursor_theme_dir "$dir"
}

cm_is_cinnamon_theme_dir() { [ -d "$1/cinnamon" ]; }

# cm_catalog_list <themes|icons> <test function> [hide]: sorted, unique names of the folders in every
# search folder that pass the test; hide=0 keeps the names cm_theme_hidden would skip.
cm_catalog_list() {
    local kind="$1" check="$2" hide="${3:-1}" dir path name
    while IFS= read -r dir; do
        [ -d "$dir" ] || continue
        for path in "$dir"/*/; do
            path="${path%/}"
            [ -d "$path" ] || continue
            name="${path##*/}"
            if [ "$hide" = 1 ] && cm_theme_hidden "$name"; then continue; fi
            if "$check" "$path"; then printf '%s\n' "$name"; fi
        done
    done < <(cm_data_dirs "$kind") | sort -u
}

cm_list_gtk_themes() { cm_catalog_list themes cm_is_gtk_theme_dir; }

cm_list_icon_themes() { cm_catalog_list icons cm_is_icon_theme_dir; }

cm_list_cursor_themes() { cm_catalog_list icons cm_is_cursor_theme_dir; }

cm_list_cinnamon_themes() { cm_catalog_list themes cm_is_cinnamon_theme_dir 0; }

# Mint-Y-Dark is a theme of its own, not a colour of the light Mint-Y.
cm_list_mint_y_colors() {
    local base="$1"   # "Mint-Y" or "Mint-Y-Dark"
    cm_list_gtk_themes | grep -E "^${base}-[A-Za-z]+$" | sed -E "s/^${base}-//" | { if [ "$base" = Mint-Y ]; then grep -vx Dark; else cat; fi; } | sort -u
}

# cm_apply_mint_y_pack <color> <public mode: claro|oscuro>: the theme and the scheme are set with the libadwaita
# import held, so it is written once, for the pair of them.
cm_apply_mint_y_pack() { cm_libadwaita_hold cm_mint_y_pack_steps "$@"; }

cm_mint_y_pack_steps() {
    local color="${1:-}" mode="${2:-claro}"
    [ -z "$color" ] && { printf '%s\n' "$(cm_t mint_color_required)" >&2; return 1; }
    local base="Mint-Y"
    [ "$mode" = "oscuro" ] && base="Mint-Y-Dark"
    local gtk_name="${base}-${color}" icon_name="Mint-Y-${color}"

    cm_panel_locate_base "$gtk_name" >/dev/null 2>&1
    local has_cinnamon=$?
    if ! cm_find_theme_dir themes "$gtk_name" >/dev/null; then
        printf '%s\n' "$(printf "$(cm_t theme_not_found)" "$gtk_name")" >&2
        return 1
    fi

    cm_apply_gtk_theme "$gtk_name" || return 1
    if cm_find_theme_dir icons "$icon_name" >/dev/null; then
        cm_apply_icon_theme "$icon_name" || return 1
    fi
    if [ "$has_cinnamon" -eq 0 ]; then
        cm_apply_cinnamon_theme "$gtk_name" || return 1
    fi
    # The scheme only makes libadwaita apps follow the pack: if it cannot be written (the error is
    # already on stderr and in the log), the pack stays applied.
    local scheme="prefer-light"
    [ "$mode" = "oscuro" ] && scheme="prefer-dark"
    cm_apply_color_scheme "$scheme" >/dev/null
    cm_state_set "MINT_Y_COLOR" "$color"
    cm_state_set "MINT_Y_MODE" "$mode"
    printf '%s\n' "$(printf "$(cm_t mint_pack_applied)" "$gtk_name" "$icon_name")"
}

cm_apply_gtk_theme() {
    local name="${1:-}"
    [ -z "$name" ] && { printf '%s\n' "$(cm_t gtk_name_required)" >&2; return 1; }
    cm_validate_theme_name "$name" || { printf '%s\n' "$(printf "$(cm_t theme_name_invalid)" "$name")" >&2; return 1; }
    cm_theme_installed themes "$name" || { printf '%s\n' "$(printf "$(cm_t theme_not_found)" "$name")" >&2; return 1; }
    cm_gset org.cinnamon.desktop.interface gtk-theme "$name" || return 1
    gsettings set org.cinnamon.desktop.wm.preferences theme "$name" 2>/dev/null || true
    printf '%s\n' "$(printf "$(cm_t gtk_applied)" "$name")"
    cm_libadwaita_refresh "$name"
}

cm_apply_icon_theme() {
    local name="${1:-}"
    [ -z "$name" ] && { printf '%s\n' "$(cm_t icon_name_required)" >&2; return 1; }
    cm_validate_theme_name "$name" || { printf '%s\n' "$(printf "$(cm_t theme_name_invalid)" "$name")" >&2; return 1; }
    cm_theme_installed icons "$name" || { printf '%s\n' "$(printf "$(cm_t theme_not_found)" "$name")" >&2; return 1; }
    cm_gset org.cinnamon.desktop.interface icon-theme "$name" || return 1
    printf '%s\n' "$(printf "$(cm_t icon_applied)" "$name")"
}

cm_apply_cursor_theme() {
    local name="${1:-}" skip_reload="${2:-0}"
    [ -z "$name" ] && { printf '%s\n' "$(cm_t cursor_name_required)" >&2; return 1; }
    cm_validate_theme_name "$name" || { printf '%s\n' "$(printf "$(cm_t theme_name_invalid)" "$name")" >&2; return 1; }
    cm_theme_installed icons "$name" || { printf '%s\n' "$(printf "$(cm_t theme_not_found)" "$name")" >&2; return 1; }
    cm_cursor_targets_ok || return 1
    cm_gset org.cinnamon.desktop.interface cursor-theme "$name" || return 1
    cm_refresh_cursor "$skip_reload" || return 1
    printf '%s\n' "$(printf "$(cm_t cursor_applied)" "$name")"
    cm_theme_has_cursors "$name" || printf '%s\n' "$(printf "$(cm_t cursor_inherited)" "$name")" >&2
}

# Markers delimiting the block this script owns in ~/.Xresources.
CM_XRES_BEGIN="! >>> Color Mint: cursor (autogenerado, no editar a mano) >>>"
CM_XRES_END="! <<< Color Mint: cursor <<<"

# Remove from <file> the block delimited by two literal marker lines, if any.
# Shared "strip + append" pattern for gtk.css (global accent), ~/.Xresources
# (cursor) and the cinnamon.css overrides; avoids stacking duplicate blocks each
# time a setting is reapplied.
cm_strip_marked_block() {
    local file="$1" b="$2" e="$3"
    cm_look_marked_replace "$file" "$b" "$e" ""
}

cm_strip_xresources_block() { cm_strip_marked_block "$1" "$CM_XRES_BEGIN" "$CM_XRES_END"; }

# The two files a cursor change writes; checked before the setting changes, so a refusal changes nothing.
cm_cursor_targets_ok() {
    cm_look_targets_ok "$HOME/.Xresources" "$HOME/.config/environment.d/60-color-mint-cursor.conf"
}

# Best-effort cursor refresh after a theme or size change, without sudo.
cm_refresh_cursor() {
    local skip_reload="${1:-0}"
    local size current_theme other_theme envdir envfile xresfile
    size=$(gsettings get org.cinnamon.desktop.interface cursor-size 2>/dev/null | tr -d "'")
    current_theme=$(cm_gs_string org.cinnamon.desktop.interface cursor-theme)

    if [ -n "$current_theme" ]; then
        other_theme="Adwaita"
        [ "$current_theme" = "Adwaita" ] && other_theme="Mint-Y"
        gsettings set org.cinnamon.desktop.interface cursor-theme "$other_theme" 2>/dev/null
        sleep 0.4
        gsettings set org.cinnamon.desktop.interface cursor-theme "$current_theme" 2>/dev/null
        sleep 0.2
    fi

    if [ -n "$size" ]; then
        gsettings set org.gnome.desktop.interface cursor-size "$size" 2>/dev/null || true
    fi
    if [ -n "$current_theme" ]; then
        gsettings set org.gnome.desktop.interface cursor-theme "$current_theme" 2>/dev/null || true
    fi

    # Besides the live "xrdb -merge" (current X session only), persist the values
    # in ~/.Xresources so they survive a logout, which remains the only fully
    # reliable way to refresh an already drawn pointer.
    if [ -n "$size" ] || [ -n "$current_theme" ]; then
        xresfile="$HOME/.Xresources"
        local xres_block
        xres_block="$CM_XRES_BEGIN"$'\n'
        [ -n "$current_theme" ] && xres_block+="Xcursor.theme: ${current_theme}"$'\n'
        [ -n "$size" ]          && xres_block+="Xcursor.size: ${size}"$'\n'
        xres_block+="$CM_XRES_END"
        cm_look_marked_replace "$xresfile" "$CM_XRES_BEGIN" "$CM_XRES_END" "$xres_block" || return 1
        if command -v xrdb >/dev/null 2>&1; then
            xrdb -merge "$xresfile" 2>/dev/null
        fi
    fi

    if [ -n "$size" ]; then
        envdir="$HOME/.config/environment.d"
        envfile="$envdir/60-color-mint-cursor.conf"
        mkdir -p "$envdir" 2>/dev/null
        printf 'XCURSOR_SIZE=%s\n' "$size" | cm_look_write_locked "$envfile" || return 1
    fi

    if [ -n "$size" ] && command -v cinnamon-settings-daemon >/dev/null 2>&1; then
        nohup cinnamon-settings-daemon --replace >/dev/null 2>&1 &
        disown 2>/dev/null || true
    fi

    # Best effort like every other caller: the change is saved and persisted by now, and the failure is in the log.
    [ "$skip_reload" = "1" ] || cm_reload_cinnamon || true
}

# Cursor size in px (cursor-size; usual values: 24, 32, 48, 64, 96).
cm_apply_cursor_size() {
    local size="${1:-}" skip_reload="${2:-0}"
    if ! cm_int_in_range "$size" 16 96; then
        printf '%s\n' "$(cm_t cursor_size_invalid)" >&2
        return 1
    fi
    cm_cursor_targets_ok || return 1
    cm_gset org.cinnamon.desktop.interface cursor-size "$size" || return 1

    # Read the value back: a successful "gsettings set" does not prove it was
    # saved, and this separates a real save failure from Cinnamon's known
    # limitation of not refreshing the already drawn pointer live.
    local verify
    verify=$(gsettings get org.cinnamon.desktop.interface cursor-size 2>/dev/null | tr -d "'")
    if [ "$verify" != "$size" ]; then
        printf '%s\n' "$(printf "$(cm_t cursor_size_verify)" "${verify:-$(cm_t value_empty)}" "$size")" >&2
        return 1
    fi

    cm_refresh_cursor "$skip_reload" || return 1
    printf '%s\n' "$(printf "$(cm_t cursor_size_saved)" "$size")"
}

cm_current_cursor_size() {
    gsettings get org.cinnamon.desktop.interface cursor-size 2>/dev/null | tr -d "'" || echo "24"
}

cm_apply_cinnamon_theme() {
    local name="${1:-}"
    [ -z "$name" ] && { printf '%s\n' "$(cm_t cinnamon_name_required)" >&2; return 1; }
    cm_validate_theme_name "$name" || { printf '%s\n' "$(printf "$(cm_t theme_name_invalid)" "$name")" >&2; return 1; }
    cm_theme_installed cinnamon "$name" || { printf '%s\n' "$(printf "$(cm_t theme_not_found)" "$name")" >&2; return 1; }
    cm_gset org.cinnamon.theme name "$name" || return 1
    printf '%s\n' "$(printf "$(cm_t cinnamon_applied)" "$name")"
}

# cm_apply_color_scheme <default|prefer-dark|prefer-light>: the light/dark preference that libadwaita
# apps read from the XApp portal (Cinnamon's Themes panel writes the same key). A system without the
# org.x.apps.portal schema has nothing to write, which is skipped, not a failure.
cm_apply_color_scheme() {
    local value="${1:-}"
    case "$value" in
        default|prefer-dark|prefer-light) ;;
        *) printf '%s\n' "$(printf "$(cm_t color_scheme_invalid)" "$value")" >&2; return 1 ;;
    esac
    if ! gsettings get org.x.apps.portal color-scheme >/dev/null 2>&1; then
        printf '%s\n' "$(cm_t color_scheme_skipped)"
        return 0
    fi
    cm_gset org.x.apps.portal color-scheme "$value" || return 1
    printf '%s\n' "$(printf "$(cm_t color_scheme_applied)" "$value")"
    cm_libadwaita_refresh "" "$value"
}

# ============================================================================
# import_theme — install a downloaded theme (.zip/.tar.*, or an extracted
# folder) into ~/.themes (GTK/Cinnamon) or ~/.icons (icons/cursors), chosen
# from its structure. Installs no packages: if the extraction tool is missing,
# it says so.
# ============================================================================
CM_MAX_UNPACKED_BYTES=$((512 * 1024 * 1024))   # what an archive may unpack to (largest package checked: 196 MB installed)
CM_MAX_ENTRIES=20000                           # files and folders an archive may hold

cm_validate_archive_entries() {
    local format="$1" archive="$2" entries entry mode
    case "$format" in
        zip)
            command -v zipinfo >/dev/null 2>&1 || return 1
            while IFS= read -r entry || [ -n "$entry" ]; do
                [ -n "$entry" ] || continue
                case "$entry" in
                    /*|\*|../*|*/../*|*/..|..|*[[:cntrl:]]*) return 1 ;;
                esac
            done < <(unzip -Z1 -- "$archive" 2>/dev/null) || return 1
            # A zip made on Windows or macOS holds no Unix mode (zipinfo prints "-rw-a--" or "?---------"): a file or a
            # folder, never a link. Only the link and special-file types are refused; cm_validate_extracted_tree
            # checks what was really extracted.
            LC_ALL=C zipinfo -l -- "$archive" 2>/dev/null | awk '
                NR <= 2 { next }
                $2 == "file," || $2 == "files," { next }
                $1 ~ /^[-d?][-rwxXsStT]{9}$/ { next }
                $1 ~ /^[-d]r[-w][-x][-a][-h][-s]$/ { next }
                { exit 1 }
            '
            ;;
        tar)
            while IFS= read -r entry || [ -n "$entry" ]; do
                [ -n "$entry" ] || continue
                case "$entry" in
                    /*|\*|../*|*/../*|*/..|..|*[[:cntrl:]]*) return 1 ;;
                esac
            done < <(tar -tf "$archive" 2>/dev/null) || return 1
            LC_ALL=C tar -tvf "$archive" 2>/dev/null | awk '
                NF && substr($0,1,1) != "-" && substr($0,1,1) != "d" { exit 1 }
            '
            ;;
        *) return 1 ;;
    esac
}

# cm_validate_extracted_tree <root> [folder]...: no link and no special file anywhere, except links inside the folders
# named (a backup keeps the user's own links, a dotfile manager's, inside themes_snapshot and gtk-3.0_snapshot, and a
# restore puts them back as links). Such a folder must itself be a plain folder, so `themes_snapshot -> /etc` fails.
cm_validate_extracted_tree() {
    local root="$1" path rel top allowed
    shift
    [ -d "$root" ] && [ ! -L "$root" ] || return 1
    while IFS= read -r -d '' path; do
        rel="${path#"$root"/}"
        case "$rel" in /*|\*|../*|*/../*|*/..|..|*[[:cntrl:]]*) return 1 ;; esac
        if [ -h "$path" ]; then
            top="${rel%%/*}"
            [ "$top" != "$rel" ] || return 1
            for allowed in "$@"; do
                [ "$allowed" = "$top" ] && continue 2
            done
            return 1
        fi
        if [ -e "$path" ] && [ ! -f "$path" ] && [ ! -d "$path" ]; then
            return 1
        fi
    done < <(find "$root" -mindepth 1 -print0 2>/dev/null) || return 1
    return 0
}

# cm_archive_entries_ok <zip|tar> <archive>: succeeds when the archive lists at most CM_MAX_ENTRIES entries (files and
# folders). The listing stops one entry past the cap, so a flood of empty entries costs neither time nor a Bash loop.
# Without pipefail, as below: stopping early ends unzip or tar with SIGPIPE.
cm_archive_entries_ok() {
    local format="$1" archive="$2" counted
    case "$format" in
        zip) counted=$(set +o pipefail; unzip -Z1 -- "$archive" 2>/dev/null </dev/null \
                 | head -n "$((CM_MAX_ENTRIES + 1))" | wc -l) ;;
        tar) counted=$(set +o pipefail; tar -tf "$archive" 2>/dev/null </dev/null \
                 | head -n "$((CM_MAX_ENTRIES + 1))" | wc -l) ;;
        *)   return 1 ;;
    esac
    counted="${counted//[[:space:]]/}"
    [[ "$counted" =~ ^[0-9]{1,15}$ ]] && [ "$counted" -le "$CM_MAX_ENTRIES" ]
}

# cm_archive_unpacked_ok <zip|tar> <archive> [tar compression flag]: succeeds when the archive really unpacks to at
# most CM_MAX_UNPACKED_BYTES. The size is measured, not read: a zip's directory can declare 100 bytes for an entry that
# inflates to gigabytes, and a compressed tar declares nothing. The contents go through a counter that stops one byte
# past the cap and writes nothing to disk. The caller extracts from the same private copy with the same decoder, so
# the extraction cannot write more than was counted. The pipeline runs without pipefail: stopping early ends unzip or
# tar with SIGPIPE. An unreadable count is a refusal.
cm_archive_unpacked_ok() {
    local format="$1" archive="$2" flag="${3:-}" counted
    case "$format" in
        zip) counted=$(set +o pipefail; unzip -p -P '' -- "$archive" 2>/dev/null </dev/null \
                 | head -c "$((CM_MAX_UNPACKED_BYTES + 1))" | wc -c) ;;
        tar) counted=$(set +o pipefail; tar "-x${flag}Of" "$archive" 2>/dev/null </dev/null \
                 | head -c "$((CM_MAX_UNPACKED_BYTES + 1))" | wc -c) ;;
        *)   return 1 ;;
    esac
    counted="${counted//[[:space:]]/}"
    [[ "$counted" =~ ^[0-9]{1,15}$ ]] && [ "$counted" -le "$CM_MAX_UNPACKED_BYTES" ]
}

cm_import_theme() {
    local src="${1:-}" work="" extracted_dir="" source_name="" archive_input="" dest_name=""
    if [ -z "$src" ]; then
        printf '%s\n' "$(cm_t import_source_required)" >&2
        return 1
    fi
    if [ -L "$src" ] || { [ ! -d "$src" ] && [ ! -f "$src" ]; }; then
        printf '%s\n' "$(printf "$(cm_t path_not_found)" "$src")" >&2
        return 1
    fi

    source_name=$(basename -- "$src") || return 1
    work=$(mktemp -d) || { printf '%s\n' "$(cm_t tempdir_failed)" >&2; return 1; }

    if [ -d "$src" ]; then
        local input_dir="$work/input"
        if ! mkdir -p -- "$input_dir" || ! cp -a -- "$src/." "$input_dir/" 2>/dev/null; then
            printf '%s\n' "$(printf "$(cm_t theme_read_failed)" "$src")" >&2
            rm -rf -- "$work"
            return 1
        fi
        extracted_dir="$input_dir"
        cm_validate_extracted_tree "$extracted_dir" || {
            printf '%s\n' "$(cm_t theme_unsafe)" >&2
            rm -rf -- "$work"
            return 1
        }
    else
        archive_input="$work/archive"
        if ! cp -- "$src" "$archive_input" 2>/dev/null; then
            printf '%s\n' "$(printf "$(cm_t theme_copy_failed)" "$src")" >&2
            rm -rf -- "$work"
            return 1
        fi
        extracted_dir="$work/extracted"
        mkdir -p -- "$extracted_dir" || {
            rm -rf -- "$work"
            printf '%s\n' "$(cm_t tempdir_failed)" >&2
            return 1
        }
        local format tar_flag="" extract_failed
        case "$src" in
            *.zip)            format=zip; extract_failed=zip_extract_failed ;;
            *.tar.gz|*.tgz)   format=tar; tar_flag=z; extract_failed=tgz_extract_failed ;;
            *.tar.xz)         format=tar; tar_flag=J; extract_failed=txz_extract_failed ;;
            *.tar.bz2|*.tbz2) format=tar; tar_flag=j; extract_failed=tbz_extract_failed ;;
            *.tar)            format=tar; extract_failed=tar_extract_failed ;;
            *)
                printf '%s\n' "$(printf "$(cm_t format_unsupported)" "$src")" >&2
                rm -rf -- "$work"
                return 1
                ;;
        esac
        if [ "$format" = zip ] && { ! command -v unzip >/dev/null 2>&1 || ! command -v zipinfo >/dev/null 2>&1; }; then
            printf '%s\n' "$(cm_t unzip_missing)" >&2
            rm -rf -- "$work"
            return 1
        fi
        # Order matters: the entries are counted first (no Bash loop over a flood), the structure is judged by listing
        # only, so a hostile archive is refused before any of its data is decoded, and the size is measured before
        # anything is written.
        cm_archive_entries_ok "$format" "$archive_input" || {
            printf '%s\n' "$(printf "$(cm_t unpacked_too_big)" "$source_name" "$((CM_MAX_UNPACKED_BYTES / 1048576))" "$CM_MAX_ENTRIES")" >&2
            rm -rf -- "$work"
            return 1
        }
        cm_validate_archive_entries "$format" "$archive_input" || {
            printf '%s\n' "$(cm_t theme_unsafe)" >&2
            rm -rf -- "$work"
            return 1
        }
        cm_archive_unpacked_ok "$format" "$archive_input" "$tar_flag" || {
            printf '%s\n' "$(printf "$(cm_t unpacked_too_big)" "$source_name" "$((CM_MAX_UNPACKED_BYTES / 1048576))" "$CM_MAX_ENTRIES")" >&2
            rm -rf -- "$work"
            return 1
        }
        # No prompt may wait on the terminal: -o settles a repeated name (the last wins) and -P '' turns an encrypted
        # entry into a failure instead of a password question.
        if [ "$format" = zip ]; then
            unzip -q -o -P '' -- "$archive_input" -d "$extracted_dir" </dev/null
        else
            tar "-x${tar_flag}f" "$archive_input" -C "$extracted_dir" --no-same-owner 2>/dev/null </dev/null
        fi || {
            printf '%s\n' "$(cm_t "$extract_failed")" >&2
            rm -rf -- "$work"
            return 1
        }
        cm_validate_extracted_tree "$extracted_dir" || {
            printf '%s\n' "$(cm_t theme_unsafe)" >&2
            rm -rf -- "$work"
            return 1
        }

        local entries entry_count only_entry only_name
        entries=$(find "$extracted_dir" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
        entry_count=$(printf '%s\n' "$entries" | grep -c .)
        if [ "$entry_count" -eq 1 ]; then
            only_entry=$(printf '%s\n' "$entries")
            only_name=$(basename -- "$only_entry")
            case "$only_name" in
                cinnamon|gtk-3.0|gtk-2.0|cursors|index.theme) : ;;
                *) [ -d "$only_entry" ] && extracted_dir="$only_entry" ;;
            esac
        fi
    fi

    local dest_base
    if [ -d "$extracted_dir/cinnamon" ] || [ -d "$extracted_dir/gtk-3.0" ] || [ -d "$extracted_dir/gtk-2.0" ]; then
        dest_base="$HOME/.themes"
    elif [ -d "$extracted_dir/cursors" ]; then
        dest_base="$HOME/.icons"
    elif [ -f "$extracted_dir/index.theme" ] && grep -qi '^\[Icon Theme\]' "$extracted_dir/index.theme" 2>/dev/null; then
        dest_base="$HOME/.icons"
    elif [ -f "$extracted_dir/index.theme" ]; then
        dest_base="$HOME/.themes"
    else
        printf '%s\n' "$(cm_t theme_not_a_theme)" >&2
        rm -rf -- "$work"
        return 1
    fi
    # ~/.themes and ~/.icons are often links (dotfile managers). The theme goes into the folder the link leads to, which
    # only has to be writable itself; one that leads nowhere, to a file or in a loop is named and nothing is written.
    if [ -L "$dest_base" ] && { [ ! -d "$dest_base" ] || [ ! -w "$dest_base" ]; }; then
        printf '%s\n' "$(printf "$(cm_t link_refused)" "$dest_base")" >&2
        rm -rf -- "$work"
        return 1
    fi
    mkdir -p -- "$dest_base" || { printf '%s\n' "$(printf "$(cm_t theme_copy_failed)" "$dest_base")" >&2; rm -rf -- "$work"; return 1; }

    if [ "$extracted_dir" = "$work/extracted" ]; then
        dest_name="$source_name"
        dest_name="${dest_name%.tar.gz}"; dest_name="${dest_name%.tgz}"
        dest_name="${dest_name%.tar.xz}"; dest_name="${dest_name%.tar.bz2}"
        dest_name="${dest_name%.tbz2}";   dest_name="${dest_name%.tar}"
        dest_name="${dest_name%.zip}"
    elif [[ "$extracted_dir" == "$work/input" ]]; then
        dest_name="$source_name"
    else
        dest_name=$(basename -- "$extracted_dir")
    fi
    [ -n "$dest_name" ] || dest_name="imported-theme"
    cm_validate_theme_name "$dest_name" || {
        printf '%s\n' "$(printf "$(cm_t theme_name_invalid)" "$dest_name")" >&2
        rm -rf -- "$work"
        return 1
    }

    local dest install_rc attempt=0
    dest="$dest_base/$dest_name"
    while :; do
        if [ $attempt -ge 100 ]; then
            printf '%s\n' "$(printf "$(cm_t theme_copy_failed)" "$dest")" >&2
            rm -rf -- "$work"
            return 1
        fi
        cm_atomic_install_dir "$extracted_dir" "$dest"
        install_rc=$?
        [ "$install_rc" -ne 2 ] && break
        attempt=$((attempt + 1))
        dest="${dest_base}/${dest_name}-$(date '+%Y%m%d%H%M%S')-$$-${attempt}"
    done
    if [ "$install_rc" -ne 0 ]; then
        printf '%s\n' "$(printf "$(cm_t theme_copy_failed)" "$dest")" >&2
        rm -rf -- "$work"
        return 1
    fi

    rm -rf -- "$work" 2>/dev/null || true
    cm_record_installed "${dest_base##*/.}" "${dest##*/}" || true
    cm_log "INFO" "$(printf "$(cm_t theme_imported_log)" "$src" "$dest")"
    echo "$dest"
}

# ============================================================================
# fetch_theme — download one Cinnamon Spices theme by name and install it through cm_import_theme
#
# Spices is where Cinnamon's own Themes panel gets its themes. That client unpacks <zip>/<name> into
# ~/.themes/<name> (python3/cinnamon/harvester.py), so a Spices zip is one folder named after the theme.
# The download is HTTPS only, capped in size and time, and never executed; what arrives goes through the
# same checks as any archive the user hands over.
# ============================================================================
CM_SPICES_THEMES_URL="https://cinnamon-spices.linuxmint.com/files/themes"
CM_FETCH_MAX_BYTES=$((32 * 1024 * 1024))   # the largest theme on Spices is under 10 MB as a zip
CM_FETCH_TIMEOUT=120                       # seconds, as in Cinnamon's own client

# The form every theme name on Spices has: letters, digits, dot, hyphen and underscore.
cm_spices_name_ok() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ && "${1:-}" != *..* ]]
}

# cm_fetch_download <name> <zip> <errfile>: one HTTPS request for the theme's zip. curl's own limit only works
# when the server announces a length, so the size cap is also a file size limit on the process (the write then
# fails with "File too large"; SIGXFSZ is ignored so no signal message appears) and a check of what arrived.
cm_fetch_download() {
    local name="$1" zip="$2" errfile="$3"
    (
        trap '' XFSZ
        ulimit -c 0 2>/dev/null || true
        ulimit -f $(((CM_FETCH_MAX_BYTES + 1023) / 1024 + 1)) 2>/dev/null || true
        exec curl --fail --silent --show-error --location --max-redirs 3 \
            --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --connect-timeout 15 --max-time "$CM_FETCH_TIMEOUT" --max-filesize "$CM_FETCH_MAX_BYTES" \
            --output "$zip" -- "$CM_SPICES_THEMES_URL/$name.zip?time=$(date +%s)"
    ) 2>"$errfile"
}

# cm_zip_declared <zip>: "<entries> <unpacked bytes>" as the zip's central directory declares them; nothing when
# zipinfo cannot read it. A zip of 3 MB of zeros fits in 3 KB, so the compressed cap alone does not protect the disk.
cm_zip_declared() {
    LC_ALL=C zipinfo -t -- "$1" 2>/dev/null \
        | sed -n '$s/^\([0-9][0-9]*\) files\{0,1\}, \([0-9][0-9]*\) bytes uncompressed.*$/\1 \2/p'
}

# cm_zip_within_limits <zip>: succeeds only when both declared numbers are readable and within the caps. The digit
# counts come first: [ ] fails on a number past 64 bits, but with an error message of its own.
cm_zip_within_limits() {
    local declared entries bytes
    declared=$(cm_zip_declared "$1") || declared=""
    entries="${declared%% *}"; bytes="${declared#* }"
    [[ "$entries" =~ ^[0-9]{1,9}$ && "$bytes" =~ ^[0-9]{1,15}$ ]] || return 1
    [ "$entries" -le "$CM_MAX_ENTRIES" ] && [ "$bytes" -le "$CM_MAX_UNPACKED_BYTES" ]
}

# cm_fetch_theme_run <name> <work folder>: download, check and import. The caller removes the work folder.
cm_fetch_theme_run() {
    local name="$1" work="$2" zip="$2/$1.zip" rc=0 size sig entry err dest base p list="" cmd count=0
    local -a how=()
    cm_fetch_download "$name" "$zip" "$work/curl.err" || rc=$?
    size=$(stat -c '%s' -- "$zip" 2>/dev/null) || size=0
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    if [ "$rc" -eq 63 ] || [ "$size" -gt "$CM_FETCH_MAX_BYTES" ]; then
        printf '%s\n' "$(printf "$(cm_t fetch_too_big)" "$name" "$((CM_FETCH_MAX_BYTES / 1048576))")" >&2
        return 1
    fi
    if [ "$rc" -ne 0 ] || [ "$size" -eq 0 ]; then
        printf '%s\n' "$(printf "$(cm_t fetch_failed)" "$name")" >&2
        err=$(tail -n 1 -- "$work/curl.err" 2>/dev/null) || err=""
        err="${err//[[:cntrl:]]/}"
        [ -z "$err" ] || printf '  %s\n' "$err" >&2
        return 1
    fi
    sig=$(LC_ALL=C head -c 4 -- "$zip" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ "$sig" != 504b0304 ]; then
        printf '%s\n' "$(printf "$(cm_t fetch_not_zip)" "$name")" >&2
        return 1
    fi
    if ! cm_zip_within_limits "$zip"; then
        printf '%s\n' "$(printf "$(cm_t fetch_unpacked_big)" "$name" "$((CM_MAX_UNPACKED_BYTES / 1048576))" "$CM_MAX_ENTRIES")" >&2
        return 1
    fi
    while IFS= read -r entry || [ -n "$entry" ]; do
        case "$entry" in
            "$name"/*) count=$((count + 1)) ;;
            *) count=0; break ;;
        esac
    done < <(unzip -Z1 -- "$zip" 2>/dev/null)
    if [ "$count" -eq 0 ]; then
        printf '%s\n' "$(printf "$(cm_t fetch_structure)" "$name")" >&2
        return 1
    fi

    dest=$(cm_import_theme "$zip") || return 1
    printf '%s\n' "$dest"
    cm_log "INFO" "$(printf "$(cm_t theme_fetched_log)" "$name" "$dest")"

    p=$(basename "$SCRIPT_PATH"); base=$(basename -- "$dest")
    cm_is_gtk_theme_dir "$dest"      && how+=("theme gtk $base")
    cm_is_cinnamon_theme_dir "$dest" && how+=("theme cinnamon $base")
    cm_is_icon_theme_dir "$dest"     && how+=("theme icon $base")
    cm_is_cursor_theme_dir "$dest"   && how+=("theme cursor $base")
    for cmd in "${how[@]+"${how[@]}"}"; do list+="${list:+ / }$p $cmd"; done
    [ -z "$list" ] || printf '%s\n' "$(printf "$(cm_t fetch_apply_hint)" "$list")" >&2
    return 0
}

# The theme is installed only if nothing of that name exists yet (an update is a deliberate delete and fetch, so a
# theme the user edited is never overwritten, and a second run never leaves a numbered copy behind).
cm_fetch_theme() {
    local name="${1:-}" work base rc=0
    if [ -z "$name" ]; then
        printf '%s\n' "$(cm_t fetch_name_required)" >&2
        return 1
    fi
    cm_spices_name_ok "$name" || {
        printf '%s\n' "$(printf "$(cm_t fetch_name_invalid)" "$name")" >&2
        return 1
    }
    for base in "$HOME/.themes" "$HOME/.icons"; do
        if [ -e "$base/$name" ] || [ -L "$base/$name" ]; then
            printf '%s\n' "$base/$name"
            printf '%s\n' "$(printf "$(cm_t fetch_already)" "$name" "$base/$name")" >&2
            return 0
        fi
    done
    command -v curl >/dev/null 2>&1 || { printf '%s\n' "$(cm_t fetch_curl_missing)" >&2; return 1; }
    if ! command -v unzip >/dev/null 2>&1 || ! command -v zipinfo >/dev/null 2>&1; then
        printf '%s\n' "$(cm_t unzip_missing)" >&2
        return 1
    fi
    work=$(mktemp -d) || { printf '%s\n' "$(cm_t tempdir_failed)" >&2; return 1; }
    cm_fetch_theme_run "$name" "$work" || rc=$?
    rm -rf -- "$work" 2>/dev/null || true
    return "$rc"
}

# ============================================================================
# theme packages — a short list of theme packages checked against Ubuntu 24.04, the base of Linux Mint 22.x
#
# Only these names ever reach apt, so nothing typed on the command line goes to sudo unchecked. The list is short on
# purpose: packages that fill the selectors with dozens of variants (orchis-gtk-theme, yaru-theme-gtk) are left out.
# package|what it brings|name
# ============================================================================
cm_theme_package_table() {
    printf '%s\n' \
        'arc-theme|gtk_cin|Arc' \
        'materia-gtk-theme|gtk_cin|Materia' \
        'numix-gtk-theme|gtk|Numix' \
        'papirus-icon-theme|icons|Papirus' \
        'numix-icon-theme-circle|icons|Numix Circle' \
        'breeze-icon-theme|icons|Breeze' \
        'elementary-icon-theme|icons|elementary' \
        'bibata-cursor-theme|cursors|Bibata' \
        'dmz-cursor-theme|cursors|DMZ' \
        'breeze-cursor-theme|cursors|Breeze'
}

cm_theme_package_known() {
    local pkg
    while IFS='|' read -r pkg _; do
        [ "$pkg" = "${1:-}" ] && return 0
    done < <(cm_theme_package_table)
    return 1
}

cm_apt_package_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' -- "${1:-}" 2>/dev/null)" == ii* ]]
}

cm_list_theme_packages() {
    local pkg kind brand mark
    printf '%s\n\n' "$(printf "$(cm_t pkg_list_header)" "$(basename "$SCRIPT_PATH")")"
    while IFS='|' read -r pkg kind brand; do
        mark=""
        if command -v dpkg-query >/dev/null 2>&1 && cm_apt_package_installed "$pkg"; then
            mark="  $(cm_t pkg_installed_mark)"
        fi
        printf '  %-26s %-15s %s%s\n' "$pkg" "$(cm_t "pkg_kind_$kind")" "$brand" "$mark"
    done < <(cm_theme_package_table)
}

cm_install_theme_package() {
    local pkg="${1:-}" rc=0
    if [ -z "$pkg" ]; then
        printf '%s\n' "$(cm_t package_required)" >&2
        return 1
    fi
    cm_theme_package_known "$pkg" || {
        printf '%s\n' "$(printf "$(cm_t package_unknown)" "$pkg")" >&2
        return 1
    }
    if [ "$(cm_pkg_manager)" != apt ]; then
        printf '%s\n' "$(cm_t package_apt_only)" >&2
        return 1
    fi
    if cm_apt_package_installed "$pkg"; then
        printf '%s\n' "$(printf "$(cm_t package_already)" "$pkg")"
        return 0
    fi
    cm_apt_install_run 0 "$(printf "$(cm_t package_installing)" "$pkg")" "$pkg" || rc=$?
    case "$rc" in
        2) printf '%s\n' "$(cm_t tempdir_failed)" >&2; return 1 ;;
        3) printf '%s\n' "$(printf "$(cm_t no_terminal_install)" "$pkg")" >&2; return 1 ;;
        4) printf '%s\n' "$(cm_t deps_timeout)" >&2; return 1 ;;
    esac
    if ! cm_apt_package_installed "$pkg"; then
        printf '%s\n' "$(printf "$(cm_t package_failed)" "$pkg")" >&2
        return 1
    fi
    cm_record_installed apt "$pkg" || true
    cm_log "INFO" "$(printf "$(cm_t theme_package_log)" "$pkg")"
    printf '%s\n' "$(printf "$(cm_t package_done)" "$pkg")"
}

# Open ~/.themes in the file manager to hand-edit an imported theme. The
# Panel tab always works on an editable CM-<theme> copy of the active theme.
cm_open_themes_folder() {
    mkdir -p "$HOME/.themes"
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$HOME/.themes" >/dev/null 2>&1 &
    elif command -v nemo >/dev/null 2>&1; then
        nemo "$HOME/.themes" >/dev/null 2>&1 &
    elif command -v nautilus >/dev/null 2>&1; then
        nautilus "$HOME/.themes" >/dev/null 2>&1 &
    else
        printf '%s\n' "$(printf "$(cm_t file_manager_missing)" "$HOME")"
        return 1
    fi
    echo "$HOME/.themes"
}

# ============================================================================
# apply_panel — accent, background and opacity of the Cinnamon panel/menus
#
# Compiled Cinnamon themes expose no CSS variables, so this module edits a COPY
# of the theme (~/.themes/CM-<theme>/), never the original. To undo, use
# "Restore backup" or edit ~/.themes/CM-<theme>/cinnamon/cinnamon.css by hand.
# ============================================================================
cm_panel_target_dir() {
    local base="$1"
    echo "$HOME/.themes/${CM_THEME_PREFIX}-${base}"
}

cm_panel_locate_base() {
    local base="$1" d
    while IFS= read -r d; do
        [ -d "$d/$base/cinnamon" ] && { echo "$d/$base"; return 0; }
    done < <(cm_data_dirs themes)
    return 1
}

# Prepare (or reuse) an editable copy of the active Cinnamon theme.
# Prints "target_dir|base_name".
cm_panel_prepare_custom_theme() {
    local base
    base=$(cm_gs_string org.cinnamon.theme name)
    [ -z "$base" ] && base="Mint-Y-Dark"

    # Already working on a CM-* copy: keep editing that one
    if [[ "$base" == ${CM_THEME_PREFIX}-* ]]; then
        echo "$HOME/.themes/$base|${base#"${CM_THEME_PREFIX}"-}"
        return 0
    fi

    cm_state_set "ORIGINAL_CINNAMON_THEME" "$base"

    local src target
    src=$(cm_panel_locate_base "$base") || { printf '%s\n' "$(printf "$(cm_t base_theme_not_found)" "$base")" >&2; return 1; }
    target=$(cm_panel_target_dir "$base")

    local fresh=0
    [ -e "$target" ] || [ -L "$target" ] || fresh=1
    mkdir -p "$HOME/.themes"
    cm_atomic_copy_dir_if_missing "$src" "$target" || return 1
    [ "$fresh" -eq 0 ] || cm_record_installed themes "${target##*/}" || true

    echo "$target|$base"
}

# Preset accent colors for the Panel tab: a GUI convenience that adds no
# gsettings key. "custom" means "use the color picker above". Labels get their
# hex from CM_ACCENT_PRESET_HEX (see cm_apply_language_labels).
CM_ACCENT_PRESET_ORDER=(custom nord mint dracula gruvbox solarized rose-pine crimson forest catppuccin tokyo-night one-dark monokai cyberpunk sakura lavender amber turquoise emerald)
declare -A CM_ACCENT_PRESET_LABELS=()
declare -A CM_ACCENT_PRESET_HEX=(
    [nord]="#88C0D0"
    [mint]="#56B6C2"
    [dracula]="#BD93F9"
    [gruvbox]="#D79921"
    [solarized]="#268BD2"
    [rose-pine]="#EBBCBA"
    [crimson]="#DC322F"
    [forest]="#3B7A57"
    [catppuccin]="#89B4FA"
    [tokyo-night]="#7AA2F7"
    [one-dark]="#61AFEF"
    [monokai]="#66D9EF"
    [cyberpunk]="#FF2E97"
    [sakura]="#F7A8C4"
    [lavender]="#B39DDB"
    [amber]="#F5A623"
    [turquoise]="#1ABC9C"
    [emerald]="#2ECC71"
)

# Activate the editable copy after writing a new color into it. The gsettings
# result is checked so a failed activation is reported as an error instead of a
# color that sits in the CSS while Cinnamon keeps the old theme.
cm_panel_activate_custom_theme() {
    local base="$1"
    cm_gset org.cinnamon.theme name "${CM_THEME_PREFIX}-${base}" || {
        printf '%s\n' "$(cm_t custom_theme_activation_failed)" >&2
        return 1
    }
}

cm_accent_preset_key_from_label() {
    local label="$1" k
    for k in "${CM_ACCENT_PRESET_ORDER[@]}"; do
        [ "${CM_ACCENT_PRESET_LABELS[$k]}" = "$label" ] && { echo "$k"; return 0; }
    done
    return 1
}

# The panel background does not live in "#panel" (that block only has
# font-weight/height/width/icon color) but in the grouped selector
# ".panel-top, .panel-bottom, .panel-left, .panel-right" (checked against the
# real Mint-Y cinnamon.css, branch master.mint22). "#panel" is still used for
# text/icons (CM_PANEL_FG_BLOCK_RE), where it is correct.
#
# The *_BLOCK_RE patterns require "," "{" or ":" right after the name (spaces
# allowed) instead of any character, so a selector only matches the element
# itself, not a descendant or an id/class that merely shares the prefix
# (".popup-menu #notification...", "#panelLeft", ".menu-top"). Without that
# limit the sed range started there and the color leaked into unrelated blocks.
CM_PANEL_BG_BLOCK_RE='\.panel-(top|bottom|left|right)([[:space:]]*[,{]|:)'
CM_PANEL_FG_BLOCK_RE='(#|\.)panel([[:space:]]*[,{]|:)'
CM_MENU_BLOCK_RE='\.(menu|popup-menu)([[:space:]]*[,{]|:)'

# cm_css_ensure_override <cinnamon.css> <id> <selector> <declaration>
# Safety net for themes lacking the expected selector or any reference color:
# append our own rule at the end instead of failing. At equal specificity the
# later CSS rule wins, so repeating the SAME selector is enough, without
# !important. Marked with an id (see cm_strip_marked_block) so the next apply
# replaces it instead of stacking copies.
cm_css_ensure_override() {
    local css="$1" id="$2" selector="$3" decl="$4"
    local b="/* >>> Color Mint override:${id} (autogenerado, no editar a mano) >>> */"
    local e="/* <<< Color Mint override:${id} <<< */"
    cm_atomic_marked_replace "$css" "$b" "$e" "$b"$'\n'"${selector} { ${decl} }"$'\n'"$e"
}

CM_COLOR_TARGET_ORDER=(accent bg fg menu_bg menu_fg tooltip_bg tooltip_fg gtk_accent)
declare -A CM_COLOR_TARGET_LABELS=()
cm_color_target_key_from_label() {
    local label="$1" k
    for k in "${CM_COLOR_TARGET_ORDER[@]}"; do
        [ "${CM_COLOR_TARGET_LABELS[$k]}" = "$label" ] && { echo "$k"; return 0; }
    done
    echo "accent"
}

# Most frequent hex color in the WHOLE file, ignoring typical blacks, whites
# and grays plus any extra hex values to exclude:
#   cm_panel_dominant_hex <css> [hex...]
cm_panel_dominant_hex() {
    local css="$1"; shift
    local pattern='^#(000000|ffffff|f0f0f0|fafafa|303030|202020'
    local hex clean
    for hex in "$@"; do
        [ -z "$hex" ] && continue
        clean="${hex#\#}"
        pattern="${pattern}|${clean}"
    done
    pattern="${pattern})\$"
    grep -oE '#[0-9A-Fa-f]{6}' "$css" 2>/dev/null \
        | grep -viE "$pattern" \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}

cm_panel_bg_dominant_hex() {
    local css="$1"
    sed -n -E "/${CM_PANEL_BG_BLOCK_RE}/,/\}/ s/.*background(-color)?:[[:space:]]*#([0-9A-Fa-f]{6}).*/#\2/p" "$css" 2>/dev/null \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}

# Same, for TEXT/icon color: matches "color:" (not "background-color:"). The
# "^" anchor is what tells them apart, since compiled Cinnamon CSS usually has
# one declaration per line. No match means the theme sets no plain text color
# there and there is nothing safe to replace.
cm_panel_fg_dominant_hex() {
    local css="$1"
    sed -n -E "/${CM_PANEL_FG_BLOCK_RE}/,/\}/ s/^[[:space:]]*color:[[:space:]]*#([0-9A-Fa-f]{6}).*/#\1/p" "$css" 2>/dev/null \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}

cm_apply_accent_color() {
    local raw="${1:-}"
    if [ -z "$raw" ]; then
        printf '%s\n' "$(cm_t color_required)" >&2
        return 1
    fi

    # Also accept raw yad :CLR output (rgb(...), #RRGGBBAA).
    local new_hex
    new_hex=$(cm_normalize_hex "$raw")
    if ! cm_is_valid_hex "$new_hex"; then
        printf '%s\n' "$(printf "$(cm_t hex_invalid)" "$raw")" >&2
        return 1
    fi
    # Expand #RGB to #RRGGBB so the CSS replacement is consistent
    if [[ "$new_hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]]; then
        new_hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"
    fi

    local info target base css old_hex
    info=$(cm_panel_prepare_custom_theme) || return 1
    target="${info%%|*}"
    base="${info##*|}"
    css="$target/cinnamon/cinnamon.css"

    [ -f "$css" ] || { printf '%s\n' "$(printf "$(cm_t css_not_found)" "$target")" >&2; return 1; }

    local excl_bg excl_fg excl_menu_bg excl_menu_fg excl_tip_bg excl_tip_fg
    excl_bg=$(cm_panel_bg_dominant_hex "$css")
    excl_fg=$(cm_panel_fg_dominant_hex "$css")
    excl_menu_bg=$(cm_panel_menu_bg_dominant_hex "$css")
    excl_menu_fg=$(cm_panel_menu_fg_dominant_hex "$css")
    excl_tip_bg=$(cm_panel_tooltip_bg_dominant_hex "$css")
    excl_tip_fg=$(cm_panel_tooltip_fg_dominant_hex "$css")
    old_hex=$(cm_panel_dominant_hex "$css" "$excl_bg" "$excl_fg" "$excl_menu_bg" "$excl_menu_fg" "$excl_tip_bg" "$excl_tip_fg")
    if [ -z "$old_hex" ]; then
        printf '%s\n' "$(cm_t accent_warning)" >&2
        return 1
    fi

    cm_atomic_sed_locked "$css" "s/${old_hex}/${new_hex}/gI" || return 1
    # Also apply to the gtk.css bundled in the same theme, if any
    if [ -f "$target/gtk-3.0/gtk.css" ]; then
        cm_atomic_sed_locked "$target/gtk-3.0/gtk.css" "s/${old_hex}/${new_hex}/gI" || return 1
    fi

    cm_panel_activate_custom_theme "$base" || return 1
    cm_state_set "ACCENT_COLOR" "$new_hex"
    printf '%s\n' "$(printf "$(cm_t accent_applied)" "$old_hex" "$new_hex" "${CM_THEME_PREFIX}-${base}")"
}

cm_replace_block_bg_color() {
    local css="$1" block="$2" new_hex="$3"
    local r g b before_sum after_sum old_desc
    r=$((16#${new_hex:1:2})); g=$((16#${new_hex:3:2})); b=$((16#${new_hex:5:2}))

    old_desc=$(sed -n -E "/${block}/,/\}/ s/.*(rgba\\([0-9]+,[[:space:]]*[0-9]+,[[:space:]]*[0-9]+,[[:space:]]*[0-9.]+\\)).*/\\1/p" "$css" 2>/dev/null | head -n1)
    before_sum=$(md5sum "$css" 2>/dev/null | awk '{print $1}')
    cm_atomic_sed_locked "$css" -E "/${block}/,/\}/ s/rgba\\([0-9]+,[[:space:]]*[0-9]+,[[:space:]]*[0-9]+,[[:space:]]*([0-9.]+)\\)/rgba(${r}, ${g}, ${b}, \\1)/gI" || return 1
    after_sum=$(md5sum "$css" 2>/dev/null | awk '{print $1}')

    if [ "$before_sum" != "$after_sum" ]; then
        echo "${old_desc:-rgba(...)}"
        return 0
    fi

    local old_hex
    old_hex=$(sed -n -E "/${block}/,/\}/ s/.*background(-color)?:[[:space:]]*#([0-9A-Fa-f]{6}).*/#\\2/p" "$css" 2>/dev/null | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
    [ -z "$old_hex" ] && return 1

    cm_atomic_sed_locked "$css" -E "/${block}/,/\}/ s/(background(-color)?:[[:space:]]*)#[0-9A-Fa-f]{6}/\\1${new_hex}/gI" || return 1
    echo "$old_hex"
    return 0
}

cm_apply_panel_bg_color() {
    local raw="${1:-}"
    if [ -z "$raw" ]; then
        printf '%s\n' "$(cm_t color_required)" >&2
        return 1
    fi
    local new_hex
    new_hex=$(cm_normalize_hex "$raw")
    if ! cm_is_valid_hex "$new_hex"; then
        printf '%s\n' "$(printf "$(cm_t hex_invalid)" "$raw")" >&2
        return 1
    fi
    if [[ "$new_hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]]; then
        new_hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"
    fi

    local info target base css old_desc
    info=$(cm_panel_prepare_custom_theme) || return 1
    target="${info%%|*}"
    base="${info##*|}"
    css="$target/cinnamon/cinnamon.css"
    [ -f "$css" ] || { printf '%s\n' "$(printf "$(cm_t css_not_found)" "$target")" >&2; return 1; }

    if ! old_desc=$(cm_replace_block_bg_color "$css" "$CM_PANEL_BG_BLOCK_RE" "$new_hex"); then
        cm_css_ensure_override "$css" "panel-bg" ".panel-top, .panel-bottom, .panel-left, .panel-right" "background-color: ${new_hex};"
        old_desc="$(cm_t theme_no_match)"
    fi

    cm_panel_activate_custom_theme "$base" || return 1
    cm_state_set "PANEL_BG_COLOR" "$new_hex"
    printf '%s\n' "$(printf "$(cm_t panel_bg_applied)" "$old_desc" "$new_hex" "${CM_THEME_PREFIX}-${base}")"
}

cm_apply_panel_fg_color() {
    local raw="${1:-}"
    if [ -z "$raw" ]; then
        printf '%s\n' "$(cm_t color_required)" >&2
        return 1
    fi
    local new_hex
    new_hex=$(cm_normalize_hex "$raw")
    if ! cm_is_valid_hex "$new_hex"; then
        printf '%s\n' "$(printf "$(cm_t hex_invalid)" "$raw")" >&2
        return 1
    fi
    if [[ "$new_hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]]; then
        new_hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"
    fi

    local info target base css old_hex
    info=$(cm_panel_prepare_custom_theme) || return 1
    target="${info%%|*}"
    base="${info##*|}"
    css="$target/cinnamon/cinnamon.css"
    [ -f "$css" ] || { printf '%s\n' "$(printf "$(cm_t css_not_found)" "$target")" >&2; return 1; }

    old_hex=$(cm_panel_fg_dominant_hex "$css")
    if [ -z "$old_hex" ]; then
        cm_css_ensure_override "$css" "panel-fg" "#panel" "color: ${new_hex};"
        old_hex="$(cm_t theme_no_match)"
    else
        cm_atomic_sed_locked "$css" -E "/${CM_PANEL_FG_BLOCK_RE}/,/\}/ s/^([[:space:]]*color:[[:space:]]*)#[0-9A-Fa-f]{6}/\1${new_hex}/gI" || return 1
    fi

    cm_panel_activate_custom_theme "$base" || return 1
    cm_state_set "PANEL_FG_COLOR" "$new_hex"
    printf '%s\n' "$(printf "$(cm_t panel_fg_applied)" "$old_hex" "$new_hex" "${CM_THEME_PREFIX}-${base}")"
}

cm_panel_menu_bg_dominant_hex() {
    local css="$1"
    sed -n -E "/${CM_MENU_BLOCK_RE}/,/\}/ s/.*background(-color)?:[[:space:]]*#([0-9A-Fa-f]{6}).*/#\2/p" "$css" 2>/dev/null \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}
cm_panel_menu_fg_dominant_hex() {
    local css="$1"
    sed -n -E "/${CM_MENU_BLOCK_RE}/,/\}/ s/^[[:space:]]*color:[[:space:]]*#([0-9A-Fa-f]{6}).*/#\1/p" "$css" 2>/dev/null \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}

cm_apply_menu_bg_color() {
    local raw="${1:-}"
    if [ -z "$raw" ]; then
        printf '%s\n' "$(cm_t color_required)" >&2
        return 1
    fi
    local new_hex
    new_hex=$(cm_normalize_hex "$raw")
    if ! cm_is_valid_hex "$new_hex"; then
        printf '%s\n' "$(printf "$(cm_t hex_invalid)" "$raw")" >&2
        return 1
    fi
    if [[ "$new_hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]]; then
        new_hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"
    fi

    local info target base css old_desc
    info=$(cm_panel_prepare_custom_theme) || return 1
    target="${info%%|*}"
    base="${info##*|}"
    css="$target/cinnamon/cinnamon.css"
    [ -f "$css" ] || { printf '%s\n' "$(printf "$(cm_t css_not_found)" "$target")" >&2; return 1; }

    if ! old_desc=$(cm_replace_block_bg_color "$css" "$CM_MENU_BLOCK_RE" "$new_hex"); then
        cm_css_ensure_override "$css" "menu-bg" ".menu, .popup-menu" "background-color: ${new_hex};"
        old_desc="$(cm_t theme_no_match)"
    fi

    cm_panel_activate_custom_theme "$base" || return 1
    cm_state_set "MENU_BG_COLOR" "$new_hex"
    printf '%s\n' "$(printf "$(cm_t menu_bg_applied)" "$old_desc" "$new_hex" "${CM_THEME_PREFIX}-${base}")"
}

cm_apply_menu_fg_color() {
    local raw="${1:-}"
    if [ -z "$raw" ]; then
        printf '%s\n' "$(cm_t color_required)" >&2
        return 1
    fi
    local new_hex
    new_hex=$(cm_normalize_hex "$raw")
    if ! cm_is_valid_hex "$new_hex"; then
        printf '%s\n' "$(printf "$(cm_t hex_invalid)" "$raw")" >&2
        return 1
    fi
    if [[ "$new_hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]]; then
        new_hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"
    fi

    local info target base css old_hex
    info=$(cm_panel_prepare_custom_theme) || return 1
    target="${info%%|*}"
    base="${info##*|}"
    css="$target/cinnamon/cinnamon.css"
    [ -f "$css" ] || { printf '%s\n' "$(printf "$(cm_t css_not_found)" "$target")" >&2; return 1; }

    old_hex=$(cm_panel_menu_fg_dominant_hex "$css")
    if [ -z "$old_hex" ]; then
        cm_css_ensure_override "$css" "menu-fg" ".menu, .popup-menu" "color: ${new_hex};"
        old_hex="$(cm_t theme_no_match)"
    else
        cm_atomic_sed_locked "$css" -E "/${CM_MENU_BLOCK_RE}/,/\}/ s/^([[:space:]]*color:[[:space:]]*)#[0-9A-Fa-f]{6}/\1${new_hex}/gI" || return 1
    fi

    cm_panel_activate_custom_theme "$base" || return 1
    cm_state_set "MENU_FG_COLOR" "$new_hex"
    printf '%s\n' "$(printf "$(cm_t menu_fg_applied)" "$old_hex" "$new_hex" "${CM_THEME_PREFIX}-${base}")"
}

cm_panel_tooltip_fg_dominant_hex() {
    sed -n -E "/#[Tt]ooltip|\.tooltip([^-]|$)/,/\}/ s/^[[:space:]]*color:[[:space:]]*#([0-9A-Fa-f]{6}).*/#\1/p" "$1" 2>/dev/null \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}

cm_panel_tooltip_bg_dominant_hex() {
    sed -n -E "/#[Tt]ooltip|\.tooltip([^-]|$)/,/\}/ s/.*background(-color)?:[[:space:]]*#([0-9A-Fa-f]{6}).*/#\2/p" "$1" 2>/dev/null \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}

cm_apply_tooltip_bg_color() {
    local raw="${1:-}" new_hex
    [ -z "$raw" ] && { printf '%s\n' "$(cm_t color_required)" >&2; return 1; }
    new_hex=$(cm_normalize_hex "$raw")
    cm_is_valid_hex "$new_hex" || { printf '%s\n' "$(printf "$(cm_t hex_invalid)" "$raw")" >&2; return 1; }
    [[ "$new_hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]] && new_hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"
    local info target base css old_desc
    info=$(cm_panel_prepare_custom_theme) || return 1
    target="${info%%|*}"; base="${info##*|}"; css="$target/cinnamon/cinnamon.css"
    [ -f "$css" ] || { printf '%s\n' "$(printf "$(cm_t css_not_found)" "$target")" >&2; return 1; }
    if ! old_desc=$(cm_replace_block_bg_color "$css" '#[Tt]ooltip' "$new_hex"); then
        cm_css_ensure_override "$css" "tooltip-bg" "#Tooltip" "background-color: ${new_hex};"
        old_desc="$(cm_t theme_no_match)"
    fi
    cm_panel_activate_custom_theme "$base" || return 1
    cm_state_set "TOOLTIP_BG_COLOR" "$new_hex"
    printf '%s\n' "$(printf "$(cm_t tooltip_bg_applied)" "$old_desc" "$new_hex" "${CM_THEME_PREFIX}-${base}")"
}

cm_apply_tooltip_fg_color() {
    local raw="${1:-}" new_hex
    [ -z "$raw" ] && { printf '%s\n' "$(cm_t color_required)" >&2; return 1; }
    new_hex=$(cm_normalize_hex "$raw")
    cm_is_valid_hex "$new_hex" || { printf '%s\n' "$(printf "$(cm_t hex_invalid)" "$raw")" >&2; return 1; }
    [[ "$new_hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]] && new_hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"
    local info target base css old_hex
    info=$(cm_panel_prepare_custom_theme) || return 1
    target="${info%%|*}"; base="${info##*|}"; css="$target/cinnamon/cinnamon.css"
    [ -f "$css" ] || { printf '%s\n' "$(printf "$(cm_t css_not_found)" "$target")" >&2; return 1; }
    old_hex=$(cm_panel_tooltip_fg_dominant_hex "$css")
    if [ -z "$old_hex" ]; then
        cm_css_ensure_override "$css" "tooltip-fg" "#Tooltip" "color: ${new_hex};"
        old_hex="$(cm_t theme_no_match)"
    else
        cm_atomic_sed_locked "$css" -E "/#[Tt]ooltip/,/\}/ s/^([[:space:]]*color:[[:space:]]*)#[0-9A-Fa-f]{6}/\1${new_hex}/gI" || return 1
    fi
    cm_panel_activate_custom_theme "$base" || return 1
    cm_state_set "TOOLTIP_FG_COLOR" "$new_hex"
    printf '%s\n' "$(printf "$(cm_t tooltip_fg_applied)" "$old_hex" "$new_hex" "${CM_THEME_PREFIX}-${base}")"
}

# The Cinnamon theme a reset puts back; nothing unless ORIGINAL_CINNAMON_THEME is set and the active theme is a Color Mint
# copy (CM-*) or cannot be read. The record is written when the panel is first customized and never cleared, so with the
# original active again there is nothing to put back, and a theme the user chose since is not Color Mint's to undo.
cm_panel_theme_to_restore() {
    local original current
    original=$(cm_state_get "ORIGINAL_CINNAMON_THEME" "")
    [ -n "$original" ] || return 0
    current=$(cm_gs_string org.cinnamon.theme name) || current=""
    if [ -z "$current" ] || [[ "$current" == "${CM_THEME_PREFIX}-"* ]]; then
        printf '%s\n' "$original"
    fi
}

cm_reset_panel_colors() {
    local original had_gtk_accent=0 gtk_status=0 gtk_err
    original=$(cm_panel_theme_to_restore)
    gtk_err=$(cm_reset_gtk_accent_color 2>&1 >/dev/null) || gtk_status=$?
    [ "$gtk_status" -ne 0 ] || had_gtk_accent=1
    [ "$gtk_status" -ne 2 ] || printf '%s\n' "$gtk_err" >&2
    if [ -z "$original" ] && [ "$had_gtk_accent" -eq 0 ]; then
        [ "$gtk_status" -eq 2 ] && return 1
        printf '%s\n' "$(cm_t color_reset_none)" >&2
        return 1
    fi
    local restore_fail=0
    if [ -n "$original" ]; then
        cm_gset org.cinnamon.theme name "$original" || restore_fail=1
    fi
    local _msg
    _msg="$(cm_t reset_colors_summary)"
    if [ -n "$original" ]; then
        if [ "$restore_fail" -eq 1 ]; then
            _msg="${_msg}$(printf "$(cm_t theme_restore_failed)" "$original")"
        else
            _msg="${_msg}$(printf "$(cm_t reset_colors_original_theme)" "$original")"
        fi
    fi
    [ "$had_gtk_accent" -eq 1 ] && _msg="${_msg}$(cm_t reset_colors_gtk_included)"
    printf "%s\n" "${_msg}."
    [ "$gtk_status" -ne 2 ]
}

# --- global GTK accent: GTK3 and libadwaita apps, not just the panel
#
# GTK3 has no accent-color gsettings key (that is libadwaita/GTK4 on newer
# desktops). The standard trick is to redefine the named colors themes already
# use (theme_selected_bg_color/fg_color and the GTK4 accent_* equivalents) in
# the USER gtk.css, which GTK loads with higher priority than the theme.
# GTK3, GTK4 and libadwaita read it once per process, so only apps started
# afterwards show the accent (measured: GTK 3.24.41, GTK 4.14.5, libadwaita
# 1.5.0). Plain GTK4 paints nothing from these names; the visible effect is on
# GTK3, libadwaita and themes that use them. By their documentation, Flatpak
# apps (the sandbox does not expose ~/.config/gtk-*) and GTK2 apps (they read
# gtkrc, not gtk.css) do not get it by default; not measured here.
CM_GTK_ACCENT_BEGIN="/* >>> Color Mint: acento GTK global (autogenerado, no editar a mano) >>> */"
CM_GTK_ACCENT_END="/* <<< Color Mint: acento GTK global <<< */"

# Remove Color Mint's block from a gtk.css, if present (used on reapply and on
# reset, to avoid duplicates).
cm_strip_gtk_accent_block() { cm_strip_marked_block "$1" "$CM_GTK_ACCENT_BEGIN" "$CM_GTK_ACCENT_END"; }

# The block in ~/.config/gtk-4.0/gtk.css has two independent parts: an optional @import of a theme's gtk-4.0
# stylesheet, which goes first so the accent lines after it win (measured: the later @define-color wins), and the
# accent lines. The file is the only record of both: each writer reads the other part from it and keeps it.

# cm_gtk4_block_part <import|accent>: the lines of that part of the block, without the marks.
cm_gtk4_block_part() {
    awk -v b="$CM_GTK_ACCENT_BEGIN" -v e="$CM_GTK_ACCENT_END" -v part="$1" '
        $0 == b { inblock = 1; next }
        $0 == e { inblock = 0; next }
        inblock && (($0 ~ /^@import "/) == (part == "import")) { print }
    ' "$HOME/.config/gtk-4.0/gtk.css" 2>/dev/null || true
}

# cm_gtk4_block_set <import|accent> <lines>: replace one part of the block and keep the other; with nothing left in
# either part the block goes. Read and write happen under one lock, so two commands cannot undo each other.
cm_gtk4_block_set() {
    local part="$1" lines="$2" file="$HOME/.config/gtk-4.0/gtk.css" imp acc body="" status
    cm_lock || return 1
    imp=$(cm_gtk4_block_part import); acc=$(cm_gtk4_block_part accent)
    if [ "$part" = import ]; then imp="$lines"; else acc="$lines"; fi
    if [ -n "$imp$acc" ]; then
        body="$CM_GTK_ACCENT_BEGIN"
        [ -z "$imp" ] || body+=$'\n'"$imp"
        [ -z "$acc" ] || body+=$'\n'"$acc"
        body+=$'\n'"$CM_GTK_ACCENT_END"
        mkdir -p "$HOME/.config/gtk-4.0" 2>/dev/null
    elif ! grep -qF "$CM_GTK_ACCENT_BEGIN" "$file" 2>/dev/null; then
        cm_unlock
        return 0
    fi
    cm_look_marked_replace "$file" "$CM_GTK_ACCENT_BEGIN" "$CM_GTK_ACCENT_END" "$body"
    status=$?
    cm_unlock
    return "$status"
}

cm_apply_gtk_accent_color() {
    local raw="${1:-}" hex
    [ -z "$raw" ] && { printf '%s\n' "$(cm_t color_required)" >&2; return 1; }
    hex=$(cm_normalize_hex "$raw")
    cm_is_valid_hex "$hex" || { printf '%s\n' "$(printf "$(cm_t hex_invalid)" "$raw")" >&2; return 1; }
    if [[ "$hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]]; then
        hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"
    fi

    local fg
    fg=$(cm_accent_fg "$hex")

    local acc_lines
    acc_lines="@define-color theme_selected_bg_color ${hex};"$'\n'"@define-color theme_selected_fg_color ${fg};"$'\n'"@define-color accent_color ${hex};"$'\n'"@define-color accent_bg_color ${hex};"$'\n'"@define-color accent_fg_color ${fg};"$'\n'"*:selected, *:selected:focus { background-color: ${hex}; color: ${fg}; }"
    cm_look_targets_ok "$HOME/.config/gtk-3.0/gtk.css" "$HOME/.config/gtk-4.0/gtk.css" || return 1
    mkdir -p "$HOME/.config/gtk-3.0" 2>/dev/null
    cm_look_marked_replace "$HOME/.config/gtk-3.0/gtk.css" "$CM_GTK_ACCENT_BEGIN" "$CM_GTK_ACCENT_END" \
        "$CM_GTK_ACCENT_BEGIN"$'\n'"$acc_lines"$'\n'"$CM_GTK_ACCENT_END" || return 1
    cm_gtk4_block_set accent "$acc_lines" || return 1

    cm_state_set "GTK_ACCENT_COLOR" "$hex"
    printf '%s\n' "$(printf "$(cm_t gtk_accent_applied)" "$hex")"
}

# Returns 0 when the accent was removed, 1 when there was none and 2 when a block is left because its file cannot be
# written (the file is named on stderr).
cm_reset_gtk_accent_color() {
    local file found=0 failed=0
    file="$HOME/.config/gtk-3.0/gtk.css"
    if [ -f "$file" ] && grep -qF "$CM_GTK_ACCENT_BEGIN" "$file" 2>/dev/null; then
        if cm_strip_gtk_accent_block "$file"; then found=1; else failed=1; fi
    fi
    file="$HOME/.config/gtk-4.0/gtk.css"
    if [ -f "$file" ] && grep -qF "$CM_GTK_ACCENT_BEGIN" "$file" 2>/dev/null; then
        if [ -z "$(cm_gtk4_block_part import)" ]; then
            if cm_strip_gtk_accent_block "$file"; then found=1; else failed=1; fi
        elif [ -n "$(cm_gtk4_block_part accent)" ]; then
            if cm_gtk4_block_set accent ""; then found=1; else failed=1; fi
        fi
    fi
    [ "$failed" -eq 0 ] || return 2
    if [ "$found" -eq 1 ]; then
        printf '%s\n' "$(cm_t gtk_accent_reset)"
        return 0
    fi
    printf '%s\n' "$(cm_t gtk_accent_none)" >&2
    return 1
}

# Status 0 while a panel reset would change something, 1 when it would not: after a reset the original-theme record is
# still there, and a second press would repeat the confirmation, the backup and the notice for nothing. A gtk-4.0 block
# with only the libadwaita import is not an accent; the reset leaves it alone.
cm_panel_reset_pending() {
    local file
    [ -z "$(cm_panel_theme_to_restore)" ] || return 0
    file="$HOME/.config/gtk-3.0/gtk.css"
    if [ -f "$file" ] && grep -qF "$CM_GTK_ACCENT_BEGIN" "$file" 2>/dev/null; then return 0; fi
    file="$HOME/.config/gtk-4.0/gtk.css"
    if [ -f "$file" ] && grep -qF "$CM_GTK_ACCENT_BEGIN" "$file" 2>/dev/null; then
        [ -z "$(cm_gtk4_block_part import)" ] && return 0
        [ -n "$(cm_gtk4_block_part accent)" ] && return 0
    fi
    return 1
}

# --- libadwaita with the GTK theme's own gtk-4.0 style (optional)
#
# libadwaita ignores the GTK theme, so a theme's gtk-4.0 stylesheet reaches libadwaita apps only when the user's
# gtk.css imports it. `theme libadwaita on` puts that @import in the block above the accent lines; the import line
# is the whole state. While it is there, a GTK theme or light/dark change that Color Mint makes rewrites it. The
# stylesheet is chosen when it is written: this GTK/libadwaita reads no gtk-dark.css of the user, takes no @media
# and does not switch an imported file when the scheme changes (measured: GTK 4.14.5, libadwaita 1.5.0).

cm_current_gtk_theme() {
    cm_gs_string org.cinnamon.desktop.interface gtk-theme
}

# The scheme the portal holds: default when it is unset or the schema is missing (libadwaita then paints light).
cm_libadwaita_scheme() {
    local v
    v=$(cm_gs_string org.x.apps.portal color-scheme) || v=""
    case "$v" in prefer-dark|prefer-light) printf '%s\n' "$v" ;; *) printf '%s\n' default ;; esac
}

# cm_libadwaita_stylesheet <theme> <scheme>: the stylesheet to import. prefer-dark takes gtk-dark.css and falls
# back to gtk.css; the others take gtk.css. A plain file that can be read, as GTK itself opens it. Status 1: none.
cm_libadwaita_stylesheet() {
    local dir
    cm_validate_theme_name "$1" || return 1
    dir=$(cm_find_theme_dir themes "$1") || return 1
    if [ "$2" = prefer-dark ] && [ -f "$dir/gtk-4.0/gtk-dark.css" ] && [ -r "$dir/gtk-4.0/gtk-dark.css" ]; then
        printf '%s\n' "$dir/gtk-4.0/gtk-dark.css"
    elif [ -f "$dir/gtk-4.0/gtk.css" ] && [ -r "$dir/gtk-4.0/gtk.css" ]; then
        printf '%s\n' "$dir/gtk-4.0/gtk.css"
    else
        return 1
    fi
}

# cm_libadwaita_import_line <path>: the @import line, as an absolute path in a double-quoted string, the one form
# that takes spaces, accents, brackets and ; } * # % { unescaped and is not decoded (measured: GTK 4.14.5): only \ and "
# are escaped. A relative path or a control character (the block is made of lines) is refused with status 2.
cm_libadwaita_import_line() {
    local path="$1"
    [[ "$path" == /* ]] || return 2
    [[ "$path" =~ [[:cntrl:]] ]] && return 2
    path=${path//\\/\\\\}
    path=${path//\"/\\\"}
    printf '@import "%s";\n' "$path"
}

# cm_css_imports_resource <file>: whether the stylesheet @imports a resource:// URL outside its comments. Yaru ships
# its gtk-4.0 style that way, next to a gtk.gresource that GTK registers only when the theme is chosen by name: from a
# user's gtk.css the import fails in every process and nothing enters (measured: GTK 4.14.5).
cm_css_imports_resource() {
    awk '
    { line = $0
      while (length(line)) {
          if (inc) { i = index(line, "*/"); if (!i) break; line = substr(line, i + 2); inc = 0 }
          else { i = index(line, "/*"); if (!i) { buf = buf line; break }
                 buf = buf substr(line, 1, i - 1) " "; line = substr(line, i + 2); inc = 1 } }
      buf = buf "\n" }
    END { exit !(tolower(buf) ~ /@import[ \t\n]*(url\([ \t\n]*)?["\047]?[ \t\n]*resource:/) }' "$1"
}

# cm_libadwaita_write <theme> <scheme>: point the block's import at that theme. Status: 1 no stylesheet, 2 path that
# cannot be imported, 3 write failed (the reason is on stderr), 4 the stylesheet imports a bundled resource. On the dark
# scheme a theme with no gtk-dark.css has its gtk.css imported, with a warning: Color Mint cannot tell whether that
# sheet is dark, and a light one paints a light window on libadwaita's dark palette (measured: GTK 4.14.5, libadwaita 1.5.0).
cm_libadwaita_write() {
    local css line
    css=$(cm_libadwaita_stylesheet "$1" "$2") || return 1
    ! cm_css_imports_resource "$css" || return 4
    line=$(cm_libadwaita_import_line "$css") || return 2
    cm_gtk4_block_set import "$line" || return 3
    if [ "$2" = prefer-dark ] && [ "${css##*/}" = gtk.css ]; then
        printf '%s\n' "$(printf "$(cm_t libadwaita_no_dark_sheet)" "$1")" >&2
    fi
    return 0
}

# A pack or a look sets the theme and then the scheme. With the refresh held (CM_LIBADWAITA_HOLD=1) neither step moves
# the import; cm_libadwaita_hold runs it once for the pair that ends up set. Without it the first step judged the new
# theme against the old scheme and warned about the dark scheme that was about to change.
CM_LIBADWAITA_HOLD=0

# cm_libadwaita_hold <command...>: run the command with the refresh held, then refresh whatever its status was (a
# command that stops halfway has still changed the theme or the scheme). Status: the command's, or 1 if only the
# refresh failed.
cm_libadwaita_hold() {
    local status=0
    CM_LIBADWAITA_HOLD=1
    "$@" || status=$?
    CM_LIBADWAITA_HOLD=0
    cm_libadwaita_refresh || [ "$status" -ne 0 ] || status=1
    return "$status"
}

# cm_libadwaita_refresh [theme] [scheme]: after Color Mint changes the GTK theme or the scheme, keep an existing import
# in step with it. Silent and cheap when there is none. A theme with no gtk-4.0 style takes the import away (and says
# so); only a failed write is a failure.
cm_libadwaita_refresh() {
    local theme="${1:-}" scheme="${2:-}" rc=0
    [ "$CM_LIBADWAITA_HOLD" -eq 0 ] || return 0
    [ -f "$HOME/.config/gtk-4.0/gtk.css" ] && [ -n "$(cm_gtk4_block_part import)" ] || return 0
    [ -n "$theme" ] || theme=$(cm_current_gtk_theme)
    [ -n "$theme" ] || return 0
    [ -n "$scheme" ] || scheme=$(cm_libadwaita_scheme)
    cm_libadwaita_write "$theme" "$scheme" || rc=$?
    case "$rc" in
        0) return 0 ;;
        1|2) cm_gtk4_block_set import "" || return 1
             printf '%s\n' "$(printf "$(cm_t libadwaita_dropped)" "$theme")" ;;
        4)   cm_gtk4_block_set import "" || return 1
             printf '%s\n' "$(printf "$(cm_t libadwaita_dropped_bundled)" "$theme")" ;;
        *) return 1 ;;
    esac
}

# cm_libadwaita_import_path: the file the block's import points at, as written (status 1 when there is no import).
cm_libadwaita_import_path() {
    local line path
    line=$(cm_gtk4_block_part import)
    line=${line%%$'\n'*}
    [ -n "$line" ] || return 1
    path=${line#@import \"}
    path=${path%\";}
    path=${path//\\\"/\"}
    path=${path//\\\\/\\}
    printf '%s\n' "$path"
}

# cm_libadwaita_active: whether libadwaita apps get a theme's style now, that is, the import points at a file that
# exists. An import left behind by a theme that was deleted does nothing (the GUI box stays unchecked).
cm_libadwaita_active() {
    local path
    path=$(cm_libadwaita_import_path) && [ -f "$path" ]
}

# cm_apply_libadwaita <on|off|status>
cm_apply_libadwaita() {
    local theme rc=0 path
    case "${1:-status}" in
        on)
            theme=$(cm_current_gtk_theme)
            [ -n "$theme" ] || { printf '%s\n' "$(cm_t libadwaita_no_theme)" >&2; return 1; }
            cm_libadwaita_write "$theme" "$(cm_libadwaita_scheme)" || rc=$?
            case "$rc" in
                0) ;;
                1) printf '%s\n' "$(printf "$(cm_t libadwaita_no_gtk4)" "$theme")" >&2; return 1 ;;
                2) printf '%s\n' "$(printf "$(cm_t libadwaita_path_invalid)" "$theme")" >&2; return 1 ;;
                4) printf '%s\n' "$(printf "$(cm_t libadwaita_bundled)" "$theme")" >&2; return 1 ;;
                *) return 1 ;;
            esac
            printf '%s\n' "$(printf "$(cm_t libadwaita_on)" "$theme")"
            ;;
        off)
            if [ -z "$(cm_gtk4_block_part import)" ]; then
                printf '%s\n' "$(cm_t libadwaita_already_off)"
                return 0
            fi
            cm_gtk4_block_set import "" || return 1
            printf '%s\n' "$(cm_t libadwaita_off)"
            ;;
        status)
            if ! path=$(cm_libadwaita_import_path); then
                printf '%s\n' "$(cm_t libadwaita_status_off)"
                return 0
            fi
            if [ -f "$path" ]; then
                printf '%s\n' "$(printf "$(cm_t libadwaita_status_on)" "$path")"
            else
                printf '%s\n' "$(printf "$(cm_t libadwaita_status_stale)" "$path")"
            fi
            ;;
    esac
}

cm_apply_panel_opacity() {
    local pct="${1:-}"   # 0-100
    if ! cm_int_in_range "$pct" 0 100; then
        printf '%s\n' "$(cm_t opacity_invalid)" >&2
        return 1
    fi

    local info target base css alpha
    info=$(cm_panel_prepare_custom_theme) || return 1
    target="${info%%|*}"
    base="${info##*|}"
    css="$target/cinnamon/cinnamon.css"
    [ -f "$css" ] || { printf '%s\n' "$(printf "$(cm_t css_not_found)" "$css")" >&2; return 1; }

    # LC_ALL=C: awk prints "%.2f" with the locale's decimal comma (es_ES, es_CO,
    # es_MX...), e.g. "0,90". That would be injected as "rgba(r, g, b, 0,90)",
    # invalid CSS that Cinnamon drops silently.
    alpha=$(LC_ALL=C awk -v p="$pct" 'BEGIN{printf "%.2f", p/100}')

    # Set the alpha of rgba(...) backgrounds inside the panel blocks. The file is
    # compared before/after to warn when the theme has no rgba(...) there (e.g.
    # plain hex colors) and the change had no visual effect.
    local before_sum after_sum
    before_sum=$(md5sum "$css" 2>/dev/null | awk '{print $1}')
    cm_atomic_sed_locked "$css" -E "/${CM_PANEL_BG_BLOCK_RE}/,/\}/ s/rgba\\(([0-9]+,[[:space:]]*[0-9]+,[[:space:]]*[0-9]+),[[:space:]]*[0-9.]+\\)/rgba(\\1, ${alpha})/g" || return 1
    after_sum=$(md5sum "$css" 2>/dev/null | awk '{print $1}')

    if [ "$before_sum" = "$after_sum" ]; then
        local hexbg r g b
        hexbg=$(cm_panel_bg_dominant_hex "$css")
        if [ -n "$hexbg" ]; then
            r=$((16#${hexbg:1:2})); g=$((16#${hexbg:3:2})); b=$((16#${hexbg:5:2}))
            cm_atomic_sed_locked "$css" -E "/${CM_PANEL_BG_BLOCK_RE}/,/\}/ s/(background(-color)?:[[:space:]]*)#[0-9A-Fa-f]{6}/\1rgba(${r}, ${g}, ${b}, ${alpha})/gI" || return 1
            after_sum=$(md5sum "$css" 2>/dev/null | awk '{print $1}')
        fi
    fi

    cm_panel_activate_custom_theme "$base" || return 1
    cm_state_set "PANEL_OPACITY" "$pct"

    if [ "$before_sum" = "$after_sum" ]; then
        printf '%s\n' "$(cm_t opacity_warning)" >&2
    fi
    printf '%s\n' "$(printf "$(cm_t opacity_applied)" "$pct")"
}

# Height (px) of the main panel (id 1). "org.cinnamon panels-height" is a list
# of "panelId:height" strings (no monitor field, unlike panels-enabled).
# Cinnamon Settings caps it at 60px in its own UI; 16-100 is accepted here.
cm_apply_panel_height() {
    local px="${1:-}"
    if ! cm_int_in_range "$px" 16 100; then
        printf '%s\n' "$(cm_t height_invalid)" >&2
        return 1
    fi

    local current entry id height found=0
    local -a new_list=()
    current=$(gsettings get org.cinnamon panels-height 2>/dev/null)
    current="${current#@as }"
    while IFS= read -r entry; do
        entry="${entry//\'/}"
        cm_trim_var entry
        [ -z "$entry" ] && continue
        IFS=':' read -r id height <<< "$entry"
        if [ "$id" = "1" ]; then
            new_list+=("'${id}:${px}'")
            found=1
        else
            new_list+=("'${entry}'")
        fi
    done < <(echo "$current" | tr -d '[]' | tr ',' '\n')

    [ "$found" -eq 0 ] && new_list+=("'1:${px}'")

    local joined="" item first=1
    for item in "${new_list[@]}"; do
        if [ "$first" -eq 1 ]; then joined="$item"; first=0; else joined="$joined, $item"; fi
    done

    cm_gset org.cinnamon panels-height "[$joined]" || return 1
    printf '%s\n' "$(printf "$(cm_t height_applied)" "$px")"
}

# Read the current height of panel id 1 (to preload the form)
cm_current_panel_height() {
    local current entry id height result="40"
    current=$(gsettings get org.cinnamon panels-height 2>/dev/null)
    current="${current#@as }"
    while IFS= read -r entry; do
        entry="${entry//\'/}"
        cm_trim_var entry
        [ -z "$entry" ] && continue
        IFS=':' read -r id height <<< "$entry"
        if [ "$id" = "1" ]; then result="$height"; break; fi
    done < <(echo "$current" | tr -d '[]' | tr ',' '\n')
    echo "$result"
}

# ============================================================================
# apply_desktop — panel position, window buttons and hot corners
#
# Uses only Cinnamon gsettings schemas checked against its official
# .gschema.xml:
#   org.cinnamon panels-enabled                       -> panel position
#   org.cinnamon.desktop.wm.preferences button-layout -> window buttons
#   org.cinnamon hotcorner-layout                     -> hot corners
# ============================================================================

# --- panel position
cm_apply_panel_position() {
    local position="$1"
    case "$position" in
        top|bottom) : ;;
        *) printf '%s\n' "$(printf "$(cm_t position_invalid)" "$position")" >&2; return 1 ;;
    esac

    local current entry id mon pos found=0
    local -a new_list=()
    current=$(gsettings get org.cinnamon panels-enabled 2>/dev/null)
    current="${current#@as }"
    while IFS= read -r entry; do
        entry="${entry//\'/}"
        cm_trim_var entry
        [ -z "$entry" ] && continue
        IFS=':' read -r id mon pos <<< "$entry"
        if [ "$id" = "1" ]; then
            new_list+=("'${id}:${mon}:${position}'")
            found=1
        else
            new_list+=("'${entry}'")
        fi
    done < <(echo "$current" | tr -d '[]' | tr ',' '\n')

    [ "$found" -eq 0 ] && new_list+=("'1:0:${position}'")

    local joined="" item first=1
    for item in "${new_list[@]}"; do
        if [ "$first" -eq 1 ]; then joined="$item"; first=0; else joined="$joined, $item"; fi
    done

    cm_gset org.cinnamon panels-enabled "[$joined]" || return 1
    printf '%s\n' "$(printf "$(cm_t panel_position_applied)" "${position}")"
}

# Read the current position of panel id 1 (to preload presets)
cm_current_panel_position() {
    local current entry id mon pos result="bottom"
    current=$(gsettings get org.cinnamon panels-enabled 2>/dev/null)
    current="${current#@as }"
    while IFS= read -r entry; do
        entry="${entry//\'/}"
        cm_trim_var entry
        [ -z "$entry" ] && continue
        IFS=':' read -r id mon pos <<< "$entry"
        if [ "$id" = "1" ]; then result="$pos"; break; fi
    done < <(echo "$current" | tr -d '[]' | tr ',' '\n')
    echo "$result"
}

# --- window buttons
# Short keys for the CLI and presets; each maps to a real button-layout string
# ("left:right", comma-separated names). Any value that matches no key is used
# as-is as a custom string (e.g. "close,minimize:maximize").
CM_BUTTON_PRESET_ORDER=(derecha izquierda gnome mac-clasico compacto menu-izquierda solo-cerrar-izquierda)
declare -A CM_BUTTON_PRESETS=(
    [derecha]=":minimize,maximize,close"
    [izquierda]="close,maximize,minimize:"
    [gnome]=":close"
    [mac-clasico]="close:minimize,maximize"
    [compacto]=":minimize,close"
    [menu-izquierda]="menu:minimize,maximize,close"
    [solo-cerrar-izquierda]="close:"
)
declare -A CM_BUTTON_PRESET_LABELS=()

cm_list_button_presets() {
    local k
    for k in "${CM_BUTTON_PRESET_ORDER[@]}"; do
        echo "$k -> ${CM_BUTTON_PRESETS[$k]}"
    done
}

cm_button_preset_key_from_label() {
    local label="$1" k
    for k in "${CM_BUTTON_PRESET_ORDER[@]}"; do
        [ "${CM_BUTTON_PRESET_LABELS[$k]}" = "$label" ] && { echo "$k"; return 0; }
    done
    return 1
}

# Find which preset (if any) matches an applied button-layout string, to
# preload the Desktop tab with the real value.
cm_button_preset_key_from_value() {
    local val="$1" k
    for k in "${CM_BUTTON_PRESET_ORDER[@]}"; do
        [ "${CM_BUTTON_PRESETS[$k]}" = "$val" ] && { echo "$k"; return 0; }
    done
    return 1
}

# cm_apply_window_buttons <preset-key|custom-string>
cm_apply_window_buttons() {
    local input="$1"
    [ -z "$input" ] && { printf '%s\n' "$(cm_t buttons_empty)" >&2; return 1; }
    local layout="${CM_BUTTON_PRESETS[$input]:-$input}"
    cm_gset org.cinnamon.desktop.wm.preferences button-layout "$layout" || return 1
    printf '%s\n' "$(printf "$(cm_t buttons_applied)" "$layout")"
}

cm_current_window_buttons() {
    cm_gs_string org.cinnamon.desktop.wm.preferences button-layout
}

# --- hot corners
# Four corners in the order top-left, top-right, bottom-left, bottom-right; each
# value is none|expo|scale|desktop. "none" disables the corner
# (hover-enabled=false).
CM_CORNER_ORDER=(none expo scale desktop)
declare -A CM_CORNER_LABELS=()

cm_corner_key_from_label() {
    local label="$1" k
    for k in "${CM_CORNER_ORDER[@]}"; do
        [ "${CM_CORNER_LABELS[$k]}" = "$label" ] && { echo "$k"; return 0; }
    done
    echo "none"
}

# cm_apply_hotcorners <tl> <tr> <bl> <br>
cm_apply_hotcorners() {
    local corner
    local -a corners=("${1:-none}" "${2:-none}" "${3:-none}" "${4:-none}") out=()
    for corner in "${corners[@]}"; do
        case "$corner" in
            none)              out+=("'expo:false:0'") ;;
            expo|scale|desktop) out+=("'${corner}:true:0'") ;;
            *)
                printf '%s\n' "$(printf "$(cm_t corners_invalid)" "$corner")" >&2
                return 1
                ;;
        esac
    done
    local joined="${out[0]}, ${out[1]}, ${out[2]}, ${out[3]}"
    cm_gset org.cinnamon hotcorner-layout "[$joined]" || return 1
    printf '%s\n' "$(cm_t corners_applied)"
}

# Print the current state of the 4 corners as 4 space-separated words
# (none|expo|scale|desktop), in hotcorner-layout order.
cm_current_hotcorners() {
    local current entry func hover idx=0
    local -a codes=(none none none none)
    current=$(gsettings get org.cinnamon hotcorner-layout 2>/dev/null)
    current="${current#@as }"
    while IFS= read -r entry; do
        entry="${entry//\'/}"
        cm_trim_var entry
        [ -z "$entry" ] && continue
        IFS=':' read -r func hover _ <<< "$entry"
        if [ "$hover" = "true" ]; then
            codes[idx]="$func"
        else
            codes[idx]="none"
        fi
        idx=$((idx+1))
        [ "$idx" -ge 4 ] && break
    done < <(echo "$current" | tr -d '[]' | tr ',' '\n')
    echo "${codes[0]} ${codes[1]} ${codes[2]} ${codes[3]}"
}

# --- effects, workspaces and desktop icons

cm_apply_desktop_effects() {
    local val="${1:-}"
    case "$val" in
        on|true|si|sí)   cm_gset org.cinnamon desktop-effects true  || return 1; printf '%s\n' "$(cm_t window_effects_on)" ;;
        off|false|no)    cm_gset org.cinnamon desktop-effects false || return 1; printf '%s\n' "$(cm_t window_effects_off)" ;;
        *) printf '%s\n' "$(printf "$(cm_t effects_invalid)" "$val")" >&2; return 1 ;;
    esac
}
cm_current_desktop_effects() {
    local v; v=$(gsettings get org.cinnamon desktop-effects 2>/dev/null)
    [ "$v" = "false" ] && echo "off" || echo "on"
}

cm_apply_menu_effects() {
    local val="${1:-}"
    case "$val" in
        on|true|si|sí)   cm_gset org.cinnamon desktop-effects-on-menus true  || return 1; printf '%s\n' "$(cm_t menu_effects_on)" ;;
        off|false|no)    cm_gset org.cinnamon desktop-effects-on-menus false || return 1; printf '%s\n' "$(cm_t menu_effects_off)" ;;
        *) printf '%s\n' "$(printf "$(cm_t effects_invalid)" "$val")" >&2; return 1 ;;
    esac
}
cm_current_menu_effects() {
    local v; v=$(gsettings get org.cinnamon desktop-effects-on-menus 2>/dev/null)
    [ "$v" = "false" ] && echo "off" || echo "on"
}

# Fixed number of workspaces. Muffin reads num-workspaces only while org.cinnamon.muffin dynamic-workspaces is off (its
# default; Settings has no switch for it: muffin 6.0 to 6.6, Cinnamon Settings master). Turned on by hand, it makes
# Cinnamon manage the count itself, and the change is made but not seen: that is said after it.
cm_apply_workspaces() {
    local n="${1:-}"
    if ! cm_int_in_range "$n" 1 20; then
        printf '%s\n' "$(cm_t workspaces_invalid)" >&2
        return 1
    fi
    cm_gset org.cinnamon.desktop.wm.preferences num-workspaces "$n" || return 1
    printf '%s\n' "$(printf "$(cm_t workspaces_applied)" "$n")"
    if [ "$(gsettings get org.cinnamon.muffin dynamic-workspaces 2>/dev/null)" = true ]; then
        printf '%s\n' "$(cm_t workspaces_dynamic)" >&2
    fi
}
cm_current_workspaces() {
    gsettings get org.cinnamon.desktop.wm.preferences num-workspaces 2>/dev/null | tr -d "'" || echo "4"
}

cm_apply_desktop_icons() {
    local val="${1:-}"
    case "$val" in
        show|true|si|sí) cm_gset org.nemo.desktop show-desktop-icons true  || return 1; printf '%s\n' "$(cm_t icons_shown)" ;;
        hide|false|no)   cm_gset org.nemo.desktop show-desktop-icons false || return 1; printf '%s\n' "$(cm_t icons_hidden)" ;;
        *) printf '%s\n' "$(printf "$(cm_t icons_invalid)" "$val")" >&2; return 1 ;;
    esac
}
cm_current_desktop_icons() {
    local v; v=$(gsettings get org.nemo.desktop show-desktop-icons 2>/dev/null)
    [ "$v" = "false" ] && echo "hide" || echo "show"
}

# --- desktop background color (independent of the wallpaper)
# org.cinnamon.desktop.background primary-color is the fallback color shown
# behind the image (or instead of it in "solo_color" mode). picture-uri is never
# touched: the current image is only dropped when the user explicitly picks
# "solo_color".
CM_BGMODE_ORDER=(mantener solo_color)
declare -A CM_BGMODE_LABELS=()
cm_bgmode_key_from_label() {
    local label="$1"
    [ "$label" = "${CM_BGMODE_LABELS[solo_color]}" ] && { echo "solo_color"; return 0; }
    echo "mantener"
}

cm_apply_desktop_bg_color() {
    local raw="${1:-}" mode="${2:-mantener}" hex
    [ -z "$raw" ] && { printf '%s\n' "$(cm_t color_required)" >&2; return 1; }
    hex=$(cm_normalize_hex "$raw")
    cm_is_valid_hex "$hex" || { printf '%s\n' "$(printf "$(cm_t hex_invalid)" "$raw")" >&2; return 1; }
    [[ "$hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]] && hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"

    cm_gset org.cinnamon.desktop.background primary-color "$hex" || return 1
    cm_gset org.cinnamon.desktop.background color-shading-type "solid" || return 1
    if [ "$mode" = "solo_color" ]; then
        cm_gset org.cinnamon.desktop.background picture-options "none" || return 1
    else
        # If an earlier "solo_color" apply removed the image (picture-options=none),
        # Restore it here; otherwise the public "mantener" mode would remain color-only.
        local cur_po; cur_po=$(cm_gs_string org.cinnamon.desktop.background picture-options)
        [ "$cur_po" = "none" ] && cm_gset org.cinnamon.desktop.background picture-options "zoom" 2>/dev/null
    fi
    cm_state_set "DESKTOP_BG_COLOR" "$hex"
    if [ "$mode" = "solo_color" ]; then
        printf '%s\n' "$(printf "$(cm_t desktop_bg_applied)" "$hex")"
    else
        printf '%s\n' "$(printf "$(cm_t desktop_bg_kept)" "$hex")"
    fi
}

cm_current_desktop_bg_color() {
    cm_gs_string org.cinnamon.desktop.background primary-color || echo "#2E3440"
}

declare -A CM_PANELPOS_LABELS=()
cm_panelpos_key_from_label() {
    local label="$1"
    [ "$label" = "${CM_PANELPOS_LABELS[top]}" ] && { echo "top"; return 0; }
    echo "bottom"
}

CM_ONOFF_ORDER=(on off)
declare -A CM_ONOFF_LABELS=()
cm_onoff_key_from_label() {
    local label="$1"
    [ "$label" = "${CM_ONOFF_LABELS[off]}" ] && { echo "off"; return 0; }
    echo "on"
}

CM_SHOWHIDE_ORDER=(show hide)
declare -A CM_SHOWHIDE_LABELS=()
cm_showhide_key_from_label() {
    local label="$1"
    [ "$label" = "${CM_SHOWHIDE_LABELS[hide]}" ] && { echo "hide"; return 0; }
    echo "show"
}

# ============================================================================
# apply_terminal — color palettes for the default gnome-terminal profile
# ============================================================================
declare -A CM_PALETTES=(
    [nord]="['#3B4252','#BF616A','#A3BE8C','#EBCB8B','#81A1C1','#B48EAD','#88C0D0','#E5E9F0','#4C566A','#BF616A','#A3BE8C','#EBCB8B','#81A1C1','#B48EAD','#8FBCBB','#ECEFF4']|#2E3440|#D8DEE9"
    [dracula]="['#21222C','#FF5555','#50FA7B','#F1FA8C','#BD93F9','#FF79C6','#8BE9FD','#F8F8F2','#6272A4','#FF6E6E','#69FF94','#FFFFA5','#D6ACFF','#FF92DF','#A4FFFF','#FFFFFF']|#282A36|#F8F8F2"
    [gruvbox]="['#282828','#CC241D','#98971A','#D79921','#458588','#B16286','#689D6A','#A89984','#928374','#FB4934','#B8BB26','#FABD2F','#83A598','#D3869B','#8EC07C','#EBDBB2']|#282828|#EBDBB2"
    [solarized-dark]="['#073642','#DC322F','#859900','#B58900','#268BD2','#D33682','#2AA198','#EEE8D5','#002B36','#CB4B16','#586E75','#657B83','#839496','#6C71C4','#93A1A1','#FDF6E3']|#002B36|#839496"
    [solarized-light]="['#073642','#DC322F','#859900','#B58900','#268BD2','#D33682','#2AA198','#EEE8D5','#002B36','#CB4B16','#586E75','#657B83','#839496','#6C71C4','#93A1A1','#FDF6E3']|#FDF6E3|#657B83"
    [monokai]="['#272822','#F92672','#A6E22E','#F4BF75','#66D9EF','#AE81FF','#A1EFE4','#F8F8F2','#75715E','#F92672','#A6E22E','#F4BF75','#66D9EF','#AE81FF','#A1EFE4','#F9F8F5']|#272822|#F8F8F2"
    [one-dark]="['#282C34','#E06C75','#98C379','#E5C07B','#61AFEF','#C678DD','#56B6C2','#ABB2BF','#5C6370','#E06C75','#98C379','#E5C07B','#61AFEF','#C678DD','#56B6C2','#FFFFFF']|#282C34|#ABB2BF"
    [tokyo-night]="['#15161E','#F7768E','#9ECE6A','#E0AF68','#7AA2F7','#BB9AF7','#7DCFFF','#A9B1D6','#414868','#F7768E','#9ECE6A','#E0AF68','#7AA2F7','#BB9AF7','#7DCFFF','#C0CAF5']|#1A1B26|#C0CAF5"
    [catppuccin-mocha]="['#45475A','#F38BA8','#A6E3A1','#F9E2AF','#89B4FA','#F5C2E7','#94E2D5','#BAC2DE','#585B70','#F38BA8','#A6E3A1','#F9E2AF','#89B4FA','#F5C2E7','#94E2D5','#A6ADC8']|#1E1E2E|#CDD6F4"
)

# The schema is org.gnome.Terminal.ProfilesList (key "default");
# org.gnome.terminal.legacy.profile-manager does not exist.
cm_terminal_profile_uuid() {
    cm_gs_string org.gnome.Terminal.ProfilesList default
}

cm_apply_terminal_palette() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        printf '%s\n' "$(cm_t palette_name_required)" >&2
        return 1
    fi
    local data="${CM_PALETTES[$name]:-}"
    [ -z "$data" ] && { printf '%s\n' "$(printf "$(cm_t palette_unknown)" "$name")" >&2; return 1; }

    local palette bg fg uuid path
    palette="${data%%|*}"
    bg=$(echo "$data" | cut -d'|' -f2)
    fg=$(echo "$data" | cut -d'|' -f3)

    uuid=$(cm_terminal_profile_uuid)
    if [ -z "$uuid" ]; then
        printf '%s\n' "$(cm_t terminal_profile_missing)" >&2
        return 1
    fi
    path="/org/gnome/terminal/legacy/profiles:/:${uuid}/"

    cm_dwrite "${path}palette"           "$palette"  || return 1
    cm_dwrite "${path}background-color"  "'${bg}'"   || return 1
    cm_dwrite "${path}foreground-color"  "'${fg}'"   || return 1
    cm_dwrite "${path}use-theme-colors"  "false"      || return 1

    cm_state_set "TERMINAL_PALETTE" "$name"
    printf '%s\n' "$(printf "$(cm_t palette_applied)" "$name")"
}

cm_list_terminal_palettes() {
    local k
    for k in "${!CM_PALETTES[@]}"; do echo "$k"; done | sort
}

CM_PALETTE_ORDER=(nord dracula gruvbox solarized-dark solarized-light monokai one-dark tokyo-night catppuccin-mocha)
declare -A CM_PALETTE_LABELS=()
cm_palette_key_from_label() {
    local label="$1" k
    for k in "${CM_PALETTE_ORDER[@]}"; do
        [ "${CM_PALETTE_LABELS[$k]}" = "$label" ] && { echo "$k"; return 0; }
    done
    return 1
}

# Custom background/text colors beyond the fixed palettes. Applied ONLY when
# given (empty = untouched), always on the same default profile as
# cm_apply_terminal_palette.
cm_apply_terminal_custom_colors() {
    local bg_raw="${1:-}" fg_raw="${2:-}" uuid path bg fg
    uuid=$(cm_terminal_profile_uuid)
    if [ -z "$uuid" ]; then
        printf '%s\n' "$(cm_t terminal_profile_missing)" >&2
        return 1
    fi
    path="/org/gnome/terminal/legacy/profiles:/:${uuid}/"

    if [ -n "$bg_raw" ]; then
        bg=$(cm_normalize_hex "$bg_raw")
        cm_is_valid_hex "$bg" || { printf '%s\n' "$(printf "$(cm_t terminal_color_invalid)" "$bg_raw")" >&2; return 1; }
        cm_dwrite "${path}background-color" "'${bg}'" || return 1
    fi
    if [ -n "$fg_raw" ]; then
        fg=$(cm_normalize_hex "$fg_raw")
        cm_is_valid_hex "$fg" || { printf '%s\n' "$(printf "$(cm_t terminal_fg_invalid)" "$fg_raw")" >&2; return 1; }
        cm_dwrite "${path}foreground-color" "'${fg}'" || return 1
    fi
    if [ -z "$bg_raw" ] && [ -z "$fg_raw" ]; then
        printf '%s\n' "$(cm_t terminal_color_required)" >&2
        return 1
    fi
    cm_dwrite "${path}use-theme-colors" "false" || return 1
    local bg_part="" fg_part=""
    [ -n "$bg" ] && bg_part=$(printf "$(cm_t terminal_bg_part)" "$bg")
    [ -n "$fg" ] && fg_part=$(printf "$(cm_t terminal_fg_part)" "$fg")
    printf '%s\n' "$(printf "$(cm_t terminal_custom_applied)" "$bg_part" "$fg_part")"
}

# ============================================================================
# apply_fonts — typography, antialiasing and hinting
#
# The gsettings keys for antialiasing/hinting vary with the Cinnamon /
# settings-daemon version, so this module applies them through
# ~/.config/fontconfig/fonts.conf (always supported) and also tries gsettings,
# silently.
# ============================================================================
CM_ANTIALIAS_ORDER=(rgba grayscale none)
declare -A CM_ANTIALIAS_LABELS=()
cm_antialias_key_from_label() {
    local label="$1" k
    for k in "${CM_ANTIALIAS_ORDER[@]}"; do
        [ "${CM_ANTIALIAS_LABELS[$k]}" = "$label" ] && { echo "$k"; return 0; }
    done
    echo "rgba"
}

CM_HINTING_ORDER=(slight medium full none)
declare -A CM_HINTING_LABELS=()
cm_hinting_key_from_label() {
    local label="$1" k
    for k in "${CM_HINTING_ORDER[@]}"; do
        [ "${CM_HINTING_LABELS[$k]}" = "$label" ] && { echo "$k"; return 0; }
    done
    echo "slight"
}

cm_apply_font_name() {
    local font="${1:-}"
    [ -z "$font" ] && { printf '%s\n' "$(cm_t font_required)" >&2; return 1; }
    cm_validate_font_name "$font" || { printf '%s\n' "$(printf "$(cm_t font_name_invalid)" "$font")" >&2; return 1; }
    cm_gset org.cinnamon.desktop.interface font-name "$font" || return 1
    gsettings set org.cinnamon.desktop.wm.preferences titlebar-font "$font" 2>/dev/null || true
    printf '%s\n' "$(printf "$(cm_t font_applied)" "$font")"
}

cm_apply_monospace_font() {
    local font="${1:-}"
    [ -z "$font" ] && { printf '%s\n' "$(cm_t mono_required)" >&2; return 1; }
    cm_validate_font_name "$font" || { printf '%s\n' "$(cm_t font_name_invalid)" >&2; return 1; }
    cm_gset org.gnome.desktop.interface monospace-font-name "$font" || return 1
    printf '%s\n' "$(printf "$(cm_t mono_applied)" "$font")"
}

# Rebuild the applied antialiasing/hinting from ~/.config/fontconfig/fonts.conf
# (if present) to preload the Fonts tab. Prints "<antialias> <hinting>"
# (e.g. "rgba slight").
cm_current_font_rendering() {
    local conf="$HOME/.config/fontconfig/fonts.conf"
    local antialias="rgba" hinting="slight"
    if [ -f "$conf" ]; then
        local aa rgba hs
        aa=$(sed -n 's/.*<edit name="antialias"[^>]*><bool>\([a-z]*\)<\/bool>.*/\1/p' "$conf" | head -n1)
        rgba=$(sed -n 's/.*<edit name="rgba"[^>]*><const>\([a-z]*\)<\/const>.*/\1/p' "$conf" | head -n1)
        hs=$(sed -n 's/.*<edit name="hintstyle"[^>]*><const>hint\([a-z]*\)<\/const>.*/\1/p' "$conf" | head -n1)
        if [ "$aa" = "false" ]; then
            antialias="none"
        elif [ "$rgba" = "rgb" ]; then
            antialias="rgba"
        else
            antialias="grayscale"
        fi
        [ -n "$hs" ] && hinting="$hs"
    fi
    echo "$antialias $hinting"
}

# cm_apply_font_rendering <antialias: rgba|grayscale|none> <hinting: none|slight|medium|full>
#
# fontconfig's <rgba> does not accept "rgba" (valid: none/rgb/bgr/vrgb/vbgr), so
# the UI option is translated:
#   rgba      -> antialiasing ON,  subpixel "rgb"
#   grayscale -> antialiasing ON,  subpixel "none" (grayscale only)
#   none      -> antialiasing OFF
cm_apply_font_rendering() {
    local antialias="${1:-}" hinting="${2:-}"
    if [ -z "$antialias" ] || [ -z "$hinting" ]; then
        printf '%s\n' "$(cm_t rendering_invalid)" >&2
        return 1
    fi
    local antialias_bool="true" rgba_value="none"

    case "$antialias" in
        none)      antialias_bool="false"; rgba_value="none" ;;
        grayscale) antialias_bool="true";  rgba_value="none" ;;
        rgba|rgb)  antialias_bool="true";  rgba_value="rgb"  ;;
        *)         printf '%s\n' "$(cm_t rendering_invalid)" >&2; return 1 ;;
    esac
    case "$hinting" in
        none|slight|medium|full) ;;
        *) printf '%s\n' "$(cm_t rendering_invalid)" >&2; return 1 ;;
    esac

    mkdir -p "$HOME/.config/fontconfig"
    if ! cm_lock; then
        printf '%s\n' "$(printf "$(cm_t fonts_conf_failed)" "$HOME")" >&2
        return 1
    fi
    if cm_look_write "$HOME/.config/fontconfig/fonts.conf" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <!-- Color Mint: generated file; "uninstall --restore-look" removes it -->
  <match target="font">
    <edit name="antialias" mode="assign"><bool>${antialias_bool}</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hint${hinting}</const></edit>
    <edit name="rgba" mode="assign"><const>${rgba_value}</const></edit>
  </match>
</fontconfig>
EOF
    then
        cm_unlock
    else
        cm_unlock
        printf '%s\n' "$(printf "$(cm_t fonts_conf_failed)" "$HOME")" >&2
        return 1
    fi
    gsettings set org.cinnamon.settings-daemon.plugins.xsettings hinting "$hinting"       2>/dev/null || true
    gsettings set org.cinnamon.settings-daemon.plugins.xsettings antialiasing "$antialias" 2>/dev/null || true
    printf '%s\n' "$(printf "$(cm_t rendering_applied)" "$antialias" "$hinting")"
}

# Global text scale (org.cinnamon.desktop.interface text-scaling-factor, a
# decimal factor where 1.0 = 100%), exposed as an integer percentage (50-200)
# for the GUI slider and the CLI.
cm_apply_text_scaling() {
    local pct="${1:-}"
    if ! cm_int_in_range "$pct" 50 200; then
        printf '%s\n' "$(cm_t scaling_invalid)" >&2
        return 1
    fi
    local factor
    factor=$(LC_ALL=C awk -v p="$pct" 'BEGIN{printf "%.2f", p/100}')
    cm_gset org.cinnamon.desktop.interface text-scaling-factor "$factor" || return 1
    printf '%s\n' "$(printf "$(cm_t scaling_applied)" "$pct" "$factor")"
}

# Read the current factor as an integer percentage (to preload the form);
# assumes 100% if missing or non-numeric.
cm_current_text_scaling() {
    local factor pct
    factor=$(gsettings get org.cinnamon.desktop.interface text-scaling-factor 2>/dev/null)
    pct=$(LC_ALL=C awk -v f="$factor" 'BEGIN{ if (f+0 > 0) printf "%d", (f*100)+0.5; else print 100 }' 2>/dev/null)
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=100
    echo "$pct"
}

# ============================================================================
# presets — save, list and load complete looks
#
# A preset is a plain key=value text file in $CM_PRESETS_DIR; it can be edited
# by hand or managed from the Profiles tab.
# ============================================================================
cm_save_preset() {
    local name="${1:-}"
    [ -z "$name" ] && { printf '%s\n' "$(cm_t preset_name_required)" >&2; return 1; }
    case "$name" in */*|*..*) printf '%s\n' "$(cm_t preset_name_invalid)" >&2; return 1 ;; esac
    mkdir -p "$CM_PRESETS_DIR"
    local file="$CM_PRESETS_DIR/${name}.conf"

    local gtk_theme icon_theme cursor_theme cinn_theme color_scheme font_name mono_font
    gtk_theme=$(cm_gs_string org.cinnamon.desktop.interface gtk-theme)
    icon_theme=$(cm_gs_string org.cinnamon.desktop.interface icon-theme)
    cursor_theme=$(cm_gs_string org.cinnamon.desktop.interface cursor-theme)
    cinn_theme=$(cm_gs_string org.cinnamon.theme name)
    color_scheme=$(cm_gs_string org.x.apps.portal color-scheme)
    font_name=$(cm_gs_string org.cinnamon.desktop.interface font-name)
    mono_font=$(cm_gs_string org.gnome.desktop.interface monospace-font-name)

    local panel_position window_buttons hotcorners hc_tl hc_tr hc_bl hc_br
    panel_position=$(cm_current_panel_position)
    window_buttons=$(cm_current_window_buttons)
    hotcorners=$(cm_current_hotcorners)
    read -r hc_tl hc_tr hc_bl hc_br <<< "$hotcorners"

    local cursor_size panel_height text_scaling antialias hinting
    cursor_size=$(cm_current_cursor_size)
    panel_height=$(cm_current_panel_height)
    text_scaling=$(cm_current_text_scaling)
    read -r antialias hinting <<< "$(cm_current_font_rendering)"

    # Desktop settings that can be re-read live from gsettings
    local workspaces effects menu_fx icons desktop_bg
    workspaces=$(cm_current_workspaces)
    effects=$(cm_current_desktop_effects)
    menu_fx=$(cm_current_menu_effects)
    icons=$(cm_current_desktop_icons)
    desktop_bg=$(cm_current_desktop_bg_color)

    cm_lock || { printf '%s\n' "$(printf "$(cm_t file_write_failed)" "$file")" >&2; return 1; }
    if cm_atomic_write "$file" <<EOF
# Preset generated by Color Mint - $(date '+%Y-%m-%d %H:%M:%S')
# Edit these values by hand and load the preset from the Profiles tab
GTK_THEME="$gtk_theme"
ICON_THEME="$icon_theme"
CURSOR_THEME="$cursor_theme"
CURSOR_SIZE="$cursor_size"
CINNAMON_THEME="$cinn_theme"
COLOR_SCHEME="$color_scheme"
FONT_NAME="$font_name"
MONOSPACE_FONT="$mono_font"
FONT_ANTIALIAS="$antialias"
FONT_HINTING="$hinting"
TEXT_SCALING="$text_scaling"
ACCENT_COLOR="$(cm_state_get "ACCENT_COLOR" "#88C0D0")"
PANEL_BG_COLOR="$(cm_state_get "PANEL_BG_COLOR" "")"
PANEL_FG_COLOR="$(cm_state_get "PANEL_FG_COLOR" "")"
MENU_BG_COLOR="$(cm_state_get "MENU_BG_COLOR" "")"
MENU_FG_COLOR="$(cm_state_get "MENU_FG_COLOR" "")"
TOOLTIP_BG_COLOR="$(cm_state_get "TOOLTIP_BG_COLOR" "")"
TOOLTIP_FG_COLOR="$(cm_state_get "TOOLTIP_FG_COLOR" "")"
GTK_ACCENT_COLOR="$(cm_state_get "GTK_ACCENT_COLOR" "")"
PANEL_OPACITY="$(cm_state_get "PANEL_OPACITY" "90")"
PANEL_HEIGHT="$panel_height"
TERMINAL_PALETTE="$(cm_state_get "TERMINAL_PALETTE" "nord")"
PANEL_POSITION="$panel_position"
WINDOW_BUTTONS="$window_buttons"
HOTCORNER_TL="$hc_tl"
HOTCORNER_TR="$hc_tr"
HOTCORNER_BL="$hc_bl"
HOTCORNER_BR="$hc_br"
WORKSPACES="$workspaces"
DESKTOP_EFFECTS="$effects"
MENU_EFFECTS="$menu_fx"
DESKTOP_ICONS="$icons"
DESKTOP_BG_COLOR="$desktop_bg"
EOF
    then
        cm_unlock
    else
        cm_unlock
        printf '%s\n' "$(printf "$(cm_t file_write_failed)" "$file")" >&2
        return 1
    fi
    cm_log "INFO" "$(printf "$(cm_t preset_saved_log)" "$file")"
    echo "$file"
}

cm_list_presets() {
    mkdir -p "$CM_PRESETS_DIR"
    local f base
    for f in "$CM_PRESETS_DIR"/*.conf; do
        [ -e "$f" ] || continue
        base=$(basename "$f" .conf)
        echo "$base"
    done
}

# Every key a preset may hold, in the order they are saved and applied.
CM_PRESET_KEYS=(
    GTK_THEME ICON_THEME CURSOR_THEME CURSOR_SIZE CINNAMON_THEME COLOR_SCHEME FONT_NAME MONOSPACE_FONT
    FONT_ANTIALIAS FONT_HINTING TEXT_SCALING ACCENT_COLOR PANEL_BG_COLOR PANEL_FG_COLOR
    MENU_BG_COLOR MENU_FG_COLOR TOOLTIP_BG_COLOR TOOLTIP_FG_COLOR GTK_ACCENT_COLOR PANEL_OPACITY
    PANEL_HEIGHT TERMINAL_PALETTE PANEL_POSITION WINDOW_BUTTONS HOTCORNER_TL HOTCORNER_TR
    HOTCORNER_BL HOTCORNER_BR WORKSPACES DESKTOP_EFFECTS MENU_EFFECTS DESKTOP_ICONS DESKTOP_BG_COLOR
)
declare -A CM_PRESET_KEY_SET=()
for _cm_key in "${CM_PRESET_KEYS[@]}"; do CM_PRESET_KEY_SET[$_cm_key]=1; done
unset _cm_key

# The preset read by cm_preset_parse (plain global: no namerefs, which Bash 4.0 lacks).
declare -A CM_PRESET=()
# What cm_preset_validate found that does not stop the preset (see there), one line each.
declare -a CM_PRESET_NOTES=()

# cm_preset_parse <file>: read a preset as data into CM_PRESET. Only KEY="value" lines, comments and
# blank lines are accepted, with a known key and a value free of shell syntax. Nothing is executed or
# applied; on a bad line it says which one and returns 1.
cm_preset_parse() {
    local file="$1" line key value n=0
    local preset_re='^([A-Z_]+)="([^"]*)"$'
    CM_PRESET=()
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        [ -z "$line" ] && continue
        case "$line" in '#'*) continue ;; esac
        if [[ ! "$line" =~ $preset_re ]]; then
            printf '%s\n' "$(printf "$(cm_t preset_bad_line)" "$n")" >&2
            return 1
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        if [ -z "${CM_PRESET_KEY_SET[$key]:-}" ]; then
            printf '%s\n' "$(printf "$(cm_t preset_unknown_key)" "$n" "$key")" >&2
            return 1
        fi
        case "$value" in
            *'\'*|*[[:cntrl:]]*|*'$('*|*'`'*|*';'*|*'|'*)
                printf '%s\n' "$(printf "$(cm_t preset_bad_chars)" "$n")" >&2
                return 1
                ;;
        esac
        CM_PRESET[$key]="$value"
    done < "$file"
    [ ${#CM_PRESET[@]} -gt 0 ] || { printf '%s\n' "$(cm_t preset_invalid)" >&2; return 1; }
}

# cm_preset_check_value <key> <non-empty value>: the same rules the cm_apply_* functions enforce, with
# no side effects. Status 0 = fine, 1 = not a valid value, 2 = a theme that is not installed.
cm_preset_check_value() {
    local key="$1" value="$2" hex
    case "$key" in
        GTK_THEME)      cm_validate_theme_name "$value" || return 1; cm_theme_installed themes "$value" || return 2 ;;
        ICON_THEME|CURSOR_THEME)
                        cm_validate_theme_name "$value" || return 1; cm_theme_installed icons "$value" || return 2 ;;
        CINNAMON_THEME) cm_validate_theme_name "$value" || return 1; cm_theme_installed cinnamon "$value" || return 2 ;;
        COLOR_SCHEME)   case "$value" in default|prefer-dark|prefer-light) ;; *) return 1 ;; esac ;;
        FONT_NAME|MONOSPACE_FONT) cm_validate_font_name "$value" ;;
        CURSOR_SIZE)    cm_int_in_range "$value" 16 96 ;;
        TEXT_SCALING)   cm_int_in_range "$value" 50 200 ;;
        PANEL_OPACITY)  cm_int_in_range "$value" 0 100 ;;
        PANEL_HEIGHT)   cm_int_in_range "$value" 16 100 ;;
        WORKSPACES)     cm_int_in_range "$value" 1 20 ;;
        ACCENT_COLOR|PANEL_BG_COLOR|PANEL_FG_COLOR|MENU_BG_COLOR|MENU_FG_COLOR|TOOLTIP_BG_COLOR|\
        TOOLTIP_FG_COLOR|GTK_ACCENT_COLOR|DESKTOP_BG_COLOR)
                        hex=$(cm_normalize_hex "$value"); cm_is_valid_hex "$hex" ;;
        FONT_ANTIALIAS) case "$value" in none|grayscale|rgba|rgb) ;; *) return 1 ;; esac ;;
        FONT_HINTING)   case "$value" in none|slight|medium|full) ;; *) return 1 ;; esac ;;
        TERMINAL_PALETTE) [ -n "${CM_PALETTES[$value]:-}" ] ;;
        PANEL_POSITION) case "$value" in top|bottom) ;; *) return 1 ;; esac ;;
        WINDOW_BUTTONS) ;;
        HOTCORNER_TL|HOTCORNER_TR|HOTCORNER_BL|HOTCORNER_BR)
                        case "$value" in none|expo|scale|desktop) ;; *) return 1 ;; esac ;;
        DESKTOP_EFFECTS|MENU_EFFECTS) case "$value" in on|true|si|sí|off|false|no) ;; *) return 1 ;; esac ;;
        DESKTOP_ICONS)  case "$value" in show|true|si|sí|hide|false|no) ;; *) return 1 ;; esac ;;
        *)              return 1 ;;
    esac
}

# cm_preset_validate <name>: check everything in CM_PRESET before anything is applied, so a missing
# theme or a bad value cannot leave the desktop half changed. It lists every problem, not only the first.
cm_preset_validate() {
    local name="$1" sharing="${2:-}" key value rc group member
    local -a problems=()
    CM_PRESET_NOTES=()
    for key in "${CM_PRESET_KEYS[@]}"; do
        value="${CM_PRESET[$key]:-}"
        [ -n "$value" ] || continue
        rc=0
        cm_preset_check_value "$key" "$value" || rc=$?
        case "$rc" in
            0) ;;
            2) if [ -n "$sharing" ]; then
                   CM_PRESET_NOTES+=("$(printf "$(cm_t preset_problem_theme)" "$key" "$value")")
               else
                   problems+=("$(printf "$(cm_t preset_problem_theme)" "$key" "$value")")
               fi ;;
            *) problems+=("$(printf "$(cm_t preset_problem_value)" "$key" "$value")") ;;
        esac
        if [ "$key" = CURSOR_THEME ] && [ "$rc" = 0 ] && ! cm_theme_has_cursors "$value"; then
            CM_PRESET_NOTES+=("$(printf "$(cm_t preset_problem_cursor)" "$key" "$value")")
        fi
    done
    # Settings that are applied as one unit need all their keys or none.
    for group in "FONT_ANTIALIAS FONT_HINTING" "HOTCORNER_TL HOTCORNER_TR HOTCORNER_BL HOTCORNER_BR"; do
        local set_count=0 total=0
        for member in $group; do
            total=$((total + 1))
            [ -z "${CM_PRESET[$member]:-}" ] || set_count=$((set_count + 1))
        done
        if [ "$set_count" -gt 0 ] && [ "$set_count" -lt "$total" ]; then
            problems+=("$(printf "$(cm_t preset_problem_group)" "${group// /, }")")
        fi
    done
    [ ${#problems[@]} -gt 0 ] || return 0
    if [ -n "$sharing" ]; then
        printf '%s\n' "$(printf "$(cm_t preset_not_copied)" "$name")" >&2
    else
        printf '%s\n' "$(printf "$(cm_t preset_rejected)" "$name")" >&2
    fi
    printf '%s\n' "${problems[@]}" >&2
    return 1
}

# Print what cm_preset_validate noted for <name>: themes the preset names that are missing (only when
# sharing) and a cursor theme with no cursors of its own (harmless, but worth saying).
cm_preset_print_notes() {
    [ ${#CM_PRESET_NOTES[@]} -gt 0 ] || return 0
    printf '%s\n' "$(printf "$(cm_t preset_notes)" "$1")" >&2
    printf '%s\n' "${CM_PRESET_NOTES[@]}" >&2
}

# cm_preset_apply_key <key>: apply one key of CM_PRESET through its cm_apply_* function. The two
# grouped settings are applied once, from their first key.
cm_preset_apply_key() {
    local key="$1" value="${CM_PRESET[$1]:-}"
    case "$key" in
        GTK_THEME)       cm_apply_gtk_theme "$value" ;;
        ICON_THEME)      cm_apply_icon_theme "$value" ;;
        CURSOR_THEME)    cm_apply_cursor_theme "$value" 1 ;;
        CURSOR_SIZE)     cm_apply_cursor_size "$value" 1 ;;
        CINNAMON_THEME)  cm_apply_cinnamon_theme "$value" ;;
        COLOR_SCHEME)    cm_apply_color_scheme "$value" ;;
        FONT_NAME)       cm_apply_font_name "$value" ;;
        MONOSPACE_FONT)  cm_apply_monospace_font "$value" ;;
        FONT_ANTIALIAS)  cm_apply_font_rendering "$value" "${CM_PRESET[FONT_HINTING]}" ;;
        TEXT_SCALING)    cm_apply_text_scaling "$value" ;;
        ACCENT_COLOR)    cm_apply_accent_color "$value" ;;
        PANEL_BG_COLOR)  cm_apply_panel_bg_color "$value" ;;
        PANEL_FG_COLOR)  cm_apply_panel_fg_color "$value" ;;
        MENU_BG_COLOR)   cm_apply_menu_bg_color "$value" ;;
        MENU_FG_COLOR)   cm_apply_menu_fg_color "$value" ;;
        TOOLTIP_BG_COLOR) cm_apply_tooltip_bg_color "$value" ;;
        TOOLTIP_FG_COLOR) cm_apply_tooltip_fg_color "$value" ;;
        GTK_ACCENT_COLOR) cm_apply_gtk_accent_color "$value" ;;
        PANEL_OPACITY)   cm_apply_panel_opacity "$value" ;;
        PANEL_HEIGHT)    cm_apply_panel_height "$value" ;;
        TERMINAL_PALETTE) cm_apply_terminal_palette "$value" ;;
        PANEL_POSITION)  cm_apply_panel_position "$value" ;;
        WINDOW_BUTTONS)  cm_apply_window_buttons "$value" ;;
        HOTCORNER_TL)    cm_apply_hotcorners "$value" "${CM_PRESET[HOTCORNER_TR]}" "${CM_PRESET[HOTCORNER_BL]}" "${CM_PRESET[HOTCORNER_BR]}" ;;
        WORKSPACES)      cm_apply_workspaces "$value" ;;
        DESKTOP_EFFECTS) cm_apply_desktop_effects "$value" ;;
        MENU_EFFECTS)    cm_apply_menu_effects "$value" ;;
        DESKTOP_ICONS)   cm_apply_desktop_icons "$value" ;;
        DESKTOP_BG_COLOR) cm_apply_desktop_bg_color "$value" "mantener" ;;
    esac
}

# cm_preset_precheck <name>: read a saved preset into CM_PRESET and validate it, changing nothing. The
# Profiles tab runs it before taking a backup, so a refused preset leaves none.
cm_preset_precheck() {
    local name="${1:-}"
    [ -z "$name" ] && { printf '%s\n' "$(cm_t preset_name_required)" >&2; return 1; }
    case "$name" in */*|*..*) printf '%s\n' "$(cm_t preset_name_invalid)" >&2; return 1 ;; esac
    local file="$CM_PRESETS_DIR/${name}.conf"
    [ -f "$file" ] || { printf '%s\n' "$(printf "$(cm_t preset_not_found)" "$name")" >&2; return 1; }

    cm_preset_parse "$file" || return 1
    cm_preset_validate "$name"
}

# cm_preset_apply_all: apply every key CM_PRESET holds, in the order of CM_PRESET_KEYS, and stop at the first that fails.
cm_preset_apply_all() {
    local key
    for key in "${CM_PRESET_KEYS[@]}"; do
        # FONT_HINTING and the last three corners are applied with their first key.
        case "$key" in FONT_HINTING|HOTCORNER_TR|HOTCORNER_BL|HOTCORNER_BR) continue ;; esac
        [ -n "${CM_PRESET[$key]:-}" ] || continue
        if ! cm_preset_apply_key "$key"; then
            printf '%s\n' "$(printf "$(cm_t preset_stopped)" "$key")" >&2
            return 1
        fi
    done
}

cm_load_preset() {
    local name="${1:-}"
    cm_preset_precheck "$name" || return 1
    cm_preset_print_notes "$name"

    # The libadwaita import is held while the keys apply: the theme and the scheme of the look are set one after the other.
    cm_libadwaita_hold cm_preset_apply_all || return 1

    cm_reload_cinnamon
    cm_log "INFO" "$(printf "$(cm_t preset_loaded_log)" "$name")"
}

# A preset name is a file name: no folders, and not hidden (the list skips hidden files).
cm_preset_name_ok() {
    cm_is_valid_name "${1:-}" && [[ "${1:-}" != .* ]]
}

# cm_export_preset <name> <file|folder>: copy a saved preset out. It must parse and have valid values
# (a theme this system lacks is fine: the look is for another one), and an existing file is never
# overwritten.
cm_export_preset() {
    local name="${1:-}" dest="${2:-}" src
    [ -n "$name" ] || { printf '%s\n' "$(cm_t preset_name_required)" >&2; return 1; }
    cm_preset_name_ok "$name" || { printf '%s\n' "$(cm_t preset_name_invalid)" >&2; return 1; }
    [ -n "$dest" ] || { printf '%s\n' "$(cm_t preset_file_required)" >&2; return 1; }
    src="$CM_PRESETS_DIR/${name}.conf"
    { [ -f "$src" ] && [ ! -L "$src" ]; } || { printf '%s\n' "$(printf "$(cm_t preset_not_found)" "$name")" >&2; return 1; }
    [ ! -d "$dest" ] || dest="${dest%/}/${name}.conf"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        printf '%s\n' "$(printf "$(cm_t preset_exists)" "$dest")" >&2
        return 1
    fi
    cm_preset_parse "$src" || return 1
    cm_preset_validate "$name" sharing || return 1
    cm_atomic_write "$dest" 0644 < "$src" || { printf '%s\n' "$(printf "$(cm_t file_write_failed)" "$dest")" >&2; return 1; }
    printf '%s\n' "$(printf "$(cm_t preset_exported)" "$dest")"
}

# cm_import_preset <file> [name]: store a preset someone shared. The file is copied once, to a private
# temporary file, and read as data there; it is stored only if it parses and every value is valid. A
# theme this system lacks is a notice (loading it later says so again). It is never applied.
cm_import_preset() {
    local file="${1:-}" name="${2:-}" tmp target size status=0
    [ -n "$file" ] || { printf '%s\n' "$(cm_t preset_file_required)" >&2; return 1; }
    { [ -f "$file" ] && [ ! -L "$file" ]; } || { printf '%s\n' "$(printf "$(cm_t preset_file_missing)" "$file")" >&2; return 1; }
    if [ -z "$name" ]; then
        name="${file##*/}"
        name="${name%.conf}"
    fi
    cm_preset_name_ok "$name" || { printf '%s\n' "$(cm_t preset_name_invalid)" >&2; return 1; }
    target="$CM_PRESETS_DIR/${name}.conf"
    mkdir -p "$CM_PRESETS_DIR" || return 1
    cm_lock || { printf '%s\n' "$(printf "$(cm_t file_write_failed)" "$target")" >&2; return 1; }
    tmp=$(mktemp "$CM_PRESETS_DIR/.import.XXXXXX") || { cm_unlock; return 1; }
    if [ -e "$target" ] || [ -L "$target" ]; then
        printf '%s\n' "$(printf "$(cm_t preset_exists)" "$target")" >&2
        status=1
    elif ! head -c 65537 -- "$file" > "$tmp" 2>/dev/null; then
        printf '%s\n' "$(printf "$(cm_t preset_file_missing)" "$file")" >&2
        status=1
    elif size=$(stat -c '%s' -- "$tmp" 2>/dev/null) && [ "$size" -gt 65536 ]; then
        printf '%s\n' "$(cm_t preset_too_big)" >&2
        status=1
    elif ! cm_preset_parse "$tmp" || ! cm_preset_validate "$name" sharing; then
        status=1
    elif ! cm_atomic_write "$target" 0644 < "$tmp"; then
        printf '%s\n' "$(printf "$(cm_t file_write_failed)" "$target")" >&2
        status=1
    fi
    rm -f -- "$tmp"
    cm_unlock
    [ "$status" -eq 0 ] || return 1
    cm_log "INFO" "$(printf "$(cm_t preset_imported_log)" "$target")"
    printf '%s\n' "$(printf "$(cm_t preset_imported)" "$name" "$name")"
    cm_preset_print_notes "$name"
}

# cm_look_table: the official looks, one per line: name, GTK and Cinnamon theme, icon theme, cursor theme and
# light/dark scheme. One light and one dark look for each of the ten Mint-Y colours (green has no suffix).
# Cyan, Navy and Yaru are left out: mint-y-icons has them, mint-themes has no GTK or Cinnamon theme of
# those colours. mint-y-icons has no dark variant, so a dark look keeps the icons of its colour.
cm_look_table() {
    local color suffix
    for color in green Aqua Blue Grey Orange Pink Purple Red Sand Teal; do
        suffix=""; [ "$color" = green ] || suffix="-$color"
        printf '%s %s %s %s %s\n' "mint-${color,,}" "Mint-Y$suffix" "Mint-Y$suffix" Bibata-Modern-Classic prefer-light
        printf '%s %s %s %s %s\n' "mint-${color,,}-dark" "Mint-Y-Dark$suffix" "Mint-Y$suffix" Bibata-Modern-Ice prefer-dark
    done
}

# Looks created or found by cm_bootstrap_looks, for cm_bootstrap_presets to record in SEEDED_LOOKS.
declare -a CM_LOOKS_DONE=()

# cm_in_lines <name> <lines>: is <name> one of the lines? Whole-line match, no patterns.
cm_in_lines() {
    local nl=$'\n'
    case "$nl$2$nl" in *"$nl$1$nl"*) return 0 ;; esac
    return 1
}

# cm_bootstrap_looks: create each official look that has no mark in SEEDED_LOOKS, once. A look is written
# only if the GUI catalogs offer every theme it names, because a look is seeded unasked and a folder the
# setters accept (cm_theme_installed: any folder of that name) may be a broken install, such as a GTK
# theme with no gtk.css. A file that already exists is kept as it is. A look a user deleted is
# not recreated because its mark stays. Runs under the lock; cm_state_set releases the lock, so the caller
# records CM_LOOKS_DONE after unlocking. A look carries only themes and scheme: panel, fonts, accent,
# cursor size and terminal stay as the user has them.
cm_bootstrap_looks() {
    local seeded name gtk icons cursor scheme file gtks="" cinnamons="" iconsets="" cursors="" scanned=0
    CM_LOOKS_DONE=()
    seeded=" $(cm_state_get SEEDED_LOOKS '') "
    while read -r name gtk icons cursor scheme; do
        case "$seeded" in *" $name "*) continue ;; esac
        file="$CM_PRESETS_DIR/$name.conf"
        if [ ! -e "$file" ] && [ ! -L "$file" ]; then
            if [ "$scanned" = 0 ]; then
                gtks=$(cm_list_gtk_themes); cinnamons=$(cm_list_cinnamon_themes)
                iconsets=$(cm_list_icon_themes); cursors=$(cm_list_cursor_themes); scanned=1
            fi
            cm_in_lines "$gtk" "$gtks" && cm_in_lines "$gtk" "$cinnamons" \
                && cm_in_lines "$icons" "$iconsets" && cm_in_lines "$cursor" "$cursors" || continue
            cm_atomic_write "$file" <<EOF || return 1
# Look "$name" - official Mint themes, icons and cursor; panel, fonts, accent and terminal stay as they are
GTK_THEME="$gtk"
ICON_THEME="$icons"
CURSOR_THEME="$cursor"
CINNAMON_THEME="$gtk"
COLOR_SCHEME="$scheme"
EOF
        fi
        CM_LOOKS_DONE+=("$name")
    done < <(cm_look_table)
}

# Create the sample presets the first time the script runs, then the official looks (cm_bootstrap_looks)
cm_bootstrap_presets() {
    mkdir -p "$CM_PRESETS_DIR"
    cm_lock || return 1

    if [ ! -f "$CM_PRESETS_DIR/default.conf" ]; then
        if cm_atomic_write "$CM_PRESETS_DIR/default.conf" <<'EOF'
# Preset "default" - the light Mint-Y look with the icons and cursor Mint ships
# Edit these values by hand and load the preset from the Profiles tab
GTK_THEME="Mint-Y"
ICON_THEME="Mint-Y"
CURSOR_THEME="Bibata-Modern-Classic"
CURSOR_SIZE="24"
CINNAMON_THEME="Mint-Y"
COLOR_SCHEME="prefer-light"
FONT_NAME="Noto Sans 10"
TEXT_SCALING="100"
ACCENT_COLOR="#56B6C2"
PANEL_OPACITY="100"
PANEL_HEIGHT="40"
TERMINAL_PALETTE="nord"
PANEL_POSITION="bottom"
WINDOW_BUTTONS="derecha"
HOTCORNER_TL="none"
HOTCORNER_TR="none"
HOTCORNER_BL="none"
HOTCORNER_BR="none"
EOF
        then
            :
        else
            cm_unlock
            return 1
        fi
    fi

    if [ ! -f "$CM_PRESETS_DIR/nord-dark.conf" ]; then
        if cm_atomic_write "$CM_PRESETS_DIR/nord-dark.conf" <<'EOF'
# Preset "nord-dark" - cool, minimal look inspired by the Nord palette
GTK_THEME="Mint-Y-Dark-Aqua"
ICON_THEME="Mint-Y-Aqua"
CURSOR_THEME="Bibata-Modern-Ice"
CURSOR_SIZE="24"
CINNAMON_THEME="Mint-Y-Dark-Aqua"
COLOR_SCHEME="prefer-dark"
FONT_NAME="Noto Sans 10"
TEXT_SCALING="100"
ACCENT_COLOR="#88C0D0"
PANEL_OPACITY="88"
PANEL_HEIGHT="36"
TERMINAL_PALETTE="nord"
PANEL_POSITION="bottom"
WINDOW_BUTTONS="izquierda"
HOTCORNER_TL="none"
HOTCORNER_TR="expo"
HOTCORNER_BL="none"
HOTCORNER_BR="desktop"
EOF
        then
            :
        else
            cm_unlock
            return 1
        fi
    fi

    local status=0 marks name
    cm_bootstrap_looks || status=1
    cm_unlock
    if [ ${#CM_LOOKS_DONE[@]} -gt 0 ]; then
        marks=$(cm_state_get SEEDED_LOOKS "")
        for name in "${CM_LOOKS_DONE[@]}"; do
            case " $marks " in *" $name "*) ;; *) marks="${marks:+$marks }$name" ;; esac
        done
        cm_state_set SEEDED_LOOKS "$marks" || status=1
    fi
    return "$status"
}

# ============================================================================
# GUI — tabs (each one is a loop that redraws after "Apply")
#
# YAD cannot natively read values from several embedded tabs, so each tab runs
# in its own process (--plug), launched as an invocation of this same script in
# "__tab" mode (see the dispatcher at the end).
# ============================================================================
_join_bang() { local IFS='!'; echo "$*"; }

# Same as "cm_reorder_current_first | _join_bang" but safe for items with
# spaces (e.g. localized corner labels): each output line becomes one array
# element instead of being word-split by an unquoted command substitution.
_reorder_join_bang() {
    local current="$1"; shift
    local -a ordered=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && ordered+=("$line")
    done < <(cm_reorder_current_first "$current" "$@")
    _join_bang "${ordered[@]}"
}

# Same as "_join_bang $(command)" but safe for items with spaces (e.g. a preset
# saved as "my dark theme"): turn the multi-line output of $1 into a real array
# (one entry per line) before joining with "!".
_lines_to_bang() {
    local input="$1"
    local -a arr=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && arr+=("$line")
    done <<< "$input"
    _join_bang "${arr[@]}"
}

# yad refuses UTF-8 labels under a non-UTF-8 locale ("Invalid byte sequence in conversion input"),
# which is the default (LANG=C) in minimal sessions and containers. The language is already stored in
# the state file, so switching the locale here does not change the interface language.
cm_ensure_utf8_locale() {
    local candidate
    [ "$(locale charmap 2>/dev/null)" = "UTF-8" ] && return 0
    for candidate in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
        if [ "$(LC_ALL="$candidate" locale charmap 2>/dev/null)" = "UTF-8" ]; then
            export LC_ALL="$candidate"
            return 0
        fi
    done
    return 1
}

# cm_fbtn_apply embeds the script path in a quoted command line that YAD parses and where it
# substitutes %N: quotes, backslashes, $, backticks, %<digit> and control characters cannot be
# embedded safely, so the GUI refuses to start from such a path instead of failing oddly.
cm_gui_path_is_safe() {
    case "$SCRIPT_PATH" in
        *\"*|*\\*|*\$*|*\`*|*%[0-9]*) return 1 ;;
    esac
    [[ "$SCRIPT_PATH" != *[[:cntrl:]]* ]]
}

# cm_fbtn_apply <mode> [field-index ...] — value for an ":FBTN" field that
# applies the changes DIRECTLY when pressed, without relying on the plug closing
# or on capturing its output (see the maintainer notes in the header). Builds:
#   bash -c 'bash "$0" __apply <mode> "$1" "$2" ...' "$SCRIPT_PATH" %N %N ...
# YAD replaces each "%N" with the field's current value, already quoted as a
# single argument (spaces preserved); inside bash -c, "$0" is "$SCRIPT_PATH" and
# "$1", "$2"... are those values in the order requested here. Indexes need not
# be consecutive or cover every field: only the ones the button needs.
cm_fbtn_apply() {
    local mode="$1"; shift
    local i inner="bash \"\$0\" __apply $mode" ph="" argi=0
    for i in "$@"; do
        argi=$((argi + 1))
        inner+=" \"\$$argi\""
        ph+=" %$i"
    done
    printf "bash -c '%s' \"%s\"%s" "$inner" "$SCRIPT_PATH" "$ph"
}

# ============================================================================
# GUI — apply actions (called directly by each tab's FBTN buttons through
# cm_fbtn_apply/__apply; see the dispatcher at the end)
# ============================================================================
CM_MINTY_NONE_LABEL=""

# The folder selector of the Themes tab starts on a path that does not exist: GTK then reads "(None)", like the file
# selector above it, where an empty folder selector is a blank button. yad leaves empty values out of a button's command
# line, so the placeholder can arrive as either value, and the import ignores it in both.
CM_NO_FOLDER="/nonexistent/color-mint/no-folder"

cm_ui_backup_before_apply() {
    if ! cm_backup_current >/dev/null; then
        yad --error --text="$(cm_t backup_create_failed)" --button="$(cm_t 'done'):0" 2>/dev/null
        return 1
    fi
    return 0
}

cm_ui_apply_themes_apply() {
    local GTK_T="$1" ICON_T="$2" CURSOR_T="$3" CURSOR_SZ_RAW="$4" CINN_T="$5" MINTY_COLOR_LABEL="$6" MINTY_MODE_LABEL="$7"
    local CURSOR_SZ; CURSOR_SZ=$(cm_num_int "$CURSOR_SZ_RAW")

    cm_ui_backup_before_apply || return 1
    local -a applied=()
    local apply_failed=0

    if [ -n "$MINTY_COLOR_LABEL" ] && [ "$MINTY_COLOR_LABEL" != "$CM_MINTY_NONE_LABEL" ]; then
        local minty_mode="claro"
        [ "$MINTY_MODE_LABEL" = "$(cm_t dark_mode)" ] && minty_mode="oscuro"
        cm_report "$(printf "$(cm_t official_mint_color)" "$MINTY_COLOR_LABEL" "$MINTY_MODE_LABEL")" cm_apply_mint_y_pack "$MINTY_COLOR_LABEL" "$minty_mode" || apply_failed=1
    else
        if [ -n "$GTK_T" ]; then
            cm_report "$(printf "$(cm_t report_gtk_theme)" "$GTK_T")" cm_apply_gtk_theme "$GTK_T" || apply_failed=1
        fi
        if [ -n "$ICON_T" ]; then
            cm_report "$(printf "$(cm_t report_icon_theme)" "$ICON_T")" cm_apply_icon_theme "$ICON_T" || apply_failed=1
        fi
        if [ -n "$CINN_T" ]; then
            cm_report "$(printf "$(cm_t report_cinnamon_theme)" "$CINN_T")" cm_apply_cinnamon_theme "$CINN_T" || apply_failed=1
        fi
    fi

    if [ -n "$CURSOR_T" ]; then
        cm_report "$(printf "$(cm_t report_cursor_theme)" "$CURSOR_T")" cm_apply_cursor_theme "$CURSOR_T" 1 || apply_failed=1
    fi
    if [ -n "$CURSOR_SZ" ]; then
        cm_report "$(printf "$(cm_t cursor_size_report)" "$CURSOR_SZ")" cm_apply_cursor_size "$CURSOR_SZ" 1 || apply_failed=1
    fi

    cm_reload_cinnamon
    cm_notify_applied "Color Mint" "$(cm_t applied_themes)" "${applied[@]}"
    return "$apply_failed"
}

cm_ui_apply_themes_import() {
    local IMPORT_FILE="$1" IMPORT_DIR="$2"
    [ "$IMPORT_FILE" != "$CM_NO_FOLDER" ] || IMPORT_FILE=""
    [ "$IMPORT_DIR" != "$CM_NO_FOLDER" ] || IMPORT_DIR=""
    local src="$IMPORT_FILE"
    [ -z "$src" ] && src="$IMPORT_DIR"
    if [ -z "$src" ]; then
        yad --error --text="$(cm_t ui_theme_file_required)" --button="$(cm_t 'done'):0" 2>/dev/null
        return 1
    fi
    local dest
    if dest=$(cm_import_theme "$src"); then
        # Remembered in the state file (not a local variable: this "__apply" mode runs
        # in a separate process from the tab loop) so the next redraw preselects it.
        cm_state_set "LAST_IMPORTED_THEME" "$(basename "$dest")"
        cm_tab_redraw
        cm_notify_applied "Color Mint" "$(cm_t theme_imported)" "$(printf "$(cm_t path_detail)" "$dest")" "$(cm_t ui_import_done)"
    else
        yad --error --text="$(cm_t ui_theme_import_error)" --button="$(cm_t 'done'):0" 2>/dev/null
        return 1
    fi
}

# "Get more themes": one small form for the two ways in, a verified apt pack or a Cinnamon Spices name. The work is the
# CLI's own (cm_install_theme_package, cm_fetch_theme); this only asks, waits and reports. A pulsing bar shows while the
# download runs; its own timeout closes it if this process dies first.
CM_MORE_WAIT_PID=""

cm_ui_more_wait_start() {
    command -v yad >/dev/null 2>&1 || return 0
    yad --progress --pulsate --progress-text=" " --no-buttons --borders=12 --center --width=380 --title="Color Mint" \
        --window-icon="$(cm_icon_path)" --text="$1" --timeout=$((CM_FETCH_TIMEOUT + 30)) \
        </dev/null >/dev/null 2>&1 &
    CM_MORE_WAIT_PID=$!
}

cm_ui_more_wait_stop() {
    if [ -n "$CM_MORE_WAIT_PID" ]; then
        kill "$CM_MORE_WAIT_PID" 2>/dev/null || true
        wait "$CM_MORE_WAIT_PID" 2>/dev/null || true
    fi
    CM_MORE_WAIT_PID=""
}

cm_ui_more_fail() {
    local msg="$1"; shift
    msg="${msg#ERROR: }"; msg="${msg#ADVERTENCIA: }"; msg="${msg#WARNING: }"
    CM_NOTIFY_SUFFIX="" cm_notify_applied "Color Mint" "$(cm_t ui_more_failed)" "⚠ $(fold -s -w 60 <<< "$msg")" "$@"
}

cm_ui_apply_themes_more() {
    local pkg kind brand mark label pack="" spices="" out i err msg dest summary rc=0 changed=0 already=0
    local -a pkgs=("") labels=() form=() items=()
    labels=("$(cm_t ui_more_none)")
    form=(--form --title="$(cm_t ui_more_title)" --window-icon="$(cm_icon_path)" --borders=12 --center)
    if [ "$(cm_pkg_manager)" = apt ]; then
        while IFS='|' read -r pkg kind brand; do
            mark=""
            if command -v dpkg-query >/dev/null 2>&1 && cm_apt_package_installed "$pkg"; then mark="  ✓"; fi
            pkgs+=("$pkg"); labels+=("$brand — $(cm_t "pkg_kind_$kind")$mark")
        done < <(cm_theme_package_table)
        form+=(--text="$(cm_t ui_more_text)" --field="$(cm_t ui_more_pack):CB" "$(_join_bang "${labels[@]}")")
    else
        form+=(--text="$(cm_t ui_more_text_web)")
    fi
    form+=(--field="$(cm_t ui_more_spices)" "" --button="$(cm_t cancel):1" --button="$(cm_t ui_more_get):0")
    out=$(yad "${form[@]}" 2>/dev/null) || return 0
    if [ "${#labels[@]}" -gt 1 ]; then
        IFS='|' read -r label spices _ <<< "$out"
        for i in "${!labels[@]}"; do [ "${labels[$i]}" = "$label" ] && pack="${pkgs[$i]}"; done
    else
        IFS='|' read -r spices _ <<< "$out"
    fi
    cm_trim_var spices
    if [ -z "$pack" ] && [ -z "$spices" ]; then
        yad --error --text="$(cm_t ui_more_nothing)" --button="$(cm_t 'done'):0" 2>/dev/null
        return 1
    fi

    summary="$(cm_t ui_more_installed)"
    if [ -n "$pack" ]; then
        if command -v dpkg-query >/dev/null 2>&1 && cm_apt_package_installed "$pack"; then already=1; fi
        msg=$(cm_install_theme_package "$pack" 2>&1) || rc=$?
        if [ "$rc" -ne 0 ]; then cm_ui_more_fail "$msg"; return 1; fi
        if [ "$already" -eq 1 ]; then
            items+=("$msg")
        else
            changed=1
            items+=("$(printf "$(cm_t ui_more_package)" "$pack")" "$(cm_t ui_more_in_lists)")
        fi
    fi
    if [ -n "$spices" ]; then
        if err=$(mktemp "${CM_HOME:-/tmp}/.more-err.XXXXXX"); then
            cm_ui_more_wait_start "$(printf "$(cm_t ui_more_wait)" "$spices")"
            dest=$(cm_fetch_theme "$spices" 2>"$err") || rc=$?
            cm_ui_more_wait_stop
            msg=$(cat -- "$err" 2>/dev/null) || msg=""
            rm -f -- "$err"
        else
            rc=1; msg="$(cm_t tempdir_failed)"
        fi
        if [ "$rc" -ne 0 ] || [ -z "$dest" ]; then
            # A pack installed a moment ago stays installed: show it in the lists and say so next to the failure.
            [ "$changed" -eq 0 ] || cm_tab_redraw
            cm_ui_more_fail "${msg:-$(printf "$(cm_t fetch_failed)" "$spices")}" "${items[@]+"${items[@]}"}"
            return 1
        fi
        cm_state_set "LAST_IMPORTED_THEME" "$(basename "$dest")"
        changed=1
        summary="$(cm_t ui_more_fetched)"
        items+=("$(printf "$(cm_t path_detail)" "$dest")" "$(cm_t ui_import_done)")
    fi
    if [ "$changed" -eq 1 ]; then cm_tab_redraw; fi
    cm_notify_applied "Color Mint" "$summary" "${items[@]}"
}

# Each tab runs as its own process, keyed by the main window's PID. The loop must end
# when that process is gone, and must not spin if yad keeps closing at once.
CM_TAB_LAST_SECOND=-1
CM_TAB_BURST=0
cm_tab_alive() {
    kill -0 "$1" 2>/dev/null || return 1
    if [ "$SECONDS" -eq "$CM_TAB_LAST_SECOND" ]; then
        CM_TAB_BURST=$((CM_TAB_BURST + 1))
        [ "$CM_TAB_BURST" -lt 5 ] || sleep 1
    else
        CM_TAB_LAST_SECOND=$SECONDS
        CM_TAB_BURST=0
    fi
    return 0
}

# A button never redraws its tab: GtkSocket cannot take a second plug, so a new yad for the tab opens as a loose
# window (measured with YAD 0.40.0). A change to what a tab lists therefore rebuilds the whole window, like the
# language button: the mark tells cm_window_generation that the notebook ended on purpose (exit status 11).
# CM_TAB_KEY comes from __tab through the environment; without it, or from the command line, nothing happens.
# The trailing space in the pattern keeps one key from matching a longer one.
cm_redraw_mark() { printf '%s\n' "$CM_HOME/window-redraw.$1"; }

cm_tab_redraw() {
    local pid mark found=0
    [[ "${CM_TAB_KEY:-}" =~ ^[0-9]+$ ]] || return 0
    command -v pgrep >/dev/null 2>&1 || return 0
    mark="$(cm_redraw_mark "$CM_TAB_KEY")"
    { : > "$mark"; } 2>/dev/null || return 0
    while IFS= read -r pid; do
        if kill -TERM "$pid" 2>/dev/null; then found=1; fi
    done < <(pgrep -u "$(id -u)" -f -- "^([^ ]*/)?yad --notebook --key=$CM_TAB_KEY " 2>/dev/null)
    [ "$found" -eq 1 ] || rm -f "$mark"
    return 0
}

cm_tab_themes() {
    local KEY="$1" TABNUM="$2"
    while cm_tab_alive "$KEY"; do
        local cur_gtk cur_icon cur_cursor cur_cinn cur_cursor_size LAST_IMPORTED
        cur_gtk=$(cm_gs_string org.cinnamon.desktop.interface gtk-theme)
        cur_icon=$(cm_gs_string org.cinnamon.desktop.interface icon-theme)
        cur_cursor=$(cm_gs_string org.cinnamon.desktop.interface cursor-theme)
        cur_cinn=$(cm_gs_string org.cinnamon.theme name)
        cur_cursor_size=$(cm_current_cursor_size)
        LAST_IMPORTED=$(cm_state_get "LAST_IMPORTED_THEME" "")

        # If the last imported theme is in the matching list (depending on where it
        # was installed: gtk/cinnamon or icons/cursor), it also goes to the front there
        # even if not applied yet, so a single "Apply" is enough.
        local gtk_themes icon_themes cursor_themes cinn_themes
        gtk_themes=$(cm_list_gtk_themes)
        icon_themes=$(cm_list_icon_themes)
        cursor_themes=$(cm_list_cursor_themes)
        cinn_themes=$(cm_list_cinnamon_themes)
        if [ -n "$LAST_IMPORTED" ]; then
            grep -qxF "$LAST_IMPORTED" <<< "$gtk_themes"    && cur_gtk="$LAST_IMPORTED"
            grep -qxF "$LAST_IMPORTED" <<< "$icon_themes"   && cur_icon="$LAST_IMPORTED"
            grep -qxF "$LAST_IMPORTED" <<< "$cursor_themes" && cur_cursor="$LAST_IMPORTED"
            grep -qxF "$LAST_IMPORTED" <<< "$cinn_themes"   && cur_cinn="$LAST_IMPORTED"
        fi

        local -a gtk_arr=() icon_arr=() cursor_arr=() cinn_arr=()
        local _line
        while IFS= read -r _line; do [ -n "$_line" ] && gtk_arr+=("$_line"); done <<< "$gtk_themes"
        while IFS= read -r _line; do [ -n "$_line" ] && icon_arr+=("$_line"); done <<< "$icon_themes"
        while IFS= read -r _line; do [ -n "$_line" ] && cursor_arr+=("$_line"); done <<< "$cursor_themes"
        while IFS= read -r _line; do [ -n "$_line" ] && cinn_arr+=("$_line"); done <<< "$cinn_themes"

        local GTK_LIST ICON_LIST CURSOR_LIST CINN_LIST
        GTK_LIST=$(_reorder_join_bang "$cur_gtk" "${gtk_arr[@]}")
        ICON_LIST=$(_reorder_join_bang "$cur_icon" "${icon_arr[@]}")
        CURSOR_LIST=$(_reorder_join_bang "$cur_cursor" "${cursor_arr[@]}")
        CINN_LIST=$(_reorder_join_bang "$cur_cinn" "${cinn_arr[@]}")

        local mint_y_light mint_y_dark mint_y_colors_all
        mint_y_light=$(cm_list_mint_y_colors "Mint-Y")
        mint_y_dark=$(cm_list_mint_y_colors "Mint-Y-Dark")
        mint_y_colors_all=$(printf '%s\n%s\n' "$mint_y_light" "$mint_y_dark" | grep -v '^$' | sort -u)
        local -a mint_y_arr=()
        local _line2
        while IFS= read -r _line2; do [ -n "$_line2" ] && mint_y_arr+=("$_line2"); done <<< "$mint_y_colors_all"
        local MINTY_COLOR_LIST MINTY_MODE_LIST
        MINTY_COLOR_LIST=$(_join_bang "$CM_MINTY_NONE_LABEL" "${mint_y_arr[@]}")
        MINTY_MODE_LIST=$(_join_bang "$(cm_t light_mode)" "$(cm_t dark_mode)")

        # Order for an average user: the easy path (official Mint-Y pack) first,
        # labeled "recommended"; the manual path stays marked optional. "Apply themes" comes right after
        # the cursor so it stays on screen at 1366x768; getting or importing more themes is optional and
        # goes below it. The field indexes of the buttons do NOT follow the on-screen order but the order
        # each cm_ui_apply_* function expects.
        yad --plug="$KEY" --tabnum="$TABNUM" --form --scroll \
            --text="$(cm_t ui_themes_text)" \
            --field="$(cm_t ui_themes_easy):LBL" "" \
            --field="$(cm_t ui_official_color):CB"                "$MINTY_COLOR_LIST" \
            --field="$(cm_t ui_light_dark):CB"                "$MINTY_MODE_LIST" \
            --field="$(cm_t ui_themes_manual):LBL" "" \
            --field="$(cm_t ui_gtk_theme):CB"                    "$GTK_LIST" \
            --field="$(cm_t ui_icons):CB"                       "$ICON_LIST" \
            --field="$(cm_t ui_cinnamon):CB"     "$CINN_LIST" \
            --field="$(cm_t ui_cursor_always):LBL" "" \
            --field="$(cm_t ui_cursor):CB"                       "$CURSOR_LIST" \
            --field="$(cm_t ui_cursor_size):NUM"       "${cur_cursor_size}!16..96!1" \
            --field="$(cm_t apply_themes)$(cm_yad_btn_icon gtk-apply):FBTN"  "$(cm_fbtn_apply themes_apply 5 6 9 10 7 2 3)" \
            --field="$(cm_t ui_import_theme):LBL" "" \
            --field="$(cm_t more_themes)$(cm_yad_btn_icon gtk-find):FBTN" "$(cm_fbtn_apply themes_more)" \
            --field="$(cm_t ui_theme_file):FL" "" \
            --field="$(cm_t ui_theme_dir):DIR"  "$CM_NO_FOLDER" \
            --field="$(cm_t import_theme)$(cm_yad_btn_icon gtk-add):FBTN"    "$(cm_fbtn_apply themes_import 14 15)" \
            --no-buttons >/dev/null 2>&1
    done
}

cm_ui_apply_panel_apply() {
    local TARGET_LABEL="$1" PRESET_LABEL="$2" COLOR_RAW="$3" OPACITY_RAW="$4" HEIGHT_RAW="$5"
    local COLOR OPACITY HEIGHT
    COLOR=$(cm_normalize_hex "$COLOR_RAW")
    OPACITY=$(cm_num_int "$OPACITY_RAW")
    HEIGHT=$(cm_num_int "$HEIGHT_RAW")

    local target_key; target_key=$(cm_color_target_key_from_label "$TARGET_LABEL")
    local preset_key; preset_key=$(cm_accent_preset_key_from_label "$PRESET_LABEL") || preset_key="custom"
    if [ "$preset_key" != "custom" ] && [ -n "${CM_ACCENT_PRESET_HEX[$preset_key]:-}" ]; then
        COLOR="${CM_ACCENT_PRESET_HEX[$preset_key]}"
    fi

    cm_ui_backup_before_apply || return 1
    local -a applied=()
    local apply_failed=0
    if [ -n "$COLOR" ] && cm_is_valid_hex "$COLOR"; then
        local color_label="${CM_COLOR_TARGET_LABELS[$target_key]}: $COLOR"
        case "$target_key" in
            accent)       cm_report "$color_label" cm_apply_accent_color     "$COLOR" || apply_failed=1 ;;
            bg)           cm_report "$color_label" cm_apply_panel_bg_color   "$COLOR" || apply_failed=1 ;;
            fg)           cm_report "$color_label" cm_apply_panel_fg_color   "$COLOR" || apply_failed=1 ;;
            menu_bg)      cm_report "$color_label" cm_apply_menu_bg_color    "$COLOR" || apply_failed=1 ;;
            menu_fg)      cm_report "$color_label" cm_apply_menu_fg_color    "$COLOR" || apply_failed=1 ;;
            tooltip_bg)   cm_report "$color_label" cm_apply_tooltip_bg_color "$COLOR" || apply_failed=1 ;;
            tooltip_fg)   cm_report "$color_label" cm_apply_tooltip_fg_color "$COLOR" || apply_failed=1 ;;
            gtk_accent)   cm_report "$color_label" cm_apply_gtk_accent_color "$COLOR" || apply_failed=1 ;;
        esac
    fi
    if [ -n "$OPACITY" ]; then
        cm_report "$(printf "$(cm_t report_opacity)" "${OPACITY}")" cm_apply_panel_opacity "$OPACITY" || apply_failed=1
    fi
    if [ -n "$HEIGHT" ]; then
        cm_report "$(printf "$(cm_t report_height)" "${HEIGHT}")" cm_apply_panel_height "$HEIGHT" || apply_failed=1
    fi
    cm_reload_cinnamon
    cm_notify_applied "Color Mint" "$(cm_t panel_updated)" "${applied[@]}"
    return "$apply_failed"
}

cm_ui_reset_none() {
    yad --info --text="$(cm_t color_reset_none)" --button="$(cm_t 'done'):0" 2>/dev/null
}

cm_ui_apply_panel_reset() {
    if ! cm_panel_reset_pending; then
        cm_ui_reset_none
        return 0
    fi
    if cm_confirm "$(cm_t ui_panel_reset_confirm)"; then
        cm_ui_backup_before_apply || return 1
        local _msg_file
        _msg_file=$(mktemp "${TMPDIR:-/tmp}/cm_reset_msg.XXXXXX" 2>/dev/null) \
            || _msg_file=$(mktemp "${CM_HOME:?}/.reset-msg.XXXXXX" 2>/dev/null) \
            || { yad --error --text="$(cm_t reset_failed)" --button="$(cm_t 'done'):0" 2>/dev/null; return 1; }
        if cm_reset_panel_colors >"$_msg_file" 2>&1; then
            cm_reload_cinnamon
            cm_notify_applied "Color Mint" "$(cm_t colors_reset)" "$(cat "$_msg_file")"
        elif [ "$(cat "$_msg_file")" = "$(cm_t color_reset_none)" ]; then
            cm_ui_reset_none
        else
            yad --error --text="$(cm_t reset_failed)" --button="$(cm_t 'done'):0" 2>/dev/null
            rm -f "$_msg_file" 2>/dev/null || true
            return 1
        fi
        rm -f "$_msg_file" 2>/dev/null || true
    fi
    return 0
}

cm_ui_no_backups() {
    yad --info --text="$(cm_t ui_backup_none)" --button="$(cm_t 'done'):0" 2>/dev/null
}

cm_ui_apply_panel_backup() {
    local LAST_BACKUP; LAST_BACKUP=$(cm_list_backups | head -n1)
    if [ -z "$LAST_BACKUP" ]; then
        cm_ui_no_backups
    elif cm_confirm "$(printf "$(cm_t ui_backup_confirm_last)" "$LAST_BACKUP")"; then
        if cm_restore_backup "$LAST_BACKUP"; then
            cm_notify_applied "Color Mint" "$(printf "$(cm_t backup_restore_done)" "$LAST_BACKUP")"
        else
            yad --error --text="$(cm_t backup_restore_failed)" --button="$(cm_t 'done'):0" 2>/dev/null
            return 1
        fi
    fi
}

cm_tab_panel() {
    local KEY="$1" TABNUM="$2"
    while cm_tab_alive "$KEY"; do
        local cur_accent cur_opacity cur_height
        cur_accent=$(cm_state_get "ACCENT_COLOR" "#88C0D0")
        cur_opacity=$(cm_state_get "PANEL_OPACITY" "90")
        cur_height=$(cm_current_panel_height)

        # Wide choice of preset accents. Always starts at "Custom" so it never
        # overrides the color picker above unless the user explicitly picks one.
        local accent_labels=() k PRESET_LIST
        for k in "${CM_ACCENT_PRESET_ORDER[@]}"; do accent_labels+=("${CM_ACCENT_PRESET_LABELS[$k]}"); done
        PRESET_LIST=$(_join_bang "${accent_labels[@]}")

        local target_labels=() TARGET_LIST
        for k in "${CM_COLOR_TARGET_ORDER[@]}"; do target_labels+=("${CM_COLOR_TARGET_LABELS[$k]}"); done
        TARGET_LIST=$(_join_bang "${target_labels[@]}")

        yad --plug="$KEY" --tabnum="$TABNUM" --form --scroll \
            --text="$(cm_t ui_panel_text)" \
            --field="$(cm_t ui_panel_target):CB"               "$TARGET_LIST" \
            --field="$(cm_t ui_quick_color):CB"                    "$PRESET_LIST" \
            --field="$(cm_t ui_custom_color):CLR"                        "$cur_accent" \
            --field="$(cm_t ui_panel_size):LBL" "" \
            --field="$(cm_t ui_opacity):NUM"                             "${cur_opacity}!0..100!1" \
            --field="$(cm_t ui_height):NUM"                                "${cur_height}!16..100!1" \
            --field="$(cm_t apply_panel)$(cm_yad_btn_icon gtk-apply):FBTN"                  "$(cm_fbtn_apply panel_apply 1 2 3 5 6)" \
            --field="$(cm_t reset_colors)$(cm_yad_btn_icon gtk-revert-to-saved):FBTN"  "$(cm_fbtn_apply panel_reset)" \
            --field="$(cm_t restore_last_backup)$(cm_yad_btn_icon gtk-undo):FBTN"        "$(cm_fbtn_apply panel_backup)" \
            --no-buttons >/dev/null 2>&1
    done
}

cm_ui_apply_desktop_apply() {
    local POS_LABEL="$1" BTN_PRESET_LABEL="$2" EFFECTS_LABEL="$3" MENU_FX_LABEL="$4" WORKSPACES_RAW="$5" ICONS_LABEL="$6" BG_COLOR_RAW="$7" BGMODE_LABEL="$8"

    cm_ui_backup_before_apply || return 1
    local -a applied=()
    local apply_failed=0

    local POS; POS=$(cm_panelpos_key_from_label "$POS_LABEL")
    if [ -n "$POS_LABEL" ]; then
        cm_report "$(printf "$(cm_t report_panel_position)" "${CM_PANELPOS_LABELS[$POS]}")" cm_apply_panel_position "$POS" || apply_failed=1
    fi

    # If the label matches no known preset (e.g. the user left the "keep custom
    # layout" notice selected because the current layout is custom), this returns
    # empty and the buttons are left alone; custom layouts are edited from the
    # Advanced tab.
    local final_layout; final_layout=$(cm_button_preset_key_from_label "$BTN_PRESET_LABEL")
    if [ -n "$final_layout" ]; then
        cm_report "$(printf "$(cm_t report_window_buttons)" "$final_layout")" cm_apply_window_buttons "$final_layout" || apply_failed=1
    fi

    local final_effects final_menu_fx final_workspaces final_icons
    final_effects=$(cm_onoff_key_from_label "$EFFECTS_LABEL")
    final_menu_fx=$(cm_onoff_key_from_label "$MENU_FX_LABEL")
    final_icons=$(cm_showhide_key_from_label "$ICONS_LABEL")
    final_workspaces=$(cm_num_int "$WORKSPACES_RAW")
    cm_report "$(printf "$(cm_t report_window_effects)" "$final_effects")" cm_apply_desktop_effects "$final_effects" || apply_failed=1
    cm_report "$(printf "$(cm_t report_menu_effects)" "$final_menu_fx")" cm_apply_menu_effects "$final_menu_fx" || apply_failed=1
    if [ -n "$final_workspaces" ]; then
        cm_report "$(printf "$(cm_t report_workspaces)" "$final_workspaces")" cm_apply_workspaces "$final_workspaces" || apply_failed=1
    fi
    cm_report "$(printf "$(cm_t report_desktop_icons)" "$final_icons")" cm_apply_desktop_icons "$final_icons" || apply_failed=1

    local BG_COLOR; BG_COLOR=$(cm_normalize_hex "$BG_COLOR_RAW")
    if [ -n "$BG_COLOR" ] && cm_is_valid_hex "$BG_COLOR"; then
        local final_bgmode; final_bgmode=$(cm_bgmode_key_from_label "$BGMODE_LABEL")
        cm_report "$(printf "$(cm_t report_desktop_bg)" "$BG_COLOR" "${CM_BGMODE_LABELS[$final_bgmode]}")" cm_apply_desktop_bg_color "$BG_COLOR" "$final_bgmode" || apply_failed=1
    fi

    cm_reload_cinnamon
    cm_notify_applied "Color Mint" "$(cm_t desktop_updated)" "${applied[@]}"
    return "$apply_failed"
}

cm_tab_desktop() {
    local KEY="$1" TABNUM="$2"
    while cm_tab_alive "$KEY"; do
        local cur_pos cur_btn_val cur_btn_key
        cur_pos=$(cm_current_panel_position)
        [ "$cur_pos" = "top" ] || cur_pos="bottom"
        cur_btn_val=$(cm_current_window_buttons)
        cur_btn_key=$(cm_button_preset_key_from_value "$cur_btn_val" 2>/dev/null) || cur_btn_key=""

        # Effects, workspaces and icons are re-read live (never a fixed value that
        # could revert something when pressing "Apply" untouched).
        local cur_effects cur_menu_fx cur_workspaces cur_icons cur_bg_color
        cur_effects=$(cm_current_desktop_effects)
        cur_menu_fx=$(cm_current_menu_effects)
        cur_workspaces=$(cm_current_workspaces)
        [[ "$cur_workspaces" =~ ^[0-9]+$ ]] || cur_workspaces=4
        cur_icons=$(cm_current_desktop_icons)
        cur_bg_color=$(cm_current_desktop_bg_color)
        cm_is_valid_hex "$cur_bg_color" || cur_bg_color="#2E3440"

        local POS_LIST BTN_LIST EFFECTS_LIST MENU_FX_LIST ICONS_LIST
        POS_LIST=$(_reorder_join_bang "${CM_PANELPOS_LABELS[$cur_pos]}" "${CM_PANELPOS_LABELS[bottom]}" "${CM_PANELPOS_LABELS[top]}")

        local k labels=()
        for k in "${CM_BUTTON_PRESET_ORDER[@]}"; do labels+=("${CM_BUTTON_PRESET_LABELS[$k]}"); done
        # If the current layout matches a known preset, its label goes first. If it is
        # custom (edited in Advanced), a notice that matches no real label goes first so
        # "Apply desktop" never silently overwrites it.
        local btn_reorder_label
        if [ -n "$cur_btn_key" ]; then
            btn_reorder_label="${CM_BUTTON_PRESET_LABELS[$cur_btn_key]}"
        else
            btn_reorder_label="$(cm_t keep_custom_layout)"
        fi
        BTN_LIST=$(_reorder_join_bang "$btn_reorder_label" "${labels[@]}")

        local onoff_labels=() showhide_labels=()
        for k in "${CM_ONOFF_ORDER[@]}"; do onoff_labels+=("${CM_ONOFF_LABELS[$k]}"); done
        for k in "${CM_SHOWHIDE_ORDER[@]}"; do showhide_labels+=("${CM_SHOWHIDE_LABELS[$k]}"); done
        EFFECTS_LIST=$(_reorder_join_bang "${CM_ONOFF_LABELS[$cur_effects]}" "${onoff_labels[@]}")
        MENU_FX_LIST=$(_reorder_join_bang "${CM_ONOFF_LABELS[$cur_menu_fx]}" "${onoff_labels[@]}")
        ICONS_LIST=$(_reorder_join_bang "${CM_SHOWHIDE_LABELS[$cur_icons]}" "${showhide_labels[@]}")

        local bgmode_labels=() BGMODE_LIST
        for k in "${CM_BGMODE_ORDER[@]}"; do bgmode_labels+=("${CM_BGMODE_LABELS[$k]}"); done
        BGMODE_LIST=$(_join_bang "${bgmode_labels[@]}")

        yad --plug="$KEY" --tabnum="$TABNUM" --form --scroll \
            --text="$(cm_t ui_desktop_text)" \
            --field="$(cm_t ui_desktop_panel_buttons):LBL" "" \
            --field="$(cm_t ui_panel_position):CB"                         "$POS_LIST" \
            --field="$(cm_t ui_window_buttons):CB"                          "$BTN_LIST" \
            --field="$(cm_t ui_effects_workspaces):LBL" "" \
            --field="$(cm_t ui_window_effects):CB"                          "$EFFECTS_LIST" \
            --field="$(cm_t ui_menu_effects):CB"                            "$MENU_FX_LIST" \
            --field="$(cm_t ui_workspaces):NUM"                        "${cur_workspaces}!1..20!1" \
            --field="$(cm_t ui_desktop_icons):CB"                        "$ICONS_LIST" \
            --field="$(cm_t ui_desktop_bg):LBL" "" \
            --field="$(cm_t ui_bg_color):CLR"                             "$cur_bg_color" \
            --field="$(cm_t ui_mode):CB"                                        "$BGMODE_LIST" \
            --field="$(cm_t apply_desktop)$(cm_yad_btn_icon gtk-apply):FBTN" "$(cm_fbtn_apply desktop_apply 2 3 5 6 7 8 10 11)" \
            --no-buttons >/dev/null 2>&1
    done
}

cm_ui_apply_advanced_apply() {
    local TL_LABEL="$1" TR_LABEL="$2" BL_LABEL="$3" BR_LABEL="$4" BTN_CUSTOM="$5" LIBADW="${6:-}"

    cm_ui_backup_before_apply || return 1
    local -a applied=()
    local apply_failed=0

    local tl tr bl br
    tl=$(cm_corner_key_from_label "$TL_LABEL")
    tr=$(cm_corner_key_from_label "$TR_LABEL")
    bl=$(cm_corner_key_from_label "$BL_LABEL")
    br=$(cm_corner_key_from_label "$BR_LABEL")
    cm_report "$(printf "$(cm_t report_hotcorners)" "$tl" "$tr" "$bl" "$br")" cm_apply_hotcorners "$tl" "$tr" "$bl" "$br" || apply_failed=1

    if [ -n "$BTN_CUSTOM" ]; then
        cm_report "$(printf "$(cm_t report_custom_buttons)" "$BTN_CUSTOM")" cm_apply_window_buttons "$BTN_CUSTOM" || apply_failed=1
    fi

    # Only a change of the box acts: with it as the form found it ("Apply" pressed untouched) the file is left alone.
    local cur_libadw=FALSE
    cm_libadwaita_active && cur_libadw=TRUE
    case "$LIBADW:$cur_libadw" in
        TRUE:FALSE) cm_report "$(cm_t report_libadwaita_on)" cm_apply_libadwaita on || apply_failed=1 ;;
        FALSE:TRUE) cm_report "$(cm_t report_libadwaita_off)" cm_apply_libadwaita off || apply_failed=1 ;;
    esac

    cm_reload_cinnamon
    cm_notify_applied "Color Mint" "$(cm_t advanced_updated)" "${applied[@]}"
    return "$apply_failed"
}

# Less-used settings, split from the Desktop tab (which grew to 20 fields).
cm_tab_advanced() {
    local KEY="$1" TABNUM="$2"
    while cm_tab_alive "$KEY"; do
        local hc_tl hc_tr hc_bl hc_br cur_btn_val cur_libadw=FALSE
        read -r hc_tl hc_tr hc_bl hc_br <<< "$(cm_current_hotcorners)"
        cur_btn_val=$(cm_current_window_buttons)
        cm_libadwaita_active && cur_libadw=TRUE

        local k corner_labels=() CORNER_LIST_TL CORNER_LIST_TR CORNER_LIST_BL CORNER_LIST_BR
        for k in "${CM_CORNER_ORDER[@]}"; do corner_labels+=("${CM_CORNER_LABELS[$k]}"); done
        CORNER_LIST_TL=$(_reorder_join_bang "${CM_CORNER_LABELS[$hc_tl]:-}" "${corner_labels[@]}")
        CORNER_LIST_TR=$(_reorder_join_bang "${CM_CORNER_LABELS[$hc_tr]:-}" "${corner_labels[@]}")
        CORNER_LIST_BL=$(_reorder_join_bang "${CM_CORNER_LABELS[$hc_bl]:-}" "${corner_labels[@]}")
        CORNER_LIST_BR=$(_reorder_join_bang "${CM_CORNER_LABELS[$hc_br]:-}" "${corner_labels[@]}")

        yad --plug="$KEY" --tabnum="$TABNUM" --form --scroll \
            --text="$(cm_t ui_advanced_text)" \
            --field="$(cm_t ui_hotcorners):LBL" "" \
            --field="$(cm_t ui_top_left):CB"                             "$CORNER_LIST_TL" \
            --field="$(cm_t ui_top_right):CB"                                "$CORNER_LIST_TR" \
            --field="$(cm_t ui_bottom_left):CB"                              "$CORNER_LIST_BL" \
            --field="$(cm_t ui_bottom_right):CB"                                "$CORNER_LIST_BR" \
            --field="$(cm_t ui_custom_buttons):LBL" "" \
            --field="$(cm_t ui_custom_string)"                          "$cur_btn_val" \
            --field="$(cm_t ui_button_values):LBL" "" \
            --field="$(cm_t ui_libadwaita):LBL" "" \
            --field="$(cm_t ui_libadwaita_use):CHK"                       "$cur_libadw" \
            --field="$(cm_t ui_libadwaita_hint):LBL" "" \
            --field="$(cm_t apply_advanced)$(cm_yad_btn_icon gtk-apply):FBTN" "$(cm_fbtn_apply advanced_apply 2 3 4 5 7 10)" \
            --no-buttons >/dev/null 2>&1
    done
}

cm_ui_apply_terminal_apply() {
    local PALETTE_LABEL="$1" CUSTOM_BG_RAW="$2" CUSTOM_FG_RAW="$3" USE_CUSTOM="$4"
    if [ -z "$PALETTE_LABEL" ] && [ "$USE_CUSTOM" != "TRUE" ]; then
        yad --error --text="$(cm_t ui_terminal_required)" --button="$(cm_t 'done'):0" 2>/dev/null
        return 1
    fi

    local PALETTE=""
    [ -n "$PALETTE_LABEL" ] && PALETTE=$(cm_palette_key_from_label "$PALETTE_LABEL")

    cm_ui_backup_before_apply || return 1
    local -a applied=()
    local apply_failed=0
    if [ -n "$PALETTE" ]; then
        cm_report "$(printf "$(cm_t report_palette)" "${CM_PALETTE_LABELS[$PALETTE]}")" cm_apply_terminal_palette "$PALETTE" || apply_failed=1
    fi

    # yad :CLR never returns empty (it always has a default color), so whether to
    # apply depends on this explicit checkbox, not on the field content.
    if [ "$USE_CUSTOM" = "TRUE" ]; then
        local cbg="" cfg=""
        [ -n "$CUSTOM_BG_RAW" ] && cbg=$(cm_normalize_hex "$CUSTOM_BG_RAW")
        [ -n "$CUSTOM_FG_RAW" ] && cfg=$(cm_normalize_hex "$CUSTOM_FG_RAW")
        cm_report "$(cm_t report_terminal_custom)" cm_apply_terminal_custom_colors "$cbg" "$cfg" || apply_failed=1
    fi

    cm_notify_applied "Color Mint" "$(cm_t terminal_updated)" "${applied[@]}"
    return "$apply_failed"
}

cm_tab_terminal() {
    local KEY="$1" TABNUM="$2"
    while cm_tab_alive "$KEY"; do
        local cur_palette cur_palette_label="" k palette_labels=() PALETTES
        cur_palette=$(cm_state_get "TERMINAL_PALETTE" "")
        [ -n "$cur_palette" ] && cur_palette_label="${CM_PALETTE_LABELS[$cur_palette]:-}"
        for k in "${CM_PALETTE_ORDER[@]}"; do palette_labels+=("${CM_PALETTE_LABELS[$k]}"); done
        PALETTES=$(_reorder_join_bang "$cur_palette_label" "${palette_labels[@]}")

        yad --plug="$KEY" --tabnum="$TABNUM" --form --scroll \
            --text="$(cm_t ui_terminal_text)" \
            --field="$(cm_t ui_palette):CB" "$PALETTES" \
            --field="$(cm_t ui_terminal_custom):LBL" "" \
            --field="$(cm_t ui_background):CLR" "" \
            --field="$(cm_t ui_text_color):CLR" "" \
            --field="$(cm_t ui_use_custom):CHK" "FALSE" \
            --field="$(cm_t ui_color_hint):LBL" "" \
            --field="$(cm_t apply_terminal)$(cm_yad_btn_icon gtk-apply):FBTN" "$(cm_fbtn_apply terminal_apply 1 3 4 5)" \
            --no-buttons >/dev/null 2>&1
    done
}

cm_ui_apply_fonts_apply() {
    local FONT_UI="$1" FONT_MONO="$2" ANTIALIAS_LABEL="$3" HINTING_LABEL="$4" SCALING_RAW="$5"
    local SCALING; SCALING=$(cm_num_int "$SCALING_RAW")
    local ANTIALIAS HINTING
    ANTIALIAS=$(cm_antialias_key_from_label "$ANTIALIAS_LABEL")
    HINTING=$(cm_hinting_key_from_label "$HINTING_LABEL")

    cm_ui_backup_before_apply || return 1
    local -a applied=()
    local apply_failed=0
    if [ -n "$FONT_UI" ]; then
        cm_report "$(printf "$(cm_t report_font)" "$FONT_UI")" cm_apply_font_name "$FONT_UI" || apply_failed=1
    fi
    if [ -n "$FONT_MONO" ]; then
        cm_report "$(printf "$(cm_t report_mono)" "$FONT_MONO")" cm_apply_monospace_font "$FONT_MONO" || apply_failed=1
    fi
    if [ -n "$ANTIALIAS_LABEL" ] && [ -n "$HINTING_LABEL" ]; then
        cm_report "$(printf "$(cm_t report_rendering)" "${CM_ANTIALIAS_LABELS[$ANTIALIAS]}" "${CM_HINTING_LABELS[$HINTING]}")" cm_apply_font_rendering "$ANTIALIAS" "$HINTING" || apply_failed=1
    fi
    if [ -n "$SCALING" ]; then
        cm_report "$(printf "$(cm_t report_scaling)" "$SCALING")" cm_apply_text_scaling "$SCALING" || apply_failed=1
    fi
    cm_notify_applied "Color Mint" "$(cm_t fonts_updated)" "${applied[@]}"
    return "$apply_failed"
}

cm_tab_fonts() {
    local KEY="$1" TABNUM="$2"
    while cm_tab_alive "$KEY"; do
        local cur_font cur_mono cur_antialias cur_hinting cur_scaling
        cur_font=$(cm_gs_string org.cinnamon.desktop.interface font-name)
        cur_mono=$(cm_gs_string org.gnome.desktop.interface monospace-font-name)
        read -r cur_antialias cur_hinting <<< "$(cm_current_font_rendering)"
        cur_scaling=$(cm_current_text_scaling)
        [ -z "$cur_font" ] && cur_font="Noto Sans 10"
        [ -z "$cur_mono" ] && cur_mono="Noto Sans Mono 10"

        local k antialias_labels=() hinting_labels=() ANTIALIAS_LIST HINTING_LIST
        for k in "${CM_ANTIALIAS_ORDER[@]}"; do antialias_labels+=("${CM_ANTIALIAS_LABELS[$k]}"); done
        for k in "${CM_HINTING_ORDER[@]}"; do hinting_labels+=("${CM_HINTING_LABELS[$k]}"); done
        ANTIALIAS_LIST=$(_reorder_join_bang "${CM_ANTIALIAS_LABELS[$cur_antialias]:-${CM_ANTIALIAS_LABELS[rgba]}}" "${antialias_labels[@]}")
        HINTING_LIST=$(_reorder_join_bang "${CM_HINTING_LABELS[$cur_hinting]:-${CM_HINTING_LABELS[slight]}}" "${hinting_labels[@]}")

        yad --plug="$KEY" --tabnum="$TABNUM" --form --scroll \
            --text="$(cm_t ui_fonts_text)" \
            --field="$(cm_t ui_typography):LBL" "" \
            --field="$(cm_t ui_interface):FN"                  "$cur_font" \
            --field="$(cm_t ui_monospace):FN"              "$cur_mono" \
            --field="$(cm_t ui_rendering):LBL" "" \
            --field="$(cm_t ui_antialias):CB"               "$ANTIALIAS_LIST" \
            --field="$(cm_t ui_hinting):CB"                    "$HINTING_LIST" \
            --field="$(cm_t ui_font_hint):LBL" "" \
            --field="$(cm_t ui_scaling):LBL" "" \
            --field="$(cm_t ui_text_scaling):NUM"       "${cur_scaling}!50..200!5" \
            --field="$(cm_t apply_fonts)$(cm_yad_btn_icon gtk-apply):FBTN" "$(cm_fbtn_apply fonts_apply 2 3 5 6 9)" \
            --no-buttons >/dev/null 2>&1
    done
}

cm_ui_apply_profiles_save() {
    local NEW_NAME="$1"
    if [ -n "$NEW_NAME" ]; then
        local preset_file=""
        if ! preset_file=$(cm_save_preset "$NEW_NAME"); then
            yad --error --text="$(cm_t preset_save_failed)" --button="$(cm_t 'done'):0" 2>/dev/null
            return 1
        fi
        cm_notify_applied "Color Mint" "$(cm_t preset_saved)" "$(printf "$(cm_t backup_name_detail)" "$NEW_NAME")" "$(printf "$(cm_t file_detail)" "$preset_file")"
    else
        yad --error --text="$(cm_t ui_preset_name_required)" --button="$(cm_t 'done'):0" 2>/dev/null
        return 1
    fi
}

cm_ui_apply_profiles_load() {
    local LOAD_NAME="$1"
    if [ -n "$LOAD_NAME" ]; then
        local why
        if ! why=$(cm_preset_precheck "$LOAD_NAME" 2>&1 >/dev/null); then
            yad --error --text="$(cm_t preset_load_failed)"$'\n\n'"$(_pango_escape "$why")" --button="$(cm_t 'done'):0" 2>/dev/null
            return 1
        fi
        cm_ui_backup_before_apply || return 1
        if ! why=$(cm_load_preset "$LOAD_NAME" 2>&1 >/dev/null); then
            yad --error --text="$(cm_t preset_load_failed)"$'\n\n'"$(_pango_escape "$why")" --button="$(cm_t 'done'):0" 2>/dev/null
            return 1
        fi
        cm_notify_applied "Color Mint" "$(cm_t preset_loaded)" "$(printf "$(cm_t backup_name_detail)" "$LOAD_NAME")" "$(cm_t preset_load_detail)"
    else
        yad --error --text="$(cm_t ui_preset_choose)" --button="$(cm_t 'done'):0" 2>/dev/null
        return 1
    fi
}

cm_ui_apply_profiles_restore() {
    local RESTORE_NAME="$1"
    # The placeholder of an empty list is not a backup: it counts as nothing chosen.
    [ "$RESTORE_NAME" != "$(cm_t ui_backup_empty_entry)" ] || RESTORE_NAME=""
    if [ -z "$RESTORE_NAME" ]; then
        if [ -z "$(cm_list_backups)" ]; then
            cm_ui_no_backups
        else
            yad --error --text="$(cm_t ui_backup_choose)" --button="$(cm_t 'done'):0" 2>/dev/null
        fi
    elif cm_confirm "$(printf "$(cm_t ui_backup_confirm)" "$RESTORE_NAME")"; then
        if cm_restore_backup "$RESTORE_NAME"; then
            cm_notify_applied "Color Mint" "$(cm_t backup_restored)" "$(printf "$(cm_t backup_name_detail)" "$RESTORE_NAME")"
        else
            yad --error --text="$(cm_t backup_restore_failed)" --button="$(cm_t 'done'):0" 2>/dev/null
            return 1
        fi
    else
        return 1
    fi
}

cm_tab_profiles() {
    local KEY="$1" TABNUM="$2"
    while cm_tab_alive "$KEY"; do
        local PRESETS BACKUPS
        PRESETS=$(_lines_to_bang "$(cm_list_presets)")
        BACKUPS=$(_lines_to_bang "$(cm_list_backups)")
        # A selector with nothing in it looks broken: say that there is no backup yet (cm_ui_apply_profiles_restore ignores it).
        [ -n "$BACKUPS" ] || BACKUPS=$(cm_t ui_backup_empty_entry)

        yad --plug="$KEY" --tabnum="$TABNUM" --form --scroll \
            --text="$(cm_t ui_profiles_text)" \
            --field="$(cm_t ui_save_preset):LBL" "" \
            --field="$(cm_t ui_new_name)"                "$(cm_t default_preset_name)" \
            --field="$(cm_t save)$(cm_yad_btn_icon gtk-save):FBTN"            "$(cm_fbtn_apply profiles_save 2)" \
            --field="$(cm_t ui_load_preset):LBL" "" \
            --field="$(cm_t ui_saved_preset):CB"           "$PRESETS" \
            --field="$(cm_t load)$(cm_yad_btn_icon gtk-open):FBTN"             "$(cm_fbtn_apply profiles_load 5)" \
            --field="$(cm_t ui_restore_backup):LBL" "" \
            --field="$(cm_t ui_available_backup):CB"         "$BACKUPS" \
            --field="$(cm_t restore)$(cm_yad_btn_icon gtk-undo):FBTN"          "$(cm_fbtn_apply profiles_restore 8)" \
            --no-buttons >/dev/null 2>&1
    done
}

# ============================================================================
# GUI — main window (YAD notebook)
# ============================================================================
# Button fields name their icon differently per yad generation: 0.40.0 (Ubuntu 24.04, Linux Mint 22.x)
# reads "label!icon", while yad 5 and later read "label!tooltip" and take the icon from
# "label!icon!tooltip" (verified with 0.40.0 and 14.1: otherwise the icon name shows up as a tooltip).
# The generation is detected once per process tree and inherited by the tabs through the environment.
cm_yad_detect_fields() {
    local major
    [ -z "${CM_YAD_NEW_FIELDS:-}" ] || return 0
    major=$(yad --version 2>/dev/null | sed -n '1s/^\([0-9][0-9]*\)\..*/\1/p')
    if [ "${major:-0}" -ge 1 ] 2>/dev/null; then CM_YAD_NEW_FIELDS=1; else CM_YAD_NEW_FIELDS=0; fi
    export CM_YAD_NEW_FIELDS
}

cm_yad_btn_icon() {
    cm_yad_detect_fields
    if [ "$CM_YAD_NEW_FIELDS" = 1 ]; then printf '!%s!' "$1"; else printf '!%s' "$1"; fi
}

# Main window size: the designed 950x740, reduced to fit the screen. On a 1366x768 laptop a 740 px
# window loses its bottom once the panel and the title bar are counted; the tab forms scroll.
cm_gui_geometry() {
    local width=950 height=740 screen sw sh
    screen=$(xrandr --current 2>/dev/null | awk '
        / connected / {
            for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+/) { split($i, a, /[x+]/); geom = a[1] " " a[2]; break }
            if (geom != "" && / primary /) { print geom; found = 1; exit }
            if (geom != "" && first == "") first = geom
            geom = ""
        }
        END { if (!found && first != "") print first }')
    [ -n "$screen" ] || screen=$(xdpyinfo 2>/dev/null | sed -n 's/.*dimensions: *\([0-9]*\)x\([0-9]*\) pixels.*/\1 \2/p' | head -n1)
    if [ -n "$screen" ]; then
        read -r sw sh <<< "$screen"
        [ $((sw - 40)) -ge "$width" ] || width=$((sw - 40))
        [ $((sh - 110)) -ge "$height" ] || height=$((sh - 110))
    else
        height=680
    fi
    [ "$width" -ge 640 ] || width=640
    [ "$height" -ge 460 ] || height=460
    printf '%s %s\n' "$width" "$height"
}

# One generation is one notebook plus its seven tabs, run as a process of its own. Its PID is the yad
# key, so nothing left by an earlier generation can attach to a later one: yad does not remove its
# shared-memory segment when killed, and a plug that starts before its notebook waits for that key.
# Every tab runs in its own process group (setsid), so a single signal stops the shell and its yad plug.
CM_TAB_PIDS=()
CM_NOTEBOOK_PID=""
CM_GEN_PID=""
CM_GEN_STOP=0

# cm_win_signal <leader-pid> <signal>: the tab's whole group, or the shell and its children when
# the tab could not get a group of its own.
cm_win_signal() {
    kill "-$2" -- "-$1" 2>/dev/null && return 0
    pkill "-$2" -P "$1" 2>/dev/null
    kill "-$2" "$1" 2>/dev/null
}

# Stops the window generation: TERM to the notebook and to every tab group first, then the notebook gets up to 1 s
# before KILL, the tab shells are waited for and what is left of them gets KILL, and the notebook's shared-memory
# segment is removed. No wait comes before a TERM: the tabs run in sessions of their own, so a caller that stops the
# program as a group and gives the cleanup only a few seconds (timeout --kill-after) would orphan them whenever a
# slow machine spends that time in the wait.
cm_win_teardown() {
    local key="$1" pid n
    trap '' HUP INT TERM
    [ -z "$CM_NOTEBOOK_PID" ] || kill -TERM "$CM_NOTEBOOK_PID" 2>/dev/null
    for pid in "${CM_TAB_PIDS[@]}"; do cm_win_signal "$pid" TERM; done
    if [ -n "$CM_NOTEBOOK_PID" ]; then
        for n in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$CM_NOTEBOOK_PID" 2>/dev/null || break; sleep 0.1; done
        # No wait on the notebook: when the signal arrives as it dies, that wait never returns.
        kill -KILL "$CM_NOTEBOOK_PID" 2>/dev/null
        CM_NOTEBOOK_PID=""
    fi
    for pid in "${CM_TAB_PIDS[@]}"; do wait "$pid" 2>/dev/null; done
    for pid in "${CM_TAB_PIDS[@]}"; do cm_win_signal "$pid" KILL; done
    CM_TAB_PIDS=()
    ipcrm -M "$key" 2>/dev/null
    return 0
}

# HUP and TERM in a generation. They are caught, never left to their default action: a second one that arrives while Bash
# is ending the process on the first (the caller's group TERM, then cm_win_abort's) stops Bash 5.2 before its EXIT trap
# has done its work, and the tabs, each in a session of its own, stay open. The handler only records the exit status
# (128 + the signal number) and ends the notebook, which ends the wait in cm_window_generation.
cm_gen_signal() {
    CM_GEN_STOP="$1"
    [ -z "$CM_NOTEBOOK_PID" ] || kill -TERM "$CM_NOTEBOOK_PID" 2>/dev/null
    return 0
}

# Runs in its own process (see cm_main_window). Exit status: the notebook's, except 10 = language button
# and 11 = a tab asked for a rebuild (cm_tab_redraw). It ends with `exit`, never `return`: before Bash 5.0 a
# background function that returns skips its EXIT trap, and the tabs would outlive the window.
cm_window_generation() {
    local gui_w="$1" gui_h="$2" KEY="$BASHPID" entry rc=0 mark
    mark="$(cm_redraw_mark "$KEY")"
    rm -f "$mark"
    local -a runner=(bash)
    CM_TAB_PIDS=()
    CM_NOTEBOOK_PID=""
    trap 'cm_win_teardown "$KEY"' EXIT
    trap 'cm_gen_signal 129' HUP
    trap 'cm_gen_signal 143' TERM
    command -v setsid >/dev/null 2>&1 && runner=(setsid bash)
    ipcrm -M "$KEY" 2>/dev/null

    # The language travels with the tab: it must not depend on the state file having been written.
    for entry in themes:1 panel:2 desktop:3 advanced:4 terminal:5 fonts:6 profiles:7; do
        CM_LANG_OVERRIDE="$CM_LANG" "${runner[@]}" "$SCRIPT_PATH" __tab "${entry%%:*}" "$KEY" "${entry##*:}" &
        CM_TAB_PIDS+=("$!")
    done

    yad --notebook --key="$KEY" \
        --title="Color Mint" \
        --window-icon="$(cm_icon_path)" \
        --width="$gui_w" --height="$gui_h" \
        --tab="$(cm_t gui_tab_themes)" \
        --tab="$(cm_t gui_tab_panel)" \
        --tab="$(cm_t gui_tab_desktop)" \
        --tab="$(cm_t gui_tab_advanced)" \
        --tab="$(cm_t gui_tab_terminal)" \
        --tab="$(cm_t gui_tab_fonts)" \
        --tab="$(cm_t gui_tab_profiles)" \
        --button="$(cm_t lang_button):10" \
        --button="$(cm_t exit):1" &
    CM_NOTEBOOK_PID=$!
    # Waiting in the background keeps the signal traps responsive; a foreground yad would delay them.
    if [ "$CM_GEN_STOP" -eq 0 ]; then wait "$CM_NOTEBOOK_PID" || rc=$?; fi
    [ "$CM_GEN_STOP" -eq 0 ] || exit "$CM_GEN_STOP"
    if [ -f "$mark" ]; then rm -f "$mark"; exit 11; fi
    exit "$rc"
}

cm_win_abort() {
    if [ -n "$CM_GEN_PID" ]; then
        kill -TERM "$CM_GEN_PID" 2>/dev/null
        wait "$CM_GEN_PID" 2>/dev/null
    fi
    exit "$1"
}

cm_main_window() {
    cm_bootstrap_presets
    cm_icon_install 2>/dev/null || true
    local gui_w gui_h rc
    cm_yad_detect_fields
    read -r gui_w gui_h < <(cm_gui_geometry)

    trap 'cm_win_abort 129' HUP
    trap 'cm_win_abort 130' INT
    trap 'cm_win_abort 143' TERM
    while true; do
        cm_window_generation "$gui_w" "$gui_h" &
        CM_GEN_PID=$!
        wait "$CM_GEN_PID"
        rc=$?
        CM_GEN_PID=""
        case "$rc" in
            10) cm_lang_toggle ;;
            11) ;;
            *) break ;;
        esac
    done
    trap - HUP INT TERM
    return 0
}

# ============================================================================
# Help / usage
# ============================================================================
# Print a help block: title plus command/description pairs, kept within 80 columns.
# Short commands share one description column; if any row of the block has a long command or
# description, the whole block stacks (command, then its description indented below) so the
# layout stays consistent inside the block. A command longer than the terminal is folded.
cm_usage_section() {
    local title="$1"; shift
    local -a rows=("$@")
    local i w=0 col line cmd desc stacked=0
    local indent='    ' max_cmd=46 width=80
    for ((i = 0; i < ${#rows[@]}; i += 2)); do
        [ -z "${rows[i]}" ] && continue
        if [ $((${#indent} + ${#rows[i]})) -gt "$max_cmd" ]; then
            stacked=1
        elif [ ${#rows[i]} -gt "$w" ]; then
            w=${#rows[i]}
        fi
    done
    col=$((${#indent} + w + 2))
    for ((i = 0; i < ${#rows[@]}; i += 2)); do
        [ $((col + ${#rows[i + 1]})) -gt "$width" ] && stacked=1
    done
    echo; echo "  $title"
    for ((i = 0; i < ${#rows[@]}; i += 2)); do
        cmd="${rows[i]}"; desc="${rows[i + 1]}"
        if [ -z "$cmd" ] && [ "$stacked" -eq 0 ]; then
            printf '%*s%s\n' "$col" '' "$desc"
        elif [ -z "$cmd" ]; then
            while IFS= read -r line; do
                printf '%s    %s\n' "$indent" "$line"
            done < <(printf '%s\n' "$desc" | fold -s -w $((width - ${#indent} - 4)) | sed 's/[[:space:]]*$//')
        elif [ "$stacked" -eq 0 ]; then
            printf '%s%-*s  %s\n' "$indent" "$w" "$cmd" "$desc"
        else
            local first=1
            while IFS= read -r line; do
                if [ "$first" -eq 1 ]; then printf '%s%s\n' "$indent" "$line"; first=0
                else printf '%s    %s\n' "$indent" "$line"; fi
            done < <(printf '%s\n' "$cmd" | fold -s -w $((width - ${#indent})) | sed 's/[[:space:]]*$//')
            while IFS= read -r line; do
                printf '%s    %s\n' "$indent" "$line"
            done < <(printf '%s\n' "$desc" | fold -s -w $((width - ${#indent} - 4)) | sed 's/[[:space:]]*$//')
        fi
    done
}

cm_print_usage() {
    local p; p=$(basename "$SCRIPT_PATH")
    local name_arg='<name>' file_arg='<file|folder>' one_file_arg='<file>' part_arg='<part>' pkg_arg='<package>' preset_arg='<preset|string>' hotcorner_args='<tl> <tr> <bl> <br>' terminal_color_args='<#background> <#text>'
    if [ "$CM_LANG" = "es" ]; then
        name_arg='<nombre>'; file_arg='<archivo|carpeta>'; one_file_arg='<archivo>'; part_arg='<parte>'; pkg_arg='<paquete>'; preset_arg='<preset|cadena>'
        hotcorner_args='<sup-izq> <sup-der> <inf-izq> <inf-der>'; terminal_color_args='<#fondo> <#texto>'
    fi
    printf '%s\n' "$(printf "$(cm_t usage_title)" "$CM_VERSION" "$CM_AUTHOR")" | fold -s -w 80 | sed 's/[[:space:]]*$//'

    local wg=$((${#p} + 6))
    echo; printf '%s\n' "$(cm_t usage_graphical)"
    printf '  %-*s%s\n' "$wg" "$p" "$(cm_t usage_graphical_desc)"
    printf '  %-*s%s\n' "$wg" "$p gui" "$(cm_t usage_same_gui)"

    echo; printf '%s\n' "$(cm_t usage_terminal)" | fold -s -w 80 | sed 's/[[:space:]]*$//'
    cm_usage_section "$(cm_t usage_language)" \
        "$p l" "$(cm_t usage_language_desc)"

    cm_usage_section "$(cm_t usage_themes)" \
        "$p theme mint-y-color <color> <claro|oscuro>" "$(cm_t u_theme_mint)" \
        "$p theme gtk $name_arg" "$(cm_t u_theme_gtk)" \
        "$p theme icon $name_arg" "$(cm_t u_theme_icon)" \
        "$p theme cursor $name_arg" "$(cm_t u_theme_cursor)" \
        "$p theme cursor-size <16-96>" "$(cm_t u_theme_cursor_size)" \
        "$p theme cinnamon $name_arg" "$(cm_t u_theme_cinnamon)" \
        "$p theme libadwaita <on|off|status>" "$(cm_t u_theme_libadwaita)" \
        "$p theme import $file_arg" "$(cm_t u_theme_import)" \
        "$p theme fetch $name_arg" "$(cm_t u_theme_fetch)" \
        "$p theme list-packages" "$(cm_t u_theme_list_packages)" \
        "$p theme install $pkg_arg" "$(cm_t u_theme_install)" \
        "$p theme folder" "$(cm_t u_theme_folder)" \
        "$p theme list-gtk" "$(cm_t u_theme_list_gtk)" \
        "$p theme list-icon" "$(cm_t u_theme_list_icon)" \
        "$p theme list-cursor" "$(cm_t u_theme_list_cursor)" \
        "$p theme list-cinnamon" "$(cm_t u_theme_list_cinnamon)" \
        "$p theme list-mint-y-colors <claro|oscuro>" "$(cm_t u_theme_list_mint)"

    cm_usage_section "$(cm_t usage_panel)" \
        "$p panel $part_arg <#RRGGBB>" "$(cm_t u_panel_part)" \
        "" "$(cm_t u_panel_keys1)" \
        "" "$(cm_t u_panel_keys2)" \
        "$p panel opacity <0-100>" "$(cm_t u_panel_opacity)" \
        "$p panel height <16-100>" "$(cm_t u_panel_height)" \
        "$p panel reset-colors" "$(cm_t u_panel_reset)"

    cm_usage_section "$(cm_t usage_desktop)" \
        "$p desktop panel-position <top|bottom>" "$(cm_t u_desktop_position)" \
        "$p desktop window-buttons $preset_arg" "$(cm_t u_desktop_buttons)" \
        "$p desktop list-button-presets" "$(cm_t u_desktop_list_buttons)" \
        "$p desktop hotcorners $hotcorner_args" "$(cm_t u_desktop_hotcorners)" \
        "$p desktop effects <on|off>" "$(cm_t u_desktop_effects)" \
        "$p desktop menu-effects <on|off>" "$(cm_t u_desktop_menu_effects)" \
        "$p desktop workspaces <1-20>" "$(cm_t u_desktop_workspaces)" \
        "$p desktop icons <show|hide>" "$(cm_t u_desktop_icons)" \
        "$p desktop bg-color <#RRGGBB> <mantener|solo_color>" "$(cm_t u_desktop_bg)"

    cm_usage_section "$(cm_t usage_terminal_section)" \
        "$p terminal apply_palette $name_arg" "$(cm_t u_terminal_apply)" \
        "$p terminal list" "$(cm_t u_terminal_list)" \
        "$p terminal custom-colors $terminal_color_args" "$(cm_t u_terminal_custom)"

    cm_usage_section "$(cm_t usage_fonts)" \
        "$p fonts font $name_arg" "$(cm_t u_fonts_font)" \
        "$p fonts monospace $name_arg" "$(cm_t u_fonts_mono)" \
        "$p fonts rendering <rgba|grayscale|none> <slight|medium|full|none>" "$(cm_t u_fonts_rendering)" \
        "$p fonts scaling <50-200>" "$(cm_t u_fonts_scaling)"

    cm_usage_section "$(cm_t usage_backups)" \
        "$p backup create" "$(cm_t u_backup_create)" \
        "$p backup list" "$(cm_t u_backup_list)" \
        "$p backup restore $name_arg" "$(cm_t u_backup_restore)" \
        "$p preset save $name_arg" "$(cm_t u_preset_save)" \
        "$p preset list" "$(cm_t u_preset_list)" \
        "$p preset load $name_arg" "$(cm_t u_preset_load)" \
        "$p preset export $name_arg $file_arg" "$(cm_t u_preset_export)" \
        "$p preset import $one_file_arg [$name_arg]" "$(cm_t u_preset_import)"

    cm_usage_section "$(cm_t usage_install)" \
        "$p install" "$(cm_t u_install)" \
        "$p uninstall [--restore-look] [--keep-config] [--yes]" "$(cm_t u_uninstall)"

    echo; printf '%s\n' "$(cm_t usage_data)"
    echo "  $CM_HOME"
}

# Short error for an unrecognized subcommand: names the received value and
# points to the matching --help section instead of repeating the syntax.
cm_usage_error() {
    printf '%s\n' "$(printf "$(cm_t unknown_option)" "$1" "$3")" >&2
    printf '%s\n' "$(printf "$(cm_t help_hint)" "$(basename "$SCRIPT_PATH")" "$2")"
    exit 1
}

# ============================================================================
# original look — what the desktop looked like before Color Mint's first change
#
# The first command that changes the look saves the dconf paths Color Mint can write and notes which of the
# files and folders it writes already existed; `uninstall --restore-look` puts all of that back. It lives
# in $CM_ORIGINAL_DIR, apart from the backups, so nothing prunes it.
# ============================================================================
# Files Color Mint writes outside its own folder, as "tag|path": xres, gtk3css and gtk4css hold one marked
# block; fonts and envd are written whole. A link at any of them counts as the file it points to (cm_real_file).
# A file added here also needs its case in cm_restore_plan_look (and cm_look_block_marks when it holds a block).
cm_look_files() {
    printf '%s\n' \
        "xres|$HOME/.Xresources" \
        "gtk3css|$HOME/.config/gtk-3.0/gtk.css" \
        "gtk4css|$HOME/.config/gtk-4.0/gtk.css" \
        "fonts|$HOME/.config/fontconfig/fonts.conf" \
        "envd|$HOME/.config/environment.d/60-color-mint-cursor.conf"
}

# cm_look_block_marks <tag>: the begin and end marker lines of the block Color Mint keeps in that file (the files it
# writes whole have none). Backups and restores read the blocks through it.
cm_look_block_marks() {
    case "$1" in
        xres)            printf '%s\n%s\n' "$CM_XRES_BEGIN" "$CM_XRES_END" ;;
        gtk3css|gtk4css) printf '%s\n%s\n' "$CM_GTK_ACCENT_BEGIN" "$CM_GTK_ACCENT_END" ;;
        *)               return 1 ;;
    esac
}

# Folders Color Mint may have to create, as "tag|path".
cm_look_dirs() {
    printf '%s\n' \
        "gtk3|$HOME/.config/gtk-3.0" \
        "gtk4|$HOME/.config/gtk-4.0" \
        "fontconfig|$HOME/.config/fontconfig" \
        "envd|$HOME/.config/environment.d" \
        "themes|$HOME/.themes" \
        "icons|$HOME/.icons"
}

# cm_original_get <key> [default]
cm_original_get() {
    awk -F= -v k="$1" -v d="${2:-}" '$1 == k { sub(/^[^=]*=/, ""); print; found = 1; exit } END { if (!found) print d }' \
        "$CM_ORIGINAL_DIR/manifest.txt" 2>/dev/null || printf '%s\n' "${2:-}"
}

# True when Color Mint was used before its original look could be saved: the state holds more than what start-up
# itself writes (the language and the seeded-look marks), a backup exists, or something besides the folders
# `install` made is on record.
cm_used_before() {
    grep -qsvE '^(LANGUAGE|SEEDED_LOOKS)=' "$CM_STATE_FILE" && return 0
    grep -qsv '^dir/' "$CM_INSTALLED_FILE" && return 0
    [ -n "$(find "$CM_BACKUP_DIR" -mindepth 1 -maxdepth 1 -name 'backup_*' -print -quit 2>/dev/null)" ]
}

# Save the original look once. Returns 0 when it is saved (now or before), 1 when it could not be.
cm_original_ensure() {
    [ -f "$CM_ORIGINAL_DIR/manifest.txt" ] && return 0
    local work dconf=no origin=first-change tag path
    mkdir -p -- "$CM_HOME" || return 1
    cm_lock || return 1
    if [ -f "$CM_ORIGINAL_DIR/manifest.txt" ]; then cm_unlock; return 0; fi
    work=$(mktemp -d "$CM_HOME/.original.tmp.XXXXXX") || { cm_unlock; return 1; }
    if command -v dconf >/dev/null 2>&1 && cm_dconf_dump_all "$work"; then
        dconf=yes
    else
        rm -f -- "$work"/dconf_*.ini
    fi
    # Color Mint was used before this version: what is saved is not the true original.
    ! cm_used_before || origin=prior-use
    if ! {
        printf 'dconf=%s\norigin=%s\ncreated=%s\nversion=%s\n' "$dconf" "$origin" "$(date '+%Y-%m-%d %H:%M:%S')" "$CM_VERSION"
        while IFS='|' read -r tag path; do
            if [ -f "$path" ]; then
                printf 'file.%s=1\n' "$tag"
                [ "$tag" != fonts ] || cp -- "$path" "$work/fonts.conf" || exit 1
            else
                printf 'file.%s=0\n' "$tag"
            fi
        done < <(cm_look_files)
        while IFS='|' read -r tag path; do
            if [ -e "$path" ]; then printf 'dir.%s=1\n' "$tag"; else printf 'dir.%s=0\n' "$tag"; fi
        done < <(cm_look_dirs)
    } | cm_atomic_write "$work/manifest.txt" 600 || ! mv -T -- "$work" "$CM_ORIGINAL_DIR" 2>/dev/null; then
        rm -rf -- "$work" 2>/dev/null || true
        cm_unlock
        return 1
    fi
    cm_unlock
    cm_log "INFO" "$(printf "$(cm_t original_logged)" "$CM_ORIGINAL_DIR")"
}

# True when the command line changes the desktop look, so the original has to be saved before it runs.
cm_changes_look() {
    case "${1:-}" in
        __apply|panel|fonts) return 0 ;;
        theme) case "${2:-}" in
            gtk|icon|cursor|cursor-size|cinnamon|import|fetch|install|mint-y-color) return 0 ;;
            libadwaita) case "${3:-}" in on|off) return 0 ;; esac ;;
        esac ;;
        desktop) case "${2:-}" in panel-position|window-buttons|hotcorners|effects|menu-effects|workspaces|icons|bg-color) return 0 ;; esac ;;
        terminal) case "${2:-}" in apply_palette|custom-colors) return 0 ;; esac ;;
        backup) [ "${2:-}" = restore ] && return 0 ;;
        preset) [ "${2:-}" = load ] && return 0 ;;
    esac
    return 1
}

# cm_record_installed <themes|icons|apt> <name>: remember what Color Mint put on the system, for `uninstall`.
cm_record_installed() {
    local line="$1/$2" tmp status=1
    mkdir -p -- "$CM_HOME" || return 1
    cm_lock || return 1
    if grep -qxF -- "$line" "$CM_INSTALLED_FILE" 2>/dev/null; then cm_unlock; return 0; fi
    tmp=$(mktemp "$CM_HOME/.${CM_INSTALLED_FILE##*/}.build.XXXXXX") || { cm_unlock; return 1; }
    if { [ ! -f "$CM_INSTALLED_FILE" ] || cat "$CM_INSTALLED_FILE" > "$tmp"; } \
        && printf '%s\n' "$line" >> "$tmp" && cm_atomic_write "$CM_INSTALLED_FILE" < "$tmp"; then
        status=0
    fi
    rm -f -- "$tmp" 2>/dev/null || true
    cm_unlock
    return "$status"
}

# ============================================================================
# install — a stable copy of the script, its icon and a menu launcher
#
# The copy lets the clone be deleted and the program still be uninstalled. Nothing needs sudo, and the
# launcher is the last file written, so the menu never points at something that is not there.
# ============================================================================
CM_INSTALLED_BIN="$HOME/.local/bin/color-mint"
CM_LAUNCHER_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/color-mint.desktop"
CM_LAUNCHER_MARK="X-Color-Mint-Launcher=true"

# A launcher's Exec line has its own quoting rules; a path with any of these is refused rather than escaped.
cm_launcher_path_ok() {
    case "$1" in *[\"\`\$\\%]*|*[[:cntrl:]]*) return 1 ;; esac
}

# cm_is_ours <file> <launcher|copy>: a regular file Color Mint wrote (or nothing at all), never someone else's.
cm_is_ours() {
    [ -e "$1" ] || [ -L "$1" ] || return 0
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    case "$2" in
        launcher) grep -qxF "$CM_LAUNCHER_MARK" "$1" ;;
        copy)     head -n 3 -- "$1" | grep -qxF '# MENU: Color Mint' ;;
    esac
}

# cm_make_dir <dir>: create it and, when it did not exist, record it so `uninstall` can remove it again.
cm_make_dir() {
    local dir="$1"
    [ -d "$dir" ] && return 0
    mkdir -p -- "$dir" || return 1
    cm_record_installed dir "$dir" || true
}

cm_install() {
    if [ ! -f "$SCRIPT_PATH" ] || [ ! -r "$SCRIPT_PATH" ]; then
        printf '%s\n' "$(printf "$(cm_t install_script_unreadable)" "$SCRIPT_PATH")" >&2
        return 1
    fi
    if ! cm_launcher_path_ok "$CM_INSTALLED_BIN" || ! cm_launcher_path_ok "$CM_ICON_FILE"; then
        printf '%s\n' "$(printf "$(cm_t install_unsafe_home)" "$HOME")" >&2
        return 1
    fi
    local item
    cm_is_ours "$CM_INSTALLED_BIN" copy || { printf '%s\n' "$(printf "$(cm_t install_foreign)" "$CM_INSTALLED_BIN")" >&2; return 1; }
    cm_is_ours "$CM_LAUNCHER_FILE" launcher || { printf '%s\n' "$(printf "$(cm_t install_foreign)" "$CM_LAUNCHER_FILE")" >&2; return 1; }
    for item in "${CM_INSTALLED_BIN%/*}" "${CM_LAUNCHER_FILE%/*}"; do
        cm_make_dir "$item" || { printf '%s\n' "$(printf "$(cm_t install_failed)" "$item")" >&2; return 1; }
    done
    if [ "$SCRIPT_PATH" != "$CM_INSTALLED_BIN" ] && ! cmp -s "$SCRIPT_PATH" "$CM_INSTALLED_BIN"; then
        cm_atomic_write "$CM_INSTALLED_BIN" 755 < "$SCRIPT_PATH" \
            || { printf '%s\n' "$(printf "$(cm_t install_failed)" "$CM_INSTALLED_BIN")" >&2; return 1; }
    fi
    cm_icon_install || true
    cm_atomic_write "$CM_LAUNCHER_FILE" 644 <<EOF \
        || { printf '%s\n' "$(printf "$(cm_t install_failed)" "$CM_LAUNCHER_FILE")" >&2; return 1; }
[Desktop Entry]
Type=Application
Name=Color Mint
Comment=$(CM_LANG=en cm_t launcher_comment)
Comment[es]=$(CM_LANG=es cm_t launcher_comment)
Exec="$CM_INSTALLED_BIN" gui
Icon=$CM_ICON_FILE
Terminal=false
Categories=Settings;DesktopSettings;GTK;
Keywords=theme;color;accent;panel;cinnamon;
$CM_LAUNCHER_MARK
EOF
    printf '%s\n' "$(printf "$(cm_t install_done)" "$CM_INSTALLED_BIN" "$CM_LAUNCHER_FILE")"
    case ":$PATH:" in *":${CM_INSTALLED_BIN%/*}:"*) ;; *) printf '%s\n' "$(printf "$(cm_t install_path_hint)" "${CM_INSTALLED_BIN%/*}")" ;; esac
    cm_log "INFO" "$(printf "$(cm_t install_done)" "$CM_INSTALLED_BIN" "$CM_LAUNCHER_FILE")"
}

# ============================================================================
# uninstall — take back what `install` and Color Mint's own use left on the system
#
#   uninstall [--restore-look] [--keep-config] [--yes]
#
# Always removed: the menu launcher and the copy in ~/.local/bin. By default the desktop keeps the look it has
# and so do the files and theme folders that look depends on. --restore-look puts all of it back as the snapshot
# in $CM_ORIGINAL_DIR describes it; --keep-config leaves $CM_HOME alone. Only what Color Mint can show to be its
# own is deleted; anything else is left and named. The snapshot and the install record go last and the program
# itself only after the look is restored, so a run that stopped half way is finished by running it again.
# ============================================================================

# cm_uninstall_remove_ours <file> <launcher|copy>: delete it when Color Mint wrote it, name it when not.
cm_uninstall_remove_ours() {
    [ -e "$1" ] || [ -L "$1" ] || return 0
    if ! cm_is_ours "$1" "$2"; then
        printf '%s\n' "$(printf "$(cm_t uninstall_kept_other)" "$1")" >&2
        return 0
    fi
    rm -f -- "$1" || { printf '%s\n' "$(printf "$(cm_t uninstall_failed_item)" "$1")" >&2; return 1; }
}

# cm_uninstall_strip <file> <begin> <end> <existed 0|1>: drop Color Mint's marked block, and the file too when it
# did not exist before Color Mint and nothing else is left in it. A link is the file it points to: the block goes from
# there and the link stays; a link is never deleted. A link whose file cannot be written keeps the block, is named and
# does not stop the uninstall.
cm_uninstall_strip() {
    local file="$1" begin="$2" end="$3" existed="$4"
    [ -f "$file" ] || return 0
    if ! cm_marked_block_ok "$file" "$begin" "$end"; then
        printf '%s\n' "$(printf "$(cm_t uninstall_block_open)" "$file")" >&2
        return 0
    fi
    if grep -qxF -- "$begin" "$file"; then
        if ! cm_resolve_look "$file" >/dev/null; then
            printf '%s\n' "$(printf "$(cm_t uninstall_kept_link)" "$file")" >&2
            return 0
        fi
        cm_look_marked_replace "$file" "$begin" "$end" "" || return 1
    fi
    if [ "$existed" = 0 ] && [ ! -L "$file" ] && ! grep -q '[^[:space:]]' "$file"; then
        rm -f -- "$file" || return 1
    fi
}

# fonts.conf is touched only while it still carries Color Mint's mark: then it goes back to the copy saved with the
# snapshot, or is removed when Color Mint made it. A file the user has edited or replaced since is left and named.
# A link is followed only when a file existed at the snapshot, and then the copy is written to the file it points to
# and the link stays; when no file existed, a link is the user's and is left and named. A link is never deleted, and
# one whose file cannot be written is left and named without stopping the uninstall.
cm_uninstall_fonts() {
    local file="$1" existed="$2" saved="$CM_ORIGINAL_DIR/fonts.conf"
    [ -e "$file" ] || [ -L "$file" ] || return 0
    if [ ! -f "$file" ] || { [ -L "$file" ] && [ "$existed" != 1 ]; } \
        || ! grep -qF 'Color Mint: generated file' "$file" \
        || { [ "$existed" = 1 ] && [ ! -f "$saved" ]; }; then
        printf '%s\n' "$(printf "$(cm_t uninstall_kept_other)" "$file")" >&2
        return 0
    fi
    if [ "$existed" = 1 ]; then
        ! cmp -s -- "$saved" "$file" || return 0
        if ! cm_resolve_look "$file" >/dev/null; then
            printf '%s\n' "$(printf "$(cm_t uninstall_kept_link)" "$file")" >&2
            return 0
        fi
        cm_look_write "$file" < "$saved"
    else
        rm -f -- "$file"
    fi
}

# The environment.d file is Color Mint's by name: removed when it did not exist before, unless it is a link, which is
# never deleted and is named when its file holds the cursor size Color Mint wrote.
cm_uninstall_envd() {
    local file="$1" existed="$2"
    [ "$existed" = 0 ] && [ -f "$file" ] || return 0
    if [ -L "$file" ]; then
        ! grep -q '^XCURSOR_SIZE=' "$file" || printf '%s\n' "$(printf "$(cm_t uninstall_kept_link)" "$file")" >&2
        return 0
    fi
    rm -f -- "$file"
}

# Theme and icon folders Color Mint imported or copied (the install record): deleted; apt packages are only named.
cm_uninstall_themes() {
    local line kind name dir status=0
    [ -f "$CM_INSTALLED_FILE" ] || return 0
    while IFS= read -r line; do
        kind="${line%%/*}"; name="${line#*/}"
        case "$kind" in themes|icons) ;; *) continue ;; esac
        cm_is_valid_name "$name" && [ "$name" != . ] || continue
        dir="$HOME/.$kind/$name"
        [ -e "$dir" ] || [ -L "$dir" ] || continue
        if [ -L "$dir" ] || [ ! -d "$dir" ]; then
            printf '%s\n' "$(printf "$(cm_t uninstall_kept_other)" "$dir")" >&2
        elif ! rm -rf -- "$dir"; then
            printf '%s\n' "$(printf "$(cm_t uninstall_failed_item)" "$dir")" >&2
            status=1
        fi
    done < "$CM_INSTALLED_FILE"
    return "$status"
}

# Put back what the snapshot describes. It stops before touching a file when dconf cannot be restored.
cm_uninstall_restore_look() {
    local tag path existed status=0 copy
    if [ "$(cm_original_get dconf no)" = yes ]; then
        if ! command -v dconf >/dev/null 2>&1 || ! cm_dconf_load_all "$CM_ORIGINAL_DIR"; then
            printf '%s\n' "$(cm_t uninstall_dconf_failed)" >&2
            return 1
        fi
    else
        printf '%s\n' "$(cm_t uninstall_no_dconf)" >&2
    fi
    while IFS='|' read -r tag path; do
        existed=$(cm_original_get "file.$tag" 0)
        case "$tag" in
            xres)            cm_uninstall_strip "$path" "$CM_XRES_BEGIN" "$CM_XRES_END" "$existed" || status=1 ;;
            gtk3css|gtk4css) cm_uninstall_strip "$path" "$CM_GTK_ACCENT_BEGIN" "$CM_GTK_ACCENT_END" "$existed" || status=1 ;;
            fonts)           cm_uninstall_fonts "$path" "$existed" || status=1 ;;
            envd)            cm_uninstall_envd "$path" "$existed" || status=1 ;;
        esac
    done < <(cm_look_files)
    cm_uninstall_themes || status=1
    while IFS='|' read -r tag path; do
        [ "$(cm_original_get "dir.$tag" 1)" = 0 ] || continue
        if [ -d "$path" ] && [ ! -L "$path" ]; then rmdir -- "$path" 2>/dev/null || true; fi
    done < <(cm_look_dirs)
    # Copies from before 3.1.0 were never recorded: name them instead of guessing.
    for copy in "$HOME/.themes/${CM_THEME_PREFIX}-"*; do
        [ -d "$copy" ] && printf '%s\n' "$(printf "$(cm_t uninstall_kept_other)" "$copy")" >&2
    done
    return "$status"
}

# Folders `install` created and recorded, deepest first, only while empty.
cm_uninstall_dirs() {
    local line dir
    while IFS= read -r line; do
        [ "${line%%/*}" = dir ] || continue
        dir="${line#*/}"
        case "$dir" in "$HOME"/?*) ;; *) continue ;; esac
        if [ -d "$dir" ] && [ ! -L "$dir" ]; then rmdir -- "$dir" 2>/dev/null || true; fi
    done < <(awk -F/ '{ print NF "\t" $0 }' "$CM_INSTALLED_FILE" 2>/dev/null | sort -rn | cut -f2-)
}

# Delete what Color Mint keeps in $CM_HOME; the folder itself goes only when nothing else is in it.
cm_uninstall_home() {
    local entry left=0
    [ -d "$CM_HOME" ] && [ ! -L "$CM_HOME" ] || return 0
    case "$CM_HOME" in
        "$HOME"/?*) ;;
        *) printf '%s\n' "$(printf "$(cm_t uninstall_kept_home)" "$CM_HOME")" >&2; return 0 ;;
    esac
    while IFS= read -r -d '' entry; do
        case "${entry##*/}" in
            backups|presets|logs|original|state.conf|installed.txt|icon.png|.lock|window-redraw.*|.*.tmp.*|.*.build.*|.install-wait.*|.more-err.*|.reset-msg.*)
                rm -rf -- "$entry" || left=1 ;;
            *) left=1 ;;
        esac
    done < <(find "$CM_HOME" -mindepth 1 -maxdepth 1 -print0)
    if [ "$left" -eq 0 ] && rmdir -- "$CM_HOME"; then return 0; fi
    printf '%s\n' "$(printf "$(cm_t uninstall_kept_home)" "$CM_HOME")" >&2
}

cm_uninstall() {
    local restore=0 keep=0 yes=0 arg status=0 resp="" have_original=0 restored=0 pkgs
    for arg in "$@"; do
        case "$arg" in
            --restore-look) restore=1 ;;
            --keep-config)  keep=1 ;;
            --yes)          yes=1 ;;
            *) cm_usage_error uninstall "$(cm_t usage_install)" "$arg" ;;
        esac
    done
    [ -f "$CM_ORIGINAL_DIR/manifest.txt" ] && have_original=1
    if [ ! -e "$CM_INSTALLED_BIN" ] && [ ! -L "$CM_INSTALLED_BIN" ] && [ ! -e "$CM_LAUNCHER_FILE" ] \
        && [ ! -L "$CM_LAUNCHER_FILE" ] && [ ! -d "$CM_HOME" ]; then
        printf '%s\n' "$(cm_t uninstall_nothing)"
        return 0
    fi

    printf '%s\n' "$(cm_t uninstall_plan)" "$(cm_t uninstall_plan_menu)"
    if [ "$restore" -eq 0 ]; then
        printf '%s\n' "$(cm_t uninstall_plan_keep_look)"
    elif [ "$have_original" -eq 0 ]; then
        if cm_used_before; then
            printf '%s\n' "$(cm_t uninstall_plan_no_original_prior)"
        else
            printf '%s\n' "$(cm_t uninstall_plan_no_original)"
        fi
    else
        printf '%s\n' "$(cm_t uninstall_plan_restore)"
        [ "$(cm_original_get origin first-change)" != prior-use ] || printf '%s\n' "$(cm_t uninstall_plan_prior)"
    fi
    if [ "$keep" -eq 1 ]; then
        printf '%s\n' "$(printf "$(cm_t uninstall_plan_keep_config)" "$CM_HOME")"
    else
        printf '%s\n' "$(printf "$(cm_t uninstall_plan_drop_config)" "$CM_HOME")"
    fi

    if [ "$yes" -eq 0 ]; then
        if [ ! -t 0 ]; then
            printf '%s\n' "$(cm_t uninstall_need_yes)" >&2
            return 1
        fi
        read -rp "$(cm_t uninstall_prompt)" resp
        if [[ ! "$resp" =~ ^[sSyY]$ ]]; then
            printf '%s\n' "$(cm_t uninstall_cancelled)"
            return 1
        fi
    fi

    pkgs=$(awk -F/ '$1 == "apt" && $2 ~ /^[a-z0-9][a-z0-9.+-]*$/ { printf "%s ", $2 }' "$CM_INSTALLED_FILE" 2>/dev/null)
    pkgs="${pkgs% }"
    if [ "$restore" -eq 1 ] && [ "$have_original" -eq 1 ]; then
        cm_uninstall_restore_look || return 1
        restored=1
        cm_reload_cinnamon || true
    fi
    cm_uninstall_remove_ours "$CM_LAUNCHER_FILE" launcher || status=1
    cm_uninstall_remove_ours "$CM_INSTALLED_BIN" copy || status=1
    cm_uninstall_dirs
    if [ "$status" -eq 0 ]; then
        if [ "$restore" -eq 1 ] && [ "$have_original" -eq 1 ]; then
            rm -rf -- "$CM_ORIGINAL_DIR"; rm -f -- "$CM_INSTALLED_FILE"
        fi
        [ "$keep" -eq 0 ] || cm_log "INFO" "$(cm_t uninstall_done)"
        [ "$keep" -eq 1 ] || cm_uninstall_home || status=1
    fi
    [ -z "$pkgs" ] || printf '%s\n' "$(printf "$(cm_t uninstall_apt_note)" "$pkgs" "$pkgs")"
    if [ "$status" -ne 0 ]; then
        printf '%s\n' "$(cm_t uninstall_incomplete)" >&2
        return 1
    fi
    [ "$restored" -eq 0 ] || printf '%s\n' "$(cm_t uninstall_relogin)"
    printf '%s\n' "$(cm_t uninstall_done)"
}

# ============================================================================
# Command-line dispatcher
# ============================================================================
cm_lang_init

if cm_changes_look "$@" && ! cm_original_ensure; then
    printf '%s\n' "$(cm_t original_failed)" >&2
    exit 1
fi

case "${1:-gui}" in
    __tab)
        # Internal mode: launch an embedded tab (used by cm_main_window)
        shift
        _name="${1:-}"; _key="${2:-}"; _tabnum="${3:-}"
        export CM_TAB_KEY="$_key"
        cm_yad_detect_fields
        case "$_name" in
            themes)     cm_tab_themes     "$_key" "$_tabnum" ;;
            panel)      cm_tab_panel      "$_key" "$_tabnum" ;;
            desktop)    cm_tab_desktop    "$_key" "$_tabnum" ;;
            advanced)   cm_tab_advanced   "$_key" "$_tabnum" ;;
            terminal)   cm_tab_terminal   "$_key" "$_tabnum" ;;
            fonts)      cm_tab_fonts      "$_key" "$_tabnum" ;;
            profiles)   cm_tab_profiles   "$_key" "$_tabnum" ;;
            *) printf '%s\n' "$(printf "$(cm_t unknown_tab)" "$_name")" >&2; exit 1 ;;
        esac
        exit 0
        ;;

    __apply)
        # Internal mode: called directly by a GUI "Apply" button (see cm_fbtn_apply);
        # receives the form field values as arguments (YAD %N substitution). It re-runs itself in a
        # session of its own: stopping the tabs (language switch, exit) must not cut an apply half way.
        if [ -z "${CM_APPLY_DETACHED:-}" ] && command -v setsid >/dev/null 2>&1; then
            CM_APPLY_DETACHED=1 exec setsid --wait bash "$SCRIPT_PATH" "$@"
        fi
        shift
        _mode="${1:-}"; shift 2>/dev/null || true
        _status=0
        case "$_mode" in
            themes_apply)     cm_ui_apply_themes_apply "$@" || _status=$? ;;
            themes_import)    cm_ui_apply_themes_import "$@" || _status=$? ;;
            themes_more)      cm_ui_apply_themes_more || _status=$? ;;
            panel_apply)      cm_ui_apply_panel_apply "$@" || _status=$? ;;
            panel_reset)      cm_ui_apply_panel_reset || _status=$? ;;
            panel_backup)     cm_ui_apply_panel_backup || _status=$? ;;
            desktop_apply)    cm_ui_apply_desktop_apply "$@" || _status=$? ;;
            advanced_apply)   cm_ui_apply_advanced_apply "$@" || _status=$? ;;
            terminal_apply)   cm_ui_apply_terminal_apply "$@" || _status=$? ;;
            fonts_apply)      cm_ui_apply_fonts_apply "$@" || _status=$? ;;
            profiles_save)    cm_ui_apply_profiles_save "$@" || _status=$? ;;
            profiles_load)    cm_ui_apply_profiles_load "$@" || _status=$? ;;
            profiles_restore) cm_ui_apply_profiles_restore "$@" || _status=$? ;;
            *) printf '%s\n' "$(printf "$(cm_t unknown_apply)" "$_mode")" >&2; _status=1 ;;
        esac
        exit "$_status"
        ;;

    theme)
        shift
        case "${1:-}" in
            gtk)           cm_apply_gtk_theme "${2:-}" ;;
            icon)          cm_apply_icon_theme "${2:-}" ;;
            cursor)        cm_apply_cursor_theme "${2:-}" ;;
            cursor-size)   cm_apply_cursor_size "${2:-}" ;;
            cinnamon)      cm_apply_cinnamon_theme "${2:-}" ;;
            libadwaita)    case "${2:-status}" in
                               on|off|status) cm_apply_libadwaita "${2:-status}" ;;
                               *) cm_usage_error theme "$(cm_t usage_themes)" "libadwaita $2" ;;
                           esac ;;
            import)        cm_import_theme "${2:-}" ;;
            fetch)         cm_fetch_theme "${2:-}" ;;
            install)       cm_install_theme_package "${2:-}" ;;
            list-packages) cm_list_theme_packages ;;
            folder)        cm_open_themes_folder ;;
            list-gtk)      cm_list_gtk_themes ;;
            list-icon)     cm_list_icon_themes ;;
            list-cursor)   cm_list_cursor_themes ;;
            list-cinnamon) cm_list_cinnamon_themes ;;
            mint-y-color      ) cm_apply_mint_y_pack "${2:-}" "${3:-claro}" ;;
            list-mint-y-colors) cm_list_mint_y_colors "$([ "${2:-claro}" = "oscuro" ] && echo Mint-Y-Dark || echo Mint-Y)" ;;
            *) cm_usage_error theme "$(cm_t usage_themes)" "${1:-}" ;;
        esac
        ;;

    panel)
        shift
        case "${1:-}" in
            accent)      cm_apply_accent_color "${2:-}" ;;
            bg)          cm_apply_panel_bg_color "${2:-}" ;;
            fg)          cm_apply_panel_fg_color "${2:-}" ;;
            menu-bg)     cm_apply_menu_bg_color "${2:-}" ;;
            menu-fg)     cm_apply_menu_fg_color "${2:-}" ;;
            tooltip-bg)  cm_apply_tooltip_bg_color "${2:-}" ;;
            tooltip-fg)  cm_apply_tooltip_fg_color "${2:-}" ;;
            gtk-accent)  cm_apply_gtk_accent_color "${2:-}" ;;
            opacity)     cm_apply_panel_opacity "${2:-}" ;;
            height)      cm_apply_panel_height "${2:-}" ;;
            reset-colors) cm_reset_panel_colors ;;
            *) cm_usage_error panel "$(cm_t usage_panel)" "${1:-}" ;;
        esac
        ;;

    desktop)
        shift
        case "${1:-}" in
            panel-position)      cm_apply_panel_position "${2:-}" ;;
            window-buttons)      cm_apply_window_buttons "${2:-}" ;;
            list-button-presets) cm_list_button_presets ;;
            hotcorners)          cm_apply_hotcorners "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
            effects)              cm_apply_desktop_effects "${2:-}" ;;
            menu-effects)         cm_apply_menu_effects "${2:-}" ;;
            workspaces)           cm_apply_workspaces "${2:-}" ;;
            icons)                cm_apply_desktop_icons "${2:-}" ;;
            bg-color)             cm_apply_desktop_bg_color "${2:-}" "${3:-mantener}" ;;
            *) cm_usage_error desktop "$(cm_t usage_desktop)" "${1:-}" ;;
        esac
        ;;

    terminal)
        shift
        case "${1:-}" in
            apply_palette)   cm_apply_terminal_palette "${2:-}" ;;
            list)            cm_list_terminal_palettes ;;
            custom-colors)   cm_apply_terminal_custom_colors "${2:-}" "${3:-}" ;;
            *) cm_usage_error terminal "$(cm_t usage_terminal_section)" "${1:-}" ;;
        esac
        ;;

    fonts)
        shift
        case "${1:-}" in
            font)      cm_apply_font_name "${2:-}" ;;
            monospace) cm_apply_monospace_font "${2:-}" ;;
            rendering) cm_apply_font_rendering "${2:-}" "${3:-}" ;;
            scaling)   cm_apply_text_scaling "${2:-}" ;;
            *) cm_usage_error fonts "$(cm_t usage_fonts)" "${1:-}" ;;
        esac
        ;;

    backup)
        shift
        case "${1:-}" in
            create)  cm_backup_current ;;
            list)    cm_list_backups ;;
            restore) cm_restore_backup "${2:-}" ;;
            *) cm_usage_error backup "$(cm_t usage_backups)" "${1:-}" ;;
        esac
        ;;

    preset)
        shift
        cm_bootstrap_presets
        case "${1:-}" in
            save) cm_save_preset "${2:-}" ;;
            list) cm_list_presets ;;
            load) cm_load_preset "${2:-}" ;;
            export) cm_export_preset "${2:-}" "${3:-}" ;;
            import) cm_import_preset "${2:-}" "${3:-}" ;;
            *) cm_usage_error preset "$(cm_t usage_backups)" "${1:-}" ;;
        esac
        ;;

    install)
        cm_install
        ;;

    uninstall)
        shift
        cm_uninstall "$@"
        ;;

    gui)
        if cm_desktop_refused; then
            desktop_msg="$(printf "$(cm_t not_cinnamon_session)" "$XDG_CURRENT_DESKTOP")"
            printf '%s\n' "$desktop_msg" >&2
            # Without a UTF-8 locale yad cannot show the text (see cm_ensure_utf8_locale).
            if cm_ensure_utf8_locale && command -v yad >/dev/null 2>&1; then
                yad --error --no-markup --title="Color Mint" --text="$desktop_msg" \
                    --button="$(cm_t 'done'):0" 2>/dev/null
            elif command -v notify-send >/dev/null 2>&1; then
                notify-send -i "$(cm_icon_path)" "Color Mint" "$desktop_msg" 2>/dev/null
            fi
            exit 1
        fi
        [ -n "${XDG_CURRENT_DESKTOP:-}" ] || printf '%s\n' "$(cm_t cinnamon_env_warning)" >&2

        cm_check_dependencies yad dconf gsettings gdbus

        if ! cm_ensure_utf8_locale; then
            printf '%s\n' "$(printf "$(cm_t gui_locale_missing)")" >&2
            exit 1
        fi

        if ! cm_gui_path_is_safe; then
            printf '%s\n' "$(printf "$(cm_t gui_path_unsafe)" "$SCRIPT_PATH")" >&2
            yad --error --no-markup --text="$(printf "$(cm_t gui_path_unsafe)" "$SCRIPT_PATH")" \
                --button="$(cm_t 'done'):0" 2>/dev/null
            exit 1
        fi

        cm_log "INFO" "$(cm_t app_started)"
        cm_main_window
        cm_log "INFO" "$(cm_t app_closed)"
        ;;

    l)
        cm_lang_toggle
        if [ "$CM_LANG" = "es" ]; then printf '%s\n' "$(cm_t lang_switched_es)"; else printf '%s\n' "$(cm_t lang_switched_en)"; fi
        ;;

    -h|--help)
        cm_print_usage
        ;;

    *)
        printf '%s\n' "$(printf "$(cm_t unknown_command)" "${1:-}")" >&2
        cm_print_usage
        exit 1
        ;;
esac

# ---- BEGIN EMBEDDED ICON (128x128 PNG, base64; made from assets/icon.png) ----
# iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAMAAAD04JH5AAABwlBMVEX///8HGysHGikHGyoKIi0N
# JjQQKzoTLkAKHzAHGioWOkcYOUoaPU0bP08cQVEdRFMdR1MiTVkZQ0skVF0mWWATMjs2WmNkfYF4
# lZmDmpyDnaGFoqZxiZBYc3c2TVWnvdDZ6efp+fXz/PqkuLkzSE602NHCztG2xsUlO0SUpqvi8e7e
# 8O0SKS5MaGlde4JMeH1pkZSnyMVHXmN1m6QqZ2glRErJ19c3ZWhAUVlWbHOIr66Mbm2TlmF4h2Ez
# cW5HpZU2eHVWZ2zRlmrmoG1femD4zmHbnm9Cmo1l5r1Js5x6ampui5BphoweUlMPMTlFa3Gu1c64
# 5Nu76uDJ7eR5p6UucnA2joJWyrNa17s8lYVSxatbqZ1i2Lxnxa5OkImer7SO0syY59SMwbWm9NuV
# +duZure4+ONp28Foz7lx8chFgntj8cNMyKc0hXhNuaRT0axh7cA5rpEiiXVBootc47kvkXxEv54W
# UE4YaV85WF1iuah56MyO9NeK59BZs6OL48983NKU2edZmbpqpcOOvOiRu/FYhoZZo7pd1cCUtZDX
# vpPvu4x5sJtjenvJ8ejVyK32u4Hjx5vk4dPs3sbx48rG49yfYvOIAAAAAXRSTlMAQObYZgAAC29J
# REFUeNrFm4t/09YZhl1FkoMcHPsoCk6D3dgJBSfOrcTxkm6EdltpttipE2gUCDR0sGQEVkbLOljX
# dqNhWzsYXcv/u3PXOdLRxUGUF35x7Nh+H33fd27SUSbj6TWtTzc8mT5lI8XfZojqR9Jk9WkZpY5J
# 7kaMuYUFH4IIAQItoL5jQft+XfI3Qu2JdY7IYgqNgq4rETQfQl9Sf+bsycpFI+jqIGh9Pv/+0Pir
# 3QeQJBA5E3FZkAjQ8fer/YWDZ87EWxZLh4DQA0F4/AMHj8yOH8/7xSAYgw+hPzoLqP70SH/uTr0H
# ZXEIEocggR5GQCoR/1UVf8keuuePE+vCYKFQKBYLWCIFQAwkCHIlQAJdmQUSALV/wB67I+ci/kFV
# KHggFCEnIPAk6KEh6Ivyxw0eBpe5C84+EQYPwaIIjEDXw6og0l84eM/btu0hLvKCxCAlgvdHYTnQ
# xAKU/enhY3tuPhSUjSQiAJYHJwFBnwrAyz7xL7BDH1KLI7BiAAMegckJlDnoD/UPHn8YgG37gpAH
# IAhgKGOQUQTA85cDQLKNnPBP/Dv8lZWAkAQgAXj9ga4C8PtLgx6kGACANQFPxUKxEBDpEAB1R/aO
# 3CUra0BX+2ezA8MnSiOvU40mFfvACFEJ6WS5YmIbJUBIAHLlN8aqtZRUHRsvm5qyCAMAxN6pjKfm
# ThnGJ7RoALEAneFTtdT1ZkUZg4wiAc7EaQydojDBGa0/HEAqgDrxr1Unp1LQZLVGCOoNPQaAFsD0
# FDn+06WZ2RQ0MzdPYjD5lhYNkBUCUK1Onl2wU9JQaQoT1PUEAFa2uYgBRodS1Fkcg8UzWqApZGR/
# 2IE5wzAD1dpiK02A1in4lbXJn8GG4GsKMgDqfJ2lKgJYhgPP228Pt37+i6FzK+dfFMAeRQDVdzTd
# Pypm/P4UoFqyh95695fv/OrX77UuvL/6wgBzVQZgqFJAAPAAKAAM/Sa9CEQDsADkBIDf2mnWgL3m
# ARhhABZdYRGAtXaaAMUyAcCDoq4CIAFAiwsKcCKbYghsSwSQCDwAMvcAHMCwiqkdv2UQgCU1AMsA
# mvuAnEVTAF8BhVQE4OSIATT8U7MMDwACyMMJFYwWBrBS1YwIYMgAvAQH0NzvJQOQOaIQggwdB1EA
# 8NzzZQDkOIDR6ZgqgCwFgDPblxsBo2OGARB/VDEvIQI5DkCXCT4AVgEIIJ8OQGV2Zr0YiEDZMB1f
# CBiANQAG0wMAax90N7rzs0EAx8EEQQAWgFQAcnPdDajN7qwfwHQQgQQglSBccKUB0Dq1QTRfVAKY
# QhEgAAcBALIGLQymADC3SQG8EEQC4BoE9PRPGgAXGcDmmg+g4/hzkOHjQIoAJQawMRMAwGtmGcDh
# JZAWwHqXBuCDYR+AowLANQhkgFrPAJc+BPz3/DINwVwumAJ81kABQM+DYIBqGEAu3H/L3R7kz+zl
# 7ubmZvdsU2iGKKwwAuS8hQjgKAFqvUVg4bLruisF/nxw9uxyaR0IHVGNAVhyFWZoCdAaJP0AIqgX
# e/WHBG2hM0SnjjhB8XW82iwjMz9AVgJo4whAgjdH1otAuCoBNbgAckF5/q67atOZbbO1fmXn6rX1
# 1iB8BorrpdN4tV928MpDAqAZ4BGgANXx+kf10klJy7sXT6pU2r3OtEs+Uhpd/vj6725c/3gZfUcJ
# ftVHVQLgxAGwCFTXKuVSXdI87Nnm60Hd7G546t6Er4yPj2/8nqg7P16vj8xUTggA2TCAggSA0lis
# VNDyGv2sXNvZ29vbuUaeY+Gld+X8/p6o/dlia7a58gemW7PDqBRmkgDgCOQ9AH87Q9q65Ht9iOWf
# 6fKlFjBXD7Bu3z6402zRfoDXgBIgHwEg1ZmPYOiPrl87twzrE2R/90/3bh98araK0QBODAAu9AXv
# OCUChb+7d85pfwb9P9u+BzlWO/awD0DVD7AUFAp+ANyqbNFHIFD5u/sLwHYPDj65t40wbjs4BzOh
# rSAOAHcjsg8nsFX+7r4NwP27f763ehf6v3/HFAE6imYYD9Be9dfZQoS/u98CoH0fph+VwbZjQIBc
# BIA3GreLbE4oAxRWAh6YIMTf3bsFwOd/wWV48Cn0emDHA1goAm1o3w4CgAsKE0gQ5u/uXEFn7Ldh
# Fd6+b8HpxvpgHAAZDcllgAAA2Fa6XL606oZp/xwEaG/ft/HlClvsB1QA3nygrYgA+NDtWTtXbYAF
# ARrN9bwEACcEfgBehW0oAQAPdHfcI2jvYYsQdMwmXR8JAA6ZkIgAWdoMoL8PgHbAPcdg/1qrCD6H
# o0Jr0BIBTG9WLAOQIiAAS14KjuiPgrB/9eHDqzvuJcvyRUAxLXdEACAALFx2X1Rb5xMBZOloUJAA
# hl7cHxLcAeoUCItT3BkOAD9AaEPvUXi+Hgng5QCWAGBFWFh1U9K2NyFp+GuQnKTy2oEHUFpxU9OF
# AgVYUgIYJAQAn6HgALsxDa0ngpVCAEALAKDOEF14pTVwPfIb//rF3x5eYfoyAcEcATA6wTMkmCBL
# QwABnAQAe1/cuHFxiamcoLfY5QCmlAFy7Zh3x7gDTwiw/yVXgiR8xQDoOSoZgIcAykoC4H79969g
# FWxtuUm7SgqgB88T6rpQhhhgekoEePgPhR59c3h4tsz0eCspwLTe8AVAo3tITDRbxDmwrInFmgCw
# 9U+FHh0eHj56zHQtIUBtbIKdLQ8C8CqAvdZ4LS4F/9p945u9nhoiBhhvKE7XazwEjMApkxTsYF39
# t0rffvftf7xmuBMrkoInenArBwTABEIInCZaS089Jfrvuwq99+zZs+8XuTafxgpduz19Rg9uJWEA
# PARozjY95l27n/yfQj989+zZj8LuhERX8MemyYYZPQDACNjGFccpj0lfii/lS/rx+x963UEw9UTl
# zwB4EghBZ2kx3Q0M1drikh4OwEOQZSHoVOrRe1iqkz5Fv3usPuH5KwA0fwicjlNZq58O16If4HnE
# m+snJhps02Tg6jl99DoDjtAgEzilGk/8ARhpNELfjNz1kB1lHMBrCRwBqYPk+0L4ih4E0Bvonfi/
# rAYU+qnezcUAhB7Z8jGgtQR7xh5VEVAHjHOY6i11HEAmIKMCWx4CC/2jgxXJjx9gcqTjyPQeP8Ew
# G8rtbCIAKUSHAcjCm1bRI+4slQC+jxEIhtEx1XsKPQAlATLNy5eQ0UuWowQIUAuBMEP28wkAlIBE
# kkyP8sqL0XDi6pwI1AAJQJ5FSkDAAQjbUykCSE2BfF7cRYgWbmTtAgFuhQDgP8MHAYBdJlLuZ5QB
# 5MaIAQgBOnPQZgBAlQIIoEiB6K/rCQCCBEA6+kH6rY4ZBMAnPxQ1EO3vB+AEQhqEnQgA7yWtTEw0
# 13z73CZHm80JfPq4qPQP2VQbBOAztGAhwNqanT9FhS7JSHrO/jK/Biyp/iL9gwBea8wKzZGU1nr3
# 6WYCPZa6oqj4KwE8AgkBHVJpM5Fuij1hjL8KgBAQBEtEsEafJgRwmD3r/0L9lQAiQVYYGpxyIv+n
# c3wIMMP6vxgABQLp10vdeP/ny002LppGrH8YgKYrEOCvD6Zj9cChA7NpGlHlHwMgEXjzABNPbqKF
# ph+djmkaSfzDARgBROj4phcN/1ynYQhcRqPBN7Trsf4RAKwQ8E6n4ARHMfHq0P2pDT79i7WPBiBR
# 0GUGz1JB1JBuMktgHweg6SICTEZHNUn1OBoN0T6JfxyAEAQBQulvSveTJLRPACAj0C3gAgLMDTE3
# jSPYo5tctB4RIIR0N15HvrmvN3utL5Pwjbruo1BJ79We3GjUGwKCUHDoxhHMoV7LJMpBAEKIh/iC
# 1qvQrV7HevxMaBesHUH4fr+jfBDbYdejGYu3+/UcghRFb73te1X+3k2nr9j/FRHINx6/Yv9XUImK
# u89/wigobn6nt///JO7S7f//B2cMO7RVOto4AAAAAElFTkSuQmCC
# ---- END EMBEDDED ICON ----
