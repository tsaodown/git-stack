# Recovery & repair

When a [reflow](concepts.md#reflow) stops on a conflict, when a stack drifts out
of shape, or when an operation went somewhere you didn't want — these are the
tools that get you back to a clean stack.

- [Recovering from a conflict](#recovering-from-a-conflict) — `continue` / `abort`
- [Squashing and repairing a stack](#squashing-and-repairing-a-stack) — `doctor`
- [Rolling back with history](#rolling-back-with-history) — snapshots

## Recovering from a conflict

Every reflow is a sequence of cherry-picks. If one collides, the reflow
**pauses**: git's index is left mid-cherry-pick, exactly as if you'd run the
cherry-pick by hand. Nothing is lost — the resume state is on disk and the stack
is waiting for you.

Resolve it the normal git way, then hand control back to `git stack`:

```sh
# ...edit the conflicted files...
git add <resolved-files>
git stack continue        # finishes the cherry-pick and resumes the reflow
```

`continue` completes the in-flight cherry-pick and picks the reflow back up where
it stopped — including any further branches still to replay.

If you'd rather back out entirely:

```sh
git stack abort           # restore every branch in the run to its saved original SHA
```

`abort` rewinds every branch the operation touched to the SHA it had before the
operation started. It warns about branches that were *already pushed* during the
run — `abort` restores your local refs but does **not** rewind the remote, so
you'll re-push (force-with-lease) to bring origin back in line.

A reflow's resume state is cleared **only** on full completion or an explicit
`abort` — any other exit leaves it paused and resumable.

> `git stack view` shows a one-line paused banner when a reflow is mid-flight,
> so you can see at a glance that the stack is waiting on `continue`/`abort`.

## Squashing and repairing a stack

`git stack doctor` scans the stack for structural problems and proposes fixes. By
default it's interactive; preview with `--dry-run`.

```sh
git stack doctor --dry-run        # show the issues and proposed fixes, change nothing
git stack doctor                  # interactive: prompt per issue
git stack doctor --yes            # auto-apply every fix (required for non-TTY / scripts)
git stack doctor --no-squash      # rename/dedup only, skip squash checks
git stack doctor --no-rename      # squash only, skip leaf-rename (also skips dup detection)
git stack doctor --no-push        # apply locally, skip the remote rename + pr sync
git stack doctor --no-sync        # rename the remote, but skip pr sync
```

Each issue prompts on a TTY: `y` apply, `e` (squash only) apply and edit the
message in `$EDITOR`, `N` skip (the default), `a` apply all remaining of that
kind, `q` quit. Duplicate-leaf prompts instead take a space- or comma-separated
permutation of `1..N` (RET keeps the current order). `--yes` applies everything
non-interactively using `sort -V` order for duplicates — required off a TTY.

It detects three kinds of issue:

### Squash

A branch that breaks the
[single-commit model](workflows.md#10-a-branch-grew-a-second-commit) — carrying
more than one commit (`multi`), a merge-commit tip (`merge`), or both (`both`) —
collapsed to a single commit (reset-soft + re-commit) on top of its predecessor:

```
doctor (dry-run): stack feat/
  squash  feat/020-login  (multi)
```

A branch whose tree is already identical to its predecessor's — so a reflow
cherry-pick would be empty — is classified `absorbed` (still listed under
squash) but offered for **deletion** rather than squashed. A squash that leaves
a branch empty is likewise offered for deletion.

### Duplicate leaf

Two or more branches sharing a [leaf](concepts.md#leaf) number, resolved by
renumbering. Non-interactively it uses `sort -V` order; interactively you can
supply a permutation:

```
doctor (dry-run): stack feat/
  duplicate leaf 10 (sort-V order; interactive mode lets you reorder):
    feat/010-auth
    feat/010-cache
  rename  feat/010-cache -> feat/011-cache
```

### Rename

A leaf-renumber needed to re-space the stack — for instance to open a
[gap](concepts.md#gap) that was exhausted, so an insert that previously refused
can succeed.

When renames are applied, doctor runs the same atomic rename + remote-rename +
`pr sync` flow as [`rename`](workflows.md#8-rename-the-stacks-prefix) and
[`fold`](workflows.md#13-a-branchs-change-is-obsolete-fold-it-away) (suppress the
remote tail with `--no-push`, or keep the rename but skip the PR step with
`--no-sync`), and a squash that rewrites commits triggers a reflow — so a
`doctor` repair can pause on a conflict just like any other reflow (resolve +
`git stack continue`).

## Rolling back with history

Before any mutating operation, `git stack` writes a
[snapshot](concepts.md#snapshot) — a backup of the stack's refs under
`refs/stack-backup/<prefix>/…`. List them, inspect one, or restore one:

```sh
git stack history                       # list snapshots, newest first
git stack history show @0               # show what a snapshot contains
git stack history restore @0            # roll the stack back to that snapshot
git stack history restore @0 --yes      # skip the confirmation prompt
```

```
prefix: feat/

  ref   age      action    run-id                            branches
  @0   0s       restack   1780341976-restack-66661          2
  @1   0s       amend     1780341976-amend-66661            2
```

A run-id can be given several ways: the full id, an action-tagged id, the bare
timestamp, or a relative `@N` (`@0` is the newest snapshot, `@1` the one before
it). Note that a single command can produce more than one snapshot — an `amend`
above writes both an `amend` and the `restack` it triggers.

Snapshots are auto-pruned by `git config stack.historyKeep` (default 100; `0`
disables pruning). [`clean`](workflows.md#7-the-bottom-pr-merged) also removes a
pruned branch's snapshots unless you pass `--keep-history`.

**See also:** [concepts: reflow & snapshot](concepts.md#reflow) · [workflows §10: multi-commit branches](workflows.md#10-a-branch-grew-a-second-commit)
