# ADR 0012 — interactive prompts re-prompt and preserve input

- **Status:** Accepted (2026-07-01)
- **Context doc:** [CONTEXT.md → Commands → create](../../CONTEXT.md#stack-level)
- **Builds on:** the existing "prompt for a missing value on a TTY" pattern (`add`'s slug prompt, the `checkout`/`pick` selectors)

## Context

`create` required `<prefix>` and `<slug>` as positional arguments and died if
either was missing. `add` already prompts for a missing slug, but as a
**single shot**: a typo (or any downstream failure) aborts the whole command, and
the next run starts from a blank prompt — you retype everything you'd typed
before. That retype-from-scratch loop is the papercut this addresses.

Making `create` interactive raises the question of what happens on bad input, and
that answer should be a **convention** the whole porcelain follows, not a
one-off — otherwise `create` and `add` drift into different prompt behaviors.

## Decision

Interactive prompts **re-prompt on invalid input and preserve what was entered**,
rather than dying. Concretely, for `create` when `<prefix>`/`<slug>` are omitted
on a TTY (off a TTY, a missing value stays a usage error — the scriptable
contract is unchanged):

1. **Re-prompt loop per field.** A rejected value re-asks the same field with the
   rejection reason shown, instead of aborting. Already-accepted fields are never
   re-asked — a bad slug never makes you retype the prefix.

2. **Edit-in-place where the shell allows it.** On bash 4+ the rejected value is
   pre-filled on the input line via `read -e -i` (readline), so you edit rather
   than retype. On bash 3.2 (stock macOS — the project keeps 3.2 compat; CI runs
   `macos-latest`) there is no `read -i`, so it degrades to a blank re-prompt. No
   information is lost either way: the rejection reason is printed above the
   re-prompt, and for slug/leaf-clash failures that reason names the offending
   value — only the in-place edit is unavailable on 3.2. Feature-detected on
   `BASH_VERSINFO[0] >= 4`; one shared helper (`_prompt_prefill`).

3. **Cancel is Ctrl-C or Ctrl-D** (EOF → `read` returns non-zero → clean
   `aborted`). Empty input re-prompts (it fails validation). No max-retry cap.

4. **Validators return, they don't die.** `_validate_slug` and the new
   `_validate_prefix` emit a message into `_VALIDATE_MSG` and return non-zero. The
   argument path reacts with `|| die "$cmd: $_VALIDATE_MSG"` (preserving the old
   hard-fail); the loop shows the message and re-asks. This split is what lets one
   validator serve both the scriptable and interactive paths.

### Ordering: fail fast before prompting

So the loop only ever fires on genuinely re-typable input errors, `create` runs
every input-independent check *before* the prompts: repo/op/state guards, base
resolution, and the **dirty-tree carry decision**. The carry *decision* moves
ahead of the prompts (declining, or a non-TTY dirty tree, aborts before you type
anything), but the carry *stash action* stays deferred to just before the ref
mutation — so a Ctrl-C mid-prompt strands no stash.

## Consequences

- `create` with no args on a TTY walks prefix → slug; a lone positional is the
  prefix, so `create foo/bar` prompts only for the slug.
- The "prefix already has branches" guard, when the prefix was *typed*, re-prompts
  ("pick another") instead of dying — the slug you'd enter next isn't thrown away.
  A *passed* prefix still dies with the point-at-`add` hint.
- Interactive loop + prefill are **not** bats-testable (no controlling terminal);
  the pure validators are unit-tested and the non-TTY usage die is pinned. Same
  coverage boundary as `_confirm`.
- `add`'s own slug prompt is **not** retrofitted here — it keeps single-shot
  behavior for now; applying this policy to `add` is a tracked follow-up. Only the
  mechanical `_validate_slug` return-not-die change touches `add` (behavior-
  preserving).
