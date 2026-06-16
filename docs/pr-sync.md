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
reattach it. So [`move`](workflows.md#5-the-branches-are-in-the-wrong-order) and
[`rename`](workflows.md#8-rename-the-stacks-prefix) — which both change branch
names — refuse by default when any affected branch has an open head PR. Pass
`--allow-pr-rebuild` to accept that those PRs close and the next `pr sync` opens
fresh ones.

[`fold`](workflows.md#13-a-branchs-change-is-obsolete-fold-it-away) closes PRs the
same way — the deleted victim's head PR always, and the survivor's if `--slug`
renames it — so it shares the `--allow-pr-rebuild` gate. When you accept it, `fold`
deletes the remote victim branch, runs `pr sync` to rebuild the chain, and then
posts a **breadcrumb** comment on the closed victim PR pointing at the PR that now
supersedes it (the breadcrumb runs after the sync, once the superseding PR exists).

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

### `--delete-remote`

Also deletes the remote branch of each PR closed. (Closing a PR leaves its branch
on origin; deleting the branch is what gives a fully clean slate.) Branches are
processed leaf→base, and a branch is **never** deleted while it still serves as
the base of a PR that was kept open — deleting it would retarget that PR to the
default branch on GitHub. Such a branch is reported `keeping remote <branch>` and
left in place. Branches without a PR (and the branches of merged or kept PRs) are
left alone; use [`clean`](workflows.md) for broader remote pruning.

**See also:** [concepts: PR chain](concepts.md#pr-chain) · [workflows §6](workflows.md#6-publish-and-refresh-the-pr-chain) · [workflows §7: bottom PR merged](workflows.md#7-the-bottom-pr-merged)
