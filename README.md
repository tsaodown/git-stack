# git-stack

Manage stacked branches with a numeric-leaf naming convention. One bash script, no
runtime dependencies beyond `git` and POSIX utilities (`fzf` enables interactive
checkout but is optional).

A stack is a series of branches sharing a prefix and ordered by a numeric leaf:

```
feat/010-auth
feat/020-login
feat/030-profile
```

`git stack` keeps the stack linear and the GitHub PRs in sync as you work. It:

- **[reflows](docs/concepts.md#reflow)** the stack after you amend the bottom or rebase onto a new base, replaying each branch onto its predecessor;
- **[inserts, moves, and renames](docs/workflows.md#4-you-need-a-branch-in-the-middle)** branches without renumbering the rest, using sparse leaf numbers;
- pushes with `--force-with-lease` and **[opens/updates a GitHub PR chain](docs/pr-sync.md)** (via `gh`), one PR per branch;
- **[repairs and rolls back](docs/doctor.md)** — squashes messy branches, prunes merged ones, and keeps snapshots so you can undo.

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

`git stack` ships short aliases (`gstk`, `gstkr`, `gstkam`, …) and dynamic helpers
that resolve the default branch at expansion time (`gstkrom`, `gstkromp`,
`gstkcl`). To install them, add the line for your shell and reload:

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

See the [full alias list](docs/reference.md#shell-integration--aliases) in the reference.

## Quick start

```sh
git checkout -b feat/010-auth      # start a stack
# ...write code, commit...
git checkout -b feat/020-login     # next branch in the stack
# ...write code, commit...

git stack list                     # see the stack and its sync state
git stack amend -m "fix typo"      # amend the current branch, reflow the rest
git stack push --all               # push every branch with --force-with-lease
git stack pr sync                  # open or update the GitHub PR chain
```

For the situations you'll actually hit — review feedback on the bottom branch,
rebasing onto a moved `main`, inserting or reordering branches, landing and
cleaning up — see **[docs/workflows.md](docs/workflows.md)**.

## Documentation

| Doc | What's in it |
|-----|--------------|
| [workflows.md](docs/workflows.md) | Real development scenarios and the git-stack moves to navigate them |
| [concepts.md](docs/concepts.md) | The vocabulary: stack, prefix, leaf, base, predecessor, reflow, PR chain |
| [pr-sync.md](docs/pr-sync.md) | How the GitHub PR chain is built; the `pr list` badge legend |
| [doctor.md](docs/doctor.md) | Recovery & repair: conflicts, `doctor`, rolling back with snapshots |
| [reference.md](docs/reference.md) | Aliases, configuration, and `git stack help` |
| [development.md](docs/development.md) | Running the tests; the script's architecture |

Full per-command flags: `git stack help`.

## License

MIT — see [LICENSE](LICENSE).
