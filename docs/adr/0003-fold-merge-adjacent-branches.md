# ADR 0003 — `fold` merges an adjacent branch away

- **Status:** Accepted (2026-06-04)
- **Context doc:** [CONTEXT.md → Commands](../../CONTEXT.md#commands)

## Context

There is no first-class way to get rid of one branch in a stack while keeping its
work. A straight delete + reflow drops the branch's commit, so children — authored
on top of that commit — cherry-pick against a tree they were never written for,
producing conflicts or silently wrong results.

The motivating case: a commit that no longer makes sense, superseded by newer work
layered directly on top of it. The user wants a single branch carrying the *net
effect* of both, at the old position, named for the new meaning — without a delete
that breaks the cherry-pick chain.

Mechanically this is a **squash of two adjacent branches into one**, which `doctor`
already performs internally (squash adjacent commits → `_doctor_delete_branch` →
re-thread children through the reflow engine). No top-level verb exposes it
deliberately.

## Decision

Add a branch-level verb **`fold`** that collapses the named branch into an adjacent
neighbor, preserving the combined diff as one squashed commit, then reflows the
children.

`fold` is chosen over `squash` and `absorb`: `doctor` already uses "squash" for the
multi-commit-per-branch fix and "absorbed" for a branch whose tree already equals
its predecessor. A top-level verb reusing either term would blur those meanings.
`fold` is unused and reads naturally with the direction flags ("fold down into the
predecessor").

### Invocation

```
git stack fold [<branch>] [--up] [--at <num>] [--slug <s>] [-e|--edit]
               [--allow-pr-rebuild] [--no-push] [--no-sync]
               [--dry-run] [--yes] [--prefix <p>]
```

- **Victim** = `<branch>` (numeric leaf or full name) or the current branch.
- **Direction** defaults to **down** — fold into the predecessor; the **survivor**
  is the lower branch. `--up` folds into the successor (survivor = upper branch).
  Down mirrors the git fixup/autosquash idiom and is the least disruptive (every
  branch above the survivor keeps its own commit, slug, and PR).

### Result identity

The survivor keeps its identity by default; both axes are independently overridable.

- **Leaf:** defaults to the **survivor's** leaf — the result sits in the survivor's
  slot, so positions above are undisturbed. `--at <num>` overrides to any free leaf
  in the gap, validated **strictly below the lowest reflowed child** (an `--at` that
  would reorder past a child is rejected). Includes the victim's now-freed number.
- **Slug:** defaults to the **survivor's** slug. On a TTY, a prompt is pre-filled
  with it and editable (RET keeps it); `--slug <s>` sets it non-interactively.
- **Commit message:** defaults to the survivor's. `-e/--edit` opens `$EDITOR`
  pre-filled with *both* commit messages (git-squash style). Reuses `doctor`'s
  editor affordance.

The canonical workflow (the motivating case): run `fold` on the **new/upper**
branch with the default **down** direction. Survivor = the old/lower branch, so the
**leaf stays** (old position) for free, and the user **overrides the slug** to the
new meaning.

### Behavior

Given a stack `010-a, 020-b, 030-c`:

| Invocation | Result |
|---|---|
| `fold 020-b` (down, default) | `010-a' (a+b), 030-c` — survivor `a` keeps `010` + its slug; `c` reflows onto `a'`. |
| `fold 020-b --slug merged` | `010-merged (a+b), 030-c` — `010-a` renamed. |
| `fold 020-b --up` | `010-a, 030-c' (b+c)` — survivor `c` keeps `030`; branches above `c` reflow. |
| `fold 020-b --at 015` | `015-… (a+b), 030-c` — result renumbered into the open gap below `c`. |
| `fold 030-c` (tip, down) | `010-a, 020-b' (b+c)` — the tip folds down normally; no special case. |

### Boundaries (no-neighbor edges)

Hard error with a directional hint; never fold into the base branch.

| Situation | Outcome |
|---|---|
| bottom branch, down (default) | error: "nothing below to fold into; use `--up`" |
| tip branch, `--up` | error: "nothing above to fold into; use `--down`" |
| lone branch in the stack | error: "only branch in the stack; use `clean` to remove it" |

## Mechanics

Squash the **whole range** (survivor's base → victim's tip) into one commit. This
absorbs multi-commit branches and merge-commit tips on either side and restores the
one-commit-per-branch invariant — no `doctor` pre-step required.

The reflow is **conflict-free in the common case**: a squashed range yields a commit
whose tree equals the top-of-range tree, and the children sat on exactly that tree,
so they cherry-pick clean. (The exception is `--at` moving the result past a child —
rejected by validation, see above.) The operation still routes through the existing
resumable engine so `continue`/`abort` and the remote tail work uniformly, and any
unexpected conflict pauses rather than aborts.

Reuses the engine phases, composing reflow + the remote tail in one resumable plan:

```
STACK_RENAME_PAIRS=(survivor-old survivor-new)   # only when the slug changes
STACK_PHASES=(reflow-pick remote-sync)           # remote-sync dropped under --no-push
```

## PR handling

Folding mutates GitHub PRs in two ways:

- **Victim:** its head ref is deleted, so GitHub auto-closes its open head PR (no
  reattach API — the same constraint behind `move`/`rename`).
- **Survivor:** if the slug changes, the survivor is renamed, so its old head PR
  also auto-closes. If the slug is unchanged, the survivor's PR survives (force-push
  only).
- **Children:** keep their names/leaves (fold-down), so their PRs survive — `pr sync`
  re-pushes and updates each base + `[N/M]` prefix.

### Gate

Reuse `move`/`rename`'s **`--allow-pr-rebuild`**: refuse by default when the fold
would close *any* open head PR (victim always; survivor only on a slug change),
unless `--no-push`. The flag accepts the close+recreate.

### Remote tail (fold owns it)

In the resumable `remote-sync` phase, in order:

1. Delete the **remote** victim branch (this is what triggers the PR close — `fold`
   does not defer remote teardown to `clean`).
2. Run `pr sync` — rebuilds the renamed survivor's PR (if any) and updates the
   children's base + `[N/M]`.
3. Post a **breadcrumb comment** on each closed PR referencing the final
   **superseding** PR number. This runs *after* step 2 because, on a slug change,
   the superseding PR doesn't exist until `pr sync` creates it.

`--no-push` skips the whole tail; `--no-sync` skips `pr sync` (and therefore the
breadcrumb) only.

> **New machinery:** posting a comment is net-new — the tool currently only *reads*
> comments (`gh api …/comments`) and edits PR bodies/titles (`gh pr edit`). `fold`
> adds a `gh pr comment` call. The nav-footer weave (`_pr_weave_footer_triples`,
> which already strikethroughs PRs that leave the stack) is the closest prior art.

## Safety

- **Dirty tree:** refuse ("commit or stash first"). `fold` checks out and hard-resets
  the survivor; dirty work has no natural destination in a squash.
- **Snapshot:** take a `history` snapshot before applying (same machinery as
  `restack`/`amend`).
- **State file:** refuse if a reflow state file already exists (mid-flight op).
- **Confirmation:** a bare TTY run uses the current branch, down, prompts for the
  slug, then a `y/N` confirm summarizing the plan + which PRs close + the breadcrumb
  target. Non-TTY requires `--yes`.

### History-restore caveat + cleanup warning

`history restore` re-creates the deleted victim ref and resets SHAs (it emits
`update refs/heads/<branch> <sha>` with no old-value guard, so a missing ref is
created). But its model is **local commit graph only**, keyed by leaf:

- On a **slug change**, the renamed survivor (e.g. `020-newslug`) is *not* in the
  snapshot, so restore re-creates `020-oldslug` **without** removing `020-newslug` →
  a transient **duplicate leaf**.
- Remote branches and PRs are **not** reverted (true of all `history restore`).

**Refinement (this ADR):** `cmd_history_restore` emits a **contextual cleanup
warning as part of the restore action** when, post-restore, the working set has
duplicate leaves or branches not present in the snapshot — naming the specific
branches that need attention (e.g. "‹020-newslug› is a duplicate leaf left by a
prior fold; delete it or run `doctor`"). This keeps the undo honest rather than
silently leaving a malformed stack.

## Validation rules (reused, not new)

- `--at` leaf strictly between the result's predecessor and the lowest reflowed
  child (monotonic); no collision with an existing leaf; leaf `0` reserved; width
  via `_leaf_width_for` / `_format_leaf`.
- Branch resolution + "not checked out elsewhere" guards as in `move`/`rename`.

## Out of scope

- Folding non-adjacent branches, or more than two at once.
- Reopening the closed victim PR on `history restore` (remote stays out of the undo
  story).
- Auto-deleting the duplicate-leaf result on restore (warn only; `doctor` fixes it).

## Consequences

- One new branch-level verb; the `fold`/`squash`/`absorb` vocabulary stays distinct.
- One more situation that mutates GitHub PRs, covered by the existing
  `--allow-pr-rebuild` gate — plus the first PR *comment* the tool posts.
- `history restore` gains cleanup-warning output, improving the undo story for any
  operation that renames or deletes branches (not just `fold`).

## Implementation steps

1. **`bin/git-stack`**
   - `cmd_fold`: arg/flag parse, victim + direction resolution, boundary errors,
     dirty-tree refusal, slug prompt/`--slug`, `--at` validation, snapshot, the
     range squash, and engine plan assembly (`reflow-pick` + `remote-sync`).
   - Remote tail: remote victim-branch delete → `pr sync` → `gh pr comment`
     breadcrumb to the superseding PR.
   - `cmd_help`: add a `fold` entry under **Branch-level subcommands** and document
     `--up`, `--at`, `--slug`, `-e/--edit`; note the history-restore caveat in the
     `fold` blurb.
   - `cmd_history_restore`: add the post-restore duplicate-leaf / orphaned-branch
     cleanup warning.
   - Shell init (`cmd_init`): add a `gstkfo` (or similar) alias for `fold`.
2. **`CONTEXT.md`** → **Commands → Branch-level**: add a `fold` paragraph; update the
   "keep their current meanings" list; add an `_Avoid_` line distinguishing
   `fold`/`squash`/`absorb`. Add the alias to **Aliases**. Link this ADR.
3. **`docs/reference.md`**: add a "Removing a branch: `fold`" section; cross-link
   `clean` (delete) vs `fold` (merge-away).
4. **`docs/workflows.md`**: add the motivating walkthrough (obsolete commit
   superseded by newer work → `fold` down + `--slug`).
5. **`docs/pr-sync.md`**: document the breadcrumb comment + the `--allow-pr-rebuild`
   interaction for `fold`.
6. **`tests/git-stack.bats`**: cover down/up, slug default + override, `--at`
   validation (reject reorder), boundary errors, multi-commit range squash, dirty-tree
   refusal, snapshot + restore (incl. the duplicate-leaf warning), PR gate +
   `--allow-pr-rebuild`, breadcrumb, `--dry-run`, and non-TTY `--yes`.
7. **`README.md`**: add `fold` to the verb list if the happy-path surface lists verbs.
