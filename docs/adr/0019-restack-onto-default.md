# ADR 0019 — `restack --onto-default`: re-root onto the fresh repo default

- **Status:** Implemented (2026-10-05)
- **Context doc:** [CONTEXT.md → Commands](../../CONTEXT.md#commands)
- **Supersedes in part:** [ADR 0001](0001-command-vocabulary-redesign.md) (the `gstkrom`/`gstkromp` drop)

## Context

ADR 0001 dropped the `gstkrom`/`gstkromp` shell helpers ("fetch origin default,
then `restack --onto origin/<default>`") on the premise that the new `clean` verb
already covered them: clean's charter was "prune → fetch → reflow survivors onto
`origin/<default>`". If clean always reflows onto the repo default, a dedicated
"rebase onto main" alias is redundant.

ADR 0018 then made the base a **per-stack** fact. Every verb that needs the branch
under the stack — clean included — now resolves `stack.<prefix>.base` first and
only falls through to `origin/<default>`. That silently voided ADR 0001's premise:
for a stack intentionally rooted elsewhere (`create --onto <ref>`), `clean` reflows
onto *that* base, not the trunk. So a user who rooted a stack on some feature
commit and later ran `clean` (`gstkcl`) expecting to land back on `main` instead
gets re-rooted onto the recorded base. That is correct per ADR 0018, but it leaves
no thin path back to the trunk: the only way is `restack --onto origin/main` typed
by hand, which also means knowing the remote ref spelling and the default's name.

## Decision

Re-add the capability as a first-class `restack` mode rather than a shell helper.

**`git stack restack --onto-default`** (alias `gstkrom`):

1. Resolves the **repo-global** default (`_resolve_parent_name` with no prefix, so
   the per-stack base is deliberately skipped): `stack.base` → `init.defaultBranch`
   → local `main`/`master`.
2. **Best-effort** `git fetch origin <default>`. A failure (offline, unreachable
   remote) warns and continues — the fetch is an optimization, never a precondition.
3. Picks the re-root target: `origin/<default>` if that remote-tracking ref exists,
   otherwise the local `<default>` branch. So there is always something to re-root
   onto, even fully offline.
4. Hands that target to the ordinary `--onto` path. Because the target *is* the
   repo-resolved default, ADR 0018's existing `_stack_base_set` call (which unsets
   the key when the target equals that default) resets `stack.<prefix>.base` back to
   the repo default for free. No new base-clearing logic. (The default is whatever
   `_resolve_parent_name` yields with no prefix — `stack.base` → `init.defaultBranch`
   → `main`/`master` — so in a `stack.base=develop` repo this lands on `develop`, not
   the trunk.)

`--onto-default` is mutually exclusive with `--onto <ref>`.

### Why a verb mode, not a shell function

ADR 0001 established the invariant that shell integration ships **plain aliases,
never compound shell functions** (enforced by `init bash`'s "no shell functions"
test). The old `gstkrom` was a compound `fetch && restack` snippet — re-adding it
that way would reinstate a shell function and break the invariant. Putting the
logic in the verb keeps `gstkrom` a one-line alias (`git stack restack
--onto-default`), so the invariant holds (the alias count moves 26 → 27,
`func_count` stays 0), the behavior gets bats coverage, and bash/zsh/fish stay
identical. The plumbing verb `default-branch` (retained by ADR 0001) already exists
for exactly this kind of "resolve the trunk for a shell caller" need.

### Why not change `clean`

`clean`'s per-stack-base behavior (ADR 0018) is intended, and the user confirmed it
reads correctly — clean tidies a stack against *its* base. Overloading it with a
"but reflow onto the trunk instead" mode would blur that. `restack` is the re-root
verb; `--onto-default` belongs there.

## Consequences

- `gstkrom` returns, now pointing at a tool verb instead of a shell snippet.
  `gstkromp` (the `--push` twin) is not restored — `--onto-default` composes with
  `--push` for anyone who wants it, and `gstkrp` already exists.
- The escape hatch from a custom-rooted stack back to the repo default is one alias
  again, and it clears the per-stack base as a side effect (via ADR 0018's resolver),
  so a subsequent `clean`/`list`/`pr sync` sees the repo-resolved default.
- `restack` gains a mode that touches the network. It is scoped: plain `restack
  --onto <ref>` and bare `restack` keep their existing no-fetch contract; only
  `--onto-default` fetches, and even then best-effort.
