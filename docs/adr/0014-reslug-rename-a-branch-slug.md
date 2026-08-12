# ADR 0014 — `reslug`: rename one branch's slug

- **Status:** Accepted (2026-08-11)
- **Context doc:** [CONTEXT.md → Language → Slug](../../CONTEXT.md#stack-shape), [CONTEXT.md → Commands → reslug](../../CONTEXT.md#branch-level)
- **Related:** [ADR 0002](0002-move-renumber-in-place.md) (the structural twin), [ADR 0013](0013-pr-state-changes-are-explicit.md) (the PR gate)

## Context

A stack branch is `<prefix>/<leaf>-<slug>` — `feat/010-auth`. Two of those three
parts had a verb that could change them; one did not:

| part                | verb                                          |
| ------------------- | --------------------------------------------- |
| prefix (`feat/`)    | `rename <new-prefix>`                          |
| leaf (`010`)        | `move --at <num>` — renumber in place (ADR 0002) |
| slug (`auth`)       | **nothing**                                    |

`fold --slug` names the *result* of a fold, so it can't rename a branch without
also destroying one. Fixing a typo in a branch name meant `git branch -m` plus
manual cleanup of whatever git-stack state referenced the old name.

## Decision

Add **`reslug [<branch>] <new-slug>`** — rename a branch's **slug**, keeping its
**leaf**.

### 1. Slug only, not the whole `<leaf>-<slug>` segment

The tempting generalisation is one verb owning the branch's whole final segment
(`reslug 020-authz`). Rejected: changing the leaf *is* a position statement even
when the branch lands in its current slot, which is `move`'s domain and settled by
ADR 0002. Subsuming it would re-open gap arithmetic, reorder-vs-in-place detection
and the placement resolver inside a verb that otherwise needs none of them.

**The disjointness is enforced, not conventional.** `_validate_slug` requires a
leading letter or underscore, so `reslug 020-x` is rejected — a leaf change cannot
be smuggled through a slug. "`reslug` never reorders" is therefore a property of
the validator, not a promise in prose.

### 2. A separate verb, not an overload of `rename`

`rename <new-prefix>` (1 arg) versus `rename <branch> <new-slug>` (2 args) was
considered and rejected twice over. The 1-arg slot is unresolvable — `rename authz`
is a valid prefix rename *and* the most common branch case — so the ergonomic form
would have to be forbidden. More decisively, ADR 0001's whole thesis was that `new`
conflating create-a-stack with add-a-branch was the defect, and the fix was two
verbs (`create`/`add`). Re-conflating a stack-level and a branch-level operation
under one verb walks that back.

`reslug` over `relabel`/`retitle`: it names the thing it changes in a word the
codebase already speaks (`_validate_slug`, `fold --slug`, `create <prefix> <slug>`),
where the alternatives would import a synonym for **slug** that earns an `_Avoid_`
entry rather than a definition. Alias `gstkrsl` — not `gstkrs`, which reads as
`gstkr` + a modifier letter, i.e. a member of the restack family.

### 3. Arity follows `git branch -m`

| arity                      | meaning                                        |
| -------------------------- | ---------------------------------------------- |
| `reslug <new-slug>`        | the current branch                             |
| `reslug <branch> <slug>`   | `<branch>` via `_resolve_branch_ref` (leaf, partial, or full name) |
| `reslug` (TTY)             | prompt, prefilling the current slug            |
| `reslug` (no TTY)          | usage error                                    |

The 0-arg TTY path uses ADR 0012's re-prompt-and-preserve loop rather than `fold`'s
one-shot read: `reslug` exists to get a name right, so looping on a rejected name
is the point. It re-prompts on bad shape, on a no-op slug, and on a collision with
another branch's slug (`_check_slug_collision`, excluding the target itself).

### 4. Structurally the twin of `move --at`

Same skeleton as the renumber-in-place path: collision check → worktree guard → PR
gate → snapshot → single-phase `[rename-batch]` engine plan. No reflow — the commit
graph is untouched.

Two deliberate divergences:

- **No clean-tree requirement.** `cmd_move` calls `require_clean_tree` because its
  *other* path reflows. `reslug` never rebases, so the index and worktree are
  untouched — exactly why `git branch -m` doesn't care either. Requiring a clean
  tree would be ceremony protecting nothing, and it would block the common case of
  fixing a name mid-work. `require_in_repo` / `require_no_op_in_progress` /
  `require_no_state_file` still apply: renaming underneath a paused engine would
  strand its captured branch set.
- **`STACK_RENAME_LABEL`.** The shared `rename-batch` phase hardcoded "move" in its
  log line and reflog message. Now a persisted global (default `move`), so `reslug`
  reports itself.

### 5. Fully local, hard PR gate

Fully local per ADR 0013 — and unlike `rename`, that costs nothing here: the stale
remote stays under the current prefix, where `clean` reaps it.

The PR gate is a **hard refuse with no escape flag**, matching `move --at` exactly.
An earlier draft gave `reslug` an `--allow-pr-orphan` escape on the theory that its
PR damage is small; that was dropped once it was clear `move --at` renames exactly
one branch too, making the damage identical and any divergence between the two
arbitrary. The escape also failed on its own terms: it left an orphaned PR for a
later `clean` to close, which is the opposite of explicit.

> **Amended by [ADR 0016](0016-single-branch-pr-desync.md).** The live objection to
> this section was cost, not correctness: the remedy it pointed at closed the
> *whole chain's* PRs to protect the one branch `reslug` renames. `pr desync` now
> takes an optional `<branch>`, so the remedy is one PR, and `reslug`'s refusal
> names that form. The no-escape-flag decision stands and is cheaper to accept.

### 6. Snapshots, and what restore does

`reslug` snapshots before mutating (focus `slug=<old> to=<new>`, rendered
`old→new` in `history`). It deliberately does **not** rewrite existing backup refs
the way prefix `rename` does: those snapshots genuinely contained `010-auth`, and
rewriting them would falsify history rather than move it.

The consequence is intentional and already handled. Backup refs are keyed by the
whole `<leaf>-<slug>` segment, so `history restore` re-creates `feat/010-auth`
beside the live `feat/010-authz` — a duplicate leaf. `_warn_duplicate_leaves`
groups by leaf *number* and already fires on exactly this shape; only its wording
needed `reslug` added.

## Consequences

- All three parts of a branch name are now addressable, by three verbs that don't
  overlap: `rename` (prefix), `reslug` (slug), `move` (leaf/position).
- `reslug` is the only mutating verb that runs with a dirty tree. Called out in
  CONTEXT.md and the help topic so it reads as deliberate.
- Undoing a `reslug` leaves a duplicate-leaf pair to reconcile via `doctor` — the
  same trade `fold` and `move` already make.
- CONTEXT.md gains a **Slug** entry (previously undefined despite `create`/`add`/
  `fold --slug` all using the word) and logs the `leaf` code-vs-docs overload under
  Flagged ambiguities.
