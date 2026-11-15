#!/usr/bin/env bash
# Container CI helper (compat.yml): install the packages Color Mint itself names for its dependencies, then check
# that their commands exist. It runs the exact line the program shows its users (cm_pkg_install_line) minus sudo,
# which a container lacks, so a wrong package name for a distribution fails here and not in front of a user.
#
# Usage: program_deps.sh <apt|dnf|pacman|zypper>
#
# Only bash builtins plus bash, dirname, mktemp, awk, sort, yes and rm are used: the test suite runs it with a
# PATH made of exactly those tools and package-manager doubles. There is no `set -e`: the program body runs
# top-level code that may fail harmlessly in that PATH, and every failure here is checked explicitly.
set -uo pipefail

# The commands the program requires in GUI mode (see cm_check_dependencies in script/color-mint.sh).
commands=(yad dconf gsettings gdbus)

manager="${1:-}"
case "$manager" in
    apt|dnf|pacman|zypper) ;;
    *)
        printf 'usage: program_deps.sh <apt|dnf|pacman|zypper>\n' >&2
        exit 2
        ;;
esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
script="$here/../../script/color-mint.sh"
[ -f "$script" ] || { printf 'program not found: %s\n' "$script" >&2; exit 2; }

work="$(mktemp -d)" || exit 2
trap 'rm -rf "$work"' EXIT

# Functions only: everything before the command-line dispatcher. Sourcing it with --help keeps it read-only
# (no state folder is created) and never runs a command.
awk '/^# Command-line dispatcher/{exit} {print}' "$script" > "$work/body.sh" || exit 2
export HOME="$work/home" CM_HOME="$work/state"
# shellcheck source=/dev/null
. "$work/body.sh" --help

packages=()
for command_name in "${commands[@]}"; do
    packages+=("$(cm_pkg_name "$manager" "$command_name")")
done
mapfile -t packages < <(printf '%s\n' "${packages[@]}" | sort -u)

line="$(cm_pkg_install_line "$manager" "${packages[@]}")"
line="${line//sudo /}"
printf '+ %s\n' "$line"

# A rolling distribution must not be left half upgraded when a package is installed.
if [ "$manager" = pacman ]; then
    printf '+ pacman -Syu --noconfirm\n'
    bash -c 'pacman -Syu --noconfirm' < <(yes) || exit 1
fi
# Some managers ask for confirmation on this line; `yes` answers it.
bash -c "$line" < <(yes) || exit 1

missing=0
for command_name in "${commands[@]}"; do
    if command -v "$command_name" >/dev/null 2>&1; then
        printf 'ok: %s\n' "$command_name"
    else
        printf 'missing after install: %s (package %s)\n' "$command_name" "$(cm_pkg_name "$manager" "$command_name")" >&2
        missing=1
    fi
done
exit "$missing"
