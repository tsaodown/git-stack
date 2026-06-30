# ADR 0011 — `history` rows carry a per-operation focus

- **Status:** Accepted (2026-06-29)
- **Context doc:** [CONTEXT.md → Commands → history](../../CONTEXT.md#stack-level), [CONTEXT.md → Snapshot](../../CONTEXT.md#reflow)
- **Builds on:** [ADR 0010](0010-amend-suppresses-inner-restack-snapshot.md) (one snapshot per operation — the suppression chokepoint this feature rides)

## Context

`git stack history` rows show `action`, `run-id`, and a bare branch **count**:

```
@4   5h   amend   …-amend-2414   2
```

The count is the stack's size at snapshot time — almost never what you scan for.
Nothing on the row says *what the operation was about*. Hunting for "the amend
where I fixed the bypass handler" across dozens of rows, the count helps not at
all; you fall back to `history show` on each candidate.

A snapshot is N refs → N SHAs with no marker for *which* branch the operation
targeted, so the focus is **not recoverable** from the snapshot after the fact
(`add`'s target isn't even captured — its snapshot predates the new branch). The
verb knows its target at action time; nothing persists it.

## Decision

Record a small **focus** descriptor at action time and render it as a column in
`history`, replacing the branch count. The commit **subject is not stored** — for
the list, the focus leaf already answers "which branch," repeated amends share a
subject anyway, and `history show` surfaces the subject on demand.

### 1. Storage — a `@meta` blob under the run-id

`snapshot_stack` writes a sibling ref
`refs/stack-backup/<prefix>/<run-id>/@meta` pointing at a **blob** of structured
`key=value` lines (one per line). A blob — not a ref-path encoding — because a
compound `clean` focus (`pruned:2 base→main`) contains spaces, `:`, and `→`, all
illegal in a ref name. The descriptor is fed via a `_SNAPSHOT_FOCUS` global the
caller sets just before invoking `snapshot_stack`, mirroring `_SNAPSHOT_SUPPRESS`.

Two properties fall out of writing the blob **inside** `snapshot_stack`:

- It is the single suppression chokepoint: a suppressed snapshot
  (`_SNAPSHOT_SUPPRESS=1`) writes **no** blob. So an `amend`'s now-suppressed inner
  `restack` (ADR 0010) contributes nothing; only the outer verb's focus survives.
- It lives under the run-id, so the existing namespace delete in
  `prune_old_snapshots` cleans it for free.

`@meta` is a valid ref component (a literal `.meta` is not — git forbids a path
component beginning with `.`).

### 2. Schema — KV written per verb, composed at display time

Storage is structured data; presentation (glyphs, format) lives in one
`case "$action"` composer at print time, so a render change reflows the whole
history rather than leaving a styling seam at the point it was introduced.

| action | KV written (subset that fired) | rendered |
|---|---|---|
| `amend` / `create` | `leaf=L` | `L` |
| `add` | `leaf=L` | `+L` |
| `drop` | `leaf=L` | `−L` |
| `move` | `leaf=L pos=N` | `L→N` |
| `fold` | `result=R victim=V` | `R←V` |
| `clean` | `pruned=N base=B from=L remote=N` | `pruned:2 base→main` |
| `restack` | `from=L` \| `onto=B` | `from:L` / `onto:B` |
| `doctor` / `doctor-reflow` | `repaired=N` (or none) | `repaired:N` / `—` |

`clean` is **compound** — a single run can prune *and* reflow onto an advanced
base *and* re-thread from a drift point; the composer joins whichever segments
fired. The glyphs (`+ − ← →N`) ride along: the `action` column already names the
verb, but `←`/`→N` encode the fold relationship / move destination that the action
alone doesn't.

### 3. Display

`cmd_history_list` drops the `branches` count, adds a flexible-width `focus`
column, and moves `run-id` to **last** (it is the widest, least-scanned field —
rows are addressed by `@N`). The subject stays only in `history show`.

### 4. `@meta` is not a branch

`snapshot_branches_for` enumerates every ref under the run-id and feeds both
`history show` and `history restore`. It **must filter the `@meta` segment**, or
`restore` will try to reset a branch named `@meta` onto a blob SHA. Filtering in
`snapshot_branches_for` (one place) covers both callers; the count was the only
list-side consumer and it is gone.

### 5. Existing snapshots render `—`

Snapshots predating this feature have no `@meta` blob. The list renders `—` for
them; no backfill. Snapshots auto-prune at `stack.historyKeep` (default 100), so
the log self-heals within normal usage, and the focus leaf genuinely isn't
recoverable for an old `amend` — a backfill would be guesswork.

## Consequences

- `history` rows say what each operation did (`amend auth-guard`,
  `clean pruned:2 base→main`) instead of a stack-size count.
- Independent of ADR 0010, but composes with it: the suppression chokepoint means
  the focus blob is written exactly once per logical operation.
- New write-side surface: every mutating verb sets `_SNAPSHOT_FOCUS` before
  snapshotting. A verb that forgets simply renders `—` — degrades, doesn't break.
- The `@meta` blob is a generic per-snapshot metadata slot; future fields
  (e.g. the originating command line) can be added as KV without a schema break.
