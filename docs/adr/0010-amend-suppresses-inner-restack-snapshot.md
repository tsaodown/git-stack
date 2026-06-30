# ADR 0010 — `amend` suppresses its inner `restack` snapshot

- **Status:** Accepted (2026-06-29)
- **Context doc:** [CONTEXT.md → Commands → amend](../../CONTEXT.md#branch-level), [CONTEXT.md → Snapshot](../../CONTEXT.md#reflow)
- **Related:** [ADR 0007 §3](0007-clean-reflows-on-local-drift.md) (`clean` takes one covering snapshot, suppresses the nested reflow's)

## Context

`cmd_amend` snapshots the stack (pre-amend SHAs), runs `git commit --amend`, then
calls `cmd_restack` to reflow the branches above. `cmd_restack` takes its **own**
snapshot. So a single amend writes **two** `history` entries — an `amend` and a
trailing `restack` — and `git stack history` shows them as adjacent pairs:

```
@3   5h   restack   …-restack-2414     ← inner snapshot from @4's amend
@4   5h   amend     …-amend-2414
```

The original code called this "intentional": the `amend` snapshot captures
pre-amend state, the `restack` snapshot captures post-amend-pre-cascade state.
But that second restore point — *keep the amended commit, un-thread the branches
above* — is a niche intermediate, and three things make it cost more than it's
worth:

- The up-front `amend` snapshot already covers **all** branches at pre-mutation
  state — it is the canonical "undo the whole amend + cascade" anchor. The inner
  `restack` snapshot is redundant relative to it.
- Its presence is **inconsistent**: amend the *top* branch and `cmd_restack`
  returns early (nothing above to reflow) **before** snapshotting, so that amend
  has no `restack` partner. Same verb, different row count depending on position.
- It is **asymmetric with `clean`**, which faced the identical nested-reflow
  situation and chose to take one covering snapshot and **suppress** the inner one
  (ADR 0007 §3). `amend` is the lone verb that still double-records; `add`,
  `move`, `fold`, and `drop` already collapse to one entry.

That asymmetry is the source of the "why is there a `restack` after every amend?"
confusion.

## Decision

`amend` adopts the same pattern `clean` uses: it keeps its own up-front snapshot as
the sole restore point and **suppresses** the snapshot the nested `cmd_restack`
would take.

Wrap the `cmd_restack` call in `cmd_amend` with `_SNAPSHOT_SUPPRESS=1` / `=0`,
exactly as `clean` does around its reflow.

**Guard — never suppress into zero restore points.** `amend` only takes its own
snapshot when a prefix is detected and the stack is non-empty. Suppress the inner
restack snapshot **only when amend's own snapshot actually fired**; otherwise let
`cmd_restack` snapshot as normal, so a restore point always exists.

The early-return case (amending the top branch) is unaffected: `cmd_restack`
returns before its snapshot regardless, so suppression is a no-op there.

## Consequences

- One `history` entry per amend. The paired `restack` rows disappear; the log is
  shorter and every row is one logical operation.
- `history restore` onto an `amend` entry lands on the full pre-amend state and
  undoes the amend **and** its cascade together — which is what restore-after-amend
  always meant in practice.
- The "keep the amend, undo only the cascade" intermediate is no longer a distinct
  restore point. No user reached for it; the pre-amend anchor plus a fresh
  `restack` reconstructs it if ever needed.
- Behavior is now uniform across every multi-step verb: the outer command owns the
  one covering snapshot, the nested reflow's is suppressed.
