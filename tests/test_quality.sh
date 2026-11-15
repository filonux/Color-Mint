#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sandbox.sh
. "$ROOT/tests/lib/sandbox.sh"
TESTS="$ROOT/tests"
SCRIPT="$ROOT/script/color-mint.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

mapfile -t shell_files < <(find "$ROOT" -type f -name '*.sh' -print | sort)
[ "${#shell_files[@]}" -gt 0 ] || fail 'no shell scripts found'
for file in "${shell_files[@]}"; do
    bash -n "$file" || fail "bash syntax: $file"
    IFS= read -r first < "$file" || fail "empty shell script: $file"
    [ "$first" = '#!/usr/bin/env bash' ] || fail "portable Bash shebang: $file"
    python3 - "$file" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
data = p.read_bytes()
text = data.decode('utf-8')
if '\r\n' in text or '\r' in text:
    raise SystemExit(f'CR character in {p}')
for line_no, line in enumerate(text.splitlines(), 1):
    if line.rstrip() != line:
        raise SystemExit(f'trailing whitespace in {p}:{line_no}')
if data and not data.endswith(b'\n'):
    raise SystemExit(f'missing final newline in {p}')
PY
done

# The execute bit is stored by git, not by a zip or a tar, so it is checked where it lives: the index. Without a
# git index there is nothing to check (a zip drops the mode of every file, and the suites run through `bash`).
script_mode() {
    local mode
    git -C "$1" ls-files --error-unmatch -- script/color-mint.sh >/dev/null 2>&1 || { printf 'unchecked\n'; return 0; }
    mode="$(git -C "$1" ls-files -s -- script/color-mint.sh | cut -c1-6)"
    if [ "$mode" = 100755 ]; then printf 'executable\n'; else printf 'not-executable\n'; fi
}
if command -v git >/dev/null 2>&1; then
    mode_repo="$(mktemp -d "${TMPDIR:-/tmp}/color-mint-mode.XXXXXX")"
    mkdir -p "$mode_repo/script"
    printf '#!/usr/bin/env bash\n' > "$mode_repo/script/color-mint.sh"
    [ "$(script_mode "$mode_repo")" = unchecked ] || fail 'script_mode: no git index must be unchecked'
    git init -q "$mode_repo" && git -C "$mode_repo" add script/color-mint.sh && git -C "$mode_repo" update-index --chmod=-x script/color-mint.sh
    [ "$(script_mode "$mode_repo")" = not-executable ] || fail 'script_mode: mode 100644 must be reported'
    git -C "$mode_repo" update-index --chmod=+x script/color-mint.sh
    [ "$(script_mode "$mode_repo")" = executable ] || fail 'script_mode: mode 100755 must be reported'
    rm -rf "$mode_repo"
fi
case "$(script_mode "$ROOT")" in
    executable)     pass 'main script is executable in the git index' ;;
    unchecked)      pass 'main script mode not checked: no git index (a zip or tar keeps no modes)' ;;
    *)              fail 'main script must be executable in git: git update-index --chmod=+x script/color-mint.sh' ;;
esac

# The repository stays clean and needs no .gitattributes: the root holds exactly these entries, files live where
# they belong, no tool leaves debris behind, and every text file is UTF-8 with LF endings and no trailing spaces.
# PLAN.txt and PUBLICACION.txt, the private working documents, may sit beside them but are never required.
python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
allowed = {'.git', '.github', 'LICENSE.txt', 'PLAN.txt', 'PUBLICACION.txt', 'README.md', 'README.es.md', 'assets', 'script', 'tests'}
required = allowed - {'.git', 'PLAN.txt', 'PUBLICACION.txt'}

def fail(message):
    raise SystemExit(message)

names = {p.name for p in root.iterdir()}
if names - allowed:
    fail(f'unexpected entries in the repository root: {sorted(names - allowed)}')
if required - names:
    fail(f'missing from the repository root: {sorted(required - names)}')
# Only suites and the two runners live loose in tests/; helpers go in tests/lib/, workflows in .github/workflows/.
loose = {'run.sh', 'lint.sh', 'aesthetic-score.baseline'}
homes = {'sandbox.sh': 'tests/lib/sandbox.sh', 'program_deps.sh': 'tests/lib/program_deps.sh',
         'compat.yml': '.github/workflows/compat.yml'}
