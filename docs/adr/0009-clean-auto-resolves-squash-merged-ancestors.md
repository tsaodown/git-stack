# ADR 0009 — `clean` auto-resolves squash-merged ancestors

- **Status:** Accepted (2026-06-29)
- **Context doc:** [CONTEXT.md → clean](../../CONTEXT.md#stack-level), [CONTEXT.md → Reflow engine](../../CONTEXT.md#reflow-engine-refactor-1)
- **Builds on:** [ADR 0007](0007-clean-reflows-on-local-drift.md) (clean reflows survivors on drift)

## Context

A merge queue can't enqueue every leaf of a stack independently, so a common move is
to **squash-merge a contiguous middle range down into a predecessor** (or into the
trunk), leaving the top PR's branch still open. Concretely, with
`main ← 020 ← 025 ← 030 ← 055 ← 060`, you squash `025…055` away (their upstreams go
`[gone]`), leaving open PRs for `020` and `060`. `060`'s branch was never rewritten, so
it still threads the **original** `025/030/055` commits.

`git stack clean` prunes the four `[gone]` branches and reflows the survivors. But the
reflow's **multi-commit guard** (`do_one_step`) refuses `060`: relative to its new
predecessor it now has several commits, and a tip-only cherry-pick "would drop all but
the tip." The guard's advice — *"pass `--force`"* — wasn't even accepted by `clean`
(it had no `--force` flag), and `--force` is the wrong remedy in general: it blindly
drops everything but the tip. The run also died **mid-reflow**, after the prune and the
bottom restack had already applied, leaving a stale state file and a half-threaded stack.

The key observation: `clean` *itself just pruned* `025/030/055` as `[gone]` (merged). It
knows their exact SHAs. So `060`'s "extra" commits are provably merged — dropping them
and keeping only `060`'s own tip is exactly right. This isn't patch-id guessing (squash
merge destroys patch-id equivalence); it's anchored on the gone-upstream signal `clean`
already trusts.

## Decision

`clean` **auto-resolves** the squash-merged-ancestor case, and refuses the genuinely
unmergeable case **atomically**.

### 1. A general engine primitive: the safe-to-drop set

Add `STACK_SAFE_DROP` to the reflow engine — commit SHAs a caller has proven merged and
the engine may therefore drop during a tip-only cherry-pick. It is serialized into the
state file (so `continue`/`abort` survive a conflict pause) and resets per run. `clean`
populates it from the branches it just pruned; other callers leave it empty.

### 2. The guard measures B's *own* commits against its *original* predecessor

When the count guard trips (`n_commits > 1`) and `--force` is off, the engine checks
whether the branch is safe to collapse: every commit between its **original**
predecessor tip (`prev_orig` in-stack, else the fork point with the onto-base) and the
branch tip, **excluding commits reachable from `STACK_SAFE_DROP`**, must be just the tip
itself. If so it cherry-picks the tip and drops the merged ancestors
(`absorb … tip-only restack, dropping N merged commit(s)`); otherwise it refuses.

Anchoring on the *original* predecessor (not the restacked one) and using structural
reachability (`git rev-list --not`, not `git cherry`/patch-id) is what makes this
correct: it counts the branch's own work directly and is immune to patch changes from a
conflict resolution on a lower branch, and `--not` excludes the merged commits' ancestors
(including a restacked predecessor's superseded commit) for free.

### 3. Pre-flight atomic refuse

`clean` runs the same safety check in its **read-only plan** (current SHAs, the gone
set). If any survivor it would reflow is unresolvable, it **refuses before pruning or
touching a ref** — no half-done state. The message leads with the usual cause (a branch
that isn't one-commit-per-branch yet): squash/rebase it and retry, with
`restack --onto <base> --force` offered as the explicit deliberate-drop escape. The
dry-run forecasts both outcomes (the tip-only collapse and the refusal). A **mixed**
stack (one resolvable survivor, one not) refuses wholesale — the direct consequence of
choosing atomicity. The engine guard stays the backstop for `restack`/`move`/`drop`.

### 4. No `clean --force`

Auto-resolve covers the safe case; the unresolvable case routes to squash/rebase or to
`restack --onto <base> --force`. Adding `--force` to `clean` would duplicate a primitive
ADR 0007 §5 deliberately placed in `restack` and blur the clean/restack division of
labor. Force stays in `restack`.

### 5. The anchor is the gone-upstream signal, not merge-verification

`STACK_SAFE_DROP` holds the SHAs of branches `clean` pruned because their upstream is
`[gone]`. `[gone]` fires for a **closed-unmerged** PR (branch deleted without merging)
just as for a merged one — so a survivor threading a closed-unmerged predecessor is
tip-only'd here too, dropping that commit. This is deliberate: `clean` already prunes
`[gone]` branches **destructively** (it deletes the local branch), so dropping their
commits from a survivor's reflow is the same accepted, **recoverable** risk — the up-front
snapshot means one `history restore @0` brings everything back. And if a dropped commit's
content is actually needed by the survivor's own tip, the tip cherry-pick **conflicts and
pauses** rather than silently producing broken code. The user-facing wording never claims
"merged" — it says **superseded** (the commits are superseded by the prune or the
restack), because the signal is gone-upstream, not merge-verified.

## Consequences

- The merge-queue squash-down workflow "just works": `clean` prunes the merged middle and
  collapses the survivor to its own commit, no flag, no manual rebase.
- Safety is anchored on the gone-upstream signal and structural reachability, never a
  patch-id heuristic — `clean` only ever drops commits it proved merged. Genuinely
  unmerged work makes it refuse, atomically.
- `STACK_SAFE_DROP` is a **general** engine primitive, now populated by both `clean` and
  `drop`. `drop` (ADR 0008) was tightened to set `STACK_SAFE_DROP=("$victim_sha")` — plus a
  precise `_reflow_own_only` pre-flight mirroring this one — in place of its old blunt
  `STACK_FORCE=1` waive, so a child carrying unmerged work of its own still refuses
  (atomically, before the victim is deleted). `--force` still waives.
- Behavior change: a survivor that previously died mid-reflow with a `--force` hint now
  either auto-resolves or refuses up front. The engine's refusal message changed wording
  ("…that aren't merged — … Squash/rebase … or pass --force …").
