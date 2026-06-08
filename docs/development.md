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

`pr sync` is split into an effectful **gather** (each active branch's PR
number/title/base/body plus merged-predecessor candidates), a pure **reconcile**
(map that *chain state* plus the stack structure to an **edit plan** — every
presentation rule: the `[N/M]` prefix, strikethrough, nav-footer rendering,
normalized change detection), and an effectful **apply** (create/edit PRs; same
write path as the engine's remote-sync phase). The pure reconciler holds the
presentation logic so it's testable without `gh`.

The gather minimizes `gh` round trips, which dominate wall time: discovery is a
single bulk `gh pr list` indexed in memory (one query for the whole stack, not
one `--head` query per branch; a clean miss means "no open PR", a load failure
falls back to per-branch lookups). Merged predecessors woven into the footer are
resolved without re-querying where possible — an entry a PR's current body
already renders struck-through as merged is trusted as-is (a merge is terminal),
and any predecessor that still needs a live check is memoised per run, so one
shared by several PRs in the stack costs a single `gh pr view`.

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

### Shell completion — dynamic candidates + per-shell grammar

`git stack init zsh` / `init fish` bundle tab completion with the aliases.
It's a two-layer split (see [ADR 0004](adr/0004-shell-completion.md) and
[`../CONTEXT.md`](../CONTEXT.md#completion)): the hidden `git stack __complete`
subcommand (`cmd___complete` + the `_complete_*` family) is the **single source
of truth for dynamic candidates** (verbs, subverbs, leaves, prefixes), while the
**static grammar** — which slot wants which kind — is hand-written, and
**duplicated**, in each shell's DSL inside `_emit_completion_zsh` /
`_emit_completion_fish`. Adding a verb or a value-taking flag means touching the
per-shell emitters; the CONTEXT.md maintenance note spells out exactly where
(and the zsh/fish asymmetry). `__complete` obeys a never-fail contract: it runs
on every tab, so it must never die/prompt/error — every degenerate case exits 0
with empty stdout.

### Manual verification checklist (completion)

bats can't drive live tab behavior, so verify by hand after a completion change.
Install a fresh init line (`eval "$(git stack init zsh)"` / `git stack init fish | source`)
in a stack repo, then check:

**zsh**
- `git stack <tab>` → verbs, each with its description.
- `git stack checkout <tab>` → leaf numbers, slug as the hint.
- `git stack view <tab>` → stack prefixes.
- `git stack add --before <tab>` → leaves.
- `git stack add --onto <tab>` → git branches (native ref completion).
- `git stack pr <tab>` → `sync`/`list`; `git stack history <tab>` → `show`/`restore`.

**fish** — same set (`git stack <tab>`, `checkout`, `view`, `--before`, `--onto`,
`pr`/`history` subverbs).

**both**
- Outside a repo / off-stack / detached HEAD → no errors, just no candidates.
- `gstkco <tab>` (alias/abbr) inherits leaf completion — the alias expands to
  `git stack checkout` before completing.

**See also:** [`../CONTEXT.md`](../CONTEXT.md) (canonical vocabulary) · [concepts.md](concepts.md) (reader-facing concepts)