for p in sorted((root / 'tests').iterdir()):
    if p.is_file() and p.name not in loose and not re.fullmatch(r'test_[a-z_]+\.sh', p.name):
        fail(f'misplaced file: tests/{p.name}: move it to '
             f'{homes.get(p.name, "tests/lib/ (helpers) or .github/workflows/ (workflows)")}, replacing the file there')
# The mutation tools and the README parity check are private working tools: they never belong in the repository.
for p in sorted(root.rglob('*')):
    if '.git' not in p.relative_to(root).parts and (re.fullmatch(r'mutation_[a-z0-9_]+\.py', p.name) or p.name == 'test_readme_parity.sh'):
        fail(f'private working tool in the repository: {p.relative_to(root)}: keep it outside the repository')

debris = {'__pycache__', '.DS_Store', 'Thumbs.db'}
for p in sorted(root.rglob('*')):
    rel = p.relative_to(root)
    if '.git' in rel.parts:
        continue
    if p.name in debris or p.suffix in {'.pyc', '.orig', '.rej', '.bak', '.swp'} or p.name.endswith('~'):
        fail(f'stray file: {rel}')
    if not p.is_file() or p.is_symlink():
        if p.is_symlink():
            fail(f'symbolic link in the repository: {rel}')
        continue
    data = p.read_bytes()
    if b'\0' in data:
        continue
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        fail(f'not UTF-8: {rel}')
    if '\r' in text:
        fail(f'CR character in {rel}')
    for number, line in enumerate(text.splitlines(), 1):
        if line != line.rstrip():
            fail(f'trailing whitespace in {rel}:{number}')
    if data and not data.endswith(b'\n'):
        fail(f'missing final newline in {rel}')
PY
pass 'repository layout: closed root, no misplaced files or debris, clean text files'

mapfile -t expected_meta < <(sed -n '2,7p' "$SCRIPT")
expected=(
    '# MENU: Color Mint'
    '# DESCRIPTION: Advanced visual customization for Linux Mint Cinnamon'
    '# CONFIRM: false'
    '# TERMINAL: false'
    '# SUDO: false'
    '# ICON: ../assets/icon.png'
)
[ "${#expected_meta[@]}" -eq "${#expected[@]}" ] || fail 'Scriptya metadata length'
for i in "${!expected[@]}"; do
    [ "${expected_meta[$i]}" = "${expected[$i]}" ] || fail 'Scriptya metadata content'
done
[ -f "$ROOT/assets/icon.png" ] || fail 'metadata icon exists'
pass 'syntax, encoding, whitespace and metadata hygiene'

for literal in claro oscuro mantener solo_color; do
    count="$(grep -o -F "$literal" "$SCRIPT" | wc -l | tr -d '[:space:]')"
    [ "$count" -gt 0 ] || fail "public CLI literal missing: $literal"
done
! grep -nE '(^|[[:space:]])(source|\.)[[:space:]]+[^"\047]*(preset|theme)' "$SCRIPT" >/dev/null || fail 'external preset source primitive detected'
pass 'public CLI literals and static shell hygiene'

for name in test_quality.sh test_aesthetics.sh test_security.sh test_robustness.sh test_functions.sh test_icons.sh test_atomicity.sh test_uninstall.sh test_color_mint.sh test_themes.sh test_presets.sh test_catalog.sh test_gui_render.sh lint.sh run.sh; do
    [ -f "$TESTS/$name" ] || fail "missing suite: $name"
done
pass 'suite inventory'

# A suite that is not in run.sh never runs in the workflow, so the two lists must be the same.
listed="$(sed -n '/^suites=(/,/^)/p' "$TESTS/run.sh" | grep -E '^[[:space:]]+[a-z_]+\.sh$' | sed 's/^[[:space:]]*//' | LC_ALL=C sort)"
present="$(cd "$TESTS" && LC_ALL=C ls test_*.sh lint.sh | LC_ALL=C sort)"
[ -n "$listed" ] || fail 'could not read the suite list from tests/run.sh'
[ "$listed" = "$present" ] || fail "tests/run.sh does not run exactly the suites in tests/: $(diff <(printf '%s\n' "$listed") <(printf '%s\n' "$present") | tr '\n' ' ')"
pass 'every suite in tests/ is run by tests/run.sh'

