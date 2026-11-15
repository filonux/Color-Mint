#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

mapfile -t shell_files < <(find "$ROOT" -type f -name '*.sh' -print | sort)
[ "${#shell_files[@]}" -gt 0 ] || fail 'no shell scripts found'

for file in "${shell_files[@]}"; do
    bash -n "$file" || fail "bash -n: $file"
    python3 - "$file" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
if '\r' in text:
    raise SystemExit(f'CR character: {p}')
if any(line.rstrip() != line for line in text.splitlines()):
    raise SystemExit(f'trailing whitespace: {p}')
if not p.read_bytes().endswith(b'\n'):
    raise SystemExit(f'no final newline: {p}')
PY
done
pass 'bash syntax and style hygiene'

SHELLCHECK_BIN="${SHELLCHECK_BIN:-shellcheck}"
SHELLCHECK_VERSION='0.11.0'
if ! command -v "$SHELLCHECK_BIN" >/dev/null 2>&1; then
    printf 'BLOCKED: ShellCheck %s is not installed; set SHELLCHECK_BIN to an exact %s binary for the static-analysis portion.\n' "$SHELLCHECK_VERSION" "$SHELLCHECK_VERSION" >&2
    exit 2
fi
version="$($SHELLCHECK_BIN --version | awk '/version:/ {print $2; exit}')"
[ "$version" = "$SHELLCHECK_VERSION" ] || fail "ShellCheck version $version found; expected $SHELLCHECK_VERSION"
"$SHELLCHECK_BIN" --severity=warning "${shell_files[@]}" || fail 'ShellCheck reported warnings/errors'
pass "ShellCheck $SHELLCHECK_VERSION"

# i18n policy: a printf format may come only from the translation tables ("$(cm_t key)").
# ShellCheck reports every variable format as SC2059 (info level), so anything else is a format-string bug.
sc_json="$("$SHELLCHECK_BIN" --severity=style --format=json "$ROOT/script/color-mint.sh" || true)"
SC_JSON="$sc_json" python3 - "$ROOT/script/color-mint.sh" <<'PY' || fail 'printf format string is not a translation-table entry'
import json, os, re, sys
lines = open(sys.argv[1], encoding='utf-8').read().split('\n')
bad = []
for item in json.loads(os.environ['SC_JSON']):
    if item['code'] != 2059:
        continue
    line = lines[item['line'] - 1]
    if not re.search(r'printf\s+(?:-v\s+\S+\s+)?"\$\(cm_t\s', line):
        bad.append(f"{item['line']}: {line.strip()[:120]}")
if bad:
    raise SystemExit('printf format not taken from cm_t:\n' + '\n'.join(bad))
PY
pass 'printf formats come only from the translation tables'

# gsettings policy: a string key is read with cm_gs_string. `tr -d "'"` leaves the double quotes that GLib prints
# around a text with an apostrophe; it is only harmless on the two integer keys.
python3 - "$ROOT/script/color-mint.sh" <<'PY' || fail 'a gsettings string key is read with tr -d instead of cm_gs_string'
import re, sys
bad = []
for n, line in enumerate(open(sys.argv[1], encoding='utf-8').read().split('\n'), 1):
    if re.search(r"gsettings get .*\|\s*tr -d \"'\"", line) and not re.search(r'\b(cursor-size|num-workspaces)\b', line):
        bad.append(f'{n}: {line.strip()[:120]}')
if bad:
    raise SystemExit('\n'.join(bad))
PY
pass 'gsettings string keys are read with cm_gs_string'
