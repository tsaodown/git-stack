# git-stack

`git stack` manages **stacks** of git branches that share a name **prefix** and
are ordered by a numeric **leaf**. This file fixes the vocabulary for the
stacking domain so refactors and reviews use one set of words.

It has two parts. **Language** is the established domain — concepts that exist in
today's code, README, and usage. **Proposed architecture** is design vocabulary
from an architecture review (2026-05-29): names for modules and mechanisms a set
of refactors *would* introduce. Nothing in that second section exists in the
code yet — don't go looking for an `engine` or a `reconciler` in `bin/git-stack`.

## Language

### Stack shape

**Stack**:
A series of branches sharing a **prefix**, ordered by **leaf**, each branched
off the one below it. The unit `git stack` operates on.
_Avoid_: series, chain (reserve "chain" for the **PR chain** on GitHub).

**Prefix**:
The shared leading segment of a stack's branch names — everything before the
leaf (e.g. `feat/` in `feat/010-auth`).
_Avoid_: namespace, group.

**Leaf**:
The numeric segment that orders a branch within its stack (the `010` in
`feat/010-auth`). Sparse by default (3-digit, step 10) so inserts find a gap
without renumbering.
_Avoid_: index, position number, branch number, sequence.

**Width**:
The digit-count of a stack's leaves. Sparse stacks are width 3 (`010`); legacy
stacks are width 2 (`01`). A stack has one width, derived from its first leaf.
_Avoid_: padding, size.

**Base**:
The branch the whole stack sits on top of — `main`/`master` or `stack.base`.
The lowest branch in the stack is rebased onto the base; everything else is
rebased onto its **predecessor**.
_Avoid_: parent (see Flagged ambiguities), trunk, target, upstream.

**Predecessor**:
The branch a given branch sits directly on top of — the next one down the
stack. The lowest branch's predecessor is the **base**.
_Avoid_: parent (see Flagged ambiguities), previous, prior.

**Gap**:
The unused leaf interval between two adjacent branches (open interval — both
endpoints are taken). A new branch is inserted into a gap. **Gap exhausted**: no
integer leaf fits (the gap is narrower than 2), so the insert is refused rather
than renumbering existing branches.
_Avoid_: space, room, slot.

### Reflow

**Reflow**:
Re-threading a stack: replaying each branch onto its (possibly changed)
**predecessor** so the stack stays linear after an amend, a rebase onto a new
**base**, a move, or a doctor repair. The core operation `restack`, `move`,
`continue`, and `doctor` all share (today: `run_reflow_loop` + `do_one_step`).
_Avoid_: rebase (reserve for the underlying git op), re-stack, restacking.

**Conflict**:
A cherry-pick collision during **reflow** that needs the user to resolve files
and resume. The reflow stops, leaving git's index mid-cherry-pick; `continue`
finishes it. (Distinct from a **duplicate group**, which is a leaf-number clash,
not a merge conflict.)

**Snapshot**:
A ref **backup** of a stack written under `refs/stack-backup/<prefix>/...`
before a mutating operation, so the stack can be rolled back via
`git stack history`. (`snapshot_stack`, `list_snapshots`, `cmd_history`.)
_Avoid_: backup-ref, checkpoint — and do not reuse "snapshot" for any other
captured state.

### PR sync

**PR chain**:
The set of GitHub PRs mirroring a **stack** — one PR per **active branch**, each
based on the previous branch's PR (the lowest on the **base**). The remote
counterpart of a stack.
_Avoid_: PR stack, PR series.

**Active branch**:
A stack branch with at least one commit ahead of its **predecessor**. Empty-diff
branches are filtered out — GitHub can't open a PR with no commits between base
and head.
_Avoid_: live branch, real branch.

**Nav footer**:
The fenced `<!-- git-stack:nav-start -->` … `nav-end` block in a PR body listing
the whole **PR chain** (this PR marked, **merged predecessors** struck through).
_Avoid_: stack block, chain list.

**Merged predecessor**:
A PR once in this **PR chain**, now merged and no longer an **active branch**,
still shown struck-through in the **nav footer**.
_Avoid_: landed PR, closed PR (a merged predecessor is specifically merged).

### Doctor

