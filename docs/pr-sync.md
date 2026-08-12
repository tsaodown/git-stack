# The PR chain

`git stack pr sync` mirrors your local [stack](concepts.md#stack) to a chain of
GitHub PRs — one PR per [active branch](concepts.md#active-branch), each based on
the branch below it. `git stack pr list` shows the chain's state. Both require
[`gh`](https://cli.github.com/) authenticated for github.com (`gh auth login`).

For the day-to-day "I changed the stack, now refresh the PRs" flow, see
[workflows §6](workflows.md#6-publish-and-refresh-the-pr-chain). This page is the
reference for what `pr sync` does and how to read `pr list`.

## `git stack pr sync`

```sh
git stack pr sync                 # default: drafts, auto-push missing branches
git stack pr sync --ready         # open as ready-for-review instead of drafts
git stack pr sync --no-push       # error if any branch isn't on origin
git stack pr sync --dry-run       # show planned actions, make no remote calls
git stack pr sync --no-template   # ignore .github/PULL_REQUEST_TEMPLATE.md
```

On each run, `pr sync`:

1. **Pushes** any unpushed branches (unless `--no-push`).
2. **Creates** a draft PR for each active branch that doesn't have one. The
   PR's base points at the previous active branch in the stack, or at
   `stack.base` for the bottom branch. The body uses the repo's PR template if
   present (`.github/PULL_REQUEST_TEMPLATE.md` or its variants) unless
   `--no-template`.
3. **Updates** existing PRs so their title tracks the branch's latest commit
   subject behind the right `[N/M]` position prefix, and their body carries an
   up-to-date [nav footer](#the-nav-footer).

It's **idempotent**: a PR whose title and body already match is left untouched, so
re-running is cheap and safe. Re-run it after *any* structural change to the stack
— a new branch, a removed branch, a reorder — to bring the chain back into
alignment.

### Empty-diff branches are skipped

GitHub can't open a PR with no commits between base and head, so a branch with no
commit ahead of its [predecessor](concepts.md#predecessor) is left out of the
chain — only [active branches](concepts.md#active-branch) get a PR.

### The title: `[N/M]` prefix + commit subject

Each PR title is the branch's latest commit subject behind a position prefix,
e.g. `[2/3] add login`. `pr sync` rebuilds the title on every run, so it tracks
both the position (as the stack grows, shrinks, or reorders) **and** the commit
subject (after an amend or rebase reword). A title you edit by hand on GitHub is
not preserved — the next `pr sync` re-derives it from the commit subject. (The
prefix is *stripped* in `pr list`'s display, since the row order already conveys
position.)

### The nav footer

`pr sync` maintains a fenced block in each PR body, between
`<!-- git-stack:nav-start -->` and `<!-- git-stack:nav-end -->` markers, listing
the whole chain with the current PR marked and any
[merged predecessors](concepts.md#nav-footer) struck through. Everything outside
the markers — your PR description, the template — is preserved untouched. Change
detection is normalized so a GitHub body round-trip doesn't produce a spurious
edit.

Every PR reference is written as an explicit `[#N](…/pull/N)` markdown link
rather than a bare `#N`. A bare `#N` is a GitHub *issue-link* that the page
resolves to the PR title client-side — so a chain of them (and the `(#N)` refs
embedded in `Revert`/`Reapply` titles) expands into an unreadable wall of nested
titles. An explicit link keeps the literal `#N` text, stays clickable, and is
not expanded. To match a stack entry's number when re-reading a footer, the
parser takes only the first `#N` on each line; later `#N` tokens are title text,
not chain members.

### Renames close head PRs

GitHub auto-closes a PR when its head branch is renamed, and there's no API to
reattach it. (Renaming a branch *does* retarget PRs that use it as their **base** —
but every stack branch is the **head** of its own PR, and those close.)

That single fact shapes every renaming verb. None of them re-publish on your
behalf: **PR state changes are explicit**, because closing and reopening a PR
discards its review threads, approvals, and CI history. So each one refuses when
the rename would hit an open head PR, and points at the same trio —
[`pr desync`](#git-stack-pr-desync) to take the stack offline → mutate locally →
`pr sync` to re-publish.

**How much of the chain the desync covers matches how much the verb renames**, and
the refusal message tells you which form you're in — it names a branch when one PR
is enough, and stays bare when the change is chain-wide:

- [`rename`](workflows.md#8-rename-the-stacks-prefix) changes every branch name.
  It renames the remote branches too (nothing else would ever reap an abandoned
  *prefix*), but never runs `pr sync`. Chain-wide, so the desync is too.
- [`reslug`](workflows.md#8a-rename-one-branchs-slug) changes one branch's slug.
  Fully local — the stale remote stays under the current prefix, so `clean` reaps it.
  One branch, so [`pr desync <branch>`](#git-stack-pr-desync-branch--close-one-pr-keep-the-rest).
- [`move`](workflows.md#5-the-branches-are-in-the-wrong-order) renames branches by
  giving them new leaf numbers. Also fully local. A **renumber in place**
  (`--at`) touches one branch and takes the one-PR form; a **reorder** reflows
  every branch above the one you moved, so it takes the whole-stack form.
- [`drop`](workflows.md#11-pull-a-branch-out-of-the-middle) gates on the victim
  alone — children pass through ungated — so it too takes the one-PR form.

The exception is [`fold`](workflows.md#13-a-branchs-change-is-obsolete-fold-it-away),
which *does* auto-sync — discarding the victim's review context is the point of the
operation, not collateral damage. It keeps the `--allow-pr-rebuild` gate, which
covers **two** PRs: the deleted victim's, and the **survivor's** whenever the result
renames it (which the default does, since the result takes the victim's slug).
Passing `--slug <survivor's current slug>` keeps the survivor's name and its PR.
When you accept the gate, `fold` deletes the remote victim branch, runs
`pr sync` to rebuild the chain, and then posts a **breadcrumb** comment on the
closed victim PR pointing at the PR that now supersedes it (the breadcrumb runs
after the sync, once the superseding PR exists).

## `git stack pr list`

```sh
git stack pr list                 # one block per PR
git stack pr list --no-fetch      # skip the upfront git fetch
```

Each branch renders as a three-line block — identifier, status badges, title:

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

- **Line 1** — `*` marks the current branch; then the branch name, the PR number
  (a clickable hyperlink in modern terminals), and a `(Nc)` suffix counting
  human (non-bot) comments.
- **Line 2** — status badges (below).
- **Line 3** — the PR title.

A branch with no open PR collapses to a single `(no PR)` line.

### Badge legend

| Badge | Meaning |
|-------|---------|
| `[synced]` | local tip matches origin |
| `[+N/-M]` | N commits ahead of / M behind origin |
| `[unpushed]` | branch isn't on origin |
| `[gone]` | upstream branch was deleted (merged & cleaned up) |
| `[draft]` | PR is a draft |
| `[base: X]` | the PR's base has **drifted** from the stack — it should target the previous branch but targets `X` (re-run `pr sync`) |
| `[approved]` / `[approved: alice]` | approved (with approver names when available) |
| `[changes]` / `[changes: bob]` | changes requested (with reviewer names) |
| `[review required: …]` | required reviewers (e.g. CODEOWNERS) still need to sign off |
| `[checks: 1 fail, 2 pending, 3 pass]` | CI status rollup; zero-count segments are suppressed |
| `[closed]` | PR closed without merging |
| `[merged]` / `[merged by alice, 2d ago]` | PR merged (with who/when when available) |

The review, check, and merge badges reflect live GitHub state, so they only
appear once a PR exists and reviewers/CI have acted.

## `git stack pr desync`

The inverse of `pr sync`: tear the chain back down. Once a stack is published,
reordering it churns every PR (bases, `[N/M]` titles, nav footers) and renamed
heads auto-close their PRs. `pr desync` takes the stack *off* GitHub so you can
reorder freely and re-publish with a clean `pr sync`.

```sh
git stack pr desync                  # close each branch's open PR
git stack pr desync feat/015-auth    # close only that branch's PR
git stack pr desync --delete-remote  # also delete the remote branches
git stack pr desync --yes            # close active PRs too, without prompting
git stack pr desync --dry-run        # show planned actions, make no changes
```

For each branch it inspects the PR and acts by state:

| PR state | Action |
|----------|--------|
| open, no activity | **closed** |
| open, with activity | **prompt** `y/N` per PR on a TTY; kept if declined. Skipped (kept) non-interactively unless `--yes` |
| merged | **skipped** — can't be closed |
| already closed | **skipped** — no-op |
| no PR | **skipped** |

**Activity** is a *human* signal on the PR — a non-bot comment, or any review a
person left (an approval, a changes-requested, or a plain *Comment* review). CI
checks are **not** activity (they run on nearly every PR). The check exists so
you don't silently close a PR someone has engaged with; everything quiet closes
without ceremony.

### `git stack pr desync <branch>` — close one PR, keep the rest

Pass a branch to tear down just its PR and leave the rest of the chain published.
This is the proportionate remedy when the change you're about to make renames
**one** branch — [`reslug`](workflows.md#8a-rename-one-branchs-slug),
[`move --at`](workflows.md#5-the-branches-are-in-the-wrong-order), or
[`drop`](workflows.md#11-pull-a-branch-out-of-the-middle). Each of those refuses on
an open head PR, and each renames a single branch, so closing the whole chain would
spend four sets of review threads to protect one:

```sh
git stack pr desync feat/015-auth    # close only #12
git stack reslug feat/015-auth authz
git stack pr sync                    # re-publish; the rest of the chain never moved
```

The trailing `pr sync` is still whole-stack, and that's the point: it opens a fresh
PR for the renamed branch and **updates** the others in place (bases, `[N/M]`
titles, nav footers). Their review threads, approvals, and CI history survive.

`<branch>` accepts a numeric leaf or a full branch name (`pr desync 15` works).
Branches outside the target aren't listed or counted — they were never in scope, so
reporting them as `skip` would misread:

```
desync: feat/015-auth only (4 other branches untouched)
close   #12 feat/015-auth
desynced: 1 closed, 0 remote deleted, 0 skipped
```

Activity gating is per-PR and unchanged, so a target with review activity still
prompts. The renamed branch gets a **new PR number** — a closed PR is never
reattached ([ADR 0013](adr/0013-pr-state-changes-are-explicit.md)).

### `--delete-remote`

Also deletes the remote branch of each PR closed. (Closing a PR leaves its branch
on origin; deleting the branch is what gives a fully clean slate.) Branches are
processed leaf→base, and a branch is **never** deleted while it still serves as
the base of a PR that was kept open — deleting it would retarget that PR to the
default branch on GitHub. Such a branch is reported `keeping remote <branch>` and
left in place. Branches without a PR (and the branches of merged or kept PRs) are
left alone; use [`clean`](workflows.md) for broader remote pruning.

With a `<branch>` target, `--delete-remote` is **refused up front** when a
still-open PR bases on that branch — normally its immediate successor's. Nothing
has retargeted that PR yet (`pr sync` does it, and hasn't run), so the delete would
close a PR you never touched. Re-run without the flag and `clean` will reap the
stale remote later, or desync the whole chain if a clean slate is what you want. A
target whose successor has no PR — or a merged or closed one — is no hazard and
deletes normally, as does the stack tip.

**See also:** [concepts: PR chain](concepts.md#pr-chain) · [workflows §14: reorganize a published stack](workflows.md#14-reorganize-a-stack-thats-already-on-github) · [workflows §6](workflows.md#6-publish-and-refresh-the-pr-chain) · [workflows §7: bottom PR merged](workflows.md#7-the-bottom-pr-merged)
