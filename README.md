# git-stack

Manage stacked branches with a numeric-leaf naming convention. One bash script, no runtime dependencies beyond `git` and POSIX utilities (`fzf` enables interactive checkout but is optional).

A stack is a series of branches sharing a prefix and ordered by a numeric leaf:

```
feat/01-auth
feat/02-login
feat/03-profile
```

`git stack` reflows the stack after you amend the bottom, renames the whole prefix atomically, pushes with `--force-with-lease`, opens and updates the GitHub PR chain (via `gh`), prunes branches whose remote has been deleted, and keeps snapshots so you can roll back.

## Install

### Quick install

```sh
curl -fsSL https://raw.githubusercontent.com/tsaodown/git-stack/main/install.sh | sh
```

Installs to `~/.local/bin/git-stack`. Override with `INSTALL_DIR=/usr/local/bin` or `GIT_STACK_REF=v0.1.0`.

### Manual install

```sh
git clone https://github.com/tsaodown/git-stack
cd git-stack
make install              # installs to ~/.local/bin
# or:
make install PREFIX=/usr/local
```

Either path puts a single executable on your `PATH`.

## Shell integration

`git stack` ships short aliases (`gstk`, `gstkr`, `gstkam`, …) and dynamic helpers that resolve the default branch at expansion time (`gstkrom`, `gstkromp`, `gstkcl`). To install them, add the line for your shell:

**bash** — append to `~/.bashrc`:

```sh
eval "$(git stack init bash)"
```

**zsh** — append to `~/.zshrc`:

```sh
eval "$(git stack init zsh)"
```

**fish** — append to `~/.config/fish/config.fish`:

```fish
git stack init fish | source
```

Then reload your shell.

### Aliases reference

| Alias       | Expands to                                                                                       |
| ----------- | ------------------------------------------------------------------------------------------------ |
| `gstk`      | `git stack`                                                                                      |
| `gstkl`     | `git stack list`                                                                                 |
| `gstkco`    | `git stack checkout`                                                                             |
| `gstks`     | `git stack status`                                                                               |
| `gstkr`     | `git stack restack`                                                                              |
| `gstkrp`    | `git stack restack --push`                                                                       |
| `gstkro`    | `git stack restack --onto`                                                                       |
| `gstkrom`   | `git fetch origin <default>` then `git stack restack --onto origin/<default>`                    |
| `gstkromp`  | same as `gstkrom` plus `--push`                                                                  |
| `gstkc`     | `git stack continue`                                                                             |
| `gstka`     | `git stack abort`                                                                                |
| `gstkam`    | `git stack amend`                                                                                |
| `gstkp`     | `git stack push`                                                                                 |
| `gstkpa`    | `git stack push --all`                                                                           |
| `gstkprs`   | `git stack pr sync`                                                                              |
| `gstkh`     | `git stack history`                                                                              |
| `gstkhs`    | `git stack history show`                                                                         |
| `gstkhr`    | `git stack history restore`                                                                      |
| `gstkmv`    | `git stack rename`                                                                               |
| `gstkcl`    | `git fetch --all --prune` then `git stack close`                                                 |

`<default>` is resolved by `git stack default-branch` (honors `stack.base` config, then `init.defaultBranch`, then falls back to `main`/`master`).

## Usage

```
git stack help
```

Common workflows:

```sh
git checkout -b feat/01-auth      # start a stack
# ... write code, commit ...
git checkout -b feat/02-login     # next branch in the stack
# ... write code, commit ...

git stack list                    # see the stack and sync state
git stack amend -m "fix typo"     # amend current branch, reflow the rest
git stack push --all              # push every branch with --force-with-lease
git stack restack --onto origin/main   # rebase the whole stack onto a new base
git stack pr sync                 # open draft PRs for the chain (or update them)
```

## Syncing PRs to GitHub

`git stack pr sync` opens and updates the GitHub PR chain to match the local stack. It pushes any unpushed branches, creates a draft PR per branch (each one's base pointing at the previous branch in the stack, or `stack.base` for the bottom), uses the repo's PR template if present (`.github/PULL_REQUEST_TEMPLATE.md` or its variants), and keeps each PR's title prefix (`[N/M]`) and a stack-navigation footer in sync. Re-run it whenever the stack changes — new branch, removed branch, reordered — to bring the PRs back into alignment. Idempotent: PRs whose title and body already match aren't touched.

```sh
git stack pr sync                 # default: drafts, auto-push missing branches
git stack pr sync --ready         # open as ready-for-review instead of drafts
git stack pr sync --no-push       # error if any branch isn't on origin
git stack pr sync --dry-run       # show planned actions, make no remote calls
git stack pr sync --no-template   # ignore .github/PULL_REQUEST_TEMPLATE.md
```

Requires [`gh`](https://cli.github.com/) authenticated for github.com (`gh auth login`).

## Configuration

```sh
git config stack.prefix feat/        # override prefix auto-detection
git config stack.base main           # parent branch (default: main/master)
git config stack.historyKeep 100     # auto-prune older snapshots (0 disables)
```

## Tests

Requires `bats-core` and `jq` (the `pr sync` tests use a stubbed `gh` that pipes JSON through `jq`):

```sh
brew install bats-core jq       # macOS
sudo apt-get install -y bats jq # Debian/Ubuntu

make test                       # JOBS=4 by default
make test JOBS=1                # sequential
```

## License

MIT — see [LICENSE](LICENSE).