# The optional compatibility workflow must never gate a change and must cover the three distributions it names.
# Text checks only: PyYAML is not installed on a minimal Fedora or Arch.
python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
wf_dir = root / '.github' / 'workflows'

def fail(message):
    raise SystemExit(message)

for f in sorted(wf_dir.glob('*.yml')):
    data = f.read_bytes()
    text = data.decode('utf-8')
    if '\r' in text or '\t' in text:
        fail(f'tab or CR in {f.name}')
    for n, line in enumerate(text.splitlines(), 1):
        if line != line.rstrip():
            fail(f'trailing whitespace in {f.name}:{n}')
    if not data.endswith(b'\n'):
        fail(f'missing final newline in {f.name}')

compat = (wf_dir / 'compat.yml').read_text()
quality = (wf_dir / 'quality.yml').read_text()

def section(text, key):
    m = re.search(rf'^{key}:[^\n]*\n((?:(?:[ ].*)?\n)*)', text, re.M)
    return m.group(1) if m else fail(f'compat.yml has no top-level "{key}"')

triggers = set(re.findall(r'^  ([a-z_]+):', section(compat, 'on'), re.M))
if triggers != {'workflow_dispatch', 'schedule'}:
    fail(f'compat.yml must run only on demand and on a schedule, found: {sorted(triggers)}')

jobs = section(compat, 'jobs')
job_count = len(re.findall(r'^  [A-Za-z0-9_-]+:\s*$', jobs, re.M))
if job_count == 0 or job_count != len(re.findall(r'^    continue-on-error: true$', jobs, re.M)):
    fail('every compat.yml job must set continue-on-error: true')
if 'fail-fast: false' not in jobs:
    fail('one failing distribution must not cancel the others (fail-fast: false)')

images = set(re.findall(r'^\s+image: "?([^"\s]+)"?\s*$', jobs, re.M))
if 'debian:13' not in images or {i.split(':')[0] for i in images} != {'debian', 'fedora', 'archlinux'}:
    fail(f'compat.yml must cover Debian 13, Fedora and Arch Linux, found: {sorted(images)}')
if set(re.findall(r'^\s+pm: (\w+)\s*$', jobs, re.M)) != {'apt', 'dnf', 'pacman'}:
    fail('compat.yml package managers must be apt, dnf and pacman')

for action in ('checkout', 'upload-artifact'):
    pattern = rf'actions/{action}@(\S+)'
    if set(re.findall(pattern, compat)) != set(re.findall(pattern, quality)):
        fail(f'compat.yml and quality.yml must use the same actions/{action} version')

for needle in ('bash ./tests/run.sh --skip lint.sh', 'CM_REQUIRE_GUI_RENDER: "1"', 'tests/lib/program_deps.sh'):
    if needle not in compat:
        fail(f'compat.yml no longer contains: {needle}')
helper_path = root / 'tests' / 'lib' / 'program_deps.sh'
if not helper_path.is_file():
    fail('the helper used by compat.yml is missing')
# The helper installs what the program requires: its command list must not drift from the program's own.
program_commands = re.search(r'^\s+cm_check_dependencies ((?:[a-z]+ ?)+)$', (root / 'script' / 'color-mint.sh').read_text(), re.M)
helper_commands = re.search(r'^commands=\(([^)]*)\)$', helper_path.read_text(), re.M)
if not program_commands or not helper_commands or program_commands.group(1).split() != helper_commands.group(1).split():
    fail('tests/lib/program_deps.sh must list the same commands as cm_check_dependencies in the program')
PY
pass 'workflow hygiene; the optional compatibility workflow never gates a change and covers Debian 13, Fedora and Arch'

# The assertion helpers must stop child shells too; a silent helper would turn every negative test into a no-op.
if bash -c 'must_fail true; echo reached' >/dev/null 2>&1; then fail 'must_fail does not stop a child shell on unexpected success'; fi
bash -c 'must_fail false' || fail 'must_fail rejected an expected failure'
if bash -c 'must_print_nothing printf leftover' >/dev/null 2>&1; then fail 'must_print_nothing ignores output'; fi
bash -c 'must_print_nothing printf ""' || fail 'must_print_nothing rejected empty output'
pass 'assertion helpers are enforced in child shells'
