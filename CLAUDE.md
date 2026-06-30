# git-stack

A `git stack` porcelain for managing stacked branches. Single bash entry point
(`bin/git-stack`), bats tests under `tests/`. Domain language and architecture
live in `CONTEXT.md`; decisions in `docs/adr/`.

## Tests

`bats tests/git-stack.bats tests/unit.bats`. Test bodies run under `set -e`; use the
`assert_*` helpers in `tests/helpers.bash`.
