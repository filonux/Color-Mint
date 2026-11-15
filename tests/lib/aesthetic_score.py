#!/usr/bin/env python3
"""Aesthetic scorecard for Color Mint: turns "looks good" into numbers a test can ratchet.

Usage: aesthetic_score.py <repo-root> [--json FILE] [--check BASELINE_FILE]
Needs bash and ImageMagick ($IM_BIN, "magick" or "convert"). Prints one table and a 0-100 score.
With --check, exits 1 when a guarded metric drops or the total falls under the baseline file
(an integer: score x 10). Raise the baseline deliberately when an improvement lands.
"""
import base64
import colorsys
import json
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
SCRIPT = ROOT / 'script' / 'color-mint.sh'
IM = os.environ.get('IM_BIN', 'convert')
TEXT = SCRIPT.read_text(encoding='utf-8')
SCREENS = [(1366, 768), (1280, 720), (1440, 900), (1920, 1080)]
PANEL, TITLE_BAR = 40, 36  # pixels reserved by the Cinnamon panel and the window title bar


def clamp(value):
    return max(0.0, min(1.0, value))


def bash(code, *args, env_extra=None):
    """Run bash code with the program body sourced in a throw-away HOME."""
    with tempfile.TemporaryDirectory() as tmp:
        env = {'PATH': os.environ['PATH'], 'HOME': tmp, 'CM_HOME': tmp + '/state', 'LC_ALL': 'C.UTF-8',
               'CM_LANG_OVERRIDE': 'en', 'TERM': 'dumb'}
        env.update(env_extra or {})
        body = tmp + '/body.sh'
        with open(body, 'w', encoding='utf-8') as handle:
            handle.write(TEXT.split('# Command-line dispatcher', 1)[0])
        result = subprocess.run(['bash', '-c', 'source "$1"; shift; ' + code, 'bash', body, *args],
                                env=env, capture_output=True, text=True, check=True)
        return result.stdout


