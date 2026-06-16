# git-stack

`git stack` manages **stacks** of git branches that share a name **prefix** and
are ordered by a numeric **leaf**. This file fixes the vocabulary for the
stacking domain so refactors and reviews use one set of words.

It has three parts. **Language** is the established domain — concepts that exist in
today's code, README, and usage. **Commands** names the user-facing verb surface.
**Architecture** names the modules and mechanisms introduced by an architecture
review (2026-05-29). Those refactors are now built: the `engine`, the PR-sync
`reconciler`, `placement`, and the doctor `scan` all exist in `bin/git-stack`
today. One proposal — the absorbed-policy — was deliberately abandoned; see that
entry.

The **Commands** section reflects the command-vocabulary redesign (2026-06-01),
now shipped: `new` split into `create`/`add`, `close`→`clean`, `push`→`sync`,
`status` folded into `view`, plus new `pick`/`list` semantics. See
[docs/adr/0001-command-vocabulary-redesign.md](docs/adr/0001-command-vocabulary-redesign.md).

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
`continue`, and `doctor` all share (the **engine**'s **reflow-pick** phase).
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

**Desync**:
Tear down the **PR chain** — close each branch's open PR (inverse of **pr
sync**) so the **stack** can be reordered and re-synced clean. Merged/closed PRs
are left alone; PRs with **activity** prompt before closing.
_Avoid_: teardown, unsync, delete-PRs.

**Activity**:
A *human* signal on a PR — a non-bot comment, or any review a person left
(approval, changes-requested, or a plain **Comment** review). CI checks are
**not** activity. Gates whether **desync** closes a PR outright or prompts first.
_Avoid_: traffic, engagement, interaction.

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

## Commands

The verb surface splits into **stack-level** commands (act on whole stacks) and
**branch-level** commands (act within one stack). The **current stack** is always
**derived from HEAD** — the prefix of the checked-out branch — never a stored
pointer. (`stack.prefix` remains a manual override, not tool-managed state.)

Shipped 2026-06-01 per
[docs/adr/0001-command-vocabulary-redesign.md](docs/adr/0001-command-vocabulary-redesign.md).
The removed verbs (`new`/`close`/`push`/`status`) now error with a "renamed to X"
hint.

### Stack-level

**create** `<prefix> <slug>`:
Start a new stack — its first branch `prefix/<first-leaf>-slug` rooted on the
**base** (`--onto <ref>` to root elsewhere). Refuses if the prefix already has
branches (directs to **add**). Checks out the new branch. Replaces the bootstrap
path of the old `new`.

