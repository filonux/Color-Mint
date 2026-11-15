# Contributing

Thanks for your interest. This guide covers the basics so your contribution can be reviewed and accepted quickly. By taking part you agree to follow the [code of conduct](CODE_OF_CONDUCT.md).

## Before writing code

- For big changes, or ones that change how Color Mint behaves today, open an issue first (use the feature request template) to agree on the approach before investing time in it.
- For a specific bug or a small improvement, you can go straight to a pull request.
- Color Mint's mission is to customize the look of Cinnamon with the least effort for the user. A change is accepted more easily when it keeps the program a single script, adds no new way of running it, adds no required dependency and keeps `sudo` out of the normal path.

## How the repository is laid out

| Path | What it holds |
| --- | --- |
| `script/color-mint.sh` | The whole program: one Bash file, with the icon embedded at its end |
| `tests/` | `run.sh`, the suites (`test_*.sh` and `lint.sh`) and `lib/` with their helpers |
| `assets/` | The project icons (`icon.png` is the one the READMEs use) |
| `.github/` | The workflows and these community files |
| `README.md`, `README.es.md`, `LICENSE.txt` | The documentation, in English and Spanish, and the license |

The root is closed on purpose: `tests/test_quality.sh` fails on any other entry, and the repository needs no `.gitattributes` or similar configuration files.

## Test requirements

Besides Bash and the usual tools of a desktop Linux, the tests need:

- ShellCheck **0.11.0** exactly: `tests/lint.sh` refuses any other version, and `SHELLCHECK_BIN` points it at the right binary. The version in your distribution is probably older; the workflow downloads 0.11.0 and checks its SHA-256, and `pip install shellcheck-py==0.11.0.1` also provides it.
- `yad`, `xvfb`, `x11-utils` (for `xwininfo`) and `xdotool`, to draw the real window and click on it.
- ImageMagick and `fonts-dejavu-core`, to measure what was drawn.
- `python3-gi`, `gir1.2-gtk-4.0` and `gir1.2-adw-1`, to draw a real GTK 4 and libadwaita window and read what it paints. Without them that part of `test_gui_render.sh` is skipped, and `CM_REQUIRE_GUI_RENDER=1` makes the skip a failure.
- `zip`, `unzip`, `xz-utils` and `bzip2`, and `python3`.

On Debian, Ubuntu and Mint:

```bash
sudo apt install imagemagick fonts-dejavu-core zip unzip xz-utils bzip2 xvfb x11-utils xdotool yad python3-gi gir1.2-gtk-4.0 gir1.2-adw-1
```

## Running the tests

```bash
bash tests/run.sh                             # every suite
bash tests/run.sh test_security.sh            # one suite
bash tests/run.sh --skip lint.sh              # everything except ShellCheck
bash tests/run.sh --skip test_gui_render.sh   # without Xvfb and yad
```

The exit status is 0 when everything passes, 1 when a suite fails and 2 when a suite could not run because a tool is missing. Three variables are worth knowing: `CM_TEST_JOBS` (how many suites run at once, 1 by default), `SUITE_TIMEOUT` (the seconds each suite may take, 180 by default) and `CM_REQUIRE_GUI_RENDER=1` (a skipped real render becomes a failure, as it does in CI). A full run takes a few minutes on one CPU. The GitHub workflow runs it on every push and pull request.

## Writing tests

- Start every suite by sourcing `tests/lib/sandbox.sh`. It makes the suite hermetic however it is started: it re-runs itself under `env -i` with a throwaway `HOME`, XDG folders and `TMPDIR` and no desktop session, so it cannot reach your real gsettings or dconf database, the session bus, the X server or your files, even if you start it by hand on a live Cinnamon desktop. `tests/run.sh` builds the same environment itself.
- Anything that would touch the system (`gsettings`, `dconf`, `gdbus`, `yad`, `curl`, `sudo`, `apt-get`...) is a double that records how it was called. See `tests/lib/doubles.sh` and the suites that already use doubles.
- Write negative assertions with `must_fail` and `must_print_nothing`. A plain `! command` is ignored by `set -e` and, inside `bash -c`, only the last status counts, so a command that unexpectedly succeeds would pass without a sound.
- A new test must fail when the fix it protects is removed, and it needs a positive control that shows it can pass. Take the fix out, watch the test fail, and put it back.
- A new suite goes into the `suites` list in `tests/run.sh`: `test_quality.sh` fails if a `tests/test_*.sh` is missing from it.
- The look of the window is measured too. `tests/lib/aesthetic_score.py` scores the interface on 13 metrics, and the total may not fall under `tests/aesthetic-score.baseline`. If your change raises the score, raise the baseline in the same pull request.

## Code conventions

- Code, identifiers and comments are in English. A comment explains a *why* that is not obvious (a YAD or Cinnamon quirk, a security decision) and never repeats what the code already says.
- Every message the user can read exists in English and Spanish in the translation tables. A `printf` format may come only from those tables (`"$(cm_t key)"`): `tests/lint.sh` rejects anything else.
- The literal CLI values `claro`, `oscuro`, `mantener` and `solo_color`, and the window-button presets, are part of the public interface and do not change.
- Use only what yad 0.40.0 (Mint 22.x, Ubuntu 24.04) has: no `--css` and no `label!tooltip`. Anything newer is detected, or not used. The maintainer notes at the top of the script explain the other quirks.
- Files are written atomically: a temporary file in the same folder, then a rename. A file that changes the user's look goes through `cm_look_write` or `cm_look_marked_replace`, is added to the inventory `uninstall` reads (`cm_look_files`, `cm_look_dirs` or the install record) and is used in the full-use step of `tests/test_uninstall.sh`, which runs the whole install, use and uninstall cycle and must still leave no trace.
- Color Mint asks for `sudo` only in `theme install`, and only after the user agrees.
- ShellCheck 0.11.0 with `--severity=warning` must report nothing.

## Documentation

- `README.md` (English, the main one) and `README.es.md` change together.
- If a change is visible to the user, mention it in the "What's new" section of both READMEs.
- Text files use LF line endings, end with a single newline and have no trailing spaces; the workflow rejects trailing spaces in the commit. In Markdown, break a line with `<br>` or a backslash, not with two spaces.

## Sending the pull request

- One logical change per pull request, with a description of what changes and why.
- Say how you tested it and where (distribution, version, session). The pull request template asks for it.
- Make sure `bash tests/run.sh` passes. If you could not run a suite (no Xvfb, for example), say which one.

## Reporting bugs or proposing ideas

Use the issue templates of the repository; they open automatically when you create an issue. The more context (distribution, Color Mint version, `yad` version, exact steps), the faster it can be diagnosed. A report from a distribution or Mint version that the README lists as "expected" is also welcome: the compatibility report template is for that.

For security problems, do not open a public issue: see [SECURITY.md](SECURITY.md).
