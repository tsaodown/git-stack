# ADR 0002 — `move` renumbers a branch in place

- **Status:** Accepted (2026-06-02)
- **Context doc:** [CONTEXT.md → Commands](../../CONTEXT.md#commands)

## Context

`git stack move` resolves a destination *position* in the stack and refuses when
that position equals the source's current position:

```
move: '<branch>' is already at position N
```

This guard fires before anything considers that the branch's **leaf number** —
not its position — might be what the user wants to change. So there is no way to
renumber a branch in place. Concretely, with a stack `010, 015, 020`, renumbering
the first branch from `010` to a free leaf still below `015` (say `012`) has no
gesture: the natural

```
git stack move 010-auth --before 015-login
```

is positionally a no-op (the branch is already directly below `015`), so it
errors instead of letting the user pick a new leaf.

## Decision

When a `move` resolves to an unchanged position but the leaf *can* change, treat
it as a **renumber-in-place** rather than an error. Works for **any** branch, not
just the first — the no-op guard blocks leaf-only changes everywhere.

### Behavior

Given a stack `010-auth, 015-login, 020-cache`:

| Invocation | Result |
|---|---|
| `move 010-auth --before 015-login` | Position unchanged → **leaf picker** for the open gap below `015`. First branch's predecessor is the base, so the gap is `(0, 15)` → choose a new leaf in `1..14`. |
| `move 015-login --after 010-auth` | Position unchanged → leaf picker for gap `(10, 20)` → choose `11..19`. |
| `move 010-auth --at 12` | Renumber directly to `12`, no picker — the path for an *exact* number. |
| no-flag interactive picker landing on a no-op position | Routes to the same leaf picker. |
| picked/explicit leaf == current leaf | Graceful `already at leaf N, nothing to do` — not an error. |
| non-interactive (no TTY) + no explicit leaf | Error instructing the user to pass `--at N`. |

The picker offers curated/spread candidate leaves (via the existing
`_placement_candidates` helper). For a specific number not in the curated set,
`--at <num>` gives exact control.

### Gap computation

Reuse `_placement_candidates <ref> <before|after> <branches…>` with the **source
branch excluded** from the branch list, so the source's own current leaf is not
mistaken for a bound of its own gap. For the first branch and `--before <second>`
this yields `lo=0` (base), `hi=second_leaf`.

## Mechanics

A renumber-in-place is a **pure rename** — no commit moves, no reflow:

- The branch keeps all its commits and its predecessor; only its name changes.
- Stack predecessor is determined by leaf-sorted order, which is unchanged
  (`012 < 015 < 020`), so successors' predecessors are unaffected.
- Commits reference SHAs, not branch names, so the DAG is untouched.

Implementation reuses the existing engine phases with no `reflow-pick`:

```
STACK_RENAME_PAIRS=(old-full new-full)
STACK_PHASES=(rename-batch remote-sync)   # remote-sync dropped under --no-push
```

This is the same machinery `doctor` uses for its leaf renames. Standard snapshot
+ abort/continue safety applies.

## PR safety

Renaming a branch orphans its open GitHub PR (a head-PR cannot survive a rename).
The renumber is gated on the existing `--allow-pr-rebuild` flag, exactly like a
reordering move: refuse by default when the branch has an open PR (unless
`--no-push`), telling the user to pass `--allow-pr-rebuild` to accept the
close+recreate.

## Validation rules (reused, not new)

- New leaf must be strictly between predecessor and successor leaves (monotonic).
- New leaf must not collide with an existing leaf.
- Leaf `0` remains reserved.
- Width / formatting via existing `_leaf_width_for` / `_format_leaf`.

## Out of scope

- Full-stack re-spacing / canonical renumbering (010/020/030…) of every branch.
- Changing how `doctor` renumbers.

## Consequences

- The `"already at position N"` hard error is replaced by either a renumber or a
  softer `"already at leaf N"` no-op, depending on whether the leaf changes.
- `--at <num>` gains meaning for a branch staying in place (previously rejected).
- One more situation where `move` mutates GitHub PRs, covered by the existing
  `--allow-pr-rebuild` gate.
