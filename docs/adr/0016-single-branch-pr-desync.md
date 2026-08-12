# ADR 0016 — `pr desync [<branch>]`: a proportionate remedy for single-branch mutations

- **Status:** Accepted (2026-08-11)
- **Context doc:** [CONTEXT.md → PR sync](../../CONTEXT.md#pr-sync), [CONTEXT.md → Commands](../../CONTEXT.md#commands)
- **Amends:** [ADR 0014 §5](0014-reslug-rename-a-branch-slug.md)'s "disproportionate
  remedy" framing; completes the [ADR 0013](0013-pr-state-changes-are-explicit.md)
  guard set

## Context

ADR 0013 established that no verb mutates the PR chain as a side effect of a local
operation: a verb whose rename would hit an open head PR refuses and points at the
`pr desync` → mutate → `pr sync` trio. Three verbs do that, and all three rename
exactly **one** branch:

| verb | gate (`bin/git-stack`) | gates on |
| --- | --- | --- |
| `reslug` | `_check_no_open_prs "$target"` | 1 branch |
| `move --at` (renumber-in-place) | `_check_no_open_prs "$src_branch"` | 1 branch |
| `drop` | `_check_no_open_prs "$victim"` | 1 branch (the victim) |

`pr desync` was whole-stack only — `cmd_pr_desync` took no positional at all. So
fixing a typo in one branch's slug on a published five-branch stack cost **five**
closed PRs, and with them five sets of review threads, approvals, and CI history,
to protect one. The gate was right; the remedy was disproportionate, and that
mismatch was the strongest live objection to ADR 0013's hard-block-with-no-escape
stance. ADR 0014 §5 had already rejected an `--allow-pr-orphan` escape on the
grounds that leaving an orphan for a later `clean` to close is the opposite of
explicit — correctly, but that left the cost unaddressed rather than answered.

The remaining gate, `move`'s **reorder** path, is different in kind: its
cherry-pick reflow rewrites every affected branch's tip, so its
`_check_no_open_prs "${affected[@]}"` is genuinely multi-branch. A multi-PR
remedy is proportionate there.

## Decision

**`pr desync` takes an optional `<branch>`.** With it, close only that branch's
PR; without it, the previous whole-stack behavior, unchanged. `<branch>` resolves
through `_resolve_branch_ref`, so a numeric leaf or a full branch name both work —
the convention `reslug`, `move`, `drop`, and `checkout` already follow.

```sh
git stack pr desync feat/015-auth    # close only #12
git stack reslug feat/015-auth authz
git stack pr sync                    # re-publish; the rest of the chain never moved
```

The trailing whole-stack `pr sync` is what makes this pay: it mints a fresh PR for
the one branch and **updates** the others in place (bases, `[N/M]` titles, nav
footers). Four review threads survive where previously zero did. That composition
is asserted end-to-end, not just reasoned about — a test walks
desync → reslug → sync and pins the neighbours' PR numbers, their open state, a
zero close count, a single create, and the successor's base following the rename.

### 1. Narrow the action set, not the scan

Phase 1 builds `PLAN_*` / `OPEN_AFTER` arrays index-aligned with the full
`branches[]`, and phase 2's `--delete-remote` guard consults a branch's
*successor* by index. Narrowing `branches[]` to one entry would destroy that
guard — `i+1` would run off the end and the successor's PR would be invisible.

So single-branch mode is a target **index** (`target_idx`, `-1` for whole-stack).
The scan stays full-width; only the set of branches acted on narrows. Out-of-scope
branches still get their PR state classified — that is all `OPEN_AFTER` needs —
but stop short of the comment query and the activity prompt, which would ask about
work we will not do either way.

### 2. `--delete-remote` is refused up front, not warned about

Deleting a remote branch closes any PR that *targets* it. In single-branch mode
the successor's PR still bases on the target's remote name, and nothing has
retargeted it — that is `pr sync`'s job, which by definition hasn't run yet.

Phase 2's existing guard would catch the hazard and warn `keeping remote X`. That
is the wrong response to an explicit request: a silent "kept it anyway" when the
user asked for a delete reads as a bug. So the check moves **up front**, before
any prompt or mutation, and refuses.

The condition is **exact, not the tip-only heuristic** first sketched: refuse when
the immediate successor exists *and* has a PR *and* that PR is `OPEN`. A successor
with no PR, or a merged or closed one, is no hazard and is allowed through.
Refused under `--dry-run` too — previewing a delete the real run would refuse is
worse than previewing nothing.

- *Alternative:* let phase 2 warn-and-skip. *Why not:* see above.
- *Alternative:* refuse unless the target is the stack tip. *Why not:* over-strict,
  and it would reject the common "successor isn't published yet" case.
- *Not used:* `_gh_open_index_find_by_base`. `cmd_pr_desync` never loads
  `_GH_OPEN_INDEX`, and pulling it in would add a bulk query (plus the gh stub's
  `__HEAD` seeding requirement) to buy nothing over index adjacency — which is
  also exactly what the phase-2 guard already keys on.

### 3. Out-of-scope branches are neither listed nor counted

In whole-stack mode `skip` means *considered and declined* — a merged PR, an
already-closed one, an activity-kept one. That is not what happens to a branch
outside a single-branch target, so printing `skip` for it would misreport. Their
rows are suppressed and they are left out of the `skipped` tally, replaced by one
scope line up front:

```
desync: feat/015-auth only (4 other branches untouched)
close   #12 feat/015-auth
desynced: 1 closed, 0 remote deleted, 0 skipped
```

Whole-stack output is byte-identical to before.

### 4. The three single-branch gates name the single-branch form

`reslug`, `move --at`, and `drop` now point at `pr desync <that branch>` rather
than bare `pr desync`. `move`'s reorder path deliberately still points at the
whole-stack form, because its gate spans every affected branch (§Context above);
a test asserts that asymmetry so it reads as deliberate rather than missed.

## Consequences

- ADR 0013's hard block is now proportionate at every gate, and the
  `--allow-pr-orphan` escape ADR 0014 §5 rejected is no longer even tempting: the
  cost it was trying to dodge is gone. That section's "disproportionate remedy"
  framing is superseded.
- A single-branch desync followed by `pr sync` gives the target a **new PR
  number**. That is inherent to ADR 0013's mechanics (a closed PR is never
  reattached), not new here — but it is now the common case rather than the
  whole-chain one.
- `--delete-remote` is unavailable for a mid-stack branch whose successor is
  published. Skipping it is cheap: the stale remote stays under the same prefix,
  where `clean` reaps it (the same trade ADR 0014 §5 already makes for `reslug`).
- The gh test stub's `--head` lookup ignored `--state`, so a closed PR still
  answered the `--state open` guard query. It now filters, matching the bulk path.
  Without that fix a single-branch desync appeared not to unblock `reslug`.
- `pr desync` gains branch completion in both shells, one level deeper than the
  usual verb positional (`words[3] == desync` in zsh; two chained
  `__fish_seen_subcommand_from` conditions in fish, since it ORs its arguments).
- `doctor` remains the one verb that can churn a published stack's PRs with no
  guard at all (ADR 0013 §3). Untouched here.
