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
