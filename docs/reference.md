# Reference

Lookup material: the shell aliases, configuration knobs, and a couple of commands
worth spelling out. For the **exhaustive per-command flag reference**, run:

```sh
git stack help
```

`help` is generated from the script itself, so it's always current — this page
covers the things `help` doesn't, plus the day-to-day shortcuts.

## Seeing your stacks: `list` vs `view`

```sh
git stack list             # overview of every stack: count, tip, base, ahead/behind
git stack view             # the current stack's branches + per-branch sync state
git stack view feat        # a named stack (trailing / optional), no checkout
```

`list` is a fast, local-only overview of **all** stacks (no fetch, no `gh`).
`view` drills into **one** stack — the parent header, each branch with its
upstream sync state, the last snapshot, and a paused-op banner if a reflow is
mid-flight. `view` fetches by default; pass `--no-fetch` to skip.

## Navigating a stack: `checkout` and `pick`

```sh
git stack checkout 10      # check out the branch whose leaf starts with 10 (e.g. feat/010-auth)
git stack checkout         # no number → interactive branch picker
git stack pick             # choose a stack, jump straight to its tip
```

`checkout` matches on the **numeric** leaf, so `git stack checkout 5` finds
`feat/05-foo` or `feat/005-foo`. With no argument it opens a branch picker; from
outside a stack it picks the stack first (the same all-stacks selector `list`
shows), then a branch. `pick` instead always offers the stack selector — even
from inside another stack — and lands you on the chosen stack's **tip** (a fast
hop); use `checkout` when you want a specific branch.

## Building with uncommitted work: `create` and `add`

Neither verb requires a clean tree — both carry uncommitted tracked changes onto
the new branch rather than erroring.

```sh
git stack create feat auth          # dirty tree → prompts before carrying
git stack create feat auth --stash  # carry without prompting (required non-interactively)
git stack add login                 # carries automatically, no prompt
```

`add` carries silently; `create` is gated, since carrying onto a brand-new stack
is a bigger surprise — on a TTY it prompts, and off a TTY it refuses unless you
pass `--stash`. The carry rides the checkout when the new branch sits on your
current commit (staged-ness preserved) and uses stash+pop when it lands elsewhere
(staged changes return unstaged, like `rebase --autostash`); a conflicting pop
warns and keeps the stash entry rather than aborting. Untracked files travel
across regardless. See [workflows scenario 4](workflows.md#4-you-need-a-branch-in-the-middle).

## Removing a branch: `clean` vs `fold`

```sh
git stack fold              # fold the current branch DOWN into its predecessor
git stack fold 020 --up     # fold leaf 020 UP into its successor
git stack fold --slug retry # keep the survivor's position, rename it
git stack fold 020 --at 15  # renumber the merged result to a free leaf
git stack fold --dry-run    # preview the plan, change nothing
```

Two different "get rid of a branch" verbs:

- **`clean`** prunes branches whose upstream is `[gone]` (already merged/closed) and
  reflows the survivors. Use it after a PR merges.
- **`fold`** *merges a branch away that you're keeping the work for* — it squashes
  the branch into an adjacent neighbor so the combined diff survives as one commit,
  then reflows the children onto the survivor. A plain delete would orphan the
  children from the context they were written against; folding keeps every
  surviving branch's tree intact, so children cherry-pick clean.

By default `fold` goes **down** (into the predecessor); `--up` folds into the
successor instead. The result lands at the survivor's leaf but is **named after
the branch you ran `fold` on** (the victim's slug) — so folding `016-split` down
into `015-reapply` yields `015-split`. Pass `--slug` to choose a different name,
or `--at` to renumber to a free leaf below the children. It squashes the whole
victim/survivor range, so multi-commit branches fold fine.

`fold` is destructive, so it snapshots first (undo with `git stack history
restore @0` — which also warns if a rename left a duplicate-leaf branch behind),
refuses a dirty tree, prompts `[Y/n]` (default yes), and needs `--yes` when run
off a TTY. Deleting the victim closes its head PR; because the default slug
renames the survivor, the survivor's PR usually closes too — so `fold` refuses
unless you pass `--allow-pr-rebuild` (or `--no-push`). With it, `fold` deletes the
remote victim branch, re-syncs the PR chain, and leaves a breadcrumb comment on
each closed PR pointing at the one that supersedes it. See
[workflows scenario 13](workflows.md#13-a-branchs-change-is-obsolete-fold-it-away).

## The default branch: `default-branch`

```sh
git stack default-branch   # prints the resolved base branch name
```

Resolution order: `git config stack.base` → `git config init.defaultBranch` →
`main` → `master` → the literal `main`. `clean` and `restack --onto` call this
so they target the right branch in any repo.

## Shell integration & aliases

Install the aliases by adding one line to your shell rc, then reloading:

```sh
# bash — ~/.bashrc
eval "$(git stack init bash)"

# zsh — ~/.zshrc
eval "$(git stack init zsh)"
```

```fish
# fish — ~/.config/fish/config.fish
git stack init fish | source
```

This defines one short alias per verb:

| Alias       | Expands to                  |
| ----------- | --------------------------- |
| `gstk`      | `git stack`                 |
| `gstkl`     | `git stack list`            |
| `gstkv`     | `git stack view`            |
| `gstkp`     | `git stack pick`            |
| `gstkco`    | `git stack checkout`        |
| `gstkcr`    | `git stack create`          |
| `gstkad`    | `git stack add`             |
| `gstks`     | `git stack sync`            |
| `gstkcl`    | `git stack clean`           |
| `gstkr`     | `git stack restack`         |
| `gstkrp`    | `git stack restack --push`  |
| `gstkro`    | `git stack restack --onto`  |
| `gstkcon`   | `git stack continue`        |
| `gstkab`    | `git stack abort`           |
| `gstkam`    | `git stack amend`           |
| `gstkprs`   | `git stack pr sync`         |
| `gstkprl`   | `git stack pr list`         |
| `gstkh`     | `git stack history`         |
| `gstkhs`    | `git stack history show`    |
| `gstkhr`    | `git stack history restore` |
| `gstkmv`    | `git stack move`            |
| `gstkrn`    | `git stack rename`          |
| `gstkd`     | `git stack doctor`          |

The old `gstkrom`/`gstkromp` (fetch + `restack --onto origin/<default>`) and the
multi-step `gstkcl` shell function are gone — `gstkcl` is now simply `git stack
clean`, which fetches, prunes, and reflows onto `origin/<default>` in one verb.

## Configuration

```sh
git config stack.prefix feat/        # override prefix auto-detection
git config stack.base main           # the base branch the stack sits on (default: main/master)
git config stack.historyKeep 100     # auto-prune snapshots older than the Nth (0 disables)
```

| Key | Effect | Default |
|-----|--------|---------|
| `stack.prefix` | Force the [prefix](concepts.md#prefix) instead of auto-detecting from the current branch | auto-detect |
| `stack.base` | The [base](concepts.md#base) branch the stack rebases onto | `init.defaultBranch` → `main` → `master` |
| `stack.historyKeep` | How many [snapshots](concepts.md#snapshot) to retain before auto-pruning | `100` (`0` disables) |

Most flags also have a `--prefix <p>` / `--no-push` / `--no-sync` /
`--color` / `--no-color` / `-v` / `-q` form — see `git stack help`.

**See also:** [concepts.md](concepts.md) · [workflows.md](workflows.md) · [development.md](development.md)
