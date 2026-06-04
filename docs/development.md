# Development

Notes for working on `git stack` itself. The whole tool is one bash script,
`bin/git-stack`, with no runtime dependencies beyond `git` and POSIX utilities.

## Tests

The suite uses [`bats-core`](https://github.com/bats-core/bats-core); the
`pr sync` tests use a stubbed `gh` that pipes JSON through `jq`.

```sh
brew install bats-core jq        # macOS
sudo apt-get install -y bats jq  # Debian/Ubuntu

make test                        # JOBS=4 by default
make test JOBS=1                 # sequential
```

> Heads up: bats test bodies run under `set -e`. `[[ … ]]` and `! …` are masked,
> but a bare `[ … ]` that fails will abort the test — use the `assert_*` helpers
> in `tests/helpers.bash`.

## Architecture map

The script is organized as a set of **pure cores** wrapped by **effectful
shells**. The pure functions take pre-gathered git facts and return data (issue
lists, edit plans, placements) with no git reads and no `die` — which is what
makes them unit-testable without a fixture repo or a TTY. The effectful wrappers
do the I/O: read git state, prompt, push, call `gh`.

The canonical vocabulary for all of this — *plan*, *phase*, *unit*, *reconciler*,
*chain state*, *scan*, *placement* — lives in
[`../CONTEXT.md`](../CONTEXT.md). Read it before a substantial change; it's the
source of truth for the words used in the code and reviews. The four major
components:

### Engine — the reflow executor

The shared machinery behind `restack`, `move`, `continue`, and `doctor` repairs.
A caller composes a **plan** (an ordered list of **phases** over a branch set);
the engine executes it one **unit** at a time, persisting the coarse
`(phase, unit)` position to disk so it can pause and resume. Phase types are
**reflow-pick** (cherry-pick one branch; can pause on a conflict),
**rename-batch** (atomic local ref rename), and **remote-sync** (remote rename +
`pr sync`). `continue`/`abort` dispatch through it. Key functions: `_engine_next`,
`save_engine_state`, the `_phase_reflow_pick_*` family.

### PR-sync reconciler — chain state → edit plan

`pr sync` is split into an effectful **gather** (read each active branch's PR
number/title/base/body and merged-predecessor candidates), a pure **reconcile**
(map that *chain state* plus the stack structure to an **edit plan** — every
presentation rule: the `[N/M]` prefix, strikethrough, nav-footer rendering,
normalized change detection), and an effectful **apply** (create/edit PRs; same
write path as the engine's remote-sync phase). The pure reconciler holds the
presentation logic so it's testable without `gh`.

### Doctor scan — stack shape → issue list

`doctor` runs `gather → scan → bucket → dry-run/prompt/apply`. `_doctor_gather`
reads the effectful git facts (per branch: tree SHA, commit count, merge-tip
flag); the pure `_doctor_scan` maps those to an **issue** list (squash / duplicate
/ rename), with `_doctor_squash_kind_pure` classifying squash kinds. Idempotent
and `gh`-free, so the whole diagnosis is unit-testable.

### Placement — where a new or moved branch lands

`_placement_resolve` is the pure resolver shared by `create`/`add` and `move`: given the
stack's leaves, a target intent (before / after / at / last), and the
[width](concepts.md#width), it returns the new branch's [leaf](concepts.md#leaf)
and [predecessor](concepts.md#predecessor) (or a base sentinel), or a
gap-exhausted error — no git reads, no `die`.

**See also:** [`../CONTEXT.md`](../CONTEXT.md) (canonical vocabulary) · [concepts.md](concepts.md) (reader-facing concepts)
