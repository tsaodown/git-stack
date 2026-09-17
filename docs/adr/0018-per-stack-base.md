# ADR 0018 — per-stack base: remember what a stack was rooted on

- **Status:** Accepted (2026-09-16)
- **Context doc:** [CONTEXT.md → Base](../../CONTEXT.md#stack-shape), [CONTEXT.md → PR sync](../../CONTEXT.md#pr-sync), [CONTEXT.md → Commands](../../CONTEXT.md#commands)

## Context

git-stack has always modelled the **base** as a single repo-global fact:
`_resolve_parent_name` reads `stack.base`, then `init.defaultBranch`, then a local
`main`/`master`. Every verb that needs the branch under the stack goes through that
one resolver.

`create --onto <ref>` lets you root a stack somewhere other than the default, but
the ref is used only to set the new branch's starting commit — it persists
nothing. The moment `create` returns, the "rooted on `<ref>`" fact is gone. A
later `pr sync` re-derives the base from the global resolver, gets `main`, and:

- opens the bottom PR with `--base main`, and
- computes that PR's diff against `main` (`base0` feeds `_pr_active_branches` and
  `_pr_is_empty_diff`), so the PR shows the parent branch's commits mixed in with
  the stack's own — the symptom a user actually notices.

The only workaround was `git config stack.base <parent>`, which is repo-global: it
retargets *every* stack in the repo and has to be unset once the parent merges.
There was no way to say "this one stack sits on `develop`" and have the tool
remember it.

## Decision

A stack's base becomes a per-stack fact, keyed on the **prefix** — the stack's
stable identity — and slotted into the existing resolver as a new highest-priority
tier.

### 1. Persist as `stack.<prefix>.base`

The base for a stack under prefix `eft/` is stored at git config key
`stack.eft/.base`. The prefix is stored exactly as the rest of the tool holds it,
trailing slash included, so the key always matches how it is looked up.

git parses a dotted config key on its *first* dot (section) and *last* dot (key),
taking everything between verbatim as the subsection — so slashes and even dots in
a prefix (`eft/v2.x/`) round-trip cleanly through `--get`, `--unset`, and
`--rename-section`. The one caveat: config **subsections are case-sensitive**
(sections and keys are not), so `stack.eft/` ≠ `stack.EFT/`. This is a non-issue
because the key is always built from the same case-stable prefix string the branch
namespace already uses; the rule is simply *never re-case the prefix* when forming
the key.

Resolution precedence becomes:

1. `stack.<prefix>.base` — this stack's own base *(new)*
2. `stack.base` — repo-global override *(unchanged)*
3. `init.defaultBranch` → `main` → `master` *(unchanged)*

`_resolve_parent_name` gains an **optional** prefix argument: with a prefix it
consults tier 1 first (stripping any `origin/`), else it behaves exactly as
before. Every no-arg caller — notably `default-branch`, which is deliberately the
global trunk — is unchanged, so the addition is backward compatible. The in-scope
prefix is then threaded into the single-stack callers (`pr sync`, `clean`,
`pr list`, `add`, `move`, `fold`, `drop`, `doctor`) so the whole tool agrees on
one base, not just `pr sync`. This is why the fix generalizes past the reported
bug: dropping the bottom branch, for instance, now lands its children on the
recorded base rather than on `main`.

### 2. Written only when it differs from the default

The key is written only when the base is genuinely non-default. Plain `create`
(rooted on the resolved default) writes nothing, so every existing stack and the
common case are untouched — the key exists *only* for stacks that are actually
rooted elsewhere. A write whose value equals the resolved default **unsets** the
key instead, so it never accumulates entries that merely restate the default.

### 3. Two write points, both branch-only

- **`create --onto <branch>`** records `stack.<prefix>.base` after the stack is
  created.
- **`restack --onto <branch>`**, on a *direct*, whole-stack re-root
  (`from_idx == 0`), rewrites it — re-rooting the stack onto a new branch updates
  what it remembers, so the recorded base always reflects where the stack actually
  sits.

Both writes require the `--onto` target to resolve to a **branch** (local or
`origin/<b>`). A bare SHA or tag records nothing and stays a one-shot re-root, as
today — a commit id is useless as a GitHub PR base.

The `restack` write is gated on `_SNAPSHOT_SUPPRESS == 0`, which is set by `clean`
and `amend` around their internal `restack` calls. That gate is what keeps
`clean`'s reflow-onto-the-existing-base (`cmd_restack --onto "$base_ref"`) from
spuriously writing a config entry: only a re-root the user typed directly counts.

- *Alternative:* key on the bottom branch name (`branch.<bottom>.stackBase`).
  *Why not:* the bottom branch changes on every `reslug`, `move`, and `drop`, so
  the key would need chasing on each — the prefix is invariant across all of them.
- *Alternative:* always write the base, even for default-rooted stacks.
  *Why not:* it churns config for every `create` and makes existing stacks look
  different from new ones for no behavioral gain; the default resolver already
  gets those right.

### 4. `rename` migrates the key

A prefix rename moves `stack.<old-prefix>.base` → `stack.<new-prefix>.base` via
`git config --rename-section`, in the same inline step that already updates
`stack.prefix` (the local-rename stage, not the generic rename-batch phase).

### 5. A gone base warns and falls back to the default

When `stack.<prefix>.base` is set but the branch no longer resolves to any ref —
the usual cause being the parent merged and was deleted — the resolver warns to
stderr and falls through to the global default (tier 2/3). The stack keeps working
without manual cleanup; the bottom PR simply retargets `main` from then on. The
stale key is **not** auto-unset (the branch may be recreated), but the warning
names it and suggests `--unset`.

- *Alternative:* error like any unresolvable ref (mirror `stack.base` today), or
  grow a `doctor` check that offers to repoint. *Why not:* a merged parent is the
  *expected* end state of a stacked branch, not an error condition — silently
  degrading to the trunk is what the user wants there, and a warning is enough to
  make it visible.

### 6. `pr sync` requires the base on origin

A non-default base only works as a GitHub PR base if it has been pushed:
`gh pr create --base <b>` fails when `<b>` isn't on the remote. `pr sync` checks
the resolved base exists as `origin/<b>` and, if not, fails with a "push `<base>`
first" message rather than surfacing a raw `gh` error. (`main` is always present,
so default-rooted stacks never hit this.)

## Consequences

- A stack rooted with `create --onto develop` now syncs, cleans, reflows, and
  lists against `develop` for its whole life, with no repo-global `stack.base`
  toggling and no per-run flags.
- The bottom PR's diff is correct: because `base0` is the real base, the PR shows
  only the stack's own commits, not the parent branch's.
- `stack.base` keeps its meaning as a repo-wide override and still wins over the
  default — it now simply sits *below* the per-stack key. A repo that never uses
  `--onto` sees no change at all.
- The base can now legitimately be a branch that later disappears. Decision 5 is
  what makes that a non-event rather than a broken stack, but it does mean a
  stack's effective base can change (to `main`) without any command being run —
  visible via the warning and in `list`'s base column.
- `restack --onto` is now mildly stateful: a direct whole-stack re-root has a
  durable side effect (the recorded base) that a partial `--from` reflow or an
  internal `clean`/`amend` restack does not. The `_SNAPSHOT_SUPPRESS` gate and the
  `from_idx == 0` + branch-only conditions are what keep that side effect scoped
  to exactly the case the user means by "re-root this stack."