**Squash** (doctor issue kind):
A branch carrying more than one commit, an empty diff, or a fixup-like commit
that doctor proposes to collapse to a single commit (reset-soft + commit).
_Avoid_: fold, collapse, combine.

**Absorbed branch / Absorption**:
A branch a **squash** made redundant — its tree now matches its new
**predecessor**, so a reflow cherry-pick would be empty.
_Avoid_: redundant branch, empty branch, collapsed branch.

In practice an absorbed branch is detected and deleted (with a prompt) during
the **squash** phase, where the scan already classifies it as a `squash`
issue of kind `absorbed` (tree equality against its predecessor). The separate
"post-squash absorbed-branch sweep" in `cmd_doctor` is **provably dead code**
(verified 2026-05-30): every doctor mutation between scan and sweep is
tree-preserving (squash = reset-soft+commit, same tree; both deletes remove
tree-redundant branches), so a branch tree-equal to its effective predecessor
at sweep time was already tree-equal at scan time and thus already handled.
The sweep fires 0 times across the whole test suite. So absorption is *not*
"only knowable after squashing" — the scan catches it.

**Duplicate group**:
Two or more branches sharing a **leaf** number, which doctor resolves by
renumbering.
_Avoid_: collision, conflict (reserve "conflict" for a merge/cherry-pick
conflict).

## Proposed architecture

Design vocabulary from the 2026-05-29 review naming the modules four refactors
would introduce. Build status is noted per entry: refactors **#1 (reflow
engine)**, **#2 (PR-sync reconciler)**, **#3 (placement)**, and **#4's pure
scan** are built; #4's **absorbed-policy** was abandoned (see that entry). Names
without a status note still describe code that exists after those refactors.

### Placement (refactor #3)

**Placement**:
A proposed pure module deciding, for a new or relocated branch, which **leaf** it
takes and which branch becomes its **predecessor** — given the stack's leaves, a
target intent (before / after / at / last), and the **width**. No git reads, no
`die`: returns a status plus `(leaf, predecessor-or-base-sentinel)`. Replaces the
placement arithmetic currently copy-pasted across `cmd_new`, `cmd_move`, and
`_pick_position_for_new`.

### Reflow engine (refactor #1)

**Engine**:
A proposed single module that executes a **plan** — owning the on-disk resume
state, the `(phase, unit)` position, and `continue`/`abort` dispatch. Callers
would hand it a plan instead of hand-populating `STACK_*` globals. Replaces
today's `run_reflow_loop` + scattered state machinery.

**Plan**:
What a caller hands the **engine**: an ordered list of **phases** plus the branch
set and original SHAs. Each command (`restack`, `move`, `doctor`, `rename`) would
compose its own plan from shared phase types.

**Phase**:
One adapter in a **plan**, satisfying a three-operation contract — `advance`
(do one unit; report `unit-done` / `paused` / `phase-complete`), `resume`
(finish an in-flight unit, then advance), `abort` (undo this phase's effects as
far as it can). Proposed phase types: **reflow-pick** (cherry-pick one branch;
can pause on **conflict**; carries an **absorbed-policy**), **rename-batch**
(atomic local ref rename), **remote-sync** (remote rename + PR sync; idempotent).
_Avoid_: step, stage, pass.

**Unit**:
One increment of work within a **phase** — for reflow-pick, one branch. The
engine persists only the coarse `(phase, unit)` position; each phase recovers its
own fine-grained in-flight state (reflow-pick from git's `CHERRY_PICK_HEAD`;
remote-sync from idempotent re-run).

**Paused**:
The state after a **phase** stops mid-**plan** needing the user to act (a
reflow-pick **conflict**, a stale-lease push, a gh-auth failure). Resume state is
retained on disk; the user resolves and runs `continue`. It is cleared **only**
on full-plan completion or explicit `abort` — every other exit is paused and
resumable.
_Avoid_: stopped, suspended, blocked.

**Absorbed-policy** (DISCARDED — see "Doctor scan (refactor #4)"):
Per-**plan** data telling **reflow-pick** what to do on an **absorbed** branch:
`skip`/`error` for `restack`, `prompt-then-delete` for doctor. Not built: the
post-squash sweep this would have served is dead code, and `prompt-then-delete`
can't run inside the engine anyway (a paused/resumed reflow has no TTY).

