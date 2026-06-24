# ADR 0008 — `drop`: discard a branch and reflow its children

- **Status:** Accepted (2026-06-24)
- **Context doc:** [CONTEXT.md → Commands → drop](../../CONTEXT.md#branch-level), [CONTEXT.md → fold](../../CONTEXT.md#branch-level)

## Context

There is no verb that removes a live mid-stack branch and *discards* its work. The
neighbors each do something else:

- **`fold`** removes a branch but **preserves** its diff, squashing it into an adjacent
  neighbor (ADR 0003).
- **`clean`** only prunes branches whose upstream is `[gone]` (merged/deleted on the
  remote); it never deletes a live local branch by request (ADR 0007).
- **`move`** reorders/renumbers; it never deletes.

So "this branch was a mistake — throw it away and heal the stack" has no single verb.
Today you'd hand-rebase the children onto the predecessor and delete the branch.

## Decision

Add a **`drop`** verb: discard a branch's diff and replay its children onto the branch's
**predecessor**, throwing the dropped commits away. It is the destructive sibling of
`fold` — fold keeps the work, `drop` discards it.

```
git stack drop [branch] [--force] [--dry-run] [--yes] [--prefix P]
```

### 1. Semantics — drop the diff, tip-only replay

The children are reflowed onto the predecessor via the engine's existing **reflow-pick**
(tip-only cherry-pick). Replaying a child onto the predecessor replays the child's *own*
commit; it does **not** retroactively scrub the dropped branch's changes out of a child
that built on them — that surfaces as a normal **conflict** the user resolves and
`continue`s. Standard rebase-onto semantics, not an "as if it never existed" rewrite.

### 2. Separate verb, named `drop`

Not a flag on `fold`. Fold's entire flag surface (`--up`/`--down`/`--slug`/`--at`) is
about *where the diff lands and what the result is named* — all meaningless when the diff
is discarded, and there is no "`--up`" analog (you cannot discard a branch *and* keep it
by merging upward). The name `drop` matches the codebase's established idiom for
discarding commits (`restack`/`move` help, fold's "drop the victim").

### 3. Target and range — one mechanism, no refusing boundary

Optional leaf/name (resolved via `_resolve_branch_ref`), default current branch, single
target. The delete-then-reflow mechanism degrades cleanly at every position:

| victim position | children reflow onto | HEAD lands on |
|---|---|---|
| middle          | predecessor          | predecessor   |
| bottom          | base                 | base          |
| tip             | (none — pure delete) | predecessor   |
| lone            | (none — stack empty) | base          |

The lone-branch case **deletes + lands on base** rather than deferring to `clean` —
`clean` only prunes `[gone]` branches, so it would *not* remove a live lone branch.
`drop` is correctly more capable than `fold` here (fold needs a neighbor to fold into;
delete needs none).

### 4. Fully local — gate the victim only

`drop` touches only local refs: no push, no remote rename, no `pr sync` (the same posture
`move` took in ADR 0006). The orphaned remote branch is left for a later `clean` to reap
(silently, as `move` does).

PR gating is **narrower than `move`'s**. `move` gates every affected branch because it
*renames* them, and a rename closes the head PR / orphans it on the next `pr sync`.
`drop` does **not** rename its children — they keep their names and leaves — so each
child's PR survives and is reconcilable with a plain `pr sync` (same PR, force-pushed,
base retargeted to the new predecessor). Only the **victim** is irreversible: deleting its
head branch closes its PR with no reattach and — unlike `fold` — no superseding PR to
breadcrumb to.

So `drop` refuses **only when the victim has an open PR**, pointing at the
`pr desync → drop → pr sync` trio. Children pass through ungated.

### 5. Multi-commit children — `move`'s pre-check + `STACK_FORCE`

reflow-pick is tip-only, so a genuinely multi-commit child would lose all but its tip.
`drop` reuses `move`'s pattern: pre-check each reflowed child is ≤1 commit beyond its
*current* predecessor (`--force` waives), then set `STACK_FORCE=1` for the engine run so
the new-predecessor count — which false-positives because the child's history still
contains the dropped branch's commit — does not abort the reflow. The victim itself needs
no guard: it is discarded wholesale, so multi-commit / merge-commit victims are fine.

### 6. Destructive ceremony — mirror `fold`

`require_in_repo` / `require_clean_tree` / `require_no_op_in_progress` /
`require_no_state_file`; one pre-mutation `snapshot_stack drop` with
`STACK_SUPPRESS_REFLOW_SNAPSHOT=1` so the snapshot capturing the to-be-deleted victim is
the single restore point; `[Y/n]` default-yes confirm worded as *"discards `<victim>`'s
work"*, `--yes` required off a TTY; `--dry-run` prints the plan and stops before mutating.

### 7. Absorbed child — advise, never delete by content

If a child goes content-empty after the reflow, emit `clean`'s non-mutating advisory
(→ `doctor` / `fold`) and leave it. `drop` deletes exactly the one named branch and
nothing by content signal — deleting a second branch as a side effect would violate the
single-target contract.

## Consequences

- The verb surface is complete across the remove axis: `fold` keeps the work, `drop`
  discards it, `clean` prunes the already-gone.
- `drop` is local-only with a single-branch PR gate; the recoverable rest (children's
  stale PRs) is left to `pr sync`, the orphaned remote to `clean`.
- Implementation reuses `cmd_fold`'s delete + `_doctor_finish` shape and `cmd_move`'s
  multi-commit pre-check / `STACK_FORCE`; no new engine phases.
- **Deferred:** the lone-branch case empties a stack, leaving its `stack-backup`
  snapshots unreachable from a base HEAD (`git stack history` resolves the prefix from
  HEAD). `drop` still snapshots for undo; reaping/reachability of orphaned history for a
  dead prefix is a pre-existing gap tracked separately, not solved here.
