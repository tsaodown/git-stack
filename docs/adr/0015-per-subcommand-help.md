# ADR 0015 — per-subcommand `--help`, and `help` demoted to an index

- **Status:** Accepted (2026-08-11)
- **Context doc:** [CONTEXT.md → Architecture → Help](../../CONTEXT.md#help)

## Context

`cmd_help` was one ~300-line heredoc: every verb, hand-wrapped into a 36-column
hanging indent, with four reference sections at the end. It was the only way to
read a verb's flags, so answering "what does `fold --slug` do again?" meant
paging a wall of text and eyeballing for the right block — and `git stack fold
--help` was an unknown-subcommand error.

The prose itself is good and worth keeping; the problem is purely that it had one
entry point and one width. A second constraint shaped the design: the same
one-line verb descriptions already existed in `_complete_verbs`, on the
completion path, which has a hard never-die/never-print contract (ADR 0004).

## Decision

Split the monolith into **help topics** — one per verb — and render them two
ways. Four decisions, each over a named alternative:

### 1. `help` becomes an index; detail moves behind `<verb> --help`

`git stack help` prints a grouped verb + one-liner table (stack-level,
branch-level, plumbing) plus the reference sections — about 65 lines. Per-verb
prose is reachable as `git stack <verb> --help`, `git stack help <verb>`, or
`git stack help --all`.

- *Alternative:* keep `help` byte-identical and have `--help` print the verb's
  existing 36-column chunk verbatim.
- *Why:* that keeps the wall *and* wastes half the terminal width on every
  standalone invocation. Relocating the prose lets each rendering pick its own
  width, and matches what `git`/`gh` users already expect. `--all` preserves the
  one-dump-to-grep case.

### 2. Prose is relocated and re-wrapped, not reflowed at runtime

Each topic is a heredoc hand-wrapped to ~78 columns.

- *Alternative:* store descriptions as data and wrap with `fold -s` per terminal
  width.
- *Why:* the text carries color escapes, which `fold` counts as visible
  characters — every wrapped line would break alignment. Hand-wrapping is also
  what the file already did.

### 3. `_verb_table` is the shared source of truth, read by both help and completion

`group<TAB>verb<TAB>one-liner` rows. `_help_index` renders all three groups;
`_complete_verbs` drops the `plumb` group. `_subverb_table` does the same for
`pr`/`history`.

- *Alternative:* leave `_complete_verbs` untouched and write the 19 one-liners a
  second time in the index.
- *Why:* two hand-maintained copies of the same sentence drift. The table is pure
  `printf` — no repo access, no stderr — so reading it from the completion path
  cannot violate the never-fail contract. A test asserts every completion verb
  has a topic and vice versa, so the remaining drift surface is covered.

### 4. `--help` is positional-only

Honored in `$2` (after the verb) or `$3` (after a subverb); nowhere else.

- *Alternative:* pre-scan all of `"$@"`, like the existing `--color` pre-scan in
  `main()`.
- *Why:* a flag *value* may contain the word. `git stack amend -m "document the
  --help flag"` must amend, not silently print help and discard the commit. That
  pre-scan is harmless for `--color` and a command-swallower for `--help`.

Two orderings fall out of this and are load-bearing:

- An undocumented verb makes `_help_verb` return 1 and **fall through** to the
  dispatch `case`, so `push --help` still prints the "renamed to `sync`" hint and
  `bogus --help` still prints unknown-subcommand — no duplicated error handling.
- `__complete` dispatches *before* the pre-scan; otherwise `__complete --help`
  would print a topic and corrupt the user's prompt.

## Topic granularity

Mirrors what the help text already distinguished, rather than forcing symmetry:

| Verb | Topics |
|---|---|
| `pr` | `pr` (index of subverbs) + `pr-sync`, `pr-list`, `pr-desync` |
| `history` | one topic; `show`/`restore` documented inside it |
| everything else | one topic per verb |

`pr`'s three subverbs each had a paragraph, so each earns a topic. `history`'s
subverbs share five lines — splitting them would mean inventing prose. So
`history restore --help` resolves to the `history` topic; `co`/`mv` resolve to
`checkout`/`move`.

## Consequences

- `git stack help` output changes shape. Anything scraping it for flags should
  use `help --all`.
- Adding a verb now touches `_verb_table`, `_help_topic`, and `_help_verb` on top
  of the dispatch `case`. The drift test fails loudly if a topic is forgotten.
- Plumbing verbs (`prefix`, `default-branch`, `init`) are visible in the index
  under their own group, while staying out of completion — the `plumb` group
  makes that split explicit rather than incidental.
- Flag-level help (`fold --slug --help`) is out of scope; topics document flags
  in prose.
