#!/usr/bin/env python3
"""Mutation pass over the "Import theme" button (CR-90). Private tool: it lives outside the repository, next to PLAN.txt.

    python3 mutation_import.py <repo> [--trim] [--list] [ID ...]

It works on its own copy of <repo>, never on the original. As root the copy belongs to `ubuntu` and the suites run with
`su ubuntu` (the real render and test_atomicity need a normal user), like the other mutation_*.py.

First the control: the unmutated copy must pass. Then, for each mutant of script/color-mint.sh (all of them, or the IDs given):
  - tests/test_gui_render.sh must fail AND its FAIL line must carry the text listed for that mutant: a mutant that dies of
    something else is not covered, it is only broken;
  - the mutants listed with no render text (KEEP) are invisible to the real button, which asks to choose something in all
    three: the window looks the same or the marker only arrives as the second value. They must survive test_gui_render.sh and
    be killed by tests/test_color_mint.sh, with its text.
--trim runs a copy of test_gui_render.sh without the sections before and after import_check (about 12 s a mutant, not about
45 s): the same lines, cut at anchors the tool asserts. The pass that is written down in the PLAN is made without it.
Exit status 0 when every mutant behaves as listed.
"""
import os
import pwd
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

USER = 'ubuntu'
SCRIPT = 'script/color-mint.sh'
RENDER = 'test_gui_render.sh'
FALLBACK = 'test_color_mint.sh'
LIMIT = 240

GENERIC = 'must ask for a file or a folder, once'
FAILED = 'raised the import-failure dialog'
NODIALOG = 'raised no dialog'

FILE_GUARD = '    [ "$IMPORT_FILE" != "$CM_NO_FOLDER" ] || IMPORT_FILE=""\n'
DIR_GUARD = '    [ "$IMPORT_DIR" != "$CM_NO_FOLDER" ] || IMPORT_DIR=""\n'
DIALOG = '        yad --error --text="$(cm_t ui_theme_file_required)" --button="$(cm_t \'done\'):0" 2>/dev/null\n'
EN_TEXT = '[ui_theme_file_required]="Choose a theme file or an already extracted folder to import."'
DISPATCH = 'themes_import)    cm_ui_apply_themes_import "$@" || _status=$? ;;'
WIRING = '"$(cm_fbtn_apply themes_import 14 15)"'
BUTTON = re.compile(r'^ *--field="\$\(cm_t import_theme\)\$\(cm_yad_btn_icon gtk-add\):FBTN" +' + re.escape(WIRING) + r' \\\n', re.M)
FOLDER_FIELD = '--field="$(cm_t ui_theme_dir):DIR"  "$CM_NO_FOLDER"'
MARKER = 'CM_NO_FOLDER="/nonexistent/color-mint/no-folder"'