def contrast(a, b):
    def lin(c):
        c /= 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    def lum(h):
        h = h.lstrip('#')
        if len(h) == 3:
            h = ''.join(c * 2 for c in h)
        r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)

    hi, lo = sorted((lum(a), lum(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


# ---------------------------------------------------------------- data collection
labels = {'es': {}, 'en': {}}
dump = bash('for l in ES EN; do declare -n t=CM_TEXT_$l; for k in "${!t[@]}"; do '
            'printf "%s\\t%s\\t%s\\n" "$l" "$k" "$(printf %s "${t[$k]}" | base64 -w0)"; done; done')
for row in dump.splitlines():
    lang, key, payload = row.split('\t')
    labels[lang.lower()][key] = base64.b64decode(payload).decode('utf-8')
gui_keys = sorted(k for k in labels['en'] if k.startswith('ui_'))


def plain(value):
    return value.replace('\\n', '\n')


def ending(value):
    last = plain(value).rstrip()[-1:]
    return last if last in '.?:!' else '-'


def pixel_widths():
    """Rendered width (px, DejaVu Sans 11pt) of every line of every GUI text, per language."""
    out = {}
    for lang in ('es', 'en'):
        widths = []
        for key in gui_keys:
            for line in plain(labels[lang][key]).splitlines() or ['']:
                safe = ''.join(c if ord(c) < 0x2500 else ' ' for c in re.sub(r'<[^>]+>', '', line)).replace('%', '%%')
                if not safe.strip():
                    continue
                shown = subprocess.check_output(
                    [IM, '-background', 'none', '-fill', 'black', '-font', 'DejaVu-Sans', '-pointsize', '11',
                     'label:' + safe.lstrip('@'), '-format', '%w', 'info:'], text=True)
                widths.append(int(shown))
        out[lang] = widths
    return out


def accent_samples():
    samples = []
    for hue in range(0, 360, 30):
        for sat in (0.45, 0.70, 0.95):
            for light in (0.35, 0.50, 0.65):
                samples.append('#%02x%02x%02x' % tuple(round(c * 255) for c in colorsys.hls_to_rgb(hue / 360, light, sat)))
    return samples


def accent_choices(samples):
    if 'cm_accent_fg()' in TEXT:
        with tempfile.NamedTemporaryFile('w', delete=False) as handle:
            handle.write('\n'.join(samples) + '\n')
        try:
            out = bash('while read -r h; do cm_accent_fg "$h"; echo; done < "$1"', handle.name)
        finally:
            os.unlink(handle.name)
        return out.split()
    # Older versions inline a luma threshold; score that rule so history stays comparable.
    choices = []
    for sample in samples:
        r, g, b = (int(sample[i:i + 2], 16) for i in (1, 3, 5))
        choices.append('#000000' if (r * 299 + g * 587 + b * 114) // 1000 > 150 else '#ffffff')
    return choices


def tab_bodies():
    return {name: body for name, body in re.findall(r'^(cm_tab_[a-z_]+)\(\) \{\n(.*?)\n\}\n', TEXT, re.S | re.M)
            if name not in ('cm_tab_alive', 'cm_tab_redraw')}


def screen_fit():
    """Share of common screens where the default window fits, using the program's own sizing."""
    fits = []
    for width, height in SCREENS:
        if 'cm_gui_geometry()' in TEXT:
            xrandr = '#!/bin/sh\necho "Screen 0: current %d x %d"\necho "screen connected primary %dx%d+0+0"\n' % (
                width, height, width, height)
            with tempfile.TemporaryDirectory() as tmp:
                fake = Path(tmp) / 'xrandr'
                fake.write_text(xrandr)
                fake.chmod(0o755)
                out = bash('cm_gui_geometry', env_extra={'PATH': tmp + ':' + os.environ['PATH']})
            win_w, win_h = (int(v) for v in out.split())
        else:
            match = re.search(r'--width=(\d+) --height=(\d+)', TEXT)
            win_w, win_h = int(match.group(1)), int(match.group(2))
        fits.append(win_w <= width and win_h + TITLE_BAR + PANEL <= height)
    return sum(fits) / len(fits), fits


# ---------------------------------------------------------------- metrics
metrics = []


def add(group, ident, name, value, shown, target, points, maximum, guard=False):
    metrics.append({'group': group, 'id': ident, 'name': name, 'value': shown, 'target': target,
                    'points': round(points, 2), 'max': maximum, 'guard': guard})


widths = pixel_widths()
all_widths = widths['es'] + widths['en']
widest = max(all_widths)
add('Text', 'T1', 'widest GUI text line (px)', widest, f'{widest}', '<= 880', 8 if widest <= 880 else 0, 8, True)
comfortable = sum(w <= 640 for w in all_widths) / len(all_widths)
add('Text', 'T2', 'GUI lines <= 640 px', comfortable, f'{comfortable:.1%}', '>= 98%',
    6 * clamp((comfortable - 0.70) / 0.28), 6)
chars = {lang: sum(len(plain(labels[lang][k])) for k in gui_keys) for lang in labels}
ratio = chars['es'] / chars['en']
add('Text', 'T3', 'ES/EN GUI length ratio', ratio, f'{ratio:.3f}', '<= 1.30', 6 * clamp((1.60 - ratio) / 0.30), 6)
violations = 0
for lang in labels:
    for key, value in labels[lang].items():
        text = plain(value).strip()
        for match in re.finditer(r' {2,}', text):
            before = text[:match.start()]
            after = text[match.end():match.end() + 1]
            deliberate = (before[-1:] in ('\u00b7', '\n') or after == '\u00b7'
                          or ord(before[-1:] or ' ') >= 0x2000)  # icon, separator or indentation
            if not deliberate:
                violations += 1
        if ('...' in value) and ('\u2026' in value):
            violations += 1
# GTK shows nothing for a label whose markup does not parse (an unquoted attribute, a bare ampersand).
for lang in labels:
    for key in sorted(k for k in labels[lang] if k.startswith(('ui_', 'gui_'))):
        try:
            ET.fromstring('<r>' + plain(labels[lang][key]) + '</r>')
        except ET.ParseError:
            violations += 1
mixed = sum('...' in v for v in labels['en'].values()) and sum('\u2026' in v for v in labels['en'].values())
violations += 1 if mixed else 0
for key in labels['en']:
    violations += ending(labels['es'][key]) != ending(labels['en'][key])
add('Text', 'T4', 'typographic inconsistencies', violations, f'{violations}', '0', 10 * clamp(1 - violations / 10), 10, True)

bodies = tab_bodies()
controls = {}
for name, body in bodies.items():
    fields = re.findall(r'--field=("[^"]*"|\S+)', body)
    controls[name] = sum(1 for f in fields if ':LBL' not in f and ':H' not in f)
most = max(controls.values())
add('Layout', 'L1', 'most controls on one tab', most, f'{most}', '<= 12', 10 * clamp(1 - max(0, most - 12) / 6), 10, True)
share, fits = screen_fit()
add('Layout', 'L2', 'screens where the window fits', share, f'{sum(fits)}/{len(fits)} (1366x768 {"ok" if fits[0] else "cut"})',
    'all', 10 * share, 10, True)
scrolled = sum('--form --scroll' in body for body in bodies.values()) / len(bodies)
intro = sum(bool(re.search(r'--field="[^"]*:LBL"', body.split('--no-buttons')[0])) for body in bodies.values()) / len(bodies)
add('Layout', 'L3', 'tabs with intro text and scroll', min(scrolled, intro), f'intro {intro:.0%}, scroll {scrolled:.0%}',
    '100%', 5 * min(scrolled, intro), 5)

samples = accent_samples()
choices = accent_choices(samples)
passing = sum(contrast(s, c) >= 4.5 for s, c in zip(samples, choices)) / len(samples)
add('Color', 'C1', 'accent text with AA contrast', passing, f'{passing:.1%}', '100%', 10 * passing, 10, True)
palettes = bash('for k in "${!CM_PALETTES[@]}"; do printf "%s\\t%s\\n" "$k" "${CM_PALETTES[$k]}"; done').splitlines()
readable = [contrast(row.split('\t')[1].split('|')[2], row.split('\t')[1].split('|')[1]) >= 4.5 for row in palettes]
add('Color', 'C2', 'terminal palettes with AA text', sum(readable) / len(readable),
    f'{sum(readable)}/{len(readable)}', 'all (Solarized Light is 4.13 by design)', 10 * sum(readable) / len(readable), 10)
# yad 0.40.0 (the Ubuntu 24.04 / Linux Mint 22.x package) has no --css option and ignores it, while newer
# yad applies it: a stylesheet makes the GUI look different per distro. The GUI follows the system theme.
styled = '--css' in TEXT or 'cm_write_css()' in TEXT
add('Color', 'C3', 'GUI looks the same on every yad', 0 if styled else 1,
    ('stylesheet depends on the yad version' if styled else 'follows the system theme'), 'follows theme',
    0 if styled else 5, 5, True)

icon = ROOT / 'assets' / 'icon.png'
box = subprocess.check_output([IM, str(icon), '-alpha', 'extract', '-threshold', '1%', '-format', '%@ %wx%h', 'info:'], text=True).split()
trim, canvas = box[0], box[1]
trim_w, trim_h = (int(v) for v in re.match(r'(\d+)x(\d+)', trim).groups())
canvas_w, canvas_h = (int(v) for v in canvas.split('x'))
coverage = (trim_w * trim_h) / (canvas_w * canvas_h)
add('Identity', 'I1', 'project icon canvas coverage', coverage, f'{coverage:.1%}', '>= 98%', 10 * clamp((coverage - 0.80) / 0.18), 10, True)

helper_widths = []
for lang in ('en', 'es'):
    with tempfile.TemporaryDirectory() as tmp:
        out = subprocess.run(['bash', str(SCRIPT), '--help'], capture_output=True, text=True, check=True,
                             env={'PATH': os.environ['PATH'], 'HOME': tmp, 'CM_HOME': tmp + '/s', 'LC_ALL': 'C.UTF-8',
                                  'CM_LANG_OVERRIDE': lang}).stdout
    helper_widths += [len(line) for line in out.splitlines()]
narrow = sum(w <= 80 for w in helper_widths) / len(helper_widths)
add('CLI', 'K1', '--help lines within 80 columns', narrow, f'{narrow:.1%} (widest {max(helper_widths)})', '100%', 5 * narrow, 5, True)

def severity(value):
    head = plain(value).lstrip()[:12].upper()
    return 'error' if head.startswith('ERROR') else 'warn' if head.startswith(('WARNING', 'ADVERTENCIA')) else 'none'

pairs_ok = sum(severity(labels['es'][k]) == severity(labels['en'][k]) for k in labels['en']) / len(labels['en'])
add('CLI', 'K2', 'ES/EN severity prefixes match', pairs_ok, f'{pairs_ok:.1%}', '100%', 5 * pairs_ok, 5, True)

# ---------------------------------------------------------------- report
total = sum(m['points'] for m in metrics)
maximum = sum(m['max'] for m in metrics)
print('Color Mint aesthetic scorecard')
print('%-9s %-3s %-36s %-30s %-12s %s' % ('Group', 'ID', 'Metric', 'Value', 'Target', 'Points'))
for m in metrics:
    print('%-9s %-3s %-36s %-30s %-12s %5.2f/%d' % (m['group'], m['id'], m['name'], m['value'], m['target'], m['points'], m['max']))
print('TOTAL %.1f / %d' % (total, maximum))

if '--json' in sys.argv:
    Path(sys.argv[sys.argv.index('--json') + 1]).write_text(json.dumps({'total': round(total, 2), 'metrics': metrics}, indent=2))
if '--check' in sys.argv:
    baseline = int(Path(sys.argv[sys.argv.index('--check') + 1]).read_text().split()[0])
    failed = [m['id'] for m in metrics if m['guard'] and m['points'] < m['max']]
    if failed:
        print('FAIL: guarded metrics below full score: ' + ', '.join(failed))
        sys.exit(1)
    if round(total * 10) < baseline:
        print('FAIL: score %.1f is under the baseline %.1f' % (total, baseline / 10))
        sys.exit(1)
