# ADR 0005 — `pr desync`: tear down the PR chain for clean reordering

- **Status:** Accepted (2026-06-15)
- **Context doc:** [CONTEXT.md → Language → PR sync](../../CONTEXT.md#pr-sync)

## Context

Once a stack is published with `pr sync`, reordering it is messy: every PR's
base, `[N/M]` title, and nav footer churns, and renaming a head branch
auto-closes its PR on GitHub with no way to reattach. Users want to take a stack
*off* GitHub — close the PRs — so they can reorder locally and re-publish with a
fresh `pr sync`. There was no command for this; the only existing PR-closing
path was `fold`'s indirect "delete the remote branch → GitHub auto-closes."

## Decision

Add `git stack pr desync`: the inverse of `pr sync`. For each branch, close its
open PR. `--delete-remote` also drops the remote branch; `--dry-run` previews.

### 1. "Activity" gates auto-close, and CI is excluded

A PR is closed silently only when it has no **activity** — defined as a *human*
signal: a non-bot comment, or any review a person left (an approval, a
changes-requested, or a plain *Comment* review). An open PR *with* activity
prompts `y/N` per PR on a TTY (kept if declined; skipped non-interactively
unless `--yes`).

- *Alternative:* also treat CI status checks as activity.
- *Why excluded:* CI runs on nearly every PR, so counting it would make almost
  every PR "active" and reduce the prompt to noise. Human comments come from the
  existing bot-filtered count (`select(.user.type != "Bot")`); reviews come from
  `_gh_pr_inspect`'s `latestReviews` (approvers, change-requesters, **and
  commenters** — a `COMMENTED` review never shows in `reviewDecision`, so the
  inspector surfaces its authors as a separate field) plus `reviewDecision`.
  `REVIEW_REQUIRED` alone (e.g. CODEOWNERS auto-request, no human has acted) is
  **not** activity.

Merged PRs are always skipped (they can't be closed); already-closed PRs are a
no-op skip.

### 2. Close explicitly, then delete — not "delete the branch to auto-close"

When `--delete-remote` is set, `desync` calls `gh pr close` *and then*
`git push origin --delete`, rather than relying on GitHub's
delete-branch-auto-closes behaviour (as `fold` does).

- *Why:* `close` and `delete remote` are reported as distinct actions, and an
  explicit close is the only path the test harness can verify — the gh stub
  can't model GitHub's auto-close (the branch delete hits the real bare remote,
  never the stub). Closing before deleting also avoids closing a PR whose head
  branch is already gone.

### 3. Leaf→base execution with a kept-PR base-branch guard

Phase 2 processes branches leaf→base. A branch is **never** deleted under
`--delete-remote` while it still serves as the base of a PR that was kept open
(an activity-declined PR, or one whose close failed) — deleting it would
retarget that open PR to the default branch on GitHub, defeating the very
sanity check that kept it. Such a branch is reported `keeping remote <branch>`
and left in place.

- *Why leaf→base:* deleting branch *i* affects PR *i+1* (its successor's base).
  Processing the successor first means its kept/closed status is known by the
  time we decide branch *i*'s remote fate. An `OPEN_AFTER[]` array, flipped to 0
  as each PR is (would-be) closed, makes the guard a cheap successor lookup.

Classification and confirmation happen in a no-mutation Phase 1; all effectful
writes are in Phase 2, guarded by `--dry-run`. This mirrors the
gather → reconcile → apply shape of the PR-sync reconciler (ADR 0002 /
[CONTEXT.md → Architecture → PR-sync reconciler](../../CONTEXT.md#pr-sync-reconciler-refactor-2)).

## Consequences

- First use of `gh pr close` in the codebase (helper `_gh_pr_close`).
- `desync`'s `--delete-remote` scope is tied to PRs it closes; branches with no
  PR (and the branches of merged/kept PRs) are left for `clean`. It is not a
  full remote-branch sweep.
- The gh test stub gained a `pr close` handler and a
  `/repos/.../issues/<n>/comments` handler (human-comment seeding via
  `GH_PR_NUM_<n>__HUMANCOMMENTS`).
