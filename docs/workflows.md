# Workflows

Real development situations and how to navigate them with `git stack`. Each
scenario stands on its own — skim for the one you're in. New to the vocabulary
(*stack*, *leaf*, *reflow*, *predecessor*)? Start with [concepts.md](concepts.md).

The examples use a three-branch stack on the `feat/` prefix:

```
feat/010-auth → feat/020-login → feat/030-profile
```

Output blocks are captured from real runs; commit SHAs will differ for you.

---

## The lifecycle of a stack

Most stacks follow the same arc — build, publish, revise, extend, land. Here's
the whole path in one place; each step links to the scenario that covers it in
depth. Lines marked `# on GitHub` are actions you take in the browser, not
`git stack` commands.

```sh
# ── build it ─────────────────────────────────────────  (scenario 1)
git stack create feat auth          # bottom branch off main
git stack add login                 # ...write code + commit between each
git stack add profile

# ── publish the PR chain ─────────────────────────────  (scenario 6)
git stack pr sync                   # a draft PR per branch

# ── review lands on the bottom branch ────────────────  (scenario 2)
git stack checkout 10               # jump by leaf number
git stack amend -m "add auth (validated)" -- auth.txt
git stack sync                      # force-with-lease the rewritten branches
git stack pr sync                   # refresh titles + nav footers

# ── realize you need a branch in the middle ──────────  (scenario 4)
git stack add cache --after feat/010-auth
git stack sync && git stack pr sync

# on GitHub: reviewers approve; you merge the bottom PR (GitHub deletes its branch)

# ── catch up after the merge ─────────────────────────  (scenario 7)
git stack clean                     # prune the merged branch + reflow onto origin/main
git stack pr sync                   # repoint the remaining PRs
```

Repeat the revise → `sync` → `pr sync` loop and the merge → `clean` → `pr sync`
loop until the stack is empty. Off the happy path — reordering, renaming, folding
a branch away, dropping one entirely, or recovering from a conflict — jump to the
matching scenario below.

