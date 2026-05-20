# `git stack new` + `git stack move` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `git stack new <slug> [pos]` (create-and-place) and `git stack move <branch> [pos]` (move-existing) commands to `git-stack`, with always-consecutive auto-reflow of numeric leaves on every insert/move, including atomic remote rename via the GitHub branch-rename API and idempotent PR re-sync. As a side change, extend `git stack rename` with the same remote+PR stages and drop decimal-leaf support entirely.

**Architecture:** Single Bash script (`bin/git-stack`) with parallel-array state and a state file at `<gitdir>/stack-rebase-state`. The existing reflow loop (`run_reflow_loop` + `do_one_step` + `cmd_continue` / `cmd_abort`) handles cherry-pick conflicts via a save/resume state machine — `move` reuses it. The existing atomic `update-ref --stdin` batch primitive (`emit_rename_batch`) is wrapped to do consecutive-leaf renames. A new `_remote_rename_batch_or_skip` helper invokes GitHub's `POST /repos/{owner}/{repo}/branches/{branch}/rename` endpoint so PRs follow the local rename without orphaning. After remote rename, `cmd_pr_sync` is auto-invoked to update `[N/M]` prefixes and base relationships.

**Tech Stack:** Bash 3.2+, `git`, `gh` (optional — required only for GitHub PR/remote sync), `jq` (test-only), `bats-core` (test-only), `fzf` (optional — interactive picker fallback).

---

## File Structure

This is a single-script tool. All production code lives in one file; all tests in one `.bats` file.

| File | Purpose | Status |
|---|---|---|
| `bin/git-stack` | Main script. New commands `cmd_new` and `cmd_move`. Shared helpers `_resolve_branch_ref`, `_leaf_width_for`, `_format_leaf`, `_remote_rename_one`, `_remote_rename_batch_or_skip`, `_post_rename_sync`. Extended `cmd_rename`. Updated `_try_detect_prefix`, `stack_branches`, `stack_prefixes`, `cmd_checkout`, `cmd_help`, `_emit_init_posix`, `_emit_init_fish`. | Modify |
| `tests/git-stack.bats` | New test groups: `new`, `move`, `rename remote`. Existing decimal-leaf tests deleted. | Modify |
| `tests/bin/gh` | gh stub — extend to recognize `gh api -X POST /repos/.../branches/.../rename` and `--jq` queries against it. | Modify |
| `tests/helpers.bash` | No structural change; may add helpers if a pattern emerges. | Maybe modify |
| `README.md` | Update alias table (`gstkn`, `gstkmv` remap, `gstkrn`), add usage examples for `new` and `move`, update stack-ordering note (no more decimals). | Modify |

No new files. No file is "too big to hold in context" — the script is ~2600 lines, well-sectioned with `# ----------` dividers; new helpers go in the natural section (e.g., new ref-lookup helpers near `branch_index`, new remote helpers near `_gh_preflight`).

---

## Conventions

- **Test framework:** bats-core. Test names: lowercase verbs, colon-prefix to group (`new: creates branch at top`). Tests use `run <cmd>` then assert `[ "$status" -eq N ]` and `[[ "$output" == *"…"* ]]`.
- **Test setup:** `setup() { setup_repo; }` provides a fresh temp git repo with `main` checked out and one `seed` commit. `make_stack_branches feat 01-a 02-b 03-c` is the canonical way to build a stack. `make_remote_origin` adds a bare `origin` and pushes all branches.
- **Test naming:** existing files use `feat/<NN>-<letter>` convention (e.g., `feat/01-a`). Stick with it.
- **Color in tests:** always pass `--no-color`.
- **Commit messages:** mirror existing style. Look at `git log --oneline -20 git-stack/` for samples. Subject in imperative ("add new subcommand", not "added").
- **Test run command:** `make test` (parallel) or `make test JOBS=1` (sequential, easier debugging). To run one file: `bats tests/git-stack.bats`. To run one test: `bats tests/git-stack.bats --filter 'new: creates branch at top'`.

---

## Task 1: Drop decimal-leaf support

Decimal leaves (`06.5-baz`) are removed. Three regexes shrink and the help text loses one example block. Existing decimal-flavored tests are deleted. This task lands first because it simplifies every regex used by later tasks.

**Files:**
- Modify: `bin/git-stack:158` (regex in `_try_detect_prefix`)
- Modify: `bin/git-stack:189` (regex in `stack_branches`)
- Modify: `bin/git-stack:229` (regex in `stack_prefixes`)
- Modify: `bin/git-stack:2470` (input validation in `cmd_checkout`)
- Modify: `bin/git-stack:2482` (regex in `cmd_checkout` leaf-extract)
- Modify: `bin/git-stack:1063-1068` (help text "Stack ordering" block)
- Modify: `tests/git-stack.bats` (delete any tests asserting decimal-leaf behavior)

- [ ] **Step 1: Find every site that mentions decimal leaves**

```bash
grep -nE '\[0-9\]\+\(\\?\.\[0-9\]\+\)\??-?' bin/git-stack
grep -nE '6\.5|07\.5|03\.5|2\.5|1\.5' bin/git-stack tests/git-stack.bats
```

Expected hits: three regex locations in `bin/git-stack` (lines 158, 189, 229), one usage-string in `cmd_checkout` (line 2470), one extraction regex (line 2482), one help-text example block (lines 1063-1068), plus the `cmd_checkout` usage hint at line 2470.

- [ ] **Step 2: Write a failing test that decimal leaves are NOT picked up as stack branches**

Add to `tests/git-stack.bats` (under a new `# ---------- decimal leaves (rejected) ----------` divider):

```bash
@test "decimals: branches with decimal leaves are ignored by list" {
  make_stack_branches feat 01-a 02-b
  git branch feat/02.5-skip feat/02-b
  run git stack list --no-fetch --no-color
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "feat/01-a"
  echo "$output" | grep -q "feat/02-b"
  ! echo "$output" | grep -q "feat/02.5-skip"
}

@test "decimals: checkout 2.5 errors out" {
  make_stack_branches feat 01-a 02-b
  git branch feat/02.5-skip feat/02-b
  run git stack checkout 2.5 --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a number"* ]] || [[ "$output" == *"no stack branch"* ]]
}
```

- [ ] **Step 3: Run the failing tests**

```bash
cd /Users/tsaodown/dotfiles/git-stack
bats tests/git-stack.bats --filter 'decimals:'
```

Expected: FAIL for both (current regex matches `02.5-skip` so it appears in `list`, and `checkout 2.5` succeeds against `02.5-skip`).

- [ ] **Step 4: Tighten the three core regexes**

In `bin/git-stack`, change three lines:

`_try_detect_prefix` (around line 158):
```bash
  [[ "$leaf" =~ ^[0-9]+- ]] || return 2
```

`stack_branches` (around line 189):
```bash
          if (match(leaf, /^[0-9]+-/)) {
            key = substr(leaf, 1, RLENGTH - 1)
            print key "\t" $0
          }
```

`stack_prefixes` (around line 229):
```bash
          if (match(leaf, /^[0-9]+-/)) {
            n = length($0) - length(leaf)
            print substr($0, 1, n)
          }
```

- [ ] **Step 5: Tighten `cmd_checkout` argument validation and leaf extraction**

In `cmd_checkout` (around line 2470):
```bash
  [[ "$input" =~ ^[0-9]+$ ]] || die "checkout: '$input' is not a number (e.g., 5, 06)"
```

And the leaf-extract regex (around line 2482):
```bash
    [[ "$leaf" =~ ^([0-9]+)- ]] || continue
    num="${BASH_REMATCH[1]}"
```

And inside the `awk` comparison on line 2484, `c="$num"` still works since num is now strictly integer.

- [ ] **Step 6: Strip decimals from help text**

In `cmd_help` (around line 1063-1068), replace the "Stack ordering" example block so it no longer shows `06.5-baz`:

```bash
${b}Stack ordering:${r}
  Branches whose final path segment matches  ${d}^[0-9]+-${r}  are sorted by
  \`sort -V\` on that numeric portion. Examples (in order):
    ${cy}<prefix>/05-foo${r}
    ${cy}<prefix>/06-bar${r}
    ${cy}<prefix>/07-qux${r}
```

Also: in the `checkout` help (around line 972), remove the parenthetical about `6.5 finds 06.5-baz`:

```bash
  ${sub}checkout${r} [<number>]               Check out the stack branch whose leaf starts
                                    with that number (numeric match, so \`5\`
                                    finds \`05-foo\`).
```

- [ ] **Step 7: Run the failing tests — should now pass**

```bash
bats tests/git-stack.bats --filter 'decimals:'
```

Expected: PASS for both.

- [ ] **Step 8: Run the full suite to make sure nothing else broke**

```bash
make test JOBS=1
```

Expected: all green. If any existing test referenced decimal leaves directly (search for `\.5-` in `tests/`), update or delete it.

- [ ] **Step 9: Commit**

```bash
git add bin/git-stack tests/git-stack.bats
git commit -m "drop decimal-leaf support; tighten leaf regex to ^[0-9]+-"
```

---

## Task 2: Extract `_resolve_branch_ref` helper

Both `new --after`/`--at` and `move`'s position arg accept "numeric leaf OR full branch name". Factor this into one helper used by both. (Naïvely re-using `cmd_checkout`'s logic isn't viable because that function calls `git checkout` directly.)

**Files:**
- Modify: `bin/git-stack` — add helper near `branch_index` (around line 250)
- Modify: `tests/git-stack.bats`

