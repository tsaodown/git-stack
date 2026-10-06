# ADR 0020 — `stack.namespace`: a personal root prepended to typed prefixes

- **Status:** Implemented (2026-10-05)
- **Context doc:** [CONTEXT.md → Stack shape](../../CONTEXT.md#stack-shape), [CONTEXT.md → Commands](../../CONTEXT.md#commands)

## Context

A stack's **prefix** is its name — the first argument to `create`, the shared
leading segment of every branch in the stack (`feat/` in `feat/010-auth`). Many
users root *every* stack under a constant personal segment — e.g. all of a
developer's stacks live under `eft/`, so their prefixes are `eft/feat`,
`eft/spike-foo`, `eft/heal-6910`. Today that root is retyped on every `create`
and `rename`: `git stack create eft/feat auth`, `git stack rename eft/other`.
The root carries no information the tool couldn't supply — it is the same string
every time — so typing it is pure friction.

`stack.prefix` already exists but means something different: it **pins the
current stack** when branch auto-detection can't (read ahead of auto-detect by
every verb). Overloading it with "prepend this to new prefixes" would entangle
"which stack am I on" with "what namespace do I create under," and change the
resolution of unrelated verbs. The need is a separate, additive fact.

## Decision

Add **`stack.namespace`** (typically set `--global`, e.g. `eft`): a root
prepended to every *human-typed* prefix.

One helper, `_expand_prefix <typed>`, applied at exactly the points a human
types a prefix — `create` (positional arg + interactive prompt) and `rename`
(`<new-prefix>` arg). Its rules:

1. **No namespace set → identity.** Unset/empty `stack.namespace` leaves every
   typed prefix untouched — including a leading `/`, which still falls through to
   `_validate_prefix`'s "must not start with /" rejection exactly as before. The
   escape and root-rejection rules below apply *only* under a namespace, so the
   feature is fully inert when off. (The one test-suite change is harness
   isolation — see Consequences — not a behavior change.)
2. **Leading `/` → absolute escape.** `create /hotfix slug` strips the slash and
   skips the namespace, rooting outside it (`hotfix/010-slug`). This is the
   explicit way to make a stack that does not live under the namespace — and the
   only way to root one *at* the namespace itself (`create /eft slug` →
   `eft/010-slug`). The slash is consumed inside the helper, before
   `_validate_prefix` (which otherwise rejects a leading slash) ever sees it.
3. **Typed value == the root → reject.** `create eft slug` (or pressing Enter on
   the prefilled `eft/`) names no stack *under* the root, which contradicts the
   namespace sitting above every stack name. It is refused — re-prompt on a TTY,
   die for a positional arg — with a message pointing at the `/` escape for the
   deliberate root-level case. `_expand_prefix` returns non-zero with
   `_VALIDATE_MSG` set, mirroring `_validate_prefix`'s return-not-die contract.
4. **Already under the root → identity (idempotent).** `create eft/feat` under
   `stack.namespace=eft` stays `eft/feat`, never `eft/eft/feat`. So a typed full
   prefix and a typed short name both do the right thing.
5. **Otherwise → `<root>/<typed>`.** `create feat auth` → `eft/feat/010-auth`.

Expansion runs **first**, then `_validate_prefix` runs on the full expanded
prefix, so the leaf-clash check inspects the real last segment. Because
`_expand_prefix` reports its rejection through `_VALIDATE_MSG`, it writes its
result into a caller-named out-var (like `_prompt_prefill`) rather than echoing
through a command substitution, which would discard that message.

The interactive `create` prompt **prefills the namespace** (`eft/`) so the user
sees the root and extends it rather than retyping; the idempotence rule keeps
that prefill from doubling if they paste a full prefix.

### Scope: only typed prefixes, only create/rename

`_expand_prefix` is called **only** on values a human types. It is deliberately
**not** applied to:

- **auto-detected prefixes** (derived from the checked-out branch — already a
  full prefix),
- the **`stack.prefix`** config value,
- **`stack.<prefix>.base`** keys (ADR 0018), or
- **snapshot refs** (`refs/stack-backup/<prefix>/…`).

Those are already full prefixes; expanding them would double the root.

v1 wires `create` and `rename` only — the two verbs where you *name* a stack.
`--prefix`/`pick`/`reslug` (pointing at an **existing** stack) are left as-is;
extending the short form to them is a possible follow-up, not part of this ADR.

### Why not a default/fixed prefix

An earlier reading was "a configured prefix used when you type none" (`create
<slug>` → `eft/010-slug`). Rejected: `create` refuses a prefix that already has
branches, so a single fixed prefix would allow exactly one stack ever, and a
lone positional arg would be ambiguous between prefix and slug. The namespace
model keeps `create <prefix> <slug>`'s shape and supports many stacks under the
root.

## Consequences

- `git config --global stack.namespace eft` once, then `create feat auth` and
  `rename other` stay in `eft/` without retyping it.
- The word "namespace" is now a first-class term for this root (CONTEXT.md),
  removed from the prefix term's _Avoid_ list — it names a concept that sits
  *above* the prefix, distinct from the prefix itself.
- Tab-completion (ADR 0004) still offers full prefixes; whether the completers
  should also offer short (namespace-relative) forms is a named follow-up.
- **Test-harness isolation.** `setup_repo` now runs each test under an empty
  `GIT_CONFIG_GLOBAL` with `GIT_CONFIG_NOSYSTEM=1`. Without it, a developer who
  sets `stack.namespace` `--global` (the intended way) would see every
  bare-prefix assertion fail locally, while CI — whose runners have no global
  config — stayed green. Tests must not depend on the runner's own git config.
