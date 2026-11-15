#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sandbox.sh
. "$ROOT/tests/lib/sandbox.sh"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }
command -v identify >/dev/null 2>&1 || fail 'ImageMagick identify required'

for n in 3 4 5; do
    file="$ROOT/assets/icon${n}.png"
    [ -f "$file" ] || fail "missing icon${n}.png"
    read -r format width height channels <<< "$(identify -format '%m %w %h %[channels]' "$file")"
    [ "$format" = PNG ] || fail "icon${n} is not PNG"
    [ "$width" = 1024 ] && [ "$height" = 1024 ] || fail "icon${n} dimensions ${width}x${height}"
    case "$channels" in
        *a*) ;;
        *) fail "icon${n} lacks alpha channel" ;;
    esac
done

python3 - "$ROOT/assets/icon3.png" "$ROOT/assets/icon4.png" "$ROOT/assets/icon5.png" <<'PY'
from pathlib import Path
import sys, hashlib
hashes = [hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in sys.argv[1:]]
if len(set(hashes)) != len(hashes):
    raise SystemExit('new icons are byte-identical')
PY
pass 'icon3/icon4/icon5 are distinct RGBA PNGs at 1024x1024'

# The icon chosen for the project is one of the three new designs, byte for byte, at full size.
chosen=""
for n in 3 4 5; do
    if cmp -s "$ROOT/assets/icon.png" "$ROOT/assets/icon${n}.png"; then chosen="icon${n}.png"; fi
done
[ -n "$chosen" ] || fail 'assets/icon.png must be one of the new icon3/icon4/icon5 designs'
pass "assets/icon.png is the chosen new design ($chosen)"

# The embedded copy (base64 block at the end of the script) is a 128x128 PNG that matches that design.
SCRIPT="$ROOT/script/color-mint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sed -n '/^# ---- BEGIN EMBEDDED ICON/,/^# ---- END EMBEDDED ICON/{//!p;}' "$SCRIPT" | sed 's/^# //' | base64 -d > "$TMP/embedded.png" \
    || fail 'embedded icon is not valid base64'
[ "$(identify -format '%m %w %h' "$TMP/embedded.png")" = 'PNG 128 128' ] || fail 'embedded icon is not a 128x128 PNG'
if command -v compare >/dev/null 2>&1; then COMPARE=(compare); else COMPARE=(magick compare); fi
if command -v convert >/dev/null 2>&1; then RESIZE=(convert); else RESIZE=(magick); fi
"${RESIZE[@]}" "$ROOT/assets/icon.png" -resize 128x128 "$TMP/reference.png"
difference="$("${COMPARE[@]}" -metric RMSE "$TMP/embedded.png" "$TMP/reference.png" null: 2>&1 || true)"
difference="${difference##*(}"; difference="${difference%)*}"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 0.03 else 1)' "$difference" \
    || fail "embedded icon differs from assets/icon.png (RMSE $difference)"
pass 'embedded icon is a 128x128 copy of assets/icon.png'

# Installing it: atomic, mode 644, rewritten only when it differs, repaired when damaged, no temporary files.
BODY="$TMP/body.sh"
awk '/^# Command-line dispatcher/{exit} {print}' "$SCRIPT" > "$BODY"
mkdir -p "$TMP/bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${CM_TEST_NOTIFY_LOG:?}"' > "$TMP/bin/notify-send"
chmod 755 "$TMP/bin/notify-send"
: > "$TMP/notify.log"
PATH="$TMP/bin:$PATH" CM_TEST_NOTIFY_LOG="$TMP/notify.log" HOME="$TMP/home" CM_HOME="$TMP/state" CM_LANG_OVERRIDE=en SCRIPT="$SCRIPT" bash -c '
    source "$1"
    SCRIPT_PATH="$SCRIPT"
    [ "$(cm_icon_path)" = preferences-desktop-theme ] || exit 1
    cm_notify "Title" "Body"
    cm_icon_install || exit 2
    [ "$(cm_icon_path)" = "$CM_HOME/icon.png" ] || exit 3
    [ "$(stat -c %a "$CM_ICON_FILE")" = 644 ] || exit 4
    cmp -s "$CM_ICON_FILE" "$2" || exit 5
    touch -d 2001-01-01 "$CM_ICON_FILE"
    cm_icon_install || exit 6
    [ "$(stat -c %Y "$CM_ICON_FILE")" = "$(date -d 2001-01-01 +%s)" ] || exit 7
    printf garbage > "$CM_ICON_FILE"
    cm_icon_install || exit 8
    cmp -s "$CM_ICON_FILE" "$2" || exit 9
    cm_notify "Title" "Body"
    must_print_nothing find "$CM_HOME" -name ".*tmp*" -print -quit
' bash "$BODY" "$TMP/embedded.png" || fail "embedded icon installer (exit $?)"
grep -q -- '-i preferences-desktop-theme Title Body' "$TMP/notify.log" || fail 'notifications must fall back to the theme icon'
grep -q -- "-i $TMP/state/icon.png Title Body" "$TMP/notify.log" || fail 'notifications must use the installed program icon'
pass 'embedded icon installs atomically, idempotently and is used by notifications'
