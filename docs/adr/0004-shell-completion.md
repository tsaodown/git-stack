# ADR 0004 — git-native shell completion for zsh and fish

- **Status:** Accepted (2026-06-08)
- **Context doc:** [CONTEXT.md → Architecture → Completion](../../CONTEXT.md#completion)

## Context

`git stack init` installs aliases but no tab completion. Typing verbs, leaf
numbers, and stack prefixes by hand is the friction point — exactly the values
the tool already knows. Completion needs live repo state (which leaves exist,
which prefixes), so a static completion file won't do; it has to call back into
the script. And because it fires on every tab, the data path has a hard
never-fail requirement.

## Decision

Ship git-native tab completion for `git stack`, driven by a hidden
`git stack __complete` plumbing subcommand, bundled into `init`. Five decisions,
each chosen over a named alternative:

### 1. git-native completion, not alias completion

Define a `_git-stack` function (zsh) / `complete -c git -n '__fish_git_using_command stack'`
rules (fish) so completion attaches to the real `git stack` command.

- *Alternative:* complete the `gstk*` aliases directly.
- *Why:* both shells expand aliases before completing (zsh with `complete_aliases`
  unset, fish because abbrs expand on space), so the aliases **inherit** the
  `git stack` arg completion for free. Completing the aliases would mean
  re-declaring the grammar per alias.

### 2. Value-only `__complete` helper, not a whole-line parser

`__complete <kind>` emits only dynamic value lists (`verbs`, `subverbs <verb>`,
`leaves`, `prefixes`); the shells own the static grammar via zsh's `case`/
`_describe` and fish's `complete -n …` predicates.

- *Alternative:* a helper that re-parses the whole argv in bash and returns the
  finished candidate set for the current position.
- *Why:* the shells already have battle-tested cursor/argv machinery
  (`__fish_seen_subcommand_from`, `words`/`CURRENT`). Reimplementing argv parsing
  in bash would duplicate it badly. The helper stays a pure value source.

### 3. Bundle completion into `init`, not canonical completion files

`init zsh` / `init fish` emit the completion wiring alongside the aliases, for the
user's existing `eval`/`source` rc line.

- *Alternative:* write fpath/`compdef` files and a fish `completions/` file.
- *Why:* stateless eval/source matches how aliases already ship — one rc line, no
  install step, no stale on-disk copy after an upgrade. zsh's bundled `_git`
  auto-dispatches `git stack` to a `_git-stack` function found in its `$functions`
  table, so no `compdef` or fpath entry is needed.

### 4. zsh and fish only; bash dropped

- *Alternative:* also wire bash.
- *Why:* bash completion can't render per-candidate description hints, which is
  most of the value here (leaf numbers are meaningless without their slugs).
  `init bash` still installs aliases.

### 5. Scope: verbs + high-value dynamic args, not exhaustive flag grammar

Complete the things with real ambiguity and live data; defer the long tail.

- *Covered:* top-level verbs; `pr`/`history` subverbs; `checkout` leaves; `view`
  prefixes; `--prefix` → prefixes; `--before`/`--after`/`--at` → leaves;
  `--onto`/`--from` → native git ref completion.
- *Deferred:* exhaustive flag **names**, `move`/`fold`/`rename` positionals,
  `history` snapshot ids.

## Never-fail contract

Completion runs on every tab, so `__complete` must never die, prompt, or print
errors — any leak corrupts the prompt. Every degenerate case (no repo, detached
HEAD, off-stack, empty repo, unknown kind, mid-reflow) exits 0 with empty stdout.
It guards its own repo check (not the die-ing `require_in_repo`) and uses only
non-dying helpers. This is an invariant, not an optimization.

## Single source of truth vs. duplicated grammar

`__complete` (and `_complete_verbs`/`_complete_subverbs`/`_complete_leaves`/
`_complete_prefixes`) is the one source of **dynamic candidates** — both shells
render the same lists. The **static grammar** (which slot wants which kind, the
flag-value bindings) is expressed in each shell's native DSL and is therefore
**duplicated** across `_emit_completion_zsh` and `_emit_completion_fish`. The
maintenance consequences of that split — and the zsh/fish asymmetry for adding a
verb — are spelled out in
[CONTEXT.md → Completion](../../CONTEXT.md#completion).

## Known limitations (v1)

- Flag **name** completion not provided (only flag *values*).
- `move`/`fold`/`rename` positionals and `history` snapshot ids not completed.
- fish does **not** forward an explicit `--prefix` on the line into leaf
  completion (falls back to current-branch detection); zsh **does** forward it.
- fish `git stack pr sync <tab>` re-offers `sync`/`list` (they're also top-level
  verbs) — minor, known.
- Each tab re-execs the script to run `__complete` (~50–150ms); fine
  interactively, no caching in v1.

## Consequences

- `init zsh` / `init fish` output grows the completion block; `init bash` is
  unchanged (aliases only).
- A new hidden subcommand (`__complete`) on the dispatch surface, intentionally
  undocumented.
- A per-shell drift surface: the static grammar must be kept in sync by hand when
  verbs or value-taking flags change (see CONTEXT.md maintenance note). Dynamic
  value lists stay correct for free.
- Completion requires the user's shell to have git's own completion loaded
  (zsh's `_git`, fish's bundled git completion).
