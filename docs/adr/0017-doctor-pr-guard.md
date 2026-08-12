# ADR 0017 — `doctor`: a skip-don't-refuse PR guard, and a fully local renumber

- **Status:** Accepted (2026-08-11)
- **Context doc:** [CONTEXT.md → PR sync → Explicit PR state](../../CONTEXT.md#pr-sync), [CONTEXT.md → Commands](../../CONTEXT.md#commands)
- **Closes:** the `doctor` gap [ADR 0013 §3](0013-pr-state-changes-are-explicit.md) tracked

## Context

[ADR 0013](0013-pr-state-changes-are-explicit.md) established that no verb mutates
the PR chain as a side effect of a local operation, and named `doctor` as the one
place the rule still didn't hold. Its duplicate-leaf renumber renamed branches and
then ran the full remote tail — remote rename followed by `pr sync` — and
`_check_no_open_prs` had **zero** call sites in `cmd_doctor`. A `doctor` run on a
published stack with duplicate leaves closed every affected PR and opened fresh
ones in their place, with no prompt disclosing it.

0013 deferred the fix because it is a different shape of change. The one-line
suppression `rename` got does not transfer: `rename` was safe to decouple only
because its guard already existed. Removing `doctor`'s `pr sync` while leaving its
remote rename would have closed every head PR with nothing left to recreate
them — strictly worse than doing nothing. Guard and tail had to be settled
together.

Two facts decide the shape:

1. **`doctor` fixes several independent issue kinds in one run** — squash,
   absorbed-branch deletion, duplicate renumber, out-of-order renumber. Only the
   rename pass touches PR state; squashes rewrite commits under an unchanged
   branch name, which no more churns a PR than any other force-push. Refusing the
   whole run to protect one PR would block repairs that were never at risk.
2. **`doctor`'s renames are the `move`/`reslug` case, not the `rename` case.**
   0013 §1 keeps `rename`'s remote rename for one stated reason: a renamed
   *prefix*'s stale remotes land in a namespace `clean` never scans, so nothing
   else would ever reap them. A renumber stays under the same prefix, which is
   exactly what `clean`'s remote-orphan pass collects.

## Decision

### 1. `doctor` is fully local

The remote tail goes. `cmd_doctor` hands `_doctor_finish` an empty
`STACK_RENAME_PAIRS`, so no `remote-sync` phase is appended and republishing is an
explicit `pr sync` like everywhere else. `_doctor_finish` itself is unchanged, and
`fold` — which shares it and must keep auto-syncing — keeps its tail through the
`STACK_FOLD_VICTIM` branch. Nothing gates on that global's emptiness to decide
policy; the caller simply doesn't ask for a tail it doesn't want.

This is why the guard and the tail were *not* the inseparable package 0013
described for `rename`: with no remote rename, nothing closes a PR. The hazard
that remains is the one `move --at` and `reslug` already carry — the rename
strands an open head PR on the old remote branch name, and a later `pr sync`
opens a fresh PR beside it rather than reattaching.

`--no-push` and `--no-sync` become no-ops for `doctor` and are dropped from its
usage line (the same treatment 0013 gave `rename --no-sync`). They stay accepted:
both are common flags parsed centrally, and erroring on a flag that now means
"do what you were going to do anyway" buys nothing.

### 2. The rename pass skips; the run continues

When any branch the rename pass would rename has an open head PR, the pass is
skipped and the run continues. Exit status stays 0 — squash fixes are applied,
because they were never at risk. Every blocked branch is named:

```
git-stack: warn: rename pass skipped — renumbering would strand these open PRs on the old branch name:
  feat/02-c  (open PR #42)
git-stack: warn: run 'git stack pr desync feat/02-c', re-run doctor, then 'git stack pr sync'
```

`doctor` is therefore the **only** verb that skips rather than refuses. That
follows from being the only multi-fix verb: for `reslug` or `drop` the gated
rename *is* the whole command, so refusing and doing nothing are the same thing.

Reporting uses a bulk `gh pr list` through the shared open-PR index
(`_doctor_open_pr_blockers`, modelled on `_clean_orphan_prs`) rather than
`_check_no_open_prs`, which dies on the first hit and carries a single
branch/number pair. A skip has to name the whole set, since one cascade can span
several branches. Same degrade-silently contract: any gh problem — missing,
unauthenticated, no GitHub remote, failed query — yields an empty result, so an
unusable `gh` can never gate a local repair.

### 3. All-or-nothing, gated on the actual rename set

The gate covers the pass as a unit, not one pair or one duplicate group at a
time. The cascade is interdependent: each rename sets the floor for the one
above, so renumbering a subset lands branches at positions the scan never
proposed. Skipping also has to unwind the duplicate phase, which permuted the
in-memory branch array without touching refs — with no rename to realize that
order, `doctor` reloads from refs and cancels the reflow the permutation would
have driven (`lowest_dup_idx`), since that ancestry never moved.

The gate inspects the **sources** of the proposed renames, not every member of a
duplicate group. A branch that keeps its number is not at risk, so the common
case — a fresh local branch colliding with a published one — renumbers normally.

- *Alternative:* per-duplicate-group skip (the shape the handoff sketched).
  *Why not:* it needs a frozen-set cascade scan so surviving groups renumber
  against the skipped one's retained number, plus rederiving the reflow index
  from the partial result. Real complexity for a case that
  [`pr desync <branch>`](0016-single-branch-pr-desync.md) already makes cheap to
  unblock. Revisit if all-or-nothing proves annoying in practice.
- *Alternative:* gate before the duplicate prompts, so the user is never asked
  for a permutation that gets discarded. *Why not:* the exact rename set isn't
  known until after resolution, and gating on the whole group up front would
  block the keeps-its-number case above. Exactness beat one wasted prompt.

### 4. `--dry-run` marks what the guard would skip

The preview runs the same guard and reports each blocker below the rename list:

```
  rename  feat/02-c -> feat/03-c
  rename pass will be skipped: feat/02-c has an open PR (#42)
```

A separate line rather than an inline annotation per rename, because the pass is
all-or-nothing — marking individual rows would read as though only those rows
were skipped.

The dry-run path returns before any mutation and previously made no `gh` call at
all, so it advertised renumbers the real run now refuses to make. 0013 §2 set the
precedent for `clean`: a preview that omits PR consequences is a preview that
lies.

### 5. The absorbed-branch delete stays ungated — named, not ignored

`doctor` deletes a local branch in three places (an `absorbed`-kind issue, a
squash that comes out empty, and the dead post-squash sweep), all through
`_doctor_delete_branch`, and none of them consult the PR state. On a published
stack that leaves `origin/<branch>` alive with an open PR and no local
counterpart — an orphan a later `clean` offers to close.

`drop` **refuses** that exact operation, on the grounds
[ADR 0014 §5](0014-reslug-rename-a-branch-slug.md) gave: leaving an orphan for
`clean` to close is the opposite of explicit. So this is a genuine inconsistency,
not a considered exemption. It is left for a follow-up rather than folded in
here: it is a different operation from the rename this ADR is about, and gating
it changes what `doctor` does with absorbed branches on published stacks — a
behavior change that deserves its own decision. `clean` at least *names* the PR
it would close (0013 §2), so the orphan is not silent, merely late.

## Consequences

- The rename pass no longer changes PR state, and every remaining `doctor` path
  that can *strand* a PR is named above rather than left to be discovered.
- A `doctor` run on a published stack no longer pushes. That is less of a change
  than it sounds: `_doctor_finish` sets `STACK_PUSH=0`, so a squash-only run
  already left `origin` behind — the behavior is now uniform rather than
  depending on whether a rename happened to be in the mix.
- The remote tail leaves the codebase with one caller. The engine's
  `(reflow-pick, remote-sync)` plan composition is now exercised only by `fold`,
  and the two `doctor` tests that pinned its pause/abort behavior were ported
  there rather than dropped.
- A blocked renumber leaves the stack with its duplicate or out-of-order leaf
  intact. `doctor` re-detects it on the next run, so nothing is lost — but a
  script that runs `doctor --yes` and assumes a valid stack afterwards should
  check, since the exit code is 0 either way.
- `doctor` now queries `gh` on paths that previously made no network call at all
  (`--dry-run`, and any run under `--no-push`). One bulk query, and only when a
  rename is proposed. Offline and non-GitHub repos are unaffected: it is skipped
  and the pass proceeds.
- The guard necessarily runs **after** the squash phase has already mutated
  refs — the rename set isn't known until squashes and deletes have settled. So
  `doctor` does not follow `clean`'s plan-then-guard-then-mutate order, and a gh
  failure at the gate leaves a partially repaired stack rather than an untouched
  one. It degrades to "no blockers" rather than erroring, which keeps that window
  narrow, and the run's snapshot covers the whole session either way.
