# ADR 0006 — `move` is fully local: decouple reorder from `pr sync`

- **Status:** Accepted (2026-06-15)
- **Context doc:** [CONTEXT.md → Language → move](../../CONTEXT.md#language), [CONTEXT.md → PR sync](../../CONTEXT.md#pr-sync)

## Context

`move` reorders or renumbers branches in a stack. It used to finish by appending a
`remote-sync` phase to its engine plan — renaming the remote branches and running
`pr sync` automatically. That made sense when `move` was the only way to reshuffle a
published stack: do the local rebase, then reconcile GitHub in one shot.

`pr desync` (ADR 0005) changed the picture. The intended way to reorder a *published*
stack is now a matched trio: **`pr desync`** takes the stack off GitHub (closes the
PRs), you **reorder locally**, then **`pr sync`** re-publishes a fresh chain. With that
flow available, `move` auto-syncing actively fights it — it republishes mid-reorder,
re-opening PRs the user is in the middle of tearing down.

A second fact makes auto-sync after a local rename unsafe regardless. GitHub's branch
rename only retargets PRs that use the branch as their **base**; **if the renamed branch
is the *head* of an open PR, GitHub closes that PR**
([docs](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-branches-in-your-repository/renaming-a-branch)).
Every git-stack branch is the head of its own PR. And `pr sync` finds PRs **open-only**,
so after a rename `01-foo`→`04-foo` a later sync opens a *new* PR on `04-foo` and
orphans the old one on `01-foo`.

## Decision

Make `move` **fully local**: it touches only local refs and never pushes, renames remote
branches, or runs `pr sync`. `rename`, `fold`, and `doctor` are unchanged — they remain
one-shot rewrites where auto-sync-at-end is wanted, and keep using the shared
`remote-sync` phase.

### 1. Drop the `remote-sync` phase from both move plans

`move`'s two engine setups no longer append `remote-sync`:

- renumber-in-place: `[rename-batch]`
- reorder: `[reflow-pick, rename-batch]`

The shared `remote-sync` phase / `_phase_remote_sync_advance` is untouched.

### 2. Keep the PR-orphan guard, ungated, repointed at the trio

`move` still refuses when an affected branch has an open PR — but now because a local
reorder would leave that PR stranded on its old remote branch and a later `pr sync` would
orphan it, not because of any remote rename `move` performs. The guard is checked
**unconditionally** (the helper no-ops when `gh` is unusable) and its message points at
`pr desync` → reorder → `pr sync`. Its natural escape hatch is that it only inspects
*affected* branches: unpublished stacks and unaffected PRs reorder freely.

### 3. Drop `--allow-pr-rebuild`; ignore `--no-push` / `--no-sync`

`--allow-pr-rebuild` meant "rebuild the PRs via the auto-sync" — meaningless now that
`move` never syncs. It's removed with a hint pointing at the `pr desync` trio (mirroring
the `--first` removal). The shared `--no-push` / `--no-sync` flags are silently accepted
(they're common flags) but have no effect on `move` and are dropped from its usage.
`--force` (the multi-commit guard) is unrelated to PRs and stays.

## Consequences

- The matched trio is now coherent: `pr desync` unpublishes, `move`/reorder is local,
  `pr sync` republishes. No command both reorders *and* republishes.
- A `move` makes zero PR mutations and zero remote renames; the orphan guard may still
  run a read-only `pr list` preflight.
- `rename`/`fold` keep `--allow-pr-rebuild` and auto-sync. Their orphan-guard messages
  now also offer `pr desync` as the clean alternative, and the stale "head-PRs can't
  survive a rename" framing was **confirmed correct** (head PRs are closed on rename) —
  not reversed.
