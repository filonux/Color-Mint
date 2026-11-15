## What does this change?

Explain what this pull request changes and why. Link the issue if there is one (for example `Closes #12`).

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Documentation (README, templates...)
- [ ] Refactor or cleanup with no change in behavior
- [ ] Tests only

## How did you test it?

Say what you ran and where.

- Distribution and version:
- Session: X11 / Wayland
- `./color-mint.sh --version`:
- `bash tests/run.sh` (the `Summary:` line, and which suites you could not run, if any):

## Checklist

- [ ] `bash tests/run.sh` passes
- [ ] ShellCheck 0.11.0 reports nothing with `--severity=warning`
- [ ] A new test fails when my fix is removed, and it is listed in `tests/run.sh`
- [ ] New messages exist in English and Spanish
- [ ] The CLI values `claro`, `oscuro`, `mantener` and `solo_color` and the window-button presets are unchanged
- [ ] Every file the change writes is replaced atomically, and `uninstall` knows how to undo it
- [ ] README.md and README.es.md are both updated if the change affects use, commands or requirements
- [ ] The comments I added explain the *why*, not the *what*
- [ ] No generated files, temporary files or credentials
