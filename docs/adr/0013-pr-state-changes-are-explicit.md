# ADR 0013 — PR state changes are explicit

- **Status:** Accepted (2026-08-11)
- **Context doc:** [CONTEXT.md → PR sync → Explicit PR state](../../CONTEXT.md#pr-sync), [CONTEXT.md → Commands](../../CONTEXT.md#commands)
- **Supersedes:** the "`rename`, `fold`, and `doctor` are unchanged" clause of [ADR 0006](0006-move-fully-local.md)

## Context

ADR 0006 made `move` fully local, on two grounds: `pr desync` (ADR 0005) had made
"take the stack offline → mutate → re-publish" the sanctioned way to reshape a
published stack, and auto-syncing *fought* that flow by re-publishing mid-reorder.
It scoped the change to `move` and explicitly left `rename`, `fold`, and `doctor`
as "one-shot rewrites where auto-sync-at-end is wanted."

That scoping was wrong for `rename`, and the failure is reproducible:

1. `git stack rename fix/` refuses — a branch has an open head PR — and the error
   points at `git stack pr desync`.
2. The user runs `pr desync`. The chain closes. Correct so far.
3. The user re-runs `rename`. It succeeds, and then **silently runs `pr sync`**,
   re-publishing the chain the user had just deliberately torn down.

The tool sent the user to a verb and then undid it. This is ADR 0006's own
motivating scenario, applied to the verb ADR 0006 declined to change.

Behind it is a cost the codebase had never named. Closing a PR is not a neutral
refresh: it discards review threads, approvals, requested-changes state, and CI
history. A verb that churns PRs as a *side effect* of a local rename spends
something expensive without being asked.

Two mechanics constrain any fix. First, GitHub retargets PRs that use a renamed
branch as their **base**, but **closes** any PR whose **head** is the renamed
branch — and every stack branch is the head of its own PR (confirmed in ADR 0006;
`bin/git-stack` carried a comment asserting the opposite, now corrected). Second,
`pr sync` finds open PRs only, so a closed PR is never reattached — a fresh one is
opened beside it.

Those two facts combine into a trap: **removing a verb's `pr sync` while leaving
its remote rename in place is strictly worse than doing nothing.** The remote
rename closes every head PR; the sync was the only thing recreating them. Drop the
sync alone and the user gets maximum churn with zero recovery.

## Decision

**No verb mutates the PR chain as a side effect of a local operation.** A verb
whose rename would hit an open head PR refuses and points at the
`pr desync` → mutate → `pr sync` trio.

### 1. `rename` drops the auto `pr sync`, keeps the remote rename

`rename`'s engine plan still runs the `remote-sync` phase, but with the trailing
sync suppressed unconditionally (`STACK_OPT_NO_SYNC=1` at the handoff; the phase's
`_post_rename_sync` already early-returns on it). `fold` and `doctor` still pass
`OPT_NO_SYNC` through, so they are untouched by the change.

The remote rename **stays**, which is where `rename` diverges from `move` and
`reslug`. Their stale remotes sit under the *same* prefix, so `clean` reaps them.
A renamed prefix's stale remotes land in a namespace `clean` never scans — nothing
would ever collect them. `rename` must therefore collect its own litter.

Dropping the sync is safe here precisely because the open-PR guard already exists:
when the guard passes there is no open head PR for the remote rename to close. The
guard and the sync-drop are a package, never separable (see the trap above).

`--allow-pr-rebuild` is **removed** (die-with-hint, mirroring `move --first`): it
meant "accept the close, the auto-sync will rebuild them", and there is no longer
an auto-sync to do the rebuilding. `--no-push` now means "skip the remote rename";
`--no-sync` is a no-op and is dropped from the usage line.

### 2. `clean` names the PRs its remote-orphan deletion would close

`clean` deletes remote branches with no local counterpart, which closes any PR
heading them — and its confirmation listed branch names only, with no `gh` call
anywhere in that path. It was the last place PR state changed invisibly.

It now annotates each orphan and the prompt. Deleting a remote branch closes PRs
**two** ways, and both are reported:

- **head** — the PR whose head is that branch;
- **base** — any open PR that *targets* it. This one is nastier: it closes a PR the
  user never touched. It is reachable after any local rename (`reslug`, `move`)
  whose successor's PR still bases on the old remote name, if `clean` runs before
  the `pr sync` that would retarget it. `pr desync --delete-remote` already guards
  the same hazard (`keeping remote X — base of still-open PR #N`); `clean` did not.

```
remote  2 remote branch(es) under 'feat/' with no local counterpart:
  origin/feat/010-auth   [open PR #12 — will be closed]
  origin/feat/015-old    [open PR #13 targets this branch — deleting it closes that PR]
delete these on origin? (closes 2 PRs) [y/N]
```

One bulk `gh pr list` (reusing the **Gather** index, not a query per branch), shown
in `--dry-run` too. **Advisory only**: it never gates the deletion, and every gh
problem — missing, unauthenticated, no GitHub remote, failed query — degrades to an
unannotated listing rather than an error. Refusing would strand the orphans, which
is the opposite of `clean`'s job.

### 3. Exceptions, named rather than ignored

- **`fold` keeps auto-sync.** Discarding the victim's review context *is* the
  operation, not collateral damage — the cost the rule protects is one the user is
  deliberately paying. It keeps `--allow-pr-rebuild` and the breadcrumb comment
  linking the closed PR to its successor.

  Its **gate was under-broad**, though, and is widened here. It inspected only the
  victim, on the premise — stated in a code comment and one test name — that the
  survivor's PR "retargets and stays open" on rename. That is the same premise ADR
  0006 disproved for head PRs, and the same `branches/rename` call whose
  PR-closing behavior `rename`'s entire guard exists to prevent; CONTEXT.md's fold
  entry already described the correct behavior. So a default `fold` (result takes
  the victim's slug, which renames the survivor) silently closed the survivor's
  PR — losing its review threads with no breadcrumb, since the breadcrumb only
  ever targets the victim's PR. The gate now covers the survivor whenever the
  result renames it, and the error offers `--slug <survivor's slug>` as the
  keep-the-PR escape. An unrenamed survivor is still not gated.
- **`doctor` is a tracked gap.** Its duplicate-leaf renumber renames branches and
  runs the full remote tail, and it has **no** open-PR guard (`_check_no_open_prs`
  has zero call sites in `cmd_doctor`). It cannot be fixed by the one-line change
  `rename` got: the guard must land *first*, and it wants per-issue gating inside
  an interactive multi-fix flow — skip the renumber, keep the squash fixes — which
  is a different shape of change. Deferred deliberately; the help text and
  `docs/doctor.md` say so out loud rather than leaving it to be discovered.

## Consequences

- The trio finally works as advertised: `pr desync` → `rename` → `pr sync`, with
  nothing re-publishing behind the user's back.
- `rename` is **not** a member of the fully-local family (`move`, `drop`,
  `reslug`) — it renames remote refs. Stated explicitly in CONTEXT.md so the
  asymmetry reads as deliberate.
- A `rename` on an unpublished stack is unchanged; the guard only inspects
  branches that actually have open PRs.
- `doctor` remains able to churn a published stack's PRs without warning until its
  follow-up lands.
- `_engine_finalize` no longer claims "remote sync complete" for a plan that
  contains no `remote-sync` phase — a purely local rename plan (`move --at`,
  `reslug`) already logs its own completion line.
- A default `fold` on a stack whose survivor has an open PR now **refuses** where
  it previously proceeded. That is the intended correction, but it is a behavior
  change for anyone relying on the old path; `--allow-pr-rebuild` restores it, and
  `--slug <survivor's slug>` avoids the rename entirely.
- The remaining unguarded path to silent PR closure is `doctor`. Everything else
  either refuses, or says what it is about to close.
