# ADR 0007 — `clean` reflows on local drift (walk-driven gate)

- **Status:** Accepted (2026-06-16)
- **Context doc:** [CONTEXT.md → Commands → clean](../../CONTEXT.md#stack-level), [CONTEXT.md → Reflow](../../CONTEXT.md#reflow)

## Context

`clean` reflowed only when something was **pruned** or the **base moved**. That
gate was blind to **local content drift**: insert a branch or edit a mid-stack
branch and its successors are no longer threaded on it, yet `clean` no-op'd
("stack already on origin/<default>; skipping reflow"). A user hit exactly this —
stack `020 → 025 → 030 → 050`, inserted `025` and cherry-picked part of `030`'s
diff into it, ran `clean` expecting `030+` to re-thread, got a no-op. The correct
tool was `restack`, but the goal is to make `clean` the one-stop "make this stack
correct" verb.

The old gate had two further warts: it hardwired `origin/<default>` instead of the
shared base resolver (so it ignored `stack.base`, unlike every other verb), and it
force-triggered a churning whole-stack reflow on **any** prune — rewriting every
survivor's SHA even when the survivors were already threaded.

## Decision

Replace the two-pronged `(prune ∨ base-moved)` gate with a single **ancestor
walk** over the survivors that is the sole driver of the reflow decision. Keep
`restack` as a distinct verb — it is not redundant.

### 1. The walk is the sole reflow driver

Over the survivors (branches − pruned), in stack order:

```
pred_tip(0) = base_ref
pred_tip(i) = tip(survivor[i-1])   for i >= 1
from_idx = lowest i where NOT is-ancestor(pred_tip(i), survivor[i])
```

- `from_idx` empty → stack threaded → **skip** (as before).
- `from_idx == 0` → base moved, or the bottom branch diverged off the base →
  whole-stack `restack --onto <base_ref>`.
- `from_idx > 0` → internal drift → minimal `restack --from <survivor>` (no
  `--onto`): branches below the drift point are untouched, preserving their
  SHAs and open PRs.

This unifies **moved base**, **local drift** (edit/insert), and **mid-stack prune
orphans** into one check. Worked example: after inserting `025`, `030`'s pick of
`tip(025)` fails the ancestor test at `i=2` → `restack --from 030`; `020` and
`025` are untouched. Prune is thereby demoted to a non-reflow concern — it no
longer churns the whole stack when the survivors are already threaded.

### 2. Base via the shared resolver — honors `stack.base`, offline falls out free

`pred_tip(0)` uses `_resolve_parent_ref "$(_resolve_parent_name)"`. This (a)
honors `stack.base`, fixing a `clean`-only inconsistency; (b) returns the local
trunk when no remote exists, giving offline behavior with no `--local` flag; (c)
is identical to the old target (`origin/<base>`) when a remote exists. Degenerate
case (no trunk resolves at all): skip the `i=0` check, re-thread internal drift
(`i >= 1`) only, and warn that it did not rebase onto a trunk. When `i=0` fails
against a base that **advanced**, keep the loud `base … moved` announcement;
distinguish it from a merely diverged bottom branch.

### 3. Plan-then-guard-then-mutate, with one covering snapshot

The walk is read-only, so the whole plan is computed before any mutation: fetch →
prune set → survivors → walk. A planned reflow then requires a clean tree
**before** any mutation (a prune-only run does not — a dirty tree must still
prune). One up-front `snapshot_stack` is taken when either a prune or a reflow
will happen, and the nested `restack`'s own snapshot is **suppressed**
(`_SNAPSHOT_SUPPRESS`), so a single `history restore` lands on the one
pre-mutation anchor and undoes prune + reflow together. Snapshots cover local
refs only; remote deletions are not undone by a restore.

### 4. Conflict and absorbed outcomes

The reflow is a normal reflow, so a partial-duplicate drift hits a cherry-pick
**conflict** → the engine pauses → `git stack continue` finishes the reflow tail
(prune + remote-delete + snapshot are already applied). A full-duplicate goes
**empty** → the empty-branch heal keeps the branch, and `clean` emits a
**non-mutating advisory** ("… is now empty (absorbed into …) — run `doctor` to
drop it, or `fold` to collapse"). `clean` never auto-deletes by content signal —
only by remote-gone signal; the content→deletion decision stays in `doctor`.

### 5. `restack` stays the surgical / arbitrary-onto / offline primitive

`clean`-with-a-flag could only ever equal `restack --onto <base>` (whole stack).
`restack` additionally does the partial/above-HEAD reflow `amend` relies on,
`--from <branch>`, arbitrary `--onto <ref>` re-root, and `--push`. Deleting it
would lose capability and minimal-churn, so it stays. Division of labor:

| You want… | Use |
|---|---|
| fix whole stack — prune gone, clean remotes, re-thread onto trunk | **clean** |
| re-thread after editing a branch, **no network** | **restack** |
| re-thread only from branch X up | **restack --from** |
| re-root onto an **arbitrary** ref (not the base) | **restack --onto <ref>** |
| reflow **and push** | **restack --push** |
| internal primitive for `amend` | **restack** |

## Consequences

- `clean` now re-threads after a local mid-stack edit/insert — the case the user
  reached for the wrong verb on. It can leave you in a paused reflow on conflict.
- Minimal churn: a drift above the bottom rewrites only the drifted branch and up;
  lower branches (and their PRs) are untouched.
- `clean` honors `stack.base` and works offline; the abandoned engine
  absorbed-policy is respected (no auto-delete in a paused/resumed reflow).
- Behavior change: a prune that leaves survivors threaded (e.g. removing the top
  branch) now **skips** the reflow instead of churning every survivor's SHA. The
  test encoding the old "any prune forces a reflow" rule was inverted accordingly.
- Edge of that same change: a *bottom* branch deleted **without merging** (its
  content never reached the trunk) no longer has its abandoned commits dropped —
  the survivor stays threaded through them. The realistic merged case still
  reflows, because the merge advances the base and `i=0` then fails (whole-stack
  reflow onto the new base, duplicated commits dropped).
