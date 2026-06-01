# Concepts

The vocabulary `git stack` is built around. Everything in [workflows.md](workflows.md)
leans on these terms.

## Stack

A series of branches that share a name **prefix** and are ordered by a numeric
**leaf**, each branched off the one below it. The stack is the unit `git stack`
operates on.

```
feat/010-auth      ← bottom (sits on the base)
feat/020-login     ← sits on feat/010-auth
feat/030-profile   ← top, sits on feat/020-login
```

`git stack` infers the current stack from the branch you're on. You can override
detection with `git config stack.prefix feat/` or `--prefix`.

## Prefix

The shared leading segment of a stack's branch names — everything before the
leaf. In `feat/010-auth` the prefix is `feat/`. A stack has exactly one prefix;
renaming it (`git stack rename`) moves the whole stack at once.

## Leaf

The numeric segment that orders a branch within its stack — the `010` in
`feat/010-auth`. Leaves are **sparse** by default: fresh stacks use 3 digits and
step by 10 (`010`, `020`, `030`), so there's room to insert a branch between two
others without renumbering anything.

### Width

The digit-count of a stack's leaves. Sparse stacks are width 3 (`010`); older
"legacy" stacks created before sparse numbering are width 2 (`01`) and keep that
width. A stack has one width, derived from its lowest leaf.

## Gap

The unused leaf interval between two adjacent branches. Inserting a branch picks
the **midpoint** of a gap — `new --after feat/010-auth` on a `010`/`020` stack
lands at `015`.

**Gap exhausted:** when no whole number fits between two neighbors (e.g. trying
to insert between `01` and `02` on a tightly-packed legacy stack), the insert is
*refused* rather than renumbering existing branches. Pick another spot or run
[`doctor`](doctor.md) to re-space the stack.

## Base

The branch the whole stack sits on top of — usually `main` or `master`, or
whatever `git config stack.base` names. The lowest branch in the stack is rebased
onto the base; everything above is rebased onto its **predecessor**.

## Predecessor

The branch a given branch sits directly on top of — the next one down. In the
example above, `feat/020-login`'s predecessor is `feat/010-auth`. The lowest
branch's predecessor is the **base**.

## Reflow

Re-threading the stack: replaying each branch onto its (possibly changed)
predecessor so the stack stays linear. A reflow runs automatically after you
amend the bottom, rebase onto a new base, move a branch, or let `doctor` repair
the stack. Under the hood it's a sequence of cherry-picks, one per branch.

If a cherry-pick collides, the reflow **pauses** on a [conflict](doctor.md#recovering-from-a-conflict)
— you resolve the files, `git add` them, and run `git stack continue`, or back
the whole thing out with `git stack abort`.

## Snapshot

A backup of the stack's refs, written before any mutating operation, so you can
roll back. List them with `git stack history` and restore one with
`git stack history restore`. See [doctor.md](doctor.md#rolling-back-with-history).

## PR chain

The set of GitHub PRs mirroring a stack — one PR per **active branch**, each
based on the previous branch's PR (the lowest one targets the **base**). It's the
remote counterpart of a stack, kept in sync by `git stack pr sync`. See
[pr-sync.md](pr-sync.md).

### Active branch

A stack branch with at least one commit ahead of its predecessor. Empty-diff
branches are skipped in the PR chain — GitHub can't open a PR with no commits
between base and head.

### Nav footer

A fenced block `git stack pr sync` maintains in each PR body, listing the whole
PR chain with the current PR marked and merged predecessors struck through.