- [ ] **Step 1: Write the test (no `cmd` calls it yet — direct bash invocation via a hidden subcommand later, or test indirectly through `new`/`move`. We'll wire indirectly.)**

Defer testing this helper directly — it has no command callsite yet. We'll test it via `cmd_new` and `cmd_move` integration tests. Skip the standalone test; just add the function with strong contract docs.

- [ ] **Step 2: Add the helper**

Insert in `bin/git-stack` right after `branch_index` (after line 250):

```bash
# Resolve a position-ref argument to a full branch name.
# Accepts:
#   - a numeric leaf (matches by integer-equal on the leading [0-9]+ of the
#     stack branch's leaf; e.g., "2" finds "02-foo")
#   - a full branch name (must equal exactly one stack branch)
# Args: <ref> <branch1> <branch2> ...
# Prints the matched branch name to stdout, exits 0.
# On no match or multiple matches, exits non-zero (caller dies with context).
_resolve_branch_ref() {
  local ref="$1"; shift
  (( $# > 0 )) || return 1
  local b leaf num matches=()
  # Full-name match takes precedence.
  for b in "$@"; do
    if [[ "$b" == "$ref" ]]; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  # Numeric-leaf match.
  if [[ "$ref" =~ ^[0-9]+$ ]]; then
    for b in "$@"; do
      leaf="${b##*/}"
      [[ "$leaf" =~ ^([0-9]+)- ]] || continue
      num="${BASH_REMATCH[1]}"
      if awk -v a="$ref" -v c="$num" 'BEGIN { exit !(a+0 == c+0) }'; then
        matches+=("$b")
      fi
    done
    case "${#matches[@]}" in
      1) printf '%s\n' "${matches[0]}"; return 0 ;;
      0) return 1 ;;
      *) return 2 ;;
    esac
  fi
  return 1
}
```

- [ ] **Step 3: Commit (no test yet — covered by integration tests in later tasks)**

```bash
git add bin/git-stack
git commit -m "add _resolve_branch_ref helper (used by upcoming new/move commands)"
```

---

## Task 3: Add `_leaf_width_for` and `_format_leaf` helpers

When renumbering, leaves must preserve the existing zero-pad width. Default to 2 when starting a fresh stack.

**Files:**
- Modify: `bin/git-stack` — add near `branch_index`

- [ ] **Step 1: Write a quick test by exposing via a debug subcommand? No — keep helpers private and test through `new`/`move` outcomes.**

No direct test. Move on.

- [ ] **Step 2: Add the two helpers**

Insert in `bin/git-stack` after the `_resolve_branch_ref` block:

```bash
# Infer numeric-leaf width from a stack's existing leaves. Looks at the first
# (lowest-numbered) branch and counts the leading-digit run. Returns 2 if no
# branches were given (fresh-stack default).
# Usage: _leaf_width_for <branch1> <branch2> ...
_leaf_width_for() {
  if (( $# == 0 )); then
    printf '2\n'
    return 0
  fi
  local first="$1"
  local leaf="${first##*/}"
  if [[ "$leaf" =~ ^([0-9]+)- ]]; then
    printf '%d\n' "${#BASH_REMATCH[1]}"
  else
    printf '2\n'
  fi
}

# Format an integer as a zero-padded leaf number of the given width.
# Usage: _format_leaf <num> <width>
_format_leaf() {
  printf '%0*d\n' "$2" "$1"
}
```

- [ ] **Step 3: Commit**

```bash
git add bin/git-stack
git commit -m "add _leaf_width_for and _format_leaf helpers"
```

---

## Task 4: Add remote-rename helpers

Wrap `gh api ... /rename` calls. Silently skip if `gh` unavailable or non-GitHub remote (warn once). Hard error on per-call failure.

**Files:**
- Modify: `bin/git-stack` — add helpers near `_gh_preflight` (around line 691)
- Modify: `tests/bin/gh` — extend stub to recognize `gh api -X POST /repos/.../branches/<old>/rename ...`

- [ ] **Step 1: Extend the gh stub to recognize the rename endpoint**

In `tests/bin/gh`, add a new case after the existing `gh api` handling (find where `gh api` is parsed; if there's no existing `gh api` case, add one). Add this block:

```bash
# gh api -X POST /repos/OWNER/REPO/branches/OLD/rename -f new_name=NEW
if [ "$1" = "api" ]; then
  shift
  _method=""
  _path=""
  _new_name=""
  while (( $# > 0 )); do
    case "$1" in
      -X) _method="$2"; shift 2 ;;
      -f)
        case "$2" in
          new_name=*) _new_name="${2#new_name=}" ;;
        esac
        shift 2 ;;
      /*) _path="$1"; shift ;;
      *) shift ;;
    esac
  done
  if [ "$_method" = "POST" ] && [[ "$_path" == */branches/*/rename ]]; then
    # Extract old branch name from path: /repos/OWNER/REPO/branches/OLD/rename
    _old="${_path#*/branches/}"
    _old="${_old%/rename}"
    # URL-decode (we use %2F for slashes).
    _old="${_old//%2F/\/}"
    if [ -n "${GH_STUB_FAIL_RENAME:-}" ] && [ "$_old" = "$GH_STUB_FAIL_RENAME" ]; then
      echo "stub: simulated rename failure for $_old" >&2
      exit 1
    fi
    # Emit a minimal JSON body matching GitHub's response.
    printf '{"name":"%s","protected":false}\n' "$_new_name"
    exit 0
  fi
  # Fall through unrecognized api calls (don't fail tests that don't use them).
  exit 0
fi
```

Place this block in the dispatch chain of `tests/bin/gh` — between the existing `pr` handler and the default exit. Read the file first to find the exact placement.

- [ ] **Step 2: Write a failing test that exercises the new helper through `cmd_new` (deferred to Task 6) — for now add a unit-style test by exposing a debug subcommand? No — same as before, defer.**

Skip standalone test. Integration tests in later tasks cover this.

- [ ] **Step 3: Add the helpers in `bin/git-stack`**

Insert after `_gh_preflight` (after line 700, before `_pr_branch_title`):

```bash
# Rename a single remote branch via gh's branches/rename endpoint. PRs that
# point at <old> are automatically retargeted by GitHub to <new>.
# Args: <old-branch-name> <new-branch-name>
# Caller must have already invoked _gh_preflight (so GH_REPO is set).
# Returns 0 on success; non-zero on API failure (caller dies).
_remote_rename_one() {
  local old="$1" new="$2"
  # URL-encode the branch name's slashes (the only special character in our
  # naming convention).
  local old_enc="${old//\//%2F}"
  local out err rc
  out=$(gh api -X POST "/repos/${GH_REPO}/branches/${old_enc}/rename" \
          -f "new_name=${new}" 2>&1) || rc=$?
  if (( ${rc:-0} != 0 )); then
    printf '%s\n' "$out" >&2
    return 1
  fi
  log_v "remote rename: $old -> $new"
}

# Rename remote refs for each (old, new) pair where origin/<old> exists.
# If gh isn't available or the remote isn't GitHub, silently skip the whole
# batch with a single warning. On per-call failure, hard-errors (caller's
# trap restores nothing — the local rename has already happened).
# Args: <old1> <new1> <old2> <new2> ...
_remote_rename_batch_or_skip() {
  (( $# % 2 == 0 )) || die "internal: _remote_rename_batch_or_skip got odd argc"
  (( $# == 0 )) && return 0
  if ! command -v gh >/dev/null 2>&1; then
    warn "gh not installed; skipping remote rename. PRs may orphan if branches were pushed."
    return 0
  fi
  if ! gh auth status -h github.com >/dev/null 2>&1; then
    warn "gh not authenticated for github.com; skipping remote rename."
    return 0
  fi
  if ! GH_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null); then
    warn "no GitHub remote detected; skipping remote rename."
    return 0
  fi
  local old new
  while (( $# >= 2 )); do
    old="$1"; new="$2"; shift 2
    # Skip branches that aren't pushed.
    if ! git rev-parse --verify --quiet "refs/remotes/origin/$old" >/dev/null; then
      log_v "skip remote rename (not pushed): $old"
      continue
    fi
    if ! _remote_rename_one "$old" "$new"; then
      die "gh api branches/${old}/rename failed; local renames already applied. Resolve on GitHub (UI or 'gh api ... /rename') then 'git fetch --prune' and re-run 'git stack pr sync'."
    fi
  done
}
```

- [ ] **Step 4: Commit**

```bash
git add bin/git-stack tests/bin/gh
git commit -m "add remote-rename helpers (gh api branches/rename) and gh stub support"
```

---

## Task 5: Add `_post_rename_sync` helper

Tiny wrapper. Invokes `cmd_pr_sync` unless `--no-sync` was passed. Captures `OPT_NO_SYNC` global (added to `parse_common_flags`).

**Files:**
- Modify: `bin/git-stack` — extend `parse_common_flags` and `_consume_common_flag`, add helper

- [ ] **Step 1: Add `OPT_NO_SYNC` and `OPT_NO_PUSH_OVERRIDE` globals + flag parsing**

In `bin/git-stack` near line 12-17 (OPT_* declarations):

```bash
OPT_NO_SYNC=0
OPT_NO_PUSH=0
```

In `parse_common_flags` (around line 266-289), add cases:

```bash
      --no-sync)    OPT_NO_SYNC=1; shift ;;
      --no-push)    OPT_NO_PUSH=1; shift ;;
```

In `_consume_common_flag` (around line 297-308), add cases:

```bash
    --no-sync)     OPT_NO_SYNC=1; _FLAG_SHIFT=1 ;;
    --no-push)     OPT_NO_PUSH=1; _FLAG_SHIFT=1 ;;
```

Also initialize them at the top of `parse_common_flags`:
```bash
  OPT_NO_SYNC=0
  OPT_NO_PUSH=0
```

- [ ] **Step 2: Add `_post_rename_sync` helper**

Insert in `bin/git-stack` after `_remote_rename_batch_or_skip`:

```bash
# Invoke pr sync unless --no-sync was given. Idempotent; safe to call after
# any local+remote rename. Silently no-op if gh isn't available (cmd_pr_sync
# handles its own preflight).
_post_rename_sync() {
  (( OPT_NO_SYNC )) && return 0
  if ! command -v gh >/dev/null 2>&1; then
    return 0
  fi
  if ! gh auth status -h github.com >/dev/null 2>&1; then
    return 0
  fi
  log "${C_DIM}post-rename:${C_RESET} pr sync"
  cmd_pr_sync || warn "pr sync returned non-zero; re-run 'gstkprs' manually"
}
```

- [ ] **Step 3: Commit**

```bash
git add bin/git-stack
git commit -m "add --no-sync / --no-push flags and _post_rename_sync helper"
```

---

## Task 6: `cmd_new` — minimal happy path (top of existing stack, no remote)

Get `git stack new <slug>` working at the top of an existing stack. No `--after`/`--at`/`--bottom` yet; no remote rename yet. Just: validate slug, find next leaf, create branch, switch HEAD.

**Files:**
- Modify: `bin/git-stack` — add `cmd_new`, register in `main`
- Modify: `tests/git-stack.bats` — add `# ---------- new ----------` section

- [ ] **Step 1: Write the failing test**

Add to `tests/git-stack.bats`:

```bash
# ---------- new ----------

@test "new: creates branch at top of stack with next leaf number" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/02-b
  run git stack new auth --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/03-auth
  # HEAD should be on the new branch
  [ "$(git symbolic-ref --short HEAD)" = "feat/03-auth" ]
  # New branch tip equals old top tip (empty branch — same SHA as predecessor).
  [ "$(git rev-parse feat/03-auth)" = "$(git rev-parse feat/02-b)" ]
}

@test "new: refuses invalid slug" {
  make_stack_branches feat 01-a
  run git stack new 'has space' --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"slug"* ]]
}

@test "new: refuses slug collision in same stack" {
  make_stack_branches feat 01-auth 02-other
  git checkout -q feat/02-other
  run git stack new auth --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"auth"* ]]
}
```

- [ ] **Step 2: Run the failing tests**

```bash
bats tests/git-stack.bats --filter 'new:'
```

Expected: FAIL — `unknown subcommand: new`.

- [ ] **Step 3: Register `new` in the dispatch**

In `bin/git-stack`'s `main()` function (around line 2610-2628), add after the existing `rename` case:

```bash
    new)               shift; cmd_new "$@" ;;
```

- [ ] **Step 4: Add `cmd_new` (minimal version — top only, in-stack only, no remote)**

Insert in `bin/git-stack` after `cmd_rename` (i.e., after line 1707):

```bash
# Slug validation: permissive — allows letters, digits, underscores, hyphens.
# Must start with a letter or underscore. Slashes forbidden (they're the
# branch suffix separator).
_validate_slug() {
  local s="$1"
  [[ -n "$s" ]] || die "new: slug is required"
  [[ "$s" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die "new: slug '$s' invalid (must match ^[A-Za-z_][A-Za-z0-9_-]*$)"
}

# Check the stack for an existing branch with the given slug suffix.
# Returns 0 if collision found (and sets _SLUG_COLLISION_BRANCH); 1 if clear.
_SLUG_COLLISION_BRANCH=""
_check_slug_collision() {
  local slug="$1"; shift
  local b leaf rest
  for b in "$@"; do
    leaf="${b##*/}"
    rest="${leaf#*-}"
    if [[ "$rest" == "$slug" ]]; then
      _SLUG_COLLISION_BRANCH="$b"
      return 0
    fi
  done
  return 1
}

# Pick the next integer leaf number above the highest existing one.
# Args: <branch1> <branch2> ...  (sorted in stack order)
# Echoes the integer.
_next_leaf_num() {
  if (( $# == 0 )); then
    printf '1\n'
    return 0
  fi
  local last="${!#}"
  local leaf="${last##*/}"
  [[ "$leaf" =~ ^([0-9]+)- ]] || die "internal: leaf '$leaf' has no numeric prefix"
  printf '%d\n' $((10#${BASH_REMATCH[1]} + 1))
}

cmd_new() {
  OPT_PREFIX=""; OPT_NO_SYNC=0; OPT_NO_PUSH=0; OPT_FORCE=0
  local slug="" opt_top=0 opt_bottom=0 opt_after="" opt_at=""
  while (( $# > 0 )); do
    if _consume_common_flag "$@"; then
      shift "$_FLAG_SHIFT"
      continue
    fi
    case "$1" in
      --top)     opt_top=1; shift ;;
      --bottom)  opt_bottom=1; shift ;;
      --after)   shift; [[ $# -gt 0 ]] || die "--after needs an argument"; opt_after="$1"; shift ;;
      --at)      shift; [[ $# -gt 0 ]] || die "--at needs an argument"; opt_at="$1"; shift ;;
      --force)   OPT_FORCE=1; shift ;;
      -*)        die "unknown new flag: $1" ;;
      *)         [[ -z "$slug" ]] || die "new: extra arg '$1'"; slug="$1"; shift ;;
    esac
  done

  _validate_slug "$slug"

  # Mutual exclusion among position flags.
  local n_pos=$((opt_top + opt_bottom + (opt_after != "" ? 1 : 0) + (opt_at != "" ? 1 : 0)))
  (( n_pos <= 1 )) || die "new: --top, --bottom, --after, --at are mutually exclusive"

  require_in_repo
  require_clean_tree
  require_no_op_in_progress
  require_no_state_file

  local prefix
  prefix=$(detect_prefix "$OPT_PREFIX")

  local branches=()
  _load_stack_branches "$prefix" branches

  # Slug collision check (against existing stack only).
  if (( ${#branches[@]} > 0 )) && _check_slug_collision "$slug" "${branches[@]}"; then
    die "new: slug '$slug' collides with existing branch '$_SLUG_COLLISION_BRANCH'"
  fi

  local width
  width=$(_leaf_width_for "${branches[@]}")

  # Compute insertion semantics. For this minimal version we only handle the
  # top-of-stack case; later tasks add --after, --at, --bottom, picker.
  # Insertion index: where the new branch will live (0-based, in the
  # post-mutation array).
  local insert_idx
  if (( ${#branches[@]} == 0 )); then
    insert_idx=0
  else
    insert_idx=${#branches[@]}
  fi

  # Predecessor: where the new branch starts from.
  local predecessor_ref
  if (( insert_idx == 0 )); then
    predecessor_ref=$(_resolve_parent_ref)
  else
    predecessor_ref="refs/heads/${branches[$((insert_idx - 1))]}"
  fi
  local predecessor_sha
  predecessor_sha=$(git rev-parse "$predecessor_ref") \
    || die "new: cannot resolve predecessor '$predecessor_ref'"

  # Compute the new branch's leaf number and full name.
  local next_num leaf new_branch
  next_num=$(_next_leaf_num "${branches[@]}")
  leaf=$(_format_leaf "$next_num" "$width")
  new_branch="${prefix}${leaf}-${slug}"

  # Refuse if the target ref already exists (paranoia — _check_slug_collision
  # would have caught a same-stack collision; this catches a foreign branch).
  if git rev-parse --verify --quiet "refs/heads/$new_branch" >/dev/null; then
    die "new: ref 'refs/heads/$new_branch' already exists"
  fi

  # Snapshot before mutation.
  snapshot_stack new "$prefix" "${branches[@]}"

  # Create the new branch ref and switch HEAD.
  git update-ref "refs/heads/$new_branch" "$predecessor_sha" \
    || die "new: failed to create ref"
  git checkout --quiet "$new_branch"

  log "${C_GREEN}new${C_RESET}     ${C_CYAN}${new_branch}${C_RESET} ${C_DIM}(from ${predecessor_ref#refs/heads/})${C_RESET}"
}
```

- [ ] **Step 5: Run the tests**

```bash
bats tests/git-stack.bats --filter 'new:'
```

Expected: PASS on `creates branch at top`, `refuses invalid slug`, `refuses slug collision`.

- [ ] **Step 6: Full suite check**

```bash
make test JOBS=1
```

Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add bin/git-stack tests/git-stack.bats
git commit -m "add 'git stack new <slug>' — minimal top-of-stack case"
```

---

## Task 7: `cmd_new --after` and `--at` with leaf renumber cascade

Add positional inserts. When inserting mid-stack, branches above get their leaves renumbered atomically via `update-ref --stdin`.

**Files:**
- Modify: `bin/git-stack` — `cmd_new`
- Modify: `tests/git-stack.bats`

- [ ] **Step 1: Write the failing tests**

Add to the `# ---------- new ----------` section:

```bash
@test "new --after: inserts between two named branches" {
  make_stack_branches feat 01-a 02-b 03-c
  run git stack new mid --after feat/01-a --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/02-mid
  # Old 02-b is now 03-b; old 03-c is now 04-c.
  git rev-parse --verify --quiet refs/heads/feat/03-b
  git rev-parse --verify --quiet refs/heads/feat/04-c
  ! git rev-parse --verify --quiet refs/heads/feat/02-b
  ! git rev-parse --verify --quiet refs/heads/feat/03-c
}

@test "new --after: accepts numeric leaf" {
  make_stack_branches feat 01-a 02-b
  run git stack new mid --after 1 --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/02-mid
  git rev-parse --verify --quiet refs/heads/feat/03-b
}

@test "new --at: takes that slot, pushing it (and above) up" {
  make_stack_branches feat 01-a 02-b 03-c
  run git stack new newone --at 2 --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/02-newone
  git rev-parse --verify --quiet refs/heads/feat/03-b
  git rev-parse --verify --quiet refs/heads/feat/04-c
}

@test "new --after: fails on unknown ref" {
  make_stack_branches feat 01-a 02-b
  run git stack new mid --after 99 --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"99"* ]]
}
```

- [ ] **Step 2: Run failing tests**

```bash
bats tests/git-stack.bats --filter 'new --'
```

Expected: FAIL (current `cmd_new` ignores `--after`/`--at`).

- [ ] **Step 3: Extend `cmd_new` to resolve position and emit a cascade rename batch**

Replace the "Compute insertion semantics" block in `cmd_new` with:

```bash
  # Compute the 0-based insertion index in the post-mutation array.
  local insert_idx
  if (( opt_top )); then
    insert_idx=${#branches[@]}
  elif (( opt_bottom )); then
    insert_idx=0
  elif [[ -n "$opt_after" ]]; then
    if (( ${#branches[@]} == 0 )); then
      die "new --after: no branches in stack '$prefix'"
    fi
    local after_branch rc=0
    after_branch=$(_resolve_branch_ref "$opt_after" "${branches[@]}") || rc=$?
    (( rc == 0 )) || die "new --after: '$opt_after' not in stack '$prefix'"
    insert_idx=$(branch_index "$after_branch" "${branches[@]}")
    insert_idx=$((insert_idx + 1))
  elif [[ -n "$opt_at" ]]; then
    if (( ${#branches[@]} == 0 )); then
      die "new --at: no branches in stack '$prefix'"
    fi
    local at_branch rc=0
    at_branch=$(_resolve_branch_ref "$opt_at" "${branches[@]}") || rc=$?
    (( rc == 0 )) || die "new --at: '$opt_at' not in stack '$prefix'"
    insert_idx=$(branch_index "$at_branch" "${branches[@]}")
  else
    # No position flag (and not picker — picker is wired later). Default: top.
    insert_idx=${#branches[@]}
  fi
```

Then below the existing predecessor block, replace the leaf-computation + branch-creation with this:

```bash
  # Compute the cascade: leaves at and above insert_idx get +1.
  # Build the new ordering: [old branches < insert_idx] + [new branch] + [old branches >= insert_idx, renumbered].
  local new_num leaf new_branch
  if (( insert_idx == 0 )); then
    # New branch becomes leaf 01 (with current width). Everything above shifts +1.
    new_num=1
  elif (( insert_idx == ${#branches[@]} )); then
    # Top append. Width unchanged.
    new_num=$(_next_leaf_num "${branches[@]}")
  else
    # Mid-insert. New leaf = predecessor's leaf + 1.
    local prev_branch="${branches[$((insert_idx - 1))]}"
    local prev_leaf="${prev_branch##*/}"
    [[ "$prev_leaf" =~ ^([0-9]+)- ]] || die "internal: prev_leaf '$prev_leaf' malformed"
    new_num=$((10#${BASH_REMATCH[1]} + 1))
  fi
  leaf=$(_format_leaf "$new_num" "$width")
  new_branch="${prefix}${leaf}-${slug}"

  # Build the rename batch for branches at insert_idx and above (each gets +1).
  # rename_pairs is a flat array: old1 new1 old2 new2 ...
  local rename_pairs=()
  local i b old_leaf old_num new_leaf_str new_full
  for ((i = insert_idx; i < ${#branches[@]}; i++)); do
    b="${branches[$i]}"
    old_leaf="${b##*/}"
    [[ "$old_leaf" =~ ^([0-9]+)- ]] || die "internal: leaf '$old_leaf' malformed"
    old_num=$((10#${BASH_REMATCH[1]}))
    new_leaf_str=$(_format_leaf $((old_num + 1)) "$width")
    new_full="${prefix}${new_leaf_str}-${old_leaf#*-}"
    if git rev-parse --verify --quiet "refs/heads/$new_full" >/dev/null; then
      die "new: cascade rename would collide with existing '$new_full'"
    fi
    rename_pairs+=("$b" "$new_full")
  done

  # Refuse if any branch in the cascade is checked out elsewhere.
  for ((i = 0; i < ${#rename_pairs[@]}; i+=2)); do
    require_branch_not_in_worktree "${rename_pairs[$i]}"
  done

  # Same paranoia check on the new branch.
  if git rev-parse --verify --quiet "refs/heads/$new_branch" >/dev/null; then
    die "new: target ref 'refs/heads/$new_branch' already exists"
  fi

  # Snapshot before mutation.
  snapshot_stack new "$prefix" "${branches[@]}"

  # Build the atomic update-ref batch:
  #   create the new branch ref
  #   rename each cascade branch (create new, delete old)
  local batch=""
  batch+="create refs/heads/${new_branch} ${predecessor_sha}"$'\n'
  for ((i = 0; i < ${#rename_pairs[@]}; i+=2)); do
    local old="${rename_pairs[$i]}"
    local new="${rename_pairs[$((i + 1))]}"
    local sha
    sha=$(git rev-parse "refs/heads/$old")
    batch+="create refs/heads/${new} ${sha}"$'\n'
    batch+="delete refs/heads/${old} ${sha}"$'\n'
  done

  # Retarget HEAD if it points at a cascade-renamed branch (parallels cmd_rename's logic).
  local head_target_before="" head_new_target=""
  if head_target_before=$(git symbolic-ref --quiet HEAD 2>/dev/null); then
    for ((i = 0; i < ${#rename_pairs[@]}; i+=2)); do
      if [[ "$head_target_before" == "refs/heads/${rename_pairs[$i]}" ]]; then
        head_new_target="refs/heads/${rename_pairs[$((i + 1))]}"
        git symbolic-ref HEAD "$head_new_target"
        break
      fi
    done
  fi

  # Apply the batch.
  if ! printf '%s' "$batch" | git update-ref --stdin -m "git-stack new $new_branch"; then
    if [[ -n "$head_new_target" ]]; then
      git symbolic-ref HEAD "$head_target_before" 2>/dev/null || true
    fi
    die "git update-ref batch failed; refs unchanged (atomic)"
  fi

  # Switch HEAD to the new branch.
  git checkout --quiet "$new_branch"

  log "${C_GREEN}new${C_RESET}     ${C_CYAN}${new_branch}${C_RESET} ${C_DIM}(from ${predecessor_ref#refs/heads/}, +${#rename_pairs[@]} renames)${C_RESET}"
```

Remove the old `git update-ref refs/heads/$new_branch` + `git checkout` block at the bottom of `cmd_new` — it's superseded by the batch.

- [ ] **Step 4: Run the tests**

```bash
bats tests/git-stack.bats --filter 'new'
```

Expected: PASS on all new tests; old `new: creates branch at top` should still pass (top case still hits the no-cascade path).

- [ ] **Step 5: Full suite**

```bash
make test JOBS=1
```

Expected: green.

- [ ] **Step 6: Commit**

```bash
git add bin/git-stack tests/git-stack.bats
git commit -m "new: support --after and --at with cascade leaf renumber"
```

---

## Task 8: `cmd_new --bottom`

Already wired in Task 7 (the `opt_bottom` branch). Add tests to lock in the contract.

**Files:**
- Modify: `tests/git-stack.bats`

- [ ] **Step 1: Write the failing test (should already pass, but lock the contract)**

Add to `# ---------- new ----------`:

```bash
@test "new --bottom: inserts as leaf 01 and shifts all branches up" {
  make_stack_branches feat 01-a 02-b
  run git stack new prep --bottom --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/01-prep
  git rev-parse --verify --quiet refs/heads/feat/02-a
  git rev-parse --verify --quiet refs/heads/feat/03-b
  # New branch's tip == parent (main) tip.
  [ "$(git rev-parse feat/01-prep)" = "$(git rev-parse main)" ]
}
```

- [ ] **Step 2: Run — should already pass**

```bash
bats tests/git-stack.bats --filter 'new --bottom'
```

Expected: PASS (Task 7's implementation already handles this).

- [ ] **Step 3: Commit (test only)**

```bash
git add tests/git-stack.bats
git commit -m "test: lock in 'new --bottom' contract"
```

---

## Task 9: `cmd_new` interactive picker (no position flag)

When no flag is passed and stdin is a TTY, present the picker. Reuse `_pick_one` for simplicity.

**Files:**
- Modify: `bin/git-stack`
- Modify: `tests/git-stack.bats`

- [ ] **Step 1: Write the failing test — use BATS_TTY / non-TTY fallback path**

Tests run with no TTY by default, so the picker's TTY branch isn't exercisable directly. We can test that **the default with no flag and no TTY behaves as `--top`** (or errors — recommended: behave as `--top` to match the existing `parse_common_flags` convention where omitted = top).

Actually no — the design says "no flag → picker". When non-TTY, the picker can't run. Let's define: non-TTY default-on-no-flag → falls back to `--top` (matching the no-pickerable case for `cmd_checkout`).

```bash
@test "new (no flag, non-TTY): defaults to --top" {
  make_stack_branches feat 01-a 02-b
  run git stack new tail --no-color </dev/null
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/03-tail
}
```

- [ ] **Step 2: Run — should already pass (the current default IS top)**

```bash
bats tests/git-stack.bats --filter 'no flag, non-TTY'
```

Expected: PASS.

- [ ] **Step 3: Now add the TTY picker path**

In `cmd_new`, after `_load_stack_branches`, before the "Compute insertion" block — add a TTY picker:

```bash
  # If no position flag and we have a TTY + branches, prompt.
  if (( n_pos == 0 )) && (( ${#branches[@]} > 0 )) && [[ -e /dev/tty ]] && [[ -t 0 || -t 2 ]]; then
    local picker_items=("[top]" "${branches[@]}" "[bottom]")
    local picked
    picked=$(_pick_one "insert new branch at position of:" "${picker_items[@]}") \
      || die "new: no position selected"
    case "$picked" in
      "[top]")    opt_top=1 ;;
      "[bottom]") opt_bottom=1 ;;
      *)          opt_at="$picked" ;;
    esac
    # Recompute n_pos so position-resolution block below picks the right branch.
    n_pos=1
  fi
```

- [ ] **Step 4: Run the previous test — must still pass**

```bash
bats tests/git-stack.bats --filter 'new'
```

Expected: green. The TTY check fails in test env so the picker branch is skipped; non-TTY behaviour unchanged.

- [ ] **Step 5: Commit**

```bash
git add bin/git-stack tests/git-stack.bats
git commit -m "new: add interactive picker (TTY only)"
```

---

## Task 10: `cmd_new` remote rename + pr sync

Wire `_remote_rename_batch_or_skip` and `_post_rename_sync` into `cmd_new`. Respect `--no-push` and `--no-sync`.

**Files:**
- Modify: `bin/git-stack` — `cmd_new`
- Modify: `tests/git-stack.bats`

- [ ] **Step 1: Write the failing test**

Add to `# ---------- new ----------`:

```bash
@test "new --after: renames remote branches via gh api and triggers pr sync" {
  make_stack_branches feat 01-a 02-b 03-c
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  run git stack new mid --after 1 --no-color
  [ "$status" -eq 0 ]
  # The two cascaded branches (was 02-b, was 03-c) must have been remote-renamed.
  [ "$(gh_log_count 'api -X POST')" -ge 2 ]
  # pr sync must have been invoked too (gh_log shows 'pr list' or 'pr create'/'pr edit').
  [ "$(gh_log_count 'pr')" -ge 1 ]
}

@test "new --after --no-push: skips remote rename and pr sync" {
  make_stack_branches feat 01-a 02-b
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  run git stack new mid --after 1 --no-push --no-color
  [ "$status" -eq 0 ]
  [ "$(gh_log_count 'api -X POST')" -eq 0 ]
  [ "$(gh_log_count 'pr')" -eq 0 ]
}

@test "new --after --no-sync: does remote rename but skips pr sync" {
  make_stack_branches feat 01-a 02-b
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  run git stack new mid --after 1 --no-sync --no-color
  [ "$status" -eq 0 ]
  [ "$(gh_log_count 'api -X POST')" -ge 1 ]
  [ "$(gh_log_count 'pr')" -eq 0 ]
}
```

- [ ] **Step 2: Run the failing tests**

```bash
bats tests/git-stack.bats --filter 'new --after: renames|new --after --no'
```

Expected: FAIL (remote rename + pr sync not yet wired in).

- [ ] **Step 3: Wire the remote stages into `cmd_new`**

At the bottom of `cmd_new`, after the `log` line at the very end (after the batch + checkout), add:

```bash
  # Stage 2: remote rename.
  if (( ! OPT_NO_PUSH )); then
    _remote_rename_batch_or_skip "${rename_pairs[@]}"
  fi

  # Stage 3: pr sync.
  if (( ! OPT_NO_PUSH )); then
    _post_rename_sync
  fi
```

(`--no-push` implies skipping both 2 and 3. `--no-sync` only skips 3.)

- [ ] **Step 4: Run the tests**

```bash
bats tests/git-stack.bats --filter 'new --after: renames|new --after --no'
```

Expected: PASS.

- [ ] **Step 5: Full suite**

```bash
make test JOBS=1
```

Expected: green.

- [ ] **Step 6: Commit**

```bash
git add bin/git-stack tests/git-stack.bats
git commit -m "new: wire remote rename and pr sync (with --no-push/--no-sync)"
```

---

## Task 11: `cmd_new` bootstrap path (no current stack)

When no prefix detected: pick existing prefix or prompt for a new one. `--prefix` skips prompts.

**Files:**
- Modify: `bin/git-stack` — `cmd_new`
- Modify: `tests/git-stack.bats`

- [ ] **Step 1: Write the failing test**

Add to `# ---------- new ----------`:

```bash
@test "new (bootstrap, --prefix): creates first branch of a new stack from main" {
  # Already on main from setup. No stack exists.
  run git stack new auth --prefix feat --no-color </dev/null
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/01-auth
  [ "$(git symbolic-ref --short HEAD)" = "feat/01-auth" ]
  # New branch tip == main tip.
  [ "$(git rev-parse feat/01-auth)" = "$(git rev-parse main)" ]
}

@test "new (bootstrap, non-TTY, no --prefix): errors with hint" {
  run git stack new auth --no-color </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"prefix"* ]]
}

@test "new (bootstrap, --prefix, --at): errors — empty stack" {
  run git stack new auth --prefix feat --at 1 --no-color </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"no branches"* ]]
}
```

- [ ] **Step 2: Run the failing tests**

```bash
bats tests/git-stack.bats --filter 'bootstrap'
```

Expected: FAIL on the `--prefix` test (current `cmd_new` calls `detect_prefix` which dies on no prefix). The other two may pass or fail depending on order.

- [ ] **Step 3: Replace `detect_prefix` call with a bootstrap-aware version**

In `cmd_new`, replace the `prefix=$(detect_prefix "$OPT_PREFIX")` line with this block:

```bash
  local prefix=""
  if [[ -n "$OPT_PREFIX" ]]; then
    prefix="${OPT_PREFIX%/}/"
  elif prefix=$(_try_detect_prefix "" 2>/dev/null); then
    :  # ok
  else
    # Bootstrap path: no current stack.
    if ! [[ -e /dev/tty ]] || ! [[ -t 0 || -t 2 ]]; then
      die "no prefix detected; pass --prefix or set git config stack.prefix"
    fi
    # Offer existing prefixes (if any) + [new prefix...].
    local existing_prefixes=()
    while IFS= read -r p; do
      [[ -n "$p" ]] && existing_prefixes+=("$p")
    done < <(stack_prefixes)
    if (( ${#existing_prefixes[@]} > 0 )); then
      local picker_items=("${existing_prefixes[@]}" "[new prefix...]")
      local picked
      picked=$(_pick_one "select stack prefix:" "${picker_items[@]}") \
        || die "new: no prefix selected"
      if [[ "$picked" == "[new prefix...]" ]]; then
        printf 'prefix (without trailing /): ' >&2
        local typed
        read -r typed < /dev/tty || die "new: aborted"
        prefix="${typed%/}/"
      else
        prefix="$picked"
      fi
    else
      printf 'prefix (without trailing /): ' >&2
      local typed
      read -r typed < /dev/tty || die "new: aborted"
      prefix="${typed%/}/"
    fi
    # Validate the typed/picked prefix.
    [[ -n "$prefix" && "$prefix" != "/" ]] || die "new: prefix is empty"
    [[ "$prefix" != /* ]] || die "new: prefix must not start with /"
    [[ "$prefix" != *' '* ]] || die "new: prefix must not contain spaces"
    local first_leaf="${prefix%/}"
    first_leaf="${first_leaf##*/}"
    [[ ! "$first_leaf" =~ ^[0-9]+- ]] || die "new: prefix '$prefix' would clash with leaf-numbering pattern"
  fi
```

Move this block to replace the current `prefix=$(detect_prefix "$OPT_PREFIX")` line.

- [ ] **Step 4: Run the bootstrap tests**

```bash
bats tests/git-stack.bats --filter 'bootstrap'
```

Expected: PASS on all three.

- [ ] **Step 5: Full suite**

```bash
make test JOBS=1
```

Expected: green.

- [ ] **Step 6: Commit**

```bash
git add bin/git-stack tests/git-stack.bats
git commit -m "new: add bootstrap path (prefix prompt/picker when no stack exists)"
```

---

## Task 12: `cmd_move` — minimal happy path (move within stack, single-commit branches)

Now the move command. Most of the heavy lifting reuses `do_one_step` + `run_reflow_loop` + the rename-batch primitive. Start with the simplest case: move a single-commit branch to a new position; no conflicts; no remote.

**Files:**
- Modify: `bin/git-stack` — add `cmd_move`, register in `main`
- Modify: `tests/git-stack.bats`

- [ ] **Step 1: Write the failing test**

Add to `tests/git-stack.bats`:

```bash
# ---------- move ----------

@test "move: relocates a single-commit branch to top" {
  make_stack_branches feat 01-a 02-b 03-c
  run git stack move feat/01-a --top --no-color
  [ "$status" -eq 0 ]
  # 01-a content should now be at the top, renumbered.
  # Stack order becomes: was-02-b, was-03-c, was-01-a.
  # With auto-reflow: 01-b, 02-c, 03-a.
  git rev-parse --verify --quiet refs/heads/feat/01-b
  git rev-parse --verify --quiet refs/heads/feat/02-c
  git rev-parse --verify --quiet refs/heads/feat/03-a
  ! git rev-parse --verify --quiet refs/heads/feat/01-a
  ! git rev-parse --verify --quiet refs/heads/feat/02-b
  ! git rev-parse --verify --quiet refs/heads/feat/03-c
}

@test "move: refuses if target == source position" {
  make_stack_branches feat 01-a 02-b
  run git stack move feat/01-a --bottom --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"already"* ]]
}

@test "move: refuses if source not in stack" {
  make_stack_branches feat 01-a 02-b
  git checkout -q main
  git branch outside
  run git stack move outside --top --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside"* ]]
}
```

- [ ] **Step 2: Run failing tests**

```bash
bats tests/git-stack.bats --filter 'move:'
```

Expected: FAIL — `unknown subcommand: move`.

- [ ] **Step 3: Register `move` and `mv` in dispatch**

In `main()`, add after the `new` case:

```bash
    move|mv)           shift; cmd_move "$@" ;;
```

- [ ] **Step 4: Add `cmd_move`**

Insert after `cmd_new`:

```bash
cmd_move() {
  OPT_PREFIX=""; OPT_NO_SYNC=0; OPT_NO_PUSH=0; OPT_FORCE=0
  local src="" opt_top=0 opt_bottom=0 opt_after="" opt_at=""
  while (( $# > 0 )); do
    if _consume_common_flag "$@"; then
      shift "$_FLAG_SHIFT"
      continue
    fi
    case "$1" in
      --top)     opt_top=1; shift ;;
      --bottom)  opt_bottom=1; shift ;;
      --after)   shift; [[ $# -gt 0 ]] || die "--after needs an argument"; opt_after="$1"; shift ;;
      --at)      shift; [[ $# -gt 0 ]] || die "--at needs an argument"; opt_at="$1"; shift ;;
      --force)   OPT_FORCE=1; shift ;;
      -*)        die "unknown move flag: $1" ;;
      *)         [[ -z "$src" ]] || die "move: extra arg '$1'"; src="$1"; shift ;;
    esac
  done

  [[ -n "$src" ]] || die "usage: git stack move <branch> [--top|--bottom|--after <ref>|--at <ref>]"

  local n_pos=$((opt_top + opt_bottom + (opt_after != "" ? 1 : 0) + (opt_at != "" ? 1 : 0)))
  (( n_pos <= 1 )) || die "move: --top, --bottom, --after, --at are mutually exclusive"

  require_in_repo
  require_clean_tree
  require_no_op_in_progress
  require_no_state_file

  local prefix
  prefix=$(detect_prefix "$OPT_PREFIX")

  local branches=()
  _load_stack_branches "$prefix" branches "no stack branches under '$prefix'"
  (( ${#branches[@]} >= 2 )) || die "move: stack has fewer than 2 branches"

  # Resolve source.
  local src_branch rc=0
  src_branch=$(_resolve_branch_ref "$src" "${branches[@]}") || rc=$?
  (( rc == 0 )) || die "move: '$src' not in stack '$prefix'"
  local src_idx
  src_idx=$(branch_index "$src_branch" "${branches[@]}")

  # TTY picker if no position flag.
  if (( n_pos == 0 )) && [[ -e /dev/tty ]] && [[ -t 0 || -t 2 ]]; then
    local picker_items=("[top]")
    local b
    for b in "${branches[@]}"; do
      [[ "$b" == "$src_branch" ]] && continue
      picker_items+=("$b")
    done
    picker_items+=("[bottom]")
    local picked
    picked=$(_pick_one "move ${src_branch} to position of:" "${picker_items[@]}") \
      || die "move: no position selected"
    case "$picked" in
      "[top]")    opt_top=1 ;;
      "[bottom]") opt_bottom=1 ;;
      *)          opt_at="$picked" ;;
    esac
    n_pos=1
  fi
  (( n_pos == 1 )) || die "move: no position specified (and no TTY for picker); pass --top/--bottom/--after/--at"

  # Resolve destination index in the *post-removal* array (i.e., the array
  # with src_branch removed). This is the index *where src will sit* after move.
  local dst_idx
  if (( opt_top )); then
    dst_idx=$((${#branches[@]} - 1))
  elif (( opt_bottom )); then
    dst_idx=0
  elif [[ -n "$opt_after" ]]; then
    local after_branch
    after_branch=$(_resolve_branch_ref "$opt_after" "${branches[@]}") \
      || die "move --after: '$opt_after' not in stack '$prefix'"
    [[ "$after_branch" != "$src_branch" ]] || die "move: cannot reference itself"
    local after_idx
    after_idx=$(branch_index "$after_branch" "${branches[@]}")
    # In post-removal array: if after_idx > src_idx, after_idx shifts down by 1.
    if (( after_idx > src_idx )); then
      dst_idx=$after_idx
    else
      dst_idx=$((after_idx + 1))
    fi
  elif [[ -n "$opt_at" ]]; then
    local at_branch
    at_branch=$(_resolve_branch_ref "$opt_at" "${branches[@]}") \
      || die "move --at: '$opt_at' not in stack '$prefix'"
    [[ "$at_branch" != "$src_branch" ]] || die "move: cannot reference itself"
    local at_idx
    at_idx=$(branch_index "$at_branch" "${branches[@]}")
    if (( at_idx > src_idx )); then
      dst_idx=$((at_idx - 1))
    else
      dst_idx=$at_idx
    fi
  fi

  # Refuse if destination == source position.
  if (( dst_idx == src_idx )); then
    die "move: '$src_branch' is already at position $((src_idx + 1))"
  fi

  # Build the post-move ordering: branches minus src, with src spliced at dst_idx.
  local post=() i
  for ((i = 0; i < ${#branches[@]}; i++)); do
    (( i == src_idx )) && continue
    post+=("${branches[$i]}")
  done
  # Splice src at dst_idx.
  local spliced=()
  for ((i = 0; i < dst_idx; i++)); do spliced+=("${post[$i]}"); done
  spliced+=("$src_branch")
  for ((i = dst_idx; i < ${#post[@]}; i++)); do spliced+=("${post[$i]}"); done
  post=("${spliced[@]}")

  # Multi-commit guard for every branch from min(src_idx, new src position) onward.
  local first_affected
  if (( dst_idx < src_idx )); then
    first_affected=$dst_idx
  else
    first_affected=$src_idx
  fi
  if (( ! OPT_FORCE )); then
    for ((i = first_affected; i < ${#post[@]}; i++)); do
      local pb="${post[$i]}"
      local prev_ref
      if (( i == 0 )); then
        prev_ref=$(_resolve_parent_ref)
      else
        prev_ref="refs/heads/${post[$((i - 1))]}"
      fi
      # Use original branches array's name to look up the *current* tip; we
      # haven't rebased yet so refs/heads/<pb> still points where it was.
      local cnt_b cnt_prev n_commits
      cnt_b=$(git rev-list --count "refs/heads/$pb" 2>/dev/null || echo 0)
      cnt_prev=$(git rev-list --count "$prev_ref" 2>/dev/null || echo 0)
      n_commits=$((cnt_b - cnt_prev))
      if (( n_commits > 1 )); then
        die "branch '$pb' has $n_commits commits beyond its planned predecessor; move would drop all but the tip. Pass --force to proceed."
      fi
    done
  fi

  # Worktree safety: every affected branch (will be cherry-picked + renamed) must not be checked out elsewhere.
  for ((i = first_affected; i < ${#post[@]}; i++)); do
    require_branch_not_in_worktree "${post[$i]}"
  done

  # Snapshot before mutation.
  snapshot_stack move "$prefix" "${branches[@]}"

  # ----- Stage A: rebase affected branches in the new order onto their new predecessors -----
  # Initialise the reflow state-machine globals so do_one_step works and so a
  # mid-flow conflict can resume via `git stack continue`.
  STACK_BRANCHES=("${post[@]}")
  STACK_ORIG_SHAS=()
  for ((i = 0; i < ${#STACK_BRANCHES[@]}; i++)); do
    if (( i >= first_affected )); then
      STACK_ORIG_SHAS+=("$(git rev-parse "refs/heads/${STACK_BRANCHES[$i]}")")
    else
      STACK_ORIG_SHAS+=("")
    fi
  done
  STACK_STARTED_AT=$(date +%s)
  STACK_STARTING_BRANCH=$(current_branch || echo "")
  STACK_PREFIX="$prefix"
  STACK_PUSH=0
  STACK_FORCE="$OPT_FORCE"
  STACK_ONTO=""
  STACK_ONTO_REF=""
  STACK_FROM_IDX="$first_affected"
  STACK_CURSOR="$first_affected"
  STACK_PUSH_FAILURES=()
  # If the very first affected branch should rebase onto the stack parent
  # (only when first_affected == 0 and the branches were moved at the bottom),
  # set STACK_ONTO so do_one_step replays correctly.
  if (( first_affected == 0 )); then
    STACK_ONTO=$(_resolve_parent_ref)
    STACK_ONTO=$(git rev-parse "$STACK_ONTO")
    STACK_ONTO_REF=$(_resolve_parent_name)
  fi

  save_state
  run_reflow_loop

  # If run_reflow_loop returned (no conflict): proceed to renames. If a conflict
  # occurred, run_reflow_loop already exited 2 and the user must `git stack continue`.

  # ----- Stage B: cascade rename to consecutive leaves -----
  local width
  width=$(_leaf_width_for "${branches[@]}")
  local rename_pairs=()
  for ((i = 0; i < ${#post[@]}; i++)); do
    local old="${post[$i]}"
    local old_leaf="${old##*/}"
    local old_rest="${old_leaf#*-}"
    local new_num=$((i + 1))
    local new_leaf
    new_leaf=$(_format_leaf "$new_num" "$width")
    local new_full="${prefix}${new_leaf}-${old_rest}"
    if [[ "$old" != "$new_full" ]]; then
      rename_pairs+=("$old" "$new_full")
    fi
  done

  if (( ${#rename_pairs[@]} > 0 )); then
    # Build atomic batch.
    local batch=""
    local j
    for ((j = 0; j < ${#rename_pairs[@]}; j+=2)); do
      local rp_old="${rename_pairs[$j]}"
      local rp_new="${rename_pairs[$((j + 1))]}"
      local sha
      sha=$(git rev-parse "refs/heads/$rp_old")
      batch+="create refs/heads/${rp_new} ${sha}"$'\n'
      batch+="delete refs/heads/${rp_old} ${sha}"$'\n'
    done

    # Retarget HEAD if it points at a renamed branch.
    local head_before="" head_new=""
    if head_before=$(git symbolic-ref --quiet HEAD 2>/dev/null); then
      for ((j = 0; j < ${#rename_pairs[@]}; j+=2)); do
        if [[ "$head_before" == "refs/heads/${rename_pairs[$j]}" ]]; then
          head_new="refs/heads/${rename_pairs[$((j + 1))]}"
          git symbolic-ref HEAD "$head_new"
          break
        fi
      done
    fi

    if ! printf '%s' "$batch" | git update-ref --stdin -m "git-stack move ${src_branch}"; then
      [[ -n "$head_new" ]] && git symbolic-ref HEAD "$head_before" 2>/dev/null || true
      die "git update-ref batch failed; refs unchanged (atomic)"
    fi
  fi

  log "${C_GREEN}move${C_RESET}    ${C_CYAN}${src_branch}${C_RESET} ${C_DIM}-> position $((dst_idx + 1)) (+$((${#rename_pairs[@]} / 2)) renames)${C_RESET}"

  # ----- Stage C: remote rename + pr sync -----
  if (( ! OPT_NO_PUSH )); then
    _remote_rename_batch_or_skip "${rename_pairs[@]}"
    _post_rename_sync
  fi
}
```

- [ ] **Step 5: Run the move tests**

```bash
bats tests/git-stack.bats --filter 'move:'
```

Expected: PASS on all three.

- [ ] **Step 6: Full suite**

```bash
make test JOBS=1
```

Expected: green.

- [ ] **Step 7: Commit**

```bash
git add bin/git-stack tests/git-stack.bats
git commit -m "add 'git stack move <branch> [pos]' with cascade rename + remote sync"
```

---

## Task 13: `cmd_move` conflict + continue interop

`do_one_step` saves state and exits 2 on a cherry-pick conflict. The existing `cmd_continue` resumes the reflow loop. But `cmd_continue` doesn't know to do the rename-batch + remote-rename + pr-sync stages after the loop finishes — those live in `cmd_move`.

Two options:
- **(A) Store a "post-reflow action" in the state file** so `cmd_continue` can dispatch back to a follow-up function.
- **(B) Inline the rename stages into `run_reflow_loop`'s post-loop block, gated on a new field `STACK_POST_ACTION`.**

Recommended **(B)** — smaller surface, single source of truth.

**Files:**
- Modify: `bin/git-stack` — `STACK_*` globals, `save_state`, `load_state`, `run_reflow_loop`, `cmd_move`
- Modify: `tests/git-stack.bats`

- [ ] **Step 1: Write the failing test (move with a conflict)**

Add to `# ---------- move ----------`:

```bash
@test "move: cherry-pick conflict halts; continue completes move + rename" {
  # Stack: 01-a (adds 'a'), 02-b (adds 'b'). Move 02-b to bottom — when
  # cherry-picked onto main (no 'a' present), it should apply cleanly since b
  # is a fresh file. So we need to construct a *real* conflict. Use a single
  # file that both branches modify.
  make_stack_branches feat 01-a 02-b
  # Now both branches modify `file`. Reset 02-b so it ALSO modifies the same line as 01-a.
  git checkout -q feat/02-b
  printf 'CONFLICTING\n' > file
  git add file
  git commit -q --amend -m "02-b conflicting"
  # Move 02-b before 01-a: it will be replayed on main, but the conflict
  # appears when 01-a is replayed onto it.
  run git stack move feat/02-b --bottom --no-color
  [ "$status" -eq 2 ]
  [[ "$output" == *"conflict"* ]]
  # Resolve manually: take "ours" (the cherry-pick payload).
  printf 'CONFLICTING\n' > file
  git add file
  run git stack continue --no-color
  [ "$status" -eq 0 ]
  # After move + continue, both branches exist with renumbered leaves.
  git rev-parse --verify --quiet refs/heads/feat/01-b
  git rev-parse --verify --quiet refs/heads/feat/02-a
}
```

- [ ] **Step 2: Add `STACK_POST_ACTION` and related fields to state**

In `bin/git-stack` near the `STACK_*` declarations (lines 74-86):

```bash
STACK_POST_ACTION=""        # "move-rename" or empty
STACK_POST_BRANCHES=()      # post-move ordering used to compute rename batch
```

In `save_state` (around line 329), add to the serialisation block:

```bash
  printf 'STACK_POST_ACTION=%q\n' "$STACK_POST_ACTION"
  _emit_array STACK_POST_BRANCHES "${STACK_POST_BRANCHES[@]}"
```

In `load_state` (around line 349), add to the reset list:

```bash
  STACK_POST_BRANCHES=()
  STACK_POST_ACTION=""
```

- [ ] **Step 3: Move rename + remote stages out of `cmd_move`, into a new helper**

Add a new helper `_finish_move_rename` that takes the post-move ordering off the state and runs Stage B + C:

```bash
# Called by run_reflow_loop after the reflow finishes when STACK_POST_ACTION == "move-rename".
# Reads STACK_POST_BRANCHES + STACK_PREFIX. Computes the consecutive-leaf cascade,
# applies an atomic batch, then does remote rename + pr sync (unless --no-push).
# Uses OPT_NO_PUSH/OPT_NO_SYNC which are restored by load_state before this is called.
_finish_move_rename() {
  local prefix="$STACK_PREFIX"
  local post=("${STACK_POST_BRANCHES[@]}")
  local width
  # Width comes from the first branch's leaf in post (or default 2).
  width=$(_leaf_width_for "${post[@]}")
  local rename_pairs=()
  local i
  for ((i = 0; i < ${#post[@]}; i++)); do
    local old="${post[$i]}"
    local old_leaf="${old##*/}"
    local old_rest="${old_leaf#*-}"
    local new_num=$((i + 1))
    local new_leaf
    new_leaf=$(_format_leaf "$new_num" "$width")
    local new_full="${prefix}${new_leaf}-${old_rest}"
    if [[ "$old" != "$new_full" ]]; then
      rename_pairs+=("$old" "$new_full")
    fi
  done

  if (( ${#rename_pairs[@]} > 0 )); then
    local batch=""
    local j
    for ((j = 0; j < ${#rename_pairs[@]}; j+=2)); do
      local rp_old="${rename_pairs[$j]}"
      local rp_new="${rename_pairs[$((j + 1))]}"
      local sha
      sha=$(git rev-parse "refs/heads/$rp_old")
      batch+="create refs/heads/${rp_new} ${sha}"$'\n'
      batch+="delete refs/heads/${rp_old} ${sha}"$'\n'
    done
    local head_before="" head_new=""
    if head_before=$(git symbolic-ref --quiet HEAD 2>/dev/null); then
      for ((j = 0; j < ${#rename_pairs[@]}; j+=2)); do
        if [[ "$head_before" == "refs/heads/${rename_pairs[$j]}" ]]; then
          head_new="refs/heads/${rename_pairs[$((j + 1))]}"
          git symbolic-ref HEAD "$head_new"
          break
        fi
      done
    fi
    if ! printf '%s' "$batch" | git update-ref --stdin -m "git-stack move (post-rename)"; then
      [[ -n "$head_new" ]] && git symbolic-ref HEAD "$head_before" 2>/dev/null || true
      die "git update-ref batch failed; refs unchanged (atomic)"
    fi
    log "${C_GREEN}done${C_RESET}    move complete (+$((${#rename_pairs[@]} / 2)) renames)"
  fi

  if (( ! OPT_NO_PUSH )); then
    _remote_rename_batch_or_skip "${rename_pairs[@]}"
    _post_rename_sync
  fi
}
```

- [ ] **Step 4: Wire `_finish_move_rename` into `run_reflow_loop`**

At the very end of `run_reflow_loop` (after `clear_state` on line 682), but before the function-closing `}`, change:

```bash
  log "${C_GREEN}done${C_RESET}    reflow complete (${C_BOLD}${n_processed}${C_RESET} branches restacked)"
  clear_state
}
```

to:

```bash
  log "${C_GREEN}done${C_RESET}    reflow complete (${C_BOLD}${n_processed}${C_RESET} branches restacked)"
  local post_action="$STACK_POST_ACTION"
  clear_state
  if [[ "$post_action" == "move-rename" ]]; then
    _finish_move_rename
  fi
}
```

(`clear_state` zeroes `STACK_POST_ACTION`, so capture it first.)

- [ ] **Step 5: Update `cmd_move` to set `STACK_POST_ACTION` + remove inline Stages B/C**

In `cmd_move`, in the block where state is initialised (Stage A setup), add:

```bash
  STACK_POST_ACTION="move-rename"
  STACK_POST_BRANCHES=("${post[@]}")
```

And **delete** the "Stage B" and "Stage C" inline blocks from `cmd_move` — they're now in `_finish_move_rename` and called via `run_reflow_loop`.

Also, persist `OPT_NO_PUSH` and `OPT_NO_SYNC` in the state file so `_finish_move_rename` (running after `git stack continue` resumes) can honour them. In the `STACK_*` declarations, add:

```bash
STACK_OPT_NO_PUSH=0
STACK_OPT_NO_SYNC=0
```

In `save_state`, add:
```bash
  printf 'STACK_OPT_NO_PUSH=%d\n' "$STACK_OPT_NO_PUSH"
  printf 'STACK_OPT_NO_SYNC=%d\n' "$STACK_OPT_NO_SYNC"
```

In `cmd_continue` (before calling `save_state` / `run_reflow_loop`), restore them:
```bash
  OPT_NO_PUSH=$STACK_OPT_NO_PUSH
  OPT_NO_SYNC=$STACK_OPT_NO_SYNC
```

In `cmd_move` before `save_state`:
```bash
  STACK_OPT_NO_PUSH=$OPT_NO_PUSH
  STACK_OPT_NO_SYNC=$OPT_NO_SYNC
```

- [ ] **Step 6: Run the conflict test**

```bash
bats tests/git-stack.bats --filter 'cherry-pick conflict'
```

Expected: PASS.

- [ ] **Step 7: Full suite**

```bash
make test JOBS=1
```

Expected: green. (If `cmd_continue` resumes a non-move reflow and `STACK_POST_ACTION` is empty, no post-action runs — backward-compat.)

- [ ] **Step 8: Commit**

```bash
git add bin/git-stack tests/git-stack.bats
git commit -m "move: route rename batch + remote stages through reflow state machine for continue/abort interop"
```

---

## Task 14: Extend `cmd_rename` with remote rename + pr sync

Apply the same Stage 2 + Stage 3 to the existing prefix-rename command. New flags `--no-push` and `--no-sync`.

**Files:**
- Modify: `bin/git-stack` — `cmd_rename`
- Modify: `tests/git-stack.bats`

- [ ] **Step 1: Write the failing test**

Add to `tests/git-stack.bats`:

```bash
# ---------- rename (remote stages) ----------

@test "rename: triggers remote rename for pushed branches" {
  make_stack_branches feat 01-a 02-b
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  run git stack rename newfeat --no-color
  [ "$status" -eq 0 ]
  [ "$(gh_log_count 'api -X POST')" -ge 2 ]
  [ "$(gh_log_count 'pr')" -ge 1 ]
}

@test "rename --no-push: keeps local-only behavior" {
  make_stack_branches feat 01-a 02-b
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  run git stack rename newfeat --no-push --no-color
  [ "$status" -eq 0 ]
  [ "$(gh_log_count 'api -X POST')" -eq 0 ]
  [ "$(gh_log_count 'pr')" -eq 0 ]
}
```

- [ ] **Step 2: Run failing tests**

```bash
bats tests/git-stack.bats --filter 'rename: triggers|rename --no-push'
```

Expected: FAIL.

- [ ] **Step 3: Extend `cmd_rename`**

In `cmd_rename` (line 1611), add flag parsing for `--no-push` / `--no-sync`. The function already uses `_consume_common_flag` so `--no-push` / `--no-sync` are picked up automatically once Task 5 added them to the common-flag parser. Confirm by reading lines 1614-1625 — they should already work.

After the existing `log "${C_GREEN}done${C_RESET}    rename complete"` line (around line 1706), add:

```bash
  # Stage 2: remote rename. Build pairs from old_pfx -> new_pfx for each branch.
  if (( ! OPT_NO_PUSH )); then
    local rename_pairs=() b leaf
    for b in "${branches[@]}"; do
      leaf="${b##*/}"
      rename_pairs+=("$b" "${new_pfx}/${leaf}")
    done
    _remote_rename_batch_or_skip "${rename_pairs[@]}"
    _post_rename_sync
  fi
```

- [ ] **Step 4: Run the tests**

```bash
bats tests/git-stack.bats --filter 'rename: triggers|rename --no-push'
```

Expected: PASS.

- [ ] **Step 5: Full suite**

```bash
make test JOBS=1
```

Expected: green.

- [ ] **Step 6: Commit**

```bash
git add bin/git-stack tests/git-stack.bats
git commit -m "rename: add remote-rename + pr-sync stages (with --no-push/--no-sync)"
```

---

## Task 15: Update help text (`cmd_help`)

Document the new commands.

**Files:**
- Modify: `bin/git-stack` — `cmd_help`

- [ ] **Step 1: Write the test**

```bash
@test "help: documents 'new' and 'move'" {
  run git stack help --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"git stack new"* ]] || [[ "$output" == *"new "* ]]
  [[ "$output" == *"move"* ]]
}
```

- [ ] **Step 2: Run**

```bash
bats tests/git-stack.bats --filter 'help: documents'
```

Expected: FAIL.

- [ ] **Step 3: Add the new help entries**

In `cmd_help`, insert these blocks before the `init` entry (around line 1048):

```bash
  ${sub}new${r} <slug> [${fl}--top${r}|${fl}--bottom${r}|${fl}--after${r} <ref>|${fl}--at${r} <ref>] [${fl}--no-push${r}] [${fl}--no-sync${r}] [${fl}--prefix${r} <p>]
                                    Create an empty branch in the stack at the
                                    chosen position. <ref> is a numeric leaf
                                    or a full branch name. With no position
                                    flag, opens an interactive picker
                                    (\`[top]\` ... branches ... \`[bottom]\`).
                                    Cascades leaf renames for branches above
                                    the insertion; auto-renames remote refs
                                    via GitHub branch-rename API so PRs follow,
                                    then runs \`pr sync\`. With no stack
                                    detected, prompts for or picks a prefix
                                    (bootstrap path; non-TTY requires
                                    ${fl}--prefix${r}).
  ${sub}move${r} <branch> [${fl}--top${r}|${fl}--bottom${r}|${fl}--after${r} <ref>|${fl}--at${r} <ref>] [${fl}--no-push${r}] [${fl}--no-sync${r}] [${fl}--force${r}]
                                    Relocate <branch> in the current stack to
                                    the chosen position. Cherry-picks affected
                                    branches onto their new predecessors using
                                    the existing reflow state machine — on
                                    conflict, resolve + \`git stack continue\`.
                                    Cascades leaf renames + remote rename + pr
                                    sync, same as ${sub}new${r}.
```

Also: in the `${b}Common flags:${r}` block (around line 1054), add the two new flags:

```bash
  ${fl}--no-push${r}                       (new/move/rename) skip remote rename + pr sync.
  ${fl}--no-sync${r}                       (new/move/rename) skip pr sync only.
```

- [ ] **Step 4: Run the test**

```bash
bats tests/git-stack.bats --filter 'help: documents'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/git-stack tests/git-stack.bats
git commit -m "help: document 'new' and 'move' subcommands"
```

---

## Task 16: Update shell aliases

Remap `gstkmv` → `move`, add `gstkn` → `new`, add `gstkrn` → `rename`.

**Files:**
- Modify: `bin/git-stack` — `_emit_init_posix`, `_emit_init_fish`
- Modify: `README.md` — alias table

- [ ] **Step 1: Write a test that the emitted bash init contains the new aliases**

```bash
@test "init bash: emits gstkn, gstkmv (move), gstkrn" {
  run git stack init bash
  [ "$status" -eq 0 ]
  [[ "$output" == *"alias gstkn="* ]]
  [[ "$output" == *"alias gstkmv='git stack move'"* ]]
  [[ "$output" == *"alias gstkrn='git stack rename'"* ]]
}

@test "init fish: emits gstkn, gstkmv (move), gstkrn" {
  run git stack init fish
  [ "$status" -eq 0 ]
  [[ "$output" == *"gstkn git stack new"* ]]
  [[ "$output" == *"gstkmv git stack move"* ]]
  [[ "$output" == *"gstkrn git stack rename"* ]]
}
```

- [ ] **Step 2: Run**

```bash
bats tests/git-stack.bats --filter 'init bash|init fish'
```

Expected: FAIL.

- [ ] **Step 3: Update `_emit_init_posix`**

In `_emit_init_posix` (around line 2546), change:
```bash
alias gstkmv='git stack rename'
```
to:
```bash
alias gstkn='git stack new'
alias gstkmv='git stack move'
alias gstkrn='git stack rename'
```

- [ ] **Step 4: Update `_emit_init_fish`**

In `_emit_init_fish` (around line 2587), change:
```bash
abbr -a -g gstkmv git stack rename
```
to:
```bash
abbr -a -g gstkn git stack new
abbr -a -g gstkmv git stack move
abbr -a -g gstkrn git stack rename
```

- [ ] **Step 5: Run the tests**

```bash
bats tests/git-stack.bats --filter 'init bash|init fish'
```

Expected: PASS.

- [ ] **Step 6: Full suite**

```bash
make test JOBS=1
```

Expected: green.

- [ ] **Step 7: Update README alias table**

Open `README.md`. The alias table is between `### Aliases reference` and the closing `</table>` (or end of the markdown table). Add three rows and update one:

Before:
```markdown
| `gstkmv`    | `git stack rename`                                                                               |
```

After (replace and add):
```markdown
| `gstkn`     | `git stack new`                                                                                  |
| `gstkmv`    | `git stack move` (was `rename` in prior versions; **breaking change**)                            |
| `gstkrn`    | `git stack rename`                                                                                |
```

Also add a "Creating and moving branches" subsection under `## Usage`:

```markdown
### Creating and moving branches

```sh
git stack new auth                       # new branch at top (default)
git stack new cache --after 01-auth      # insert between two branches
git stack new prep --bottom              # new bottom branch (under main)
git stack new                            # interactive picker
git stack move feat/05-cache --top       # relocate to top
git stack move feat/05-cache --at 02     # move into another slot
```

Auto-reflow keeps leaves consecutive: insert/move rewrites affected leaves locally, renames remote branches via GitHub's branch-rename API (so PRs follow), and re-runs `pr sync` to update `[N/M]` prefixes. Use `--no-push` for local-only operations or `--no-sync` to skip just the PR title refresh.
```

Also update the "Stack ordering" mention in the README (if any) — search for `06.5` and remove decimal examples.

- [ ] **Step 8: Commit**

```bash
git add bin/git-stack tests/git-stack.bats README.md
git commit -m "shell init + README: add gstkn/gstkrn, remap gstkmv to 'move'"
```

---

## Task 17: Sanity-pass — abort + history restore on `new` and `move`

The existing `git stack abort` and `git stack history restore` paths should already work because `new` and `move` use `snapshot_stack` and the same `STACK_*` schema. Lock with tests.

**Files:**
- Modify: `tests/git-stack.bats`

- [ ] **Step 1: Write the tests**

```bash
# ---------- new/move history interop ----------

@test "history: 'new' produces a restorable snapshot" {
  make_stack_branches feat 01-a 02-b
  git stack new mid --after 01-a --no-color </dev/null
  run git stack history --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"new"* ]]
}

@test "history: 'move' produces a restorable snapshot" {
  make_stack_branches feat 01-a 02-b 03-c
  git stack move feat/01-a --top --no-color </dev/null
  run git stack history --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"move"* ]]
}
```

- [ ] **Step 2: Run**

```bash
bats tests/git-stack.bats --filter 'history:'
```

Expected: PASS (snapshots already wired via `snapshot_stack new` and `snapshot_stack move` in cmd_new and cmd_move).

- [ ] **Step 3: Commit**

```bash
git add tests/git-stack.bats
git commit -m "test: lock in 'new'/'move' snapshot-history interop"
```

---

## Task 18: Final sweep — full suite, lint-style review, manual smoke

- [ ] **Step 1: Run the full suite a final time**

```bash
make test JOBS=1
```

Expected: all green.

- [ ] **Step 2: Manual smoke in a real repo (optional but recommended)**

Create a throwaway repo and exercise the happy paths:

```bash
cd /tmp && rm -rf gstk-smoke && mkdir gstk-smoke && cd gstk-smoke
git init -q && git commit --allow-empty -qm init
git stack new auth --prefix feat </dev/null
echo a > f && git add f && git commit -qm "auth work"
git stack new login </dev/null
echo b >> f && git add f && git commit -qm "login work"
git stack new cache --after 1 </dev/null
git stack list --no-fetch
# Verify: 01-auth, 02-cache, 03-login
git stack move feat/03-login --bottom --no-color
git stack list --no-fetch
# Verify: 01-login, 02-auth, 03-cache (post move + restack would have happened; check parentage)
```

- [ ] **Step 3: Verify no leftover decimal-leaf references**

```bash
grep -nE '\[0-9\]\+\(\\?\.\[0-9\]\+\)' bin/git-stack
grep -nE '6\.5|06\.5|2\.5' bin/git-stack README.md
```

Expected: no output.

- [ ] **Step 4: Final commit if smoke-test surfaced fixes (otherwise skip)**

```bash
# only if needed
git add ...
git commit -m "smoke-test fixes"
```

---

## Self-review notes

Run through the spec from the Q&A summary at the top of this conversation:

- **Numbering policy (always-consecutive)** — Task 7's cascade-rename batch enforces it. ✓
- **Create semantics (ref-create + checkout, clean tree)** — Task 6 + 7. ✓
- **Position spec (`--after`/`--at`/`--top`/`--bottom`/picker)** — Tasks 6-9. ✓
- **Move semantics (rebase-then-rename, state machine, snapshot, multi-commit guard, same-position error)** — Tasks 12-13. ✓
- **Leaf width (preserve, default 2)** — Task 3 (`_leaf_width_for`). Decimal leaves removed in Task 1. ✓
- **CLI surface (new, move, mv shorthand, gstkn/gstkmv remap/gstkrn aliases)** — Tasks 6, 12, 16. ✓
- **PR/remote handling (auto rename via gh api + auto pr sync, --no-push/--no-sync flags, gh unavailable → silent skip + warn)** — Tasks 4-5 helpers, 10, 13 wiring. ✓
- **Pushed-branch cleanup (via GitHub branch-rename API)** — Task 4. ✓
- **History snapshot** — Task 6/12 `snapshot_stack`, Task 17 lock-in test. ✓
- **Safety preconditions (worktree, state file, clean tree, multi-commit guard)** — Tasks 6, 12. ✓
- **Bootstrap (no current stack — picker or text prompt)** — Task 11. ✓
- **Extend `git stack rename`** — Task 14. ✓
- **Help text updates** — Task 15. ✓
- **Decimal-leaf removal** — Task 1. ✓

No placeholders detected. All function signatures consistent (`_remote_rename_one`, `_remote_rename_batch_or_skip`, `_post_rename_sync`, `_resolve_branch_ref`, `_leaf_width_for`, `_format_leaf`, `_next_leaf_num`, `_validate_slug`, `_check_slug_collision`, `_finish_move_rename`).
