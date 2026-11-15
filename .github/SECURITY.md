# Security policy

Color Mint is a local script that runs as your user and does not need `sudo`: only `theme install` calls `sudo apt-get`, and only after you agree. If you find a real security problem, please report it in private instead of opening a public issue.

## What counts as a security problem

Anything that lets something other than you, or other than what you asked for, change your system through Color Mint. For example:

- a theme archive, a downloaded theme or a preset that writes or deletes files outside the folders Color Mint manages, or that makes it run code
- a command that overwrites or removes a file that is not Color Mint's
- a way to make `theme install`, `theme fetch` or `uninstall` do more than they say
- a link or a race that makes Color Mint write somewhere it should not

A setting that does not apply, or a theme that looks wrong, is a normal bug: open an issue with the bug report template.

## How to report it

Write to **filonux@proton.me** with:

- what the problem is and what it lets someone do
- the steps to reproduce it, if you can
- the Color Mint version (`./color-mint.sh --version`) and your distribution

## What to expect

This is a one-person project kept up in spare time, so there is no guaranteed response time. Only the latest release receives fixes.
