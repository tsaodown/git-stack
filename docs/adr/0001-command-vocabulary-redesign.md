# ADR 0001 — Command vocabulary redesign

- **Status:** Implemented (2026-06-01)
- **Context doc:** [CONTEXT.md → Commands](../../CONTEXT.md#commands)

## Context

`git stack new` was overloaded: inside a stack it inserted a branch; with no
stack detected it silently *bootstrapped a new stack* (picked or typed a prefix).
The mode was implicit — driven by where HEAD happened to be — and from inside
stack A you could not start a brand-new stack B.

A grilling session (2026-06-01) surfaced that the wider verb surface had grown
inconsistent: there was no first-class way to see or hop between stacks, `list`
meant "branches in my stack" but fell back to a stack picker from outside,
`push`/`push --all` exposed per-branch network detail nobody wanted, `close` was
a prune-only teardown, and `status` duplicated much of `list`.

## Decision

Adopt a two-tier verb model. **Current stack stays HEAD-derived** — the prefix of
the checked-out branch — with no new tool-managed pointer (`stack.prefix` remains
a manual override only).

### Verb map

| verb | alias | behavior | replaces |
|---|---|---|---|
| `list` | `gstkl` | overview of **all** stacks: branch count, tip, current marker, base + ahead/behind. Local only (no `gh`). | old per-stack `list` |
| `view [stack]` | `gstkv` | one stack's contents, no checkout (current or named; trailing `/` optional; picker on unknown/ambiguous or no-arg-outside). Folds in old `status`: per-branch local↔origin sync + paused-op banner + last-snapshot line. | `status` |
| `pick` | `gstkp` | choose a stack (selector = `list` rows) → checkout its **tip**. Works inside a stack (hop out). | extracted from checkout's outside path |
| `checkout [N]` | `gstkco` | move within current stack (leaf `N` or branch picker). Outside: `list` selector → branch picker. | unchanged (selector extracted) |
| `create <prefix> <slug>` | `gstkcr` | new stack: first branch off **base** (`--onto <ref>` override); errors if prefix exists; checks out. | `new` bootstrap path |
| `add <slug>` | `gstkad` | branch in **current** stack (flag/picker placement); errors outside a stack. | `new` insert path |
| `sync` | `gstks` | push whole stack to remote, **additive only** (no deletes, no PR work, no `--from`). | `push` / `push --all` |
| `clean` | `gstkcl` | prune local `[gone]` → delete extraneous remote branches under prefix (confirm-gated; decline skips only that step) → fetch → reflow survivors onto `origin/<default>`. Can pause. | `close` + `gstkcl`/`gstkrom`/`gstkromp` helpers |
| `abort` | `gstkab` | unchanged behavior; alias spelled out for intent. | `gstka` |
| `continue` | `gstkcon` | unchanged behavior; alias spelled out for intent. | `gstkc` |

Unchanged: `move`, `rename`, `restack` (+ `--push`/`--onto`), `amend`, `doctor`,
`history` (+ `show`/`restore`), `pr sync`, `pr list`, `default-branch`, `init`,
`prefix`.

**Removed:** `new`, `close`, `push`, `status` — dispatch errors with a one-line
"renamed to X" hint. **Dropped aliases:** `gstkn`, `gstkpa`, `gstkrom`,
`gstkromp`, and the `gstkcl` *shell function* (now the `clean` verb). `gstka` and
`gstkc` are vacated (abort/continue move to `gstkab`/`gstkcon`).

### Key behavioral rulings

- **`pick` vs `checkout` from outside:** both share the `list` stack-selector;
  `pick` then lands on the **tip** (fast hop), `checkout` then shows a **branch
  picker** (specific branch).
- **`create` base:** roots the first branch on the resolved base
  (`stack.base` → `origin/<default>` → local default); `--onto <ref>` overrides.
  First leaf `010` (sparse width-3, via `_next_leaf_num`). Requires a clean tree.
- **`create` guard:** if the prefix already has branches, error and point at `add`.
- **`add` outside a stack:** error pointing at `create`/`pick`. No silent bootstrap.
- **`sync` is additive:** never deletes remote refs; remote cleanup is `clean`'s job.
- **`clean` remote deletion is confirm-gated:** on decline, skip *only* the remote
  deletion and continue with fetch + reflow.

## Consequences

- `gstkl` silently changes meaning (per-stack branches → all-stacks overview).
  Accepted as a deliberate retrain; aliases self-update on next shell after reinstall.
- Stacks without PRs lose a "push branches without touching PRs" path (only `sync`
  and `restack --push` remain). Accepted.
- `view` carries the resume affordance (paused banner) that `status` held; the
  verbose phase/unit/from-idx dump is dropped (rely on `continue`/`abort` messaging).

---

## Implementation plan

Work bottom-up: shared helpers → command bodies → dispatch/aliases → docs/tests.
Keep the existing engine/reconciler/placement modules untouched where possible;
this is mostly a renaming + re-routing of `cmd_*` entry points plus two genuinely
new behaviors (all-stacks `list`, remote-orphan deletion in `clean`).

### Phase 0 — Safety net

1. Confirm the suite is green at HEAD: `make test` (or the bats entry in
   `tests/`). Record the baseline pass count (176 tests).
2. Branch off `main` (do not commit to `main`).

### Phase 1 — Shared selection helpers

3. Add a `_select_stack` helper that renders the **all-stacks** rows (branch
   count, tip, current marker, base + ahead/behind) and returns a chosen prefix.
   Factor it so both `cmd_list` (display) and the pickers (`pick`,
   `checkout`-outside, `view`-no-arg-outside) share one renderer. Source data:
   `stack_prefixes` + per-prefix `_load_stack_branches` + `_resolve_parent_*` +
   `git rev-list` ahead/behind counts.
4. Keep `_pick_branch` as-is for branch selection within a chosen prefix.

### Phase 2 — Stack-level commands

5. **`cmd_list` → all-stacks overview.** Replace the current per-stack body with
   the `_select_stack` renderer in non-interactive (print-all) mode. No `gh`.
6. **`cmd_view` (new).** Move the *old* `cmd_list` per-stack body here, then fold
   in `cmd_status`'s blocks: per-branch local↔origin sync, a one-line paused-op
   banner (derive from the state file / `CHERRY_PICK_HEAD` etc.), and the
   last-snapshot line. Drop the verbose state dump. Accept an optional `[stack]`
   arg (trailing-slash-tolerant; picker on unknown/ambiguous/no-arg-outside).
7. **`cmd_pick` (new).** `_select_stack` → checkout the tip (highest-leaf branch).
   Always offers the selector, even from inside a stack.
8. **`cmd_create` (new).** Split out the bootstrap path of `cmd_new`: take
   `<prefix> <slug>`, validate the prefix is *empty* (else error → `add`), resolve
   base (honor `--onto`), create `prefix/<first-leaf>-slug`, checkout. Reuse
   `_placement_resolve`/`_next_leaf_num`/`_format_leaf`.
9. **`cmd_add` (rename of branch-insert path).** Take `cmd_new`'s in-stack insert
   logic verbatim; require a current stack (error → `create`/`pick` otherwise).
   Drop the no-stack bootstrap branch entirely.
10. **`cmd_clean` (rename + expand `cmd_close`).** Keep the local `[gone]` prune.
    Add: enumerate remote branches under the prefix with no local counterpart →
    confirm → `git push origin --delete` (skip on decline, continue). Then fetch
    `origin/<default>` and run the `restack --onto` reflow over survivors (reuse
    the engine plan `cmd_restack`/the old `gstkrom` used). Preserve `--dry-run`.

### Phase 3 — Branch-level commands

11. **`cmd_sync` (rename + simplify `cmd_push`).** Whole-stack additive push only:
    drop `--from`/`--all`/single-branch logic; push every branch with
    `--force-with-lease`. No PR work.
12. **`cmd_checkout` outside-a-stack path:** route through `_select_stack` then the
    branch picker (today it inlines a prefix `_pick_one`; swap to the shared renderer).

### Phase 4 — Dispatch, removed verbs, aliases

13. **Dispatch table** (`main`): add `create`/`add`/`pick`/`view`/`sync`/`clean`;
    remove `new`/`close`/`push`/`status` and replace each with a `die "… renamed to
    X"` stub. Keep `co`/`mv` short forms.
14. **Alias emitters** (`_emit_init_posix` *and* `_emit_init_fish`): rewrite the
    table per the verb map. Remove `gstkn`, `gstkpa`, `gstkrom`/`gstkromp`, and the
    `gstkcl`/`gstkrom`/`gstkromp` shell *functions*. Move `gstkp`→pick,
    `gstks`→sync, `gstka`→`gstkab`, `gstkc`→`gstkcon`. Add `gstkcr`/`gstkad`/
    `gstkv`/`gstkcl`(verb).
15. **Help text** (`cmd_help`, ~L1650): rewrite the command list and any
    `gstk*` references in `die`/`warn` strings (the inline `[gstk…]` hints at
    L339/456/610/721-740/924/1077/1192/1214-1216/2307/4121/5239).

### Phase 5 — Tests

16. Update `tests/git-stack.bats` (33 references): rename `git stack new`→
    `create`/`add`, `close`→`clean`, `push`→`sync`, `status`→`view`. Add cases for:
    `create` prefix-exists guard, `add` outside-a-stack error, `list` all-stacks
    output, `pick` lands-on-tip, `clean` remote-orphan deletion + decline-continues,
    `sync` additive (no remote delete), removed-verb "renamed to X" hints.
17. Update `tests/unit.bats` if any unit touches renamed helpers.
18. `make test` green; pass count ≥ baseline (new cases added).

### Phase 6 — Finalize docs (per the request)

19. **README.md:** fix the Quick-start block (`new --prefix`→`create`,
    `new`→`add`, `list`→`view`/`list` as appropriate, `push --all`→`sync`); update
    the Shell-integration blurb (drop `gstkrom`/`gstkcl` helper mentions, name the
    new aliases); update the bullet list (L15-20) and the doc table if needed.
20. **docs/reference.md:** rewrite the **Shell integration & aliases** section and
    the `checkout` section; drop the `gstkrom`/`gstkcl` helper docs; document
    `pick`/`view`/`list`/`sync`/`clean`/`create`/`add`.
21. **docs/workflows.md** (548 lines, heaviest): replace every `git stack new`/
    `close`/`push`/`status` invocation; thread in `create`/`add`/`pick`/`view`/
    `sync`/`clean`; re-verify each scenario's command sequence still holds.
22. **docs/concepts.md:** add the stack-level/branch-level framing and the
    current-stack-is-HEAD-derived note; link to the Commands section.
23. **docs/doctor.md, docs/pr-sync.md, docs/development.md:** sweep for stale verb
    names (`cmd_new`/`cmd_close`/`cmd_push`/`cmd_status` and the `git stack …`
    forms).
24. **CONTEXT.md cleanup:** flip the Commands section from "agreed redesign — NOT
    YET BUILT" to shipped: remove the status caveat and the forward-looking
    paragraph in the intro, reconcile tense ("renames"→"renamed"; "replaces"→
    "replaced"), and move the verb surface into the established **Language**
    framing if appropriate. Remove any remaining aspirational phrasing elsewhere
    in CONTEXT.md surfaced during the sweep.
25. Final `make test`; manual smoke of each new verb in a scratch repo.

### Out of scope (noted, not built)

- PR-chain status columns in `list` (would need `gh`; deferred to a `--pr` flag).
- A persistent active-stack pointer (explicitly rejected — HEAD-derived).
- `push`-without-PRs as a first-class verb (rely on `sync` + `restack --push`).