# (id, what it does, [(old, new)...], text of the render failure or None, text of test_color_mint.sh when None)
MUTANTS = [
    ('G1', 'file guard removed', [(FILE_GUARD, '')], FAILED, None),
    ('G2', 'folder guard removed', [(DIR_GUARD, '')], None, 'command was expected to fail'),
    ('G3', 'both guards removed', [(FILE_GUARD, ''), (DIR_GUARD, '')], FAILED, None),
    ('G4', 'file guard compares with another path',
     [(FILE_GUARD, '    [ "$IMPORT_FILE" != "/nonexistent/color-mint/other" ] || IMPORT_FILE=""\n')], FAILED, None),
    ('T1', 'EN text of the "choose something" dialog changed',
     [(EN_TEXT, '[ui_theme_file_required]="Choose a theme file or a folder to import."')], GENERIC, None),
    ('T2', 'that dialog says the import failed',
     [(EN_TEXT, '[ui_theme_file_required]="The theme could not be imported."')], FAILED, None),
    ('D1', 'dialog is --info, not --error', [(DIALOG, DIALOG.replace('--error', '--info'))], GENERIC, None),
    ('D2', 'no dialog', [(DIALOG, '        :\n')], NODIALOG, None),
    ('D3', 'two dialogs', [(DIALOG, DIALOG + DIALOG)], GENERIC, None),
    ('W1', 'dispatcher runs the apply handler', [(DISPATCH, DISPATCH.replace('themes_import "$@"', 'themes_apply "$@"'))], NODIALOG, None),
    ('W2', 'dispatcher branch renamed (unknown mode)', [(DISPATCH, 'themes_importx)   ' + DISPATCH.split('    ', 1)[1])], NODIALOG, None),
    ('W3', 'button wired to fields 5 and 6 (the GTK and icon lists)', [(WIRING, '"$(cm_fbtn_apply themes_import 5 6)"')], FAILED, None),
    ('W4', 'button removed from the form', [(BUTTON, '')], NODIALOG, None),
    ('W5', 'button wired to no field', [(WIRING, '"$(cm_fbtn_apply themes_import)"')], NODIALOG, None),
    ('P1', 'placeholder is empty', [(MARKER, 'CM_NO_FOLDER=""')], None, 'is not an absolute path'),
    ('P2', 'placeholder is a relative path', [(MARKER, 'CM_NO_FOLDER="nonexistent/color-mint/no-folder"')], FAILED, None),
    ('P3', 'folder selector starts empty', [(FOLDER_FIELD, '--field="$(cm_t ui_theme_dir):DIR"  ""')], None,
     'the folder selector starts on <>, expected the placeholder'),
]


def trimmed(text):
    """test_gui_render.sh without the render, redraw, Get-more-themes and GTK 4 sections: the harness and import_check only."""
    out, dropped, cut, skip_pass = [], 0, False, False
    for line in text.splitlines(keepends=True):
        if skip_pass and line.startswith('pass '):
            skip_pass = False
            dropped += 1
            continue
        if line.startswith(('render english ', 'render spanish-posix ')) or line == 'redraw_check\n':
            skip_pass = True
            dropped += 1
            continue
        out.append(line)
        if line.startswith("pass 'the real Import theme button"):
            cut = True
            break
    if dropped != 6 or not cut:
        sys.exit(f'trim: the anchors of test_gui_render.sh changed (dropped {dropped} of 6 lines, import_check pass found: {cut})')
    return ''.join(out)


def apply(text, edits):
    for old, new in edits:
        n = len(old.findall(text)) if hasattr(old, 'findall') else text.count(old)
        if n != 1:
            return None, f'the pattern occurs {n} times, expected 1: {old.pattern if hasattr(old, "pattern") else old.strip()[:70]}'
        text = old.sub(lambda _m: new, text) if hasattr(old, 'findall') else text.replace(old, new)
    return text, ''


class Work:
    def __init__(self, repo):
        self.root = tempfile.mkdtemp(prefix='cm-mut-')
        os.chmod(self.root, 0o755)
        self.repo = os.path.join(self.root, 'repo')
        shutil.copytree(repo, self.repo, ignore=shutil.ignore_patterns('.git'))
        self.as_root = os.geteuid() == 0
        if self.as_root:
            try:
                self.uid, self.gid = pwd.getpwnam(USER)[2:4]
            except KeyError:
                sys.exit(f'running as root needs the user {USER}')
            for base, dirs, files in os.walk(self.root):
                for name in dirs + files:
                    os.chown(os.path.join(base, name), self.uid, self.gid)
            os.chown(self.root, self.uid, self.gid)
        self.script = os.path.join(self.repo, SCRIPT)
        self.original = read(self.script)

    def write(self, rel, text):
        path = os.path.join(self.repo, rel)
        with open(path, 'w', encoding='utf-8') as handle:
            handle.write(text)
        if self.as_root:
            os.chown(path, self.uid, self.gid)

    def run(self, suite):
        inner = f'cd {shlex.quote(self.repo)} && CM_REQUIRE_GUI_RENDER=1 timeout --kill-after=10 {LIMIT} bash tests/{suite}'
        argv = ['su', USER, '-s', '/bin/bash', '-c', inner] if self.as_root else ['bash', '-c', inner]
        start = time.time()
        done = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace')
        return done.returncode, done.stdout, time.time() - start

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