---

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
| [8a](#8a-rename-one-branchs-slug) | Rename one branch's slug (`reslug`) |
| [9](#9-push-or-reflow-only-part-of-the-stack) | Push or reflow only part of the stack *(advanced)* |
| [10](#10-a-branch-grew-a-second-commit) | A branch grew a second commit *(advanced)* |
| [11](#11-pull-a-branch-out-of-the-middle) | Pull a branch out of the middle (`drop`) *(advanced)* |
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
no local branches under 'feat/' have a gone upstream
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
git stack add                 # interactive picker (ref, after/before, leaf)
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
restack feat/030-profile onto feat/010-auth
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
untouched. It's still local-only, so the same open-PR rule applies — but since only
this branch is renamed, close only its PR:
`pr desync <branch>` → renumber → `pr sync`
([one-PR desync](pr-sync.md#git-stack-pr-desync-branch--close-one-pr-keep-the-rest)).
A full reorder is the case that needs the whole chain torn down
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
git stack pr sync --dry-run     # show planned actions, make no remote writes
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

  feat/030-profile  (no PR)
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
fetching all remotes...
prune   1 local branch(es) with gone upstream:
  delete  feat/010-auth (63aeaec)
  (no matching backup refs)

dry run: origin/main has moved a1b2c3d..e4f5a6b (+1 commit(s)); would reflow 2 survivor(s) onto it
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

It then renames the pushed branches on the remote too, so nothing is left stranded
under the old prefix. That remote half matters more here than elsewhere: a branch
`move` leaves its stale remote in the *same* prefix, where [`clean`](#7-the-bottom-pr-merged)
reaps it — but an old *prefix* is a namespace `clean` never scans, so `rename` has
to collect its own litter. `--no-push` skips it.

**`rename` never syncs PRs.** Republishing is always an explicit `pr sync`. Since
GitHub closes a PR when its head branch is renamed (no reattach), `rename`
**refuses if any branch has an open head PR** — the fix is the trio:

```sh
git stack pr desync    # close the chain deliberately
git stack rename fix/  # rename local + remote
git stack pr sync      # republish a fresh chain
```

Use `--no-history` to skip carrying backup refs.

**See also:** [rename one branch's slug](#8a-rename-one-branchs-slug) ·
[reorder branches](#5-the-branches-are-in-the-wrong-order)

---

## 8a. Rename one branch's slug

**Situation.** `rename` retargets the whole stack's prefix. You just want to fix
one branch's name — a typo, or a slug that no longer describes the change.

```sh
git stack reslug authz                  # rename the current branch's slug
git stack reslug 010 authz              # ...or name the branch (leaf, partial, or full)
git stack reslug                        # prompts, prefilling the current slug
```

**What happened.** `feat/010-auth` became `feat/010-authz`. The **leaf** is
untouched, so the branch keeps its position — `reslug` never reorders. That's
enforced, not merely intended: a slug can't start with a digit, so there's no way
to smuggle a leaf change through one. To change position or leaf number, use
[`move`](#5-the-branches-are-in-the-wrong-order) instead.

Arity follows `git branch -m`: one argument renames the current branch, two name
the target first.

It's a single atomic ref rename — no reflow, no push, no PR sync — so unlike most
mutating verbs it **doesn't require a clean tree**; you can fix a branch name
mid-work. It snapshots first, so `git stack history restore @0` undoes it (that
re-creates the old name beside the new one and warns about the resulting duplicate
leaf). The stale remote branch stays under the current prefix, where `clean` reaps
it.

### When the branch has a PR

GitHub closes a PR whose head branch is renamed, and nothing can reattach it. So
`reslug` refuses rather than silently spending the PR:

```
git-stack: error: reslug: 'feat/020-login' has an open PR (#102); renaming it would
strand that PR on the old branch name. Run 'git stack pr desync feat/020-login' to
close just that PR first, then reslug, then 'git stack pr sync'.
```

The message names the branch because only *that* PR has to go — `reslug` renames
one branch, so closing the whole chain would spend the other reviews for nothing:

```sh
git stack pr desync feat/020-login    # close just #102
git stack reslug feat/020-login signin
git stack pr sync
```

```
desync: feat/020-login only (2 other branches untouched)
close   #102 feat/020-login
desynced: 1 closed, 0 remote deleted, 0 skipped

reslug  feat/020-login -> feat/020-signin
done    reslug complete (+1 renames)

push    feat/020-signin (6f2e50e, --force-with-lease)
exists  #101 feat/010-auth
create  #104 feat/020-signin -> feat/010-auth
exists  #103 feat/030-profile
update  #101 feat/010-auth
update  #104 feat/020-signin
update  #103 feat/030-profile (base: feat/020-login -> feat/020-signin)
done    pr sync complete (3 branches)
```

Read the last block closely — it's the whole point of naming the branch:

- **`exists #101` / `exists #103`** — the neighbours are *reused*. Their review
  threads, approvals and CI history are untouched; they only needed a refreshed
  title and nav footer.
- **`create #104`** — the renamed branch gets a **new PR number**. #102 stays
  closed beside it; a closed PR is never reattached, so this is inherent, not a
  bug. Copy anything you still need from #102's discussion before you desync.
- **`update #103 (base: feat/020-login -> feat/020-signin)`** — the successor's
  base follows the rename automatically. That retarget is why the stale
  `origin/feat/020-login` must survive until `pr sync` runs: deleting it first
  would close #103. `pr desync --delete-remote` refuses for exactly this reason,
  and `clean` reaps the stale remote afterwards.

Reach for a whole-stack `pr desync` only when the change itself is chain-wide —
see [scenario 14](#14-reorganize-a-stack-thats-already-on-github).

**See also:** [rename the whole prefix](#8-rename-the-stacks-prefix) · [pr desync one branch](pr-sync.md#git-stack-pr-desync-branch--close-one-pr-keep-the-rest)

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

*(advanced)*

**Situation.** A middle branch (`feat/020-login`) turned out to be unnecessary and
you want it gone, with its changes removed from the branches above it.

> **Don't just `git branch -D` it.** Deleting the ref leaves the branch's commit
> sitting in the history of every branch above it — `feat/030-profile` would still
> contain login's changes, and `restack` would refuse it as a multi-commit branch
> (see [scenario 10](#10-a-branch-grew-a-second-commit)).

That's what `drop` is for — it discards the branch **and** reflows its children
onto its predecessor, in one command:

```sh
git stack drop feat/020-login
```

```
drop 020-login
  discards its work; reflow 1 child(ren) onto 010-auth. proceed? [Y/n] y
done    dropped feat/020-login
absorb  feat/030-profile tip-only restack, dropping 1 superseded commit(s)
restack feat/030-profile onto feat/010-auth
done    reflow complete (1 branch restacked)
```

`feat/030-profile` now sits directly on `feat/010-auth` and contains only
`auth` + `profile`; login is gone entirely. The children are cherry-picked
**tip-only**, so a child that genuinely built on the dropped work surfaces a normal
conflict — resolve it and `git stack continue`, same as any reflow.

`drop` **degrades at every position**, so you don't need a different recipe per
case: a middle branch sends its children to the predecessor, the bottom one sends
them to the base, the tip is a pure delete, and a lone branch is deleted with HEAD
landing on the base. It's destructive but recoverable — it snapshots first, so
`git stack history restore @0` puts the branch back. It confirms `[Y/n]` on a TTY
(spelling out the plan, as above), refuses a dirty tree, and off a TTY needs
`--yes`. Preview with `--dry-run`:

```
dry run: would drop feat/020-login (discards its work)
  reflow 1 child(ren) onto feat/010-auth
  rerun without --dry-run to apply
```

### When the branch has a PR

`drop` is fully local, and deleting a head branch closes its PR on GitHub with no
way to reattach — and unlike [`fold`](#13-a-branchs-change-is-obsolete-fold-it-away),
there's no superseding PR to breadcrumb to. So it refuses:

```
git-stack: error: drop: 'feat/020-login' has an open PR (#102); deleting its head
branch closes the PR on GitHub with no reattach and no superseding PR to breadcrumb
to. Run 'git stack pr desync feat/020-login' to close just that PR first, then
'git stack drop', then 'git stack pr sync' to re-publish cleanly.
```

The gate covers the **victim only** — children pass through ungated — so the
remedy is one PR, not the chain's:

```sh
git stack pr desync feat/020-login   # close just #102
git stack drop feat/020-login
git stack pr sync
```

```
push    feat/030-profile (66b57c2, --force-with-lease)
exists  #101 feat/010-auth
exists  #103 feat/030-profile
update  #101 feat/010-auth
update  #103 feat/030-profile (base: feat/020-login -> feat/010-auth)
done    pr sync complete (2 branches)
```

`exists` on both survivors is the point: #101 and #103 are **reused**, not
reopened, so their review threads, approvals and CI history carry over. All #103
needed was a new base, and `pr sync` retargeted it.

### Doing it by hand

Before `drop` existed the recipe was to **move the unwanted branch to the top, then
delete it** — the move reflows the branches that were above it down onto its old
predecessor, extracting its changes. It's worth knowing, because it's exactly what
`drop` automates, and the intermediate state is inspectable:

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

Same end state — but note the PR cost differs. This recipe's `move` is a **reorder**,
so it reflows every branch above the victim and its open-PR gate covers all of them:
you'd need a whole-stack [`pr desync`](pr-sync.md#git-stack-pr-desync), then
[`clean`](#7-the-bottom-pr-merged) to tidy the leftovers — the
[desync → reorder → re-sync trio](#14-reorganize-a-stack-thats-already-on-github) in
full. `drop` gates on the victim alone, which is why it costs one PR instead. Prefer
`drop`; reach for this when you want to inspect the intermediate state.

> **Want to keep the change, just not as its own branch?** That's
> [`fold`](#13-a-branchs-change-is-obsolete-fold-it-away) — it squashes the branch
> into a neighbor instead of discarding it.

**See also:** [reorder branches](#5-the-branches-are-in-the-wrong-order) · [multi-commit branches](#10-a-branch-grew-a-second-commit) · [fold a branch away](#13-a-branchs-change-is-obsolete-fold-it-away) · [pr desync one branch](pr-sync.md#git-stack-pr-desync-branch--close-one-pr-keep-the-rest)

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
  `git stack history restore @0 --yes` (which warns if the rename left a
  duplicate-leaf branch behind; drop `--yes` to preview the rollback first). It
  refuses a dirty tree and prompts `[Y/n]` (needs `--yes` off a TTY).
- Folding closes up to **two** PRs, and `fold` asks for `--allow-pr-rebuild` if
  either exists. The **victim's**, because its branch is deleted. And the
  **survivor's**, because the result takes the victim's slug by default
  (`020-retry` folded into `015-reapply` yields `015-retry`) — that renames the
  survivor, and [a head PR doesn't survive a rename](pr-sync.md#renames-close-head-prs).
  Pass `--slug reapply` to keep the survivor's name, and its PR.
- With `--allow-pr-rebuild`, `fold` deletes the remote victim branch, re-syncs the
  chain, and comments on the closed victim PR pointing at the one that supersedes
  it. `fold` is the one verb that re-syncs PRs on its own — discarding the
  victim's review context is the point of the operation.

Contrast with [scenario 11](#11-pull-a-branch-out-of-the-middle), which *discards*
a branch's change; `fold` *keeps* it.

**See also:** [pull a branch out](#11-pull-a-branch-out-of-the-middle) · [reference: clean vs fold vs drop](reference.md#removing-a-branch-clean-vs-fold-vs-drop)

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

**Don't reach for this when one branch is changing.** A reorder rewrites every
branch above the one you moved, so tearing the whole chain down is proportionate.
But `reslug`, `move --at`, and `drop` each rename exactly **one** branch — for
those, name it in the desync and keep the other PRs alive:

```sh
git stack pr desync feat/030-profile   # close just this one
```

The refusal message tells you which form you're in: it names the branch when one
PR is enough, and stays bare when the change is genuinely chain-wide. See
[pr desync one branch](pr-sync.md#git-stack-pr-desync-branch--close-one-pr-keep-the-rest).

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
