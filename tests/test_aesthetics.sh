#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sandbox.sh
. "$ROOT/tests/lib/sandbox.sh"
SCRIPT="$ROOT/script/color-mint.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/color-mint-aesthetic.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || fail 'python3 required for aesthetic audit'
# ImageMagick 7 ships "magick"; Linux Mint 22.3 and ubuntu-24.04 ship ImageMagick 6 ("convert").
if command -v magick >/dev/null 2>&1; then
    IM_BIN=magick
elif command -v convert >/dev/null 2>&1; then
    IM_BIN=convert
else
    printf 'BLOCKED: ImageMagick (magick or convert) is required for the aesthetic audit\n' >&2
    exit 2
fi
export IM_BIN

python3 - "$ROOT" "$SCRIPT" "$TMP" <<'PY'
from pathlib import Path
import os, re, subprocess, sys
im = os.environ['IM_BIN']
root = Path(sys.argv[1]); script = Path(sys.argv[2]); out = Path(sys.argv[3])
text = script.read_text(encoding='utf-8')
marker = 'declare -A CM_TEXT_ES='
end_marker = 'cm_apply_language_labels()'
start = text.index(marker); end = text.index(end_marker)
pre = text[start:end]
keys = '''gui_tab_themes gui_tab_panel gui_tab_desktop gui_tab_advanced gui_tab_terminal gui_tab_fonts gui_tab_profiles ui_themes_text ui_themes_easy ui_themes_manual ui_cursor_always ui_import_theme ui_panel_text ui_panel_size ui_desktop_text ui_desktop_panel_buttons ui_effects_workspaces ui_desktop_bg ui_advanced_text ui_hotcorners ui_custom_buttons ui_terminal_text ui_terminal_custom ui_color_hint ui_fonts_text ui_typography ui_rendering ui_font_hint ui_scaling ui_profiles_text ui_save_preset ui_load_preset ui_restore_backup ui_panel_reset_confirm ui_theme_import_error ui_cursor_size ui_button_values apply_themes import_theme apply_panel reset_colors restore_last_backup apply_desktop apply_advanced apply_terminal apply_fonts save load restore lang_button exit'''.split()
for lang in ('es', 'en'):
    body = out / f'body-{lang}.sh'
    body.write_text(pre + f'CM_LANG="{lang}"\n', encoding='utf-8')
    entries = []
    for key in keys:
        cmd = f'source "{body}"; printf "%s" "${{CM_TEXT_{lang.upper()}[{key}]:-}}"'
        value = subprocess.check_output(['bash', '-c', cmd], text=True)
        clean = re.sub(r'</?(?:b|span)(?: [^>]*)?>', '', value)
        entries.append((key, clean))
    max_width = 0
    max_key = ''
    for key, value in entries:
        for line in value.splitlines() or ['']:
            safe = ''.join(c if ord(c) < 0x2500 else ' ' for c in line).replace('%', '%%')
            width = int(subprocess.check_output([
                im, '-background', 'none', '-fill', 'black', '-font', 'DejaVu-Sans',
                '-pointsize', '11', f'label:{safe}', '-format', '%w', 'info:'
            ], text=True, stderr=subprocess.DEVNULL).strip())
            if width > max_width:
                max_width, max_key = width, key
    # The tab already names the page: the headline inside must say something else and carry no icon of its own.
    values = dict(entries)
    for tab in ('themes', 'panel', 'desktop', 'advanced', 'terminal', 'fonts', 'profiles'):
        label = re.sub(r'^[^\w]+', '', values[f'gui_tab_{tab}']).strip().lower()
        first = values[f'ui_{tab}_text'].replace('\\n', '\n').splitlines()[0].strip()
        if not first or not first[0].isalpha():
            raise SystemExit(f'{lang}: the headline inside the {tab} tab must start with a letter, not an icon: {first!r}')
        if first.lower() == label:
            raise SystemExit(f'{lang}: the headline inside the {tab} tab repeats the tab label: {first!r}')
    if max_width > 880:
        raise SystemExit(f'{lang} GUI text exceeds 880px: {max_width}px ({max_key})')
    # Rendered with plain ImageMagick drawing: the SVG coder depends on an optional delegate (rsvg-convert).
    rows = []
    y = 28
    for key, value in entries:
        for line in value.splitlines() or ['']:
            safe = ''.join(c if ord(c) < 0x2500 else ' ' for c in line).replace('%', '%%')
            rows.append((y, f'{key}  {safe}'))
            y += 24
        y += 5
    png = out / f'ui-{lang}.png'
    cmd = [im, '-size', f'950x{max(200, y + 20)}', 'xc:white', '-font', 'DejaVu-Sans', '-pointsize', '14', '-fill', 'black']
    for row_y, row_text in rows:
        cmd += ['-annotate', f'+20+{row_y}', row_text]
    subprocess.check_call(cmd + [str(png)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not png.is_file() or png.stat().st_size == 0:
        raise SystemExit(f'missing rendered contact sheet: {png}')
print('PASS: translated GUI text fits the 950px design budget and renders in both languages')
PY
pass 'aesthetic text and rendering audit'

python3 - "$SCRIPT" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text(encoding='utf-8')
for lang in ('ES', 'EN'):
    if f'declare -A CM_TEXT_{lang}=' not in text:
        raise SystemExit(f'missing text table: {lang}')
print('PASS: both translation tables are explicitly defined')
PY

# Quantified aesthetics: tests/lib/aesthetic_score.py scores 13 metrics (0-100). The guarded metrics
# must keep their full score and the total may not fall under tests/aesthetic-score.baseline.
python3 "$ROOT/tests/lib/aesthetic_score.py" "$ROOT" --check "$ROOT/tests/aesthetic-score.baseline" \
    || fail 'aesthetic scorecard regressed'
pass 'aesthetic scorecard at or above its baseline'
