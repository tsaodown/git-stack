# Reference

Lookup material: the shell aliases, configuration knobs, and a couple of commands
worth spelling out. For the **exhaustive per-command flag reference**, run:

```sh
git stack help
```

`help` is generated from the script itself, so it's always current — this page
covers the things `help` doesn't, plus the day-to-day shortcuts.

## Navigating a stack: `checkout`

```sh
git stack checkout 10      # check out the branch whose leaf starts with 10 (e.g. feat/010-auth)
git stack checkout         # no number → interactive picker (fzf if installed, else a numbered prompt)
```

`checkout` matches on the **numeric** leaf, so `git stack checkout 5` finds
`feat/05-foo` or `feat/005-foo`. With no argument it opens a picker; if you're on
a branch with no stack prefix (e.g. `main`) and more than one stack exists, it
prompts for the stack first.

## The default branch: `default-branch`

```sh
git stack default-branch   # prints the resolved base branch name
```

Resolution order: `git config stack.base` → `git config init.defaultBranch` →
`main` → `master` → the literal `main`. The dynamic aliases (`gstkrom`, `gstkcl`,
…) call this so they target the right branch in any repo.

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

This defines short aliases plus dynamic helpers that resolve the default branch at
expansion time:

| Alias       | Expands to                                                                        |
| ----------- | --------------------------------------------------------------------------------- |
| `gstk`      | `git stack`                                                                        |
| `gstkl`     | `git stack list`                                                                   |
| `gstkco`    | `git stack checkout`                                                               |
| `gstks`     | `git stack status`                                                                 |
| `gstkr`     | `git stack restack`                                                                |
| `gstkrp`    | `git stack restack --push`                                                         |
| `gstkro`    | `git stack restack --onto`                                                         |
| `gstkrom`   | `git fetch origin <default>` then `git stack restack --onto origin/<default>`      |
| `gstkromp`  | same as `gstkrom` plus `--push`                                                    |
| `gstkc`     | `git stack continue`                                                               |
| `gstka`     | `git stack abort`                                                                  |
| `gstkam`    | `git stack amend`                                                                  |
| `gstkp`     | `git stack push`                                                                   |
| `gstkpa`    | `git stack push --all`                                                             |
| `gstkprs`   | `git stack pr sync`                                                                |
| `gstkprl`   | `git stack pr list`                                                                |
| `gstkh`     | `git stack history`                                                                |
| `gstkhs`    | `git stack history show`                                                           |
| `gstkhr`    | `git stack history restore`                                                        |
| `gstkn`     | `git stack new`                                                                    |
| `gstkmv`    | `git stack move`                                                                   |
| `gstkrn`    | `git stack rename`                                                                 |
| `gstkcl`    | `git fetch --all --prune` then `git stack close`                                   |

`<default>` is resolved by `git stack default-branch` (above).

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
