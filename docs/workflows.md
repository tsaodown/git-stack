# Workflows

Real development situations and how to navigate them with `git stack`. Each
scenario stands on its own — skim for the one you're in. New to the vocabulary
(*stack*, *leaf*, *reflow*, *predecessor*)? Start with [concepts.md](concepts.md).

The examples use a three-branch stack on the `feat/` prefix:

```
feat/010-auth → feat/020-login → feat/030-profile
```

Output blocks are captured from real runs; commit SHAs will differ for you.

| # | Scenario |
|---|----------|
| [1](#1-start-a-new-stack) | Start a new stack |
| [2](#2-review-feedback-lands-on-the-bottom-branch) | Review feedback lands on the bottom branch |
| [3](#3-main-moved-underneath-you) | `main` moved underneath you |
| [4](#4-you-need-a-branch-in-the-middle) | You need a branch in the middle |
| [5](#5-the-branches-are-in-the-wrong-order) | The branches are in the wrong order |
| [6](#6-publish-and-refresh-the-pr-chain) | Publish and refresh the PR chain |
| [7](#7-the-bottom-pr-merged) | The bottom PR merged |
| [8](#8-rename-the-stacks-prefix) | Rename the stack's prefix |
| [9](#9-push-or-reflow-only-part-of-the-stack) | Push or reflow only part of the stack *(advanced)* |
| [10](#10-a-branch-grew-a-second-commit) | A branch grew a second commit *(advanced)* |
| [11](#11-pull-a-branch-out-of-the-middle) | Pull a branch out of the middle *(advanced)* |
| [12](#12-sharing-a-stack-with-someone-else) | Sharing a stack with someone else *(advanced)* |
| [13](#13-a-branchs-change-is-obsolete-fold-it-away) | A branch's change is obsolete: fold it away |
| [14](#14-reorganize-a-stack-thats-already-on-github) | Reorganize a stack that's already on GitHub |
| [15](#15-you-edited-a-mid-stack-branch-by-hand) | You edited a mid-stack branch by hand |

---

## 1. Start a new stack

**Situation.** You're starting a feature that's too big for one PR. Build it as a
stack from the start so each piece reviews independently.

`create` and `add` build the stack for you. From `main` (or anywhere outside a
stack), `create <prefix> <slug>` starts the stack — it creates the bottom branch
off the base, picks a sparse leaf, and checks it out. From then on `add <slug>`
infers the prefix and appends the next branch:

```sh
git stack create feat auth          # start: creates & checks out feat/010-auth
# ...write code, commit...
git stack add login                 # appends feat/020-login, checks it out
# ...write code, commit...
git stack add profile               # appends feat/030-profile
# ...write code, commit...

git stack view
```

```
parent: main  [up to date]

  feat/010-auth  [unpushed]
    af95ef5  add auth
  feat/020-login  [unpushed]
    fd25cd4  add login
* feat/030-profile  [unpushed]
    e617449  add profile
```

**What happened.** `create`/`add` each made an empty branch and checked it out;
after you commit into it, the branch carries your work. `git stack view` infers
the stack from the `feat/` prefix, orders the branches by their leaf, marks the
one you're on with `*`, and shows each branch's sync state against its remote —
here `[unpushed]`, since nothing's been pushed yet. (`git stack list` gives the
zoomed-out view: one line per stack across the whole repo.)

**Uncommitted work in the tree?** Neither verb makes you stash first — both carry
your changes onto the new branch. `add` does it silently; `create` asks before
carrying onto a fresh stack (or pass `--stash` to skip the prompt — required when
there's no terminal, e.g. in a script). The carry mechanics are spelled out in
[scenario 4](#4-you-need-a-branch-in-the-middle).

You don't have to use `create`/`add` — `git stack` adopts any branch whose final
path segment looks like `<number>-<slug>`, so building the stack the plain-git
way (`git checkout -b feat/010-auth`, commit, repeat) works just as well.

Use **leaf numbers** to move around the stack instead of typing full branch
names:

```sh
git stack checkout 10      # checks out feat/010-auth (numeric match)
git stack checkout         # no number → interactive picker (fzf if installed)
```

**See also:** [concepts: stack & leaf](concepts.md#stack) · [publish the chain](#6-publish-and-refresh-the-pr-chain)

---

## 2. Review feedback lands on the bottom branch

**Situation.** Your stack is pushed and the PR chain is open. A reviewer asks for
a change on the *lowest* branch (`feat/010-auth`). Fixing it rewrites that
branch's commit — so every branch above it now sits on a stale parent and must be
replayed.

```sh
git stack view
```

```
parent: origin/main  [up to date]

  feat/010-auth  [synced]
    52b6644  add auth
  feat/020-login  [synced]
    436ae30  add login
* feat/030-profile  [synced]
    0a94f56  add profile
```

Jump to the bottom branch by its leaf number, make the fix, and amend. `amend`
does **not** auto-stage tracked edits — stage them yourself, or hand the paths to
`amend` directly:

```sh
git stack checkout 10          # checks out feat/010-auth by leaf number
# ...edit auth.txt to address the feedback...
git stack amend -m "add auth (with validation)" -- auth.txt
```

```
[feat/010-auth e537cbe] add auth (with validation)
restack feat/020-login onto feat/010-auth
restack feat/030-profile onto feat/020-login
done    reflow complete (2 branches restacked)
```

**What happened.** `amend` amended the bottom branch, then **reflowed** the rest:
it cherry-picked `feat/020-login` onto the new `feat/010-auth`, then
`feat/030-profile` onto the new `feat/020-login`. Every branch above the one you
touched gets a new tip SHA and now sits ahead of *and* behind its remote — the
divergence grows as you climb, since each branch carries every rewritten commit
below it:

```sh
git stack view
```

```
parent: origin/main  [up to date]

* feat/010-auth  [+1/-1]
    e537cbe  add auth (with validation)
  feat/020-login  [+2/-2]
    bea3500  add login
  feat/030-profile  [+3/-3]
    4816a60  add profile
```

Publish the rewritten stack with `git stack sync` (force-with-lease on every
branch) — each returns to `[synced]` — then re-run `git stack pr sync` to refresh
the PR chain.

If a cherry-pick hits a conflict mid-reflow, the reflow pauses — resolve it and
run `git stack continue`, or back out with `git stack abort`. See
[doctor.md](doctor.md#recovering-from-a-conflict).

**See also:** [push & the PR chain](pr-sync.md) · [concepts: reflow](concepts.md#reflow)

---

## 3. `main` moved underneath you

**Situation.** A teammate merged to `main` while you were working. Your stack is
built on the old `main` and you want it rebased onto the new tip.

```sh
git stack clean      # fetch, prune any merged branches, reflow the stack onto origin/<default>
git stack sync       # republish the rewritten branches
```

```
fetching all remotes...
base    origin/main moved a1b2c3d..e4f5a6b (+3 commit(s)); restacking 2 survivor(s) onto it
restack feat/010-auth onto origin/main
restack feat/020-login onto feat/010-auth
done    reflow complete (2 branches restacked)
```

**What happened.** `clean` is the one-verb catch-up — the successor to the old
`gstkrom`/`gstkromp` shortcuts. It fetches, prunes any stack branch whose PR has
already merged (`[gone]`), offers to delete leftover remote branches under the
prefix (decline to skip), then reflows the survivors onto the advanced
`origin/<default>`. `sync` then force-with-lease-pushes the rewritten branches.

If you want *only* the rebase — no pruning, no remote tidy — reach for the
surgical verb instead (`--push` republishes each branch as it lands):

```sh
git fetch origin
git stack restack --onto origin/main --push
```

**See also:** [the merge/teardown flow](#7-the-bottom-pr-merged) · [partial reflow](#9-push-or-reflow-only-part-of-the-stack)

---

## 4. You need a branch in the middle

**Situation.** Mid-stack you realize a piece of work belongs *between* two
existing branches — a cache layer between `auth` and `login`, and some prep below
`auth`.

```sh
git stack add cache --after feat/010-auth     # insert just above auth
git stack add prep  --before feat/010-auth    # insert just below auth
git stack view
```

```
add     feat/015-cache (from feat/010-auth)
add     feat/005-prep (from main)
parent: main  [up to date]

* feat/005-prep  [unpushed]
    ca31a04  init
  feat/010-auth  [unpushed]
    9c21fbc  add auth
  feat/015-cache  [unpushed]
    9c21fbc  add auth
  feat/020-login  [unpushed]
    0810293  add login
  feat/030-profile  [unpushed]
    281d1f9  add profile
```

**What happened.** Each insert picks the **midpoint** of the [gap](concepts.md#gap):
`--after feat/010-auth` lands at `015` (between `010` and `020`); `--before
feat/010-auth` lands at `005` (between the base and `010`), so its predecessor is
`main`. No existing branch is renumbered.

`add` never touches **other branches** — it creates one empty branch (its tip
equals its predecessor's, which is why `015-cache` shows the same SHA as
`010-auth` until you commit). It does carry any **uncommitted work** onto the new
branch, though: when the insert lands on your current commit the changes ride
along on the checkout (staged-ness preserved); when it lands elsewhere — like the
`--before`/`--after` inserts above — `add` stashes the diff and pops it onto the
new branch. If that pop conflicts it leaves the markers in place, keeps the stash
entry, and warns rather than aborting. (`create` carries the same way but asks
first, or takes `--stash`.) Other placements:

```sh
git stack add fix --at 7      # explicit leaf → feat/007-fix
git stack add                 # interactive picker (ref, before/after, leaf)
```

If the gap is too tight to fit a whole number, the insert is **refused** rather
than cascading a renumber:

```
git-stack: error: add --before feat/02-b: no insertable leaf between 1 and 2 (gap exhausted); pick a different position or wait for doctor-reflow
```

Pick another spot, or re-space the stack with [`doctor`](doctor.md).

**See also:** [concepts: gap](concepts.md#gap) · [reorder branches](#5-the-branches-are-in-the-wrong-order)

---

## 5. The branches are in the wrong order

**Situation.** You built `auth → login → profile` but realize `profile` should
come *before* `login`.

```sh
git stack move feat/030-profile --before feat/020-login
git stack view
```

```
restack feat/020-login onto feat/030-profile
done    move complete (+1 renames)
done    reflow complete (2 branches restacked)
parent: main  [up to date]

  feat/010-auth  [unpushed]
    bb660f6  add auth
* feat/030-profile  [unpushed]
    a889a38  add profile
  feat/031-login  [unpushed]
    c0ff08d  add login
```

**What happened.** `move` relocated `feat/030-profile` below `login`, then
reflowed: `login` was cherry-picked onto its new predecessor and **renumbered** to
`031` to keep the leaf order consistent (`+1 renames`). Moving a branch changes
branch names and tip SHAs by definition.

> **Heads up — open PRs.** `move` is **fully local**: it touches only local refs,
> never pushing or syncing. So if an affected branch has an open PR, the move would
> leave that PR stranded on its old remote branch and a later `pr sync` would orphan
> it. `move` **refuses** in that case and points you at the clean trio: run
> [`pr desync`](pr-sync.md#git-stack-pr-desync) to take the stack offline, reorder
> locally, then [`pr sync`](pr-sync.md) to re-publish — walked through end-to-end
> in [scenario 14](#14-reorganize-a-stack-thats-already-on-github). (Unpublished
> stacks reorder freely.)

**Renumber a branch without moving it.** Sometimes you don't want to reorder —
you just want to change a branch's leaf number (e.g. your stack is `010, 015, 020`
and you want the bottom branch at `012` to open room below it). Point `move` at
the branch's *current* slot and it renumbers in place instead of erroring:

```sh
git stack move feat/010-auth --at 12              # exact leaf
git stack move feat/010-auth --before feat/015-b  # TTY: pick a leaf in the gap
```

This is a **pure rename** — no commits move, no reflow, every other branch
untouched. It's still local-only, so the same open-PR rule applies: if the branch
has an open PR, `pr desync` first, renumber, then `pr sync`
([scenario 14](#14-reorganize-a-stack-thats-already-on-github)).

**See also:** [insert a branch](#4-you-need-a-branch-in-the-middle) · [rename the prefix](#8-rename-the-stacks-prefix)

---

## 6. Publish and refresh the PR chain

**Situation.** The stack is ready for review, or you've changed it and the PRs are
now stale.

```sh
git stack pr sync
```

`pr sync` pushes any unpushed branches, opens a **draft PR per branch** (each
based on the branch below it, the bottom on `stack.base`), and keeps every PR's
title (`[N/M]` prefix + the branch's latest commit subject) and stack-navigation
footer in sync. Re-run it after *any* structural change — new branch, removed
branch, reorder — or after rewording a commit, to bring the PRs back into
alignment. It's idempotent: PRs already matching aren't touched.

```sh
git stack pr sync --ready       # open as ready-for-review instead of drafts
git stack pr sync --dry-run     # show planned actions, make no remote calls
git stack pr list               # inspect the chain
```

Inspecting the chain with `pr list` shows a three-line block per branch —
branch + PR number, then status badges, then the title:

```
* feat/010-auth   #41  (2c)
    [synced] [draft] [approved: alice]
    add auth

  feat/020-login  #42
    [synced] [draft] [changes: bob]
    add login

  feat/030-profile
    (no PR)
```

> The `[approved]` / `[changes]` / `[checks: …]` badges and the comment count
> depend on live review state, so the block above is illustrative. The full badge
> legend and the mechanics of how the chain is built live in
> [pr-sync.md](pr-sync.md).

Requires [`gh`](https://cli.github.com/) authenticated for github.com.

**See also:** [pr-sync.md](pr-sync.md) · [bottom PR merged](#7-the-bottom-pr-merged)

---

## 7. The bottom PR merged

**Situation.** The bottom PR (`feat/010-auth`) merged and GitHub deleted its
branch. You want to drop the merged branch locally and rebase the rest onto the
updated base.

After a fetch, the merged branch shows `[gone]` — its upstream no longer exists:

```sh
git stack view
```

```
parent: origin/main  [up to date]

  feat/010-auth  [gone]
    63aeaec  add auth
* feat/020-login  [synced]
    0ea1619  add login
  feat/030-profile  [synced]
    45b2df8  add profile
```

Preview, then tidy the stack:

```sh
git stack clean --dry-run
```

```
prune   1 local branch(es) with gone upstream:
  delete  feat/010-auth (63aeaec)
  (no matching backup refs)

dry run: would reflow 2 survivor(s) onto origin/main; rerun without --dry-run to apply
```

```sh
git stack clean       # prune [gone] branches, tidy the remote, reflow onto origin/main
git stack pr sync     # re-point the chain
```

**What happened.** `clean` does the whole teardown in one pass: it fetches and
prunes, deletes every stack branch whose upstream is `[gone]` (along with their
snapshot refs — pass `--keep-history` to keep backups), offers to delete any
remote branches under the prefix with no local counterpart (a confirmation you
can decline — it skips only that step), then reflows the surviving branches onto
the now-advanced `origin/main`. `pr sync` repoints the remaining PRs. `clean`
replaces the old `close` verb and the `gstkrom`/`gstkcl` shell helpers.

**See also:** [main moved](#3-main-moved-underneath-you) · [rolling back](doctor.md#rolling-back-with-history)

---

## 8. Rename the stack's prefix

**Situation.** You started on `feat/` but the work is really a `fix/`. Rename the
whole stack at once.

```sh
git stack rename fix/ --dry-run    # preview the old→new mapping
git stack rename fix/              # feat/010-auth → fix/010-auth, etc.
```

**What happened.** `rename` atomically renames every branch from `<old>/<leaf>` to
`<new>/<leaf>`, carrying backup refs along. It refuses if a reflow is in progress,
a branch is checked out elsewhere, or any target name already exists.

> **Heads up — open PRs.** `rename` changes every head branch name, and GitHub
> closes a PR when its head branch is renamed (no reattach). So it **refuses if any
> branch has an open head PR**. Pass `--allow-pr-rebuild` to let those PRs close and
> reopen on the next sync, or run [`pr desync`](pr-sync.md#git-stack-pr-desync) first
> to re-publish cleanly ([scenario 14](#14-reorganize-a-stack-thats-already-on-github)).
> Use `--no-history` to skip carrying backup refs.

**See also:** [reorder branches](#5-the-branches-are-in-the-wrong-order)

---

## 9. Push or reflow only part of the stack

*(advanced)*

**Situation.** The bottom branches are settled; you've only been reworking the
upper part of the stack. You want to reflow a given branch and everything above
it, not the whole stack — and push just the part you touched.

```sh
git stack restack --from feat/020-login            # re-thread feat/020-login and every branch above it
git stack restack --from feat/020-login --push     # ...and push each as it reflows
git stack sync                                      # (for contrast) push the whole stack
```

**What happened.** `restack --from X` re-threads **X and every branch above it**,
cherry-picking each onto its predecessor's new HEAD. So X is the *lowest* branch
that gets rewritten; it replays onto its own predecessor (here `feat/010-auth`),
which stays put — as does everything below X. With **no** `--from`, the reflow
starts one higher, at the current branch's child: the branch you're standing on
is the fixed base and only the branches above it move. Adding `--push`
force-with-leases each rewritten branch as it finishes, so you push only the part
from X up. `sync` is the all-or-nothing counterpart: it pushes every branch in the
stack additively, no per-branch selection. (The old `push --from`/`push --all`
per-branch push paths are gone — use `restack --push` for partial, `sync` for
whole-stack.)

**See also:** [main moved](#3-main-moved-underneath-you)

---

## 10. A branch grew a second commit

*(advanced)*

**Situation.** `git stack` treats each branch as **one commit** on top of its
predecessor (mirroring `git reset --hard <prev> && git cherry-pick <tip>`). If a
branch accumulates more than one commit, a plain `restack` refuses rather than
silently dropping work:

```
git-stack: error: branch 'feat/030-profile' has 2 commit(s) beyond its predecessor; restack would drop all but the tip. Squash/rebase 'feat/030-profile' to a single commit and retry, or pass --force to cherry-pick the tip and deliberately drop them.
```

**How to navigate it.** You have three options:

- **Prefer `amend`** for changes to an existing branch — it captures the pre-amend
  SHA up front, so the single-commit model holds and the reflow stays clean. This
  is the normal path (see [scenario 2](#2-review-feedback-lands-on-the-bottom-branch)).
- **Squash first**, then restack — collapse the branch to one commit yourself
  (`git rebase -i`), or let [`doctor`](doctor.md#squashing-and-repairing-a-stack)
  detect and squash multi-commit branches for you.
- **`restack --force`** *only* if you genuinely want just the tip commit kept;
  intermediate commits on that branch are dropped.

**See also:** [doctor.md](doctor.md#squashing-and-repairing-a-stack) · [concepts: reflow](concepts.md#reflow)

---

## 11. Pull a branch out of the middle

*(advanced — recipe, not a single command)*

**Situation.** A middle branch (`feat/020-login`) turned out to be unnecessary and
you want it gone, with its changes removed from the branches above it.

> **Don't just `git branch -D` it.** Deleting the ref leaves the branch's commit
> sitting in the history of every branch above it — `feat/030-profile` would still
> contain login's changes, and `restack` would refuse it as a multi-commit branch
> (see [scenario 10](#10-a-branch-grew-a-second-commit)).

The reliable recipe is to **move the unwanted branch to the top, then delete it** —
the move reflows the branches that were above it down onto its old predecessor,
cleanly extracting its changes:

```sh
git stack move feat/020-login --last
git stack view
```

```
restack feat/020-login onto feat/030-profile
done    move complete (+1 renames)
done    reflow complete (2 branches restacked)
parent: main  [up to date]

  feat/010-auth  [unpushed]
    27a69b6  add auth
* feat/030-profile  [unpushed]
    a8e8c48  add profile
  feat/031-login  [unpushed]
    973b9c9  add login
```

`feat/020-login` is now at the top, renumbered to `031-login`, and
`feat/030-profile` has been reflowed straight onto `feat/010-auth` — its changes
no longer carry login. Now delete the top branch:

```sh
git stack checkout 10        # switch off the branch we're about to delete
git branch -D feat/031-login
```

`feat/030-profile` now contains only `auth` + `profile`; login is gone entirely.
The `move` is local, so if the branch you're removing has an open PR, run
[`pr desync`](pr-sync.md#git-stack-pr-desync) first to close the chain's PRs (with
`--delete-remote` to drop the remote branches too); then reorder and delete, and
let [`clean`](#7-the-bottom-pr-merged) tidy up the rest — the
[desync → reorder → re-sync trio](#14-reorganize-a-stack-thats-already-on-github)
in full.

> **Want to keep the change, just not as its own branch?** That's
> [`fold`](#13-a-branchs-change-is-obsolete-fold-it-away) — it squashes the branch
> into a neighbor instead of discarding it.

**See also:** [reorder branches](#5-the-branches-are-in-the-wrong-order) · [multi-commit branches](#10-a-branch-grew-a-second-commit) · [fold a branch away](#13-a-branchs-change-is-obsolete-fold-it-away)

---

## 12. Sharing a stack with someone else

*(advanced — hazards, not a supported workflow)*

**Situation.** A teammate wants to pick up or contribute to your stack.

`git stack` is a **single-owner, rebasing** tool. Every reflow rewrites the
commits of every branch above the one you touched, and `sync` uses
`--force-with-lease`. That's safe when one person owns the stack — but it's
actively hostile to shared editing:

- If a collaborator commits on top of a branch you then reflow, their work is
  stranded on an orphaned commit — the branch tip moves out from under them.
- If they push to a branch between your fetch and your push, your
  `--force-with-lease` push is *rejected* (the lease is stale) — which is the
  safety net working, not a bug. You'll need to fetch and reconcile by hand.

There's no command that coordinates multi-owner editing. If you must share:

- **Hand off cleanly.** Agree that only one person mutates the stack at a time.
  The other works in their own branches and opens separate PRs, or waits until the
  stack lands.
- **To review someone's stack read-only**, fetch and check out their branches —
  but don't commit onto them if they're still reflowing.
- **If your push is rejected** after someone else pushed, `git fetch` and inspect
  with `git stack view`; you may need to `git stack abort` your in-progress reflow
  or reconcile the branches manually before retrying.

When a shared stack gets tangled, [`doctor`](doctor.md) and
[`history`](doctor.md#rolling-back-with-history) are your recovery tools.

**See also:** [doctor.md](doctor.md) · [rolling back](doctor.md#rolling-back-with-history)

---

## 13. A branch's change is obsolete: fold it away

**Situation.** `feat/020-retry` took an approach that no longer makes sense, and
you reworked it in `feat/030-backoff` on top. You want **one** branch carrying the
net effect, at the old position — not two. A plain delete of `020-retry` would
strip its commit out from under `030-backoff`, which was written against it, so the
rework would cherry-pick with conflicts (or silently wrong).

`fold` squashes a branch into a neighbor instead, preserving the combined diff:

```sh
git stack checkout 30        # on feat/030-backoff (the rework)
git stack fold               # fold it DOWN into 020-retry
```

```
result slug [backoff]:
fold 030-backoff
  into 020-retry
  → result 020-backoff (deletes both originals). proceed? [Y/n]
done    folded feat/030-backoff into feat/020-backoff
reflow  re-threading branches from index 2
done    reflow complete (0 branches restacked)
```

The result is a single `feat/020-backoff` at the old slot, containing both commits
squashed into one. The result lands at the **predecessor's leaf** (020, so
everything above is undisturbed) but is **named after the branch you ran `fold`
on** (`030-backoff`) — exactly the obsolete-superseded case, no flags needed. Pass
`--slug` if you want a different name.

- Fold the other way with `--up` (into the successor); renumber the result with
  `--at <leaf>`; squash the whole range, so multi-commit branches fold fine.
- It's destructive, so it snapshots first — undo with
  `git stack history restore @0` (which warns if the rename left a duplicate-leaf
  branch behind). It refuses a dirty tree and prompts `[Y/n]` (needs `--yes` off a TTY).
- Because the default renames the survivor (020-retry → 020-backoff), folding a
  branch with pushed PRs closes both the victim's PR and the survivor's, so `fold`
  asks for `--allow-pr-rebuild`: it then deletes the remote victim branch, re-syncs
  the chain, and comments on each closed PR pointing at the one that supersedes it.

Contrast with [scenario 11](#11-pull-a-branch-out-of-the-middle), which *discards*
a branch's change; `fold` *keeps* it.

**See also:** [pull a branch out](#11-pull-a-branch-out-of-the-middle) · [reference: clean vs fold](reference.md#removing-a-branch-clean-vs-fold)

---

## 14. Reorganize a stack that's already on GitHub

**Situation.** Your stack is published — an open PR per branch — and you need a
structural change: reorder the branches, renumber one, or pull a branch out.
Doing it in place is messy. `move` and `rename` are **fully local**, so they'd
leave PRs stranded on old remote branches; renaming a head branch also makes
GitHub auto-close its PR. The clean path is to take the stack *off* GitHub first,
restructure locally, then re-publish a fresh chain — the **desync → reorder →
re-sync trio**:

```sh
git stack pr desync                                        # close the chain's PRs (add --delete-remote for a clean slate)
git stack move feat/030-profile --before feat/020-login    # reorder/renumber/delete — fully local
git stack pr sync                                          # re-publish a fresh, correctly-ordered chain
```

**What happened.** `pr desync` closes each branch's PR. Quiet PRs close silently;
any PR a human has engaged with — a comment, or any review — makes it **prompt**
before closing (CI checks don't count as activity). Add `--delete-remote` to drop
the remote branches too for a fully clean slate. With the stack offline, `move`
reorders freely — no open-PR refusal to work around (scenario 5). Then `pr sync`
opens a fresh chain on the new layout, with correct bases, `[N/M]` titles, and nav
footers.

This is the proactive counterpart to the "heads up — open PRs" notes in
[scenario 5](#5-the-branches-are-in-the-wrong-order),
[scenario 8](#8-rename-the-stacks-prefix), and
[scenario 11](#11-pull-a-branch-out-of-the-middle): when one of those refuses
because you have open PRs, this is the workflow it's pointing you at. For the full
`pr desync` reference — the activity rules and `--delete-remote`'s leaf→base
deletion order — see [pr-sync.md](pr-sync.md#git-stack-pr-desync).

**See also:** [pr-sync.md](pr-sync.md#git-stack-pr-desync) · [reorder branches](#5-the-branches-are-in-the-wrong-order) · [pull a branch out](#11-pull-a-branch-out-of-the-middle) · [rename the prefix](#8-rename-the-stacks-prefix)

---

## 15. You edited a mid-stack branch by hand

**Situation.** You changed a branch in the *middle* of the stack without going
through `amend` — you committed straight onto `feat/020-login`, cherry-picked a
hunk into it, or slipped a brand-new branch in below `feat/030-profile`. Whatever
the route, the branches above are now sitting on a stale parent: `030-profile` no
longer threads onto the new `020-login`. You don't have to remember which branch
drifted or which reflow flag to use — reach for `clean`.

```sh
git stack checkout 20
# ...commit a fix straight onto feat/020-login (no amend)...

git stack clean
```

```
fetching all remotes...
no local branches under 'feat/' have a gone upstream
reflowing from feat/030-profile up (drift detected)...
restack feat/030-profile onto feat/020-login
done    reflow complete (1 branch restacked)
```

**What happened.** `clean` walks the stack from the base up and finds the *lowest*
branch that no longer threads onto its predecessor — here `030-profile`. It
reflows from there up and leaves everything below untouched, so `010-auth` and
`020-login` keep their exact SHAs (and any open PRs). The same walk is what
catches a **moved base** and a freshly **inserted** branch, so `clean` is the
single "make this stack correct" verb — pruning merged branches, tidying remotes,
*and* re-threading local drift in one shot. (Before, `clean` only reflowed on a
prune or a moved base and would no-op here.)

If the hand-edit duplicated work that's already above it, the reflow can hit a
**conflict** — resolve it and run `git stack continue`, exactly as in
[scenario 2](#2-review-feedback-lands-on-the-bottom-branch). And if a branch ends
up empty (its change was fully absorbed by your edit), `clean` says so and points
at `doctor`/`fold` — it never deletes a branch by content, only by a gone remote.

**No network handy?** `git stack restack` does the same local re-thread without
the fetch/prune/remote-cleanup — it's the surgical counterpart (and the one to use
for `--from`, an arbitrary `--onto <ref>`, or `--push`). `clean` is the
batteries-included version; `restack` is the scalpel.

**See also:** [feedback on the bottom branch](#2-review-feedback-lands-on-the-bottom-branch) · [a branch grew a second commit](#10-a-branch-grew-a-second-commit) · [concepts: reflow](concepts.md#reflow)
