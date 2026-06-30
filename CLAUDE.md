# git-stack

A `git stack` porcelain for managing stacked branches. Single bash entry point
(`bin/git-stack`), bats tests under `tests/`. Domain language and architecture
live in `CONTEXT.md`; decisions in `docs/adr/`.

## No auto-commit here

This repo is a **git submodule** of `dotfiles` (its `.git` is a gitdir pointer
into `../.git/modules/git-stack`). The dotfiles `bin/dotfiles-watcher` auto-commits
the **superproject only** — it does **not** reach inside this submodule. So changes
here are **never** committed automatically: leaving the working tree dirty leaves it
uncommitted. Commit explicitly (the global "don't commit without asking" rule
applies normally — wait for the user to ask).

## Tests

`bats tests/git-stack.bats tests/unit.bats`. Test bodies run under `set -e`; use the
`assert_*` helpers in `tests/helpers.bash`.