### PR-sync reconciler (refactor #2)

**Gather**:
The proposed effectful read step producing **chain state**: per **active
branch**, its PR number/title/base/body, plus merged-status and titles for
**merged predecessor** candidates (selected by a pure lineage-guard helper so the
**reconciler** never touches gh).

**Chain state**:
**Gather**'s output and the **reconciler**'s sole input: the current GitHub state
of the **PR chain**. (Named to avoid colliding with **Snapshot**, the ref backup.)
_Avoid_: snapshot, state dump, cache.

**Reconciler**:
A proposed pure module mapping **chain state** + stack structure to an **edit
plan**. Owns every PR-presentation rule: the `[N/M]` position prefix,
strikethrough on position change, **nav footer** rendering, **merged
predecessor** weaving, and change detection (normalized so a GitHub body
round-trip doesn't emit a spurious edit). No gh access. Extracts the logic
currently inline in `cmd_pr_sync` pass 2.
_Avoid_: syncer, updater.

**Edit plan**:
The **reconciler**'s output: per PR, either create-needed or the desired
title/body/base with which fields changed. **Apply** executes it; `--dry-run`
prints it.
_Avoid_: diff, changeset.

**Apply**:
The proposed effectful write step that executes an **edit plan** (create / edit
PRs). Same code path as the **engine**'s remote-sync **phase**.

### Doctor scan (refactor #4) — BUILT (scan), absorbed-policy ABANDONED

**Scan** (built 2026-05-30):
A pure function `_doctor_scan` mapping a **stack**'s shape to an **issue** list —
the same "pure core" role the **reconciler** plays for PR sync. Idempotent and
gh-free: it takes pre-gathered git facts from the effectful `_doctor_gather`
(per branch: tree SHA, commit count, merge-tip flag) and emits issues, so it's
unit-testable without a TTY or fixture repo. `cmd_doctor` runs
`gather → scan → bucket → dry-run/prompt/apply`. The squash-kind classification
is itself a pure helper, `_doctor_squash_kind_pure`.
_Avoid_: check, lint, diagnose.

**Issue** (built):
A data record `_doctor_scan` emits, one TSV line, kind tag first:
`squash<TAB><idx><TAB><kind>`, `dup<TAB><leaf><TAB><idx_csv>`,
`rename<TAB><old><TAB><new>`. Drives the interactive prompt and the **plan**
doctor hands the **engine**.
_Avoid_: problem, finding, warning.

**Absorbed-policy — abandoned.** The planned #4 follow-up (fold the post-squash
sweep into a `reflow-pick` **absorbed** outcome gated by a per-**plan**
absorbed-policy) was **not built**: the sweep is dead code (see **Absorbed
branch** above), so there is nothing to move into the engine. The reachable
absorbed handling already lives in the squash phase (detect + prompt + delete at
scan time). The **Absorbed-policy** entry under "Reflow engine" below is a
discarded proposal, not a target.

## Flagged ambiguities

**"parent"** — overloaded in the current code. `_resolve_parent_name` /
`_resolve_parent_ref` mean the **base** branch, but `_pr_is_empty_diff`'s
`parent` argument and several loops mean the in-stack **predecessor**. These are
two distinct concepts. Use **base** for the branch under the whole stack and
**predecessor** for the branch directly below another. Treat bare "parent" as a
smell to be replaced when touching the code.

## Example dialogue

> **Dev:** For `git stack new fix --before feat/020-login`, what leaf does it get?
>
> **Expert:** It looks at the gap below `020` — say the predecessor is
> `010-auth`. The open gap is 11–19, so it picks the midpoint, `015`. The
> predecessor of the new branch is `feat/010-auth`.
>
> **Dev:** And if I insert before the lowest branch?
>
> **Expert:** Then there's no branch below it, so its predecessor is the base.
> The gap is 1 up to the lowest leaf.
>
> **Dev:** What if the gap is too tight — `--before feat/011-x` when `010` is
> right below?
>
> **Expert:** Gap exhausted. It refuses; it never renumbers `010` to make room.
> You'd reflow with `doctor` or pick another spot.