def read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def fail_lines(output):
    return [line for line in output.splitlines() if line.startswith('FAIL')]


def verdict(code, output, want):
    if code == 0:
        return 'survived'
    if code in (124, 137):
        return 'timeout'
    return 'killed' if any(want in line for line in fail_lines(output)) else 'killed for another reason'


def main():
    args = sys.argv[1:]
    trim = '--trim' in args
    listing = '--list' in args
    args = [a for a in args if not a.startswith('--')]
    if listing:
        for ident, what, _edits, render, fallback in MUTANTS:
            print(f'{ident}  {what}: ' + (f'{RENDER} must fail with "{render}"' if render else f'KEEP: {FALLBACK} must fail with "{fallback}"'))
        return 0
    if not args or not os.path.isfile(os.path.join(args[0], SCRIPT)):
        sys.exit(__doc__)
    ids = args[1:]
    known = {m[0] for m in MUTANTS}
    if set(ids) - known:
        sys.exit(f'unknown mutants: {" ".join(sorted(set(ids) - known))}')
    chosen = [m for m in MUTANTS if not ids or m[0] in ids]

    work = Work(args[0])
    try:
        if trim:
            work.write(f'tests/{RENDER}', trimmed(read(os.path.join(work.repo, 'tests', RENDER))))
        code, out, secs = work.run(RENDER)
        if code != 0 or 'the real Import theme button' not in out:
            print(f'CONTROL {RENDER}{" (trimmed)" if trim else ""}: FAILED in {secs:.0f} s\n' + '\n'.join(fail_lines(out) or out.splitlines()[-5:]))
            return 1
        print(f'CONTROL {RENDER}{" (trimmed)" if trim else ""}: passes in {secs:.0f} s', flush=True)
        if any(m[3] is None for m in chosen):
            code, out, secs = work.run(FALLBACK)
            if code != 0:
                print(f'CONTROL {FALLBACK}: FAILED in {secs:.0f} s\n' + '\n'.join(fail_lines(out) or out.splitlines()[-5:]))
                return 1
            print(f'CONTROL {FALLBACK}: passes in {secs:.0f} s', flush=True)

        bad, tally = [], {'killed': 0, 'kept': 0}
        for ident, what, edits, render, fallback in chosen:
            mutated, why = apply(work.original, edits)
            if mutated is None:
                print(f'{ident}  DOES NOT APPLY: {why}')
                bad.append(ident)
                continue
            work.write(SCRIPT, mutated)
            if subprocess.run(['bash', '-n', work.script]).returncode != 0:
                print(f'{ident}  DOES NOT PARSE')
                bad.append(ident)
                continue
            code, out, secs = work.run(RENDER)
            if render:
                got = verdict(code, out, render)
                good = got == 'killed'
                tally['killed'] += good
                line = (fail_lines(out) or ['-'])[0]
            else:
                got = 'survived' if code == 0 else 'died in the render (not expected)'
                good, line = code == 0, ''
                if good:
                    code, out, secs2 = work.run(FALLBACK)
                    secs += secs2
                    got = f'survived {RENDER}, {verdict(code, out, fallback)} by {FALLBACK}'
                    good = got.endswith('killed by ' + FALLBACK)
                    tally['kept'] += good
                    line = next((l for l in fail_lines(out) if fallback in l), (fail_lines(out) or ['-'])[0])
            print(f'{ident}  {"ok " if good else "BAD"} {what}: {got} ({secs:.0f} s)\n        {line[:230]}', flush=True)
            if not good:
                bad.append(ident)
            work.write(SCRIPT, work.original)
        print(f'SUMMARY: {len(chosen)} mutants, {tally["killed"]} killed by {RENDER}, {tally["kept"]} survived it and were killed by '
              f'{FALLBACK}, {len(bad)} not as listed' + (f' ({" ".join(bad)})' if bad else ''))
        return 1 if bad else 0
    finally:
        work.close()


if __name__ == '__main__':
    sys.exit(main())