**add** `<slug>`:
Add a branch to the **current** stack (placement via flag or picker, as the old
`new` did inside a stack). Errors outside a stack, pointing at **create**/**pick**.
_Avoid_: "new" — the word that conflated create-a-stack with add-a-branch.

**pick**:
Choose a stack from the **list** selector and check out its **tip**. Works from
inside a stack too — this is how you hop *between* stacks. Lands on the tip; for a
specific branch, use **checkout**.

**list**:
Overview of *every* stack: branch count, tip, current-stack marker, **base** +
ahead/behind. Local and fast (no `gh`). Replaces the old per-stack `list` (whose
job moved to **view**). The selector **pick** and outside-a-stack **checkout**
present these same rows.
_Avoid_: reusing "list" for a single stack's branches (that is **view**).

**view** `[stack]`:
Show one stack's contents *without checking out* — the current stack, or a named
one (trailing slash optional; falls to the picker on an unknown/ambiguous name;
no current stack + no arg → picker). Folds in the old **status**: per-branch
local↔origin sync state, a one-line paused-operation banner, and the last
**snapshot**. Drops `status`'s verbose phase/unit/from-idx dump. Replaces the old
per-stack `list` and `status`.

**clean**:
Janitorial teardown of the current stack, in order: prune local `[gone]`
branches; delete extraneous **remote** branches under the prefix
(confirmation-gated — on decline, skip *only* the remote deletion and continue);
then fetch and **reflow** survivors onto `origin/<default>`. A reflow, so it can
pause on **conflict** and resume via `continue`. The reflow is **skipped** when
nothing was pruned *and* `origin/<default>` is already an ancestor of the bottom
survivor (base unchanged — the rebase would be a no-op, only churning SHAs);
any prune still forces it (a removed mid-stack branch orphans its successor's
predecessor). When the base *has* moved, `clean` announces it loudly
(`base origin/<default> moved <range>; restacking …`). Replaces `close` and the
`gstkcl`/`gstkrom`/`gstkromp` shell helpers.
_Avoid_: "close" (the prune-only predecessor).

### Branch-level

**checkout** `[N]`:
Move within the current stack — leaf `N`, or a branch picker with no arg. From
outside a stack, runs the **list** selector first, then a branch picker — vs
**pick**, which lands on the tip. Unchanged from today apart from the extracted
selector.

**sync**:
Push the whole stack to remote so remote matches local — **additive only**, never
deletes remote refs (that is **clean**'s job). No PR work, no per-branch `--from`
selection. Replaces `push` / `push --all`.
_Avoid_: "push" — the per-branch, network-detail framing.

**fold** `[branch]`:
Merge a branch away by squashing it into an adjacent neighbor (default `--down`
into the predecessor; `--up` into the successor), preserving the combined diff
as one commit and reflowing the children. The result keeps the survivor's leaf
but **defaults its slug to the victim's** (the branch you ran `fold` on names the
result); `--slug` overrides the slug, `--at` the leaf (to a free leaf below the
children — rejects a reorder). Squashes the whole range, so multi-commit / merge
branches fold cleanly. Destructive: snapshots first (undo via `history restore`,
which now warns about any duplicate-leaf leftovers a rename leaves behind),
refuses a dirty tree, prompts `[Y/n]` (default yes) and needs `--yes` off a TTY,
and errors at the stack boundaries (lone branch → **clean**). Note: because the
default slug renames the survivor, a plain `fold` closes the survivor's PR too
(not just the victim's) — `--allow-pr-rebuild` gate (the deleted victim's head PR
always closes; the survivor's whenever the slug differs), then the remote-sync
phase deletes the remote victim, re-syncs the PR
chain, and breadcrumbs the closed PR to the superseding one (ADR 0003).
_Avoid_: "squash"/"absorb" — **doctor** already owns those words (the
multi-commit fix and the tree-equals-predecessor case, respectively).

`move`, `rename`, `restack`, `amend`, `continue`, `abort`, `doctor`, `history`,
and `pr sync` / `pr list` keep their current meanings. **move** additionally
**renumbers in place** when the chosen position is the branch's current slot —
a pure leaf rename, no reflow (ADR 0002). **pr desync** closes the chain's PRs
to take a stack off GitHub for clean reordering (the inverse of **pr sync**;
ADR 0005).

### Removed verbs

`new` → **create** (new stack) or **add** (branch in the current stack).
`close` → **clean**. `push` / `push --all` → **sync**. `status` → folded into
**view**. Each removed verb errors with a one-line "renamed to X" hint rather
than a bare unknown-subcommand.

### Aliases

`gstkcr` create · `gstkad` add · `gstkp` pick · `gstkl` list · `gstkv` view ·
`gstkco` checkout · `gstks` sync · `gstkcl` clean · `gstkab` abort ·
`gstkcon` continue. Dropped: `gstkn` (was new), `gstkpa` (push --all),
`gstkrom`/`gstkromp`, and the `gstkcl` *shell function* (now the `clean` verb).
`gstkp` moves from push to pick; `gstks` moves from status to sync.

## Architecture

Vocabulary from the 2026-05-29 review naming the modules four refactors
introduced. All four are built — **#1 (reflow engine)**, **#2 (PR-sync
reconciler)**, **#3 (placement)**, and **#4's pure scan** — and these entries
describe code that exists in `bin/git-stack` today. The one exception is #4's
**absorbed-policy**, which was abandoned (see that entry).

### Placement (refactor #3)

**Placement**:
The pure module (`_placement_resolve`) deciding, for a new or relocated branch,
which **leaf** it takes and which branch becomes its **predecessor** — given the
stack's leaves, a target intent (before / after / at / last), and the **width**.
No git reads, no `die`: returns a status plus `(leaf, predecessor-or-base-sentinel)`.
Replaced the placement arithmetic formerly copy-pasted across `cmd_new`,
`cmd_move`, and `_pick_position_for_new`.

### Reflow engine (refactor #1)

**Engine**:
A single module that executes a **plan** — owning the on-disk resume
state, the `(phase, unit)` position, and `continue`/`abort` dispatch. Callers
hand it a plan instead of hand-populating `STACK_*` globals. Replaced the former
`run_reflow_loop` + scattered state machinery.

**Plan**:
What a caller hands the **engine**: an ordered list of **phases** plus the branch
set and original SHAs. Each command (`restack`, `move`, `doctor`, `rename`)
composes its own plan from shared phase types.

**Phase**:
One adapter in a **plan**, satisfying a three-operation contract — `advance`
(do one unit; report `unit-done` / `paused` / `phase-complete`), `resume`
(finish an in-flight unit, then advance), `abort` (undo this phase's effects as
far as it can). Phase types: **reflow-pick** (cherry-pick one branch;
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
The effectful read step producing **chain state**: per **active
branch**, its PR number/title/base/body, plus merged-status and titles for
**merged predecessor** candidates (selected by a pure lineage-guard helper so the
**reconciler** never touches gh). Built to minimize gh round trips: discovery is
one bulk `gh pr list` indexed in memory (not a query per branch), and a merged
predecessor is resolved from the PR's existing footer when already struck-through
there (a merge is terminal — no query), with any remaining live check memoised
per run so a predecessor shared by several PRs costs a single `gh pr view`.

**Chain state**:
**Gather**'s output and the **reconciler**'s sole input: the current GitHub state
of the **PR chain**. (Named to avoid colliding with **Snapshot**, the ref backup.)
_Avoid_: snapshot, state dump, cache.

**Reconciler**:
The pure module mapping **chain state** + stack structure to an **edit
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
The effectful write step that executes an **edit plan** (create / edit
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

### Completion

**Completion** (built 2026-06-08, ADR 0004):
git-native tab completion for `git stack`, **zsh and fish only** (bash has no
description-hint support, so it's excluded). Two-layer split:

- **`__complete`** (hidden plumbing subcommand `cmd___complete`, with
  `_complete_verbs` / `_complete_subverbs` / `_complete_leaves` /
  `_complete_prefixes`) is the **single source of truth for dynamic candidates**.
  It emits `candidate<TAB>description` lines and exits 0. Kinds: `verbs`,
  `subverbs <verb>`, `leaves [--prefix <p>]`, `prefixes`.
- **Static grammar** (which slot wants which kind, flag-value bindings) lives —
  **duplicated** — in each shell's native DSL inside `_emit_completion_zsh`
  (a `_git-stack` function zsh's `_git` auto-dispatches via its `$functions`
  table, no `compdef`/fpath) and `_emit_completion_fish`
  (`complete -c git -n '__fish_git_using_command stack' …`). Both are bundled into
  `git stack init zsh` / `init fish` alongside the aliases, so the user's existing
  rc line gains completion with no new step.

Because zsh (`complete_aliases` unset) and fish (abbrs expand on space) expand
the `gstk*` aliases before completing, the aliases inherit arg completion for free.

**Never-fail contract** (invariant of `__complete`): completion runs on every
tab, so `__complete` must **never** die, prompt, or print errors. Every
degenerate case — no repo, detached HEAD, off-stack, empty repo, unknown kind,
mid-reflow — exits 0 with empty stdout. It guards the repo check itself and uses
only the non-dying helpers (`_try_detect_prefix`, `_load_stack_branches` without
its error arg). Any leak would corrupt the user's prompt.

> **MAINTENANCE NOTE — drift surface.** The dynamic candidate lists stay correct
> for free (they derive from live repo state via `__complete`); the *static
> grammar* is hand-duplicated per shell and is what drifts. zsh and fish are
> **not symmetric** — note where each needs editing:
>
> - **Add or rename a verb** → update (a) the dispatch `case` in `main()`,
>   (b) `_complete_verbs` (the candidate source of truth — **both** shells render
>   it automatically), and (c) **fish only**: the
>   `not __fish_seen_subcommand_from …` guard list in `_emit_completion_fish`
>   (the full verb set; omit the new verb and fish keeps re-offering top-level
>   verbs after it's typed). zsh needs **nothing** for a plain verb name — it
>   completes names dynamically at `CURRENT==2`, and a verb with no special
>   positional just offers nothing after it (correct).
> - **A verb that takes special positional/value completion** (leaf number,
>   prefix, subverb) → add a zsh `case ${words[2]}` arm in `_git-stack` **and** a
>   fish `__fish_seen_subcommand_from <verb>` line.
> - **Add a flag that needs value completion** → update each shell's grammar (zsh
>   prev-word `case` + fish `complete -c git … -x` line). Flag **name**
>   completion is intentionally not provided (out of scope, v1).
> - **Add a new dynamic value type** → add a `__complete` kind (`cmd___complete`
>   case + a `_complete_*` function), then reference it from each shell emitter.
>
> So verb *names* are genuinely single-source (`_complete_verbs`); the fish guard
> duplicates the verb *set* for suppression timing only, not as a candidate list.

## Flagged ambiguities

**"parent"** — overloaded in the current code. `_resolve_parent_name` /
`_resolve_parent_ref` mean the **base** branch, but `_pr_is_empty_diff`'s
`parent` argument and several loops mean the in-stack **predecessor**. These are
two distinct concepts. Use **base** for the branch under the whole stack and
**predecessor** for the branch directly below another. Treat bare "parent" as a
smell to be replaced when touching the code.

## Example dialogue

> **Dev:** For `git stack add fix --before feat/020-login`, what leaf does it get?
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
