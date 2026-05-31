#!/usr/bin/env bash
# Helpers for git-stack bats tests. Loaded via `load helpers` at the top of
# each .bats file.

GIT_STACK_BIN_DIR="${BATS_TEST_DIRNAME}/../bin"
GIT_STACK_TEST_BIN_DIR="${BATS_TEST_DIRNAME}/bin"

# Per-test scratch repo. Each test gets its own via setup().
setup_repo() {
  TEST_REPO=$(mktemp -d)
  cd "$TEST_REPO"
  # gh stub first so it shadows any real gh; git-stack bin second.
  PATH="${GIT_STACK_TEST_BIN_DIR}:${GIT_STACK_BIN_DIR}:$PATH"
  export PATH
  GH_STUB_DIR="${TEST_REPO}.gh-stub"
  GH_STUB_LOG="${GH_STUB_DIR}/log"
  mkdir -p "$GH_STUB_DIR"
  : > "$GH_STUB_LOG"
  export GH_STUB_DIR GH_STUB_LOG
  git init -q
  git checkout -q -B main 2>/dev/null
  git config user.email "test@test.invalid"
  git config user.name "Test"
  git config commit.gpgsign false
  git config core.pager cat
  git commit --allow-empty -q -m init
  : > file
  git add file
  git commit -q -m "seed"
}

teardown_repo() {
  cd /
  if [[ -n "${TEST_REPO-}" && -d "$TEST_REPO" ]]; then
    rm -rf "$TEST_REPO"
  fi
  if [[ -n "${GH_STUB_DIR-}" && -d "$GH_STUB_DIR" ]]; then
    rm -rf "$GH_STUB_DIR"
  fi
}

# Count occurrences of a `gh <sub1> <sub2>` invocation in the stub log.
# Usage: gh_log_count "pr create"
gh_log_count() {
  local needle="$1" n
  # grep -c always writes the count to stdout, but exits 1 when zero matches —
  # swallow the exit code so callers can use `[ "$(gh_log_count …)" -eq N ]`.
  n=$(grep -c "^gh ${needle}" "$GH_STUB_LOG" 2>/dev/null || true)
  printf '%d' "${n:-0}"
}

# Print the argv portion of every logged invocation whose first two argv
# tokens match. One per line.
gh_log_grep() {
  local needle="$1"
  grep "^gh ${needle}" "$GH_STUB_LOG" 2>/dev/null | cut -f1
}

# Print decoded stdin for the Nth (1-indexed) logged invocation matching
# `gh <prefix>`. Empty if not found.
gh_log_stdin() {
  local needle="$1" n="${2:-1}"
  local line
  line=$(grep "^gh ${needle}" "$GH_STUB_LOG" 2>/dev/null | sed -n "${n}p") || return 0
  [ -n "$line" ] || return 0
  printf '%s' "$line" | cut -f2 | base64 -d 2>/dev/null
}

# make_stack_branches <prefix> <leaf>...
# Creates branches in order, each adding one line to `file`. Caller must be
# on the desired base branch.
make_stack_branches() {
  local prefix="$1"; shift
  local leaf
  for leaf in "$@"; do
    git checkout -q -b "${prefix}/${leaf}"
    printf '%s\n' "$leaf" >> file
    git add file
    git commit -q -m "$leaf"
  done
}

# Add a bare origin and push every local branch to it.
make_remote_origin() {
  local remote_dir="${TEST_REPO}.origin"
  git init -q --bare "$remote_dir"
  git remote add origin "$remote_dir"
  git push -q --all -u origin
}

# Assert <branch>'s tip's parent SHA equals <expected_parent>.
assert_branch_parent_is() {
  local branch="$1" expected_parent="$2"
  local actual
  actual=$(git log -1 --format=%P "$branch")
  [[ "$actual" == "$expected_parent" ]] || {
    echo "expected $branch parent to be $expected_parent, got $actual" >&2
    return 1
  }
}

# ---------- fail-fast assertion helpers ----------
#
# bats-core 1.13 only fails a test on its LAST command's status, so a bare
# intermediate `[ ... ]` / `[[ ... ]]` that evaluates false is silently
# skipped. These helpers each `return 1` (failing the test wherever they sit)
# and print context, so an assertion in non-final position actually fires.
# Use them instead of bare test brackets in any test with multiple checks.

# assert <cmd...> : the command must succeed (exit 0).
assert() {
  if ! "$@"; then echo "assert failed: $*" >&2; return 1; fi
}

# refute <cmd...> : the command must fail (non-zero exit).
refute() {
  if "$@"; then echo "refute failed (expected non-zero): $*" >&2; return 1; fi
}

# assert_eq <actual> <expected> [label] : string equality.
assert_eq() {
  if [[ "$1" != "$2" ]]; then
    echo "assert_eq failed${3:+ ($3)}: got '$1', want '$2'" >&2
    return 1
  fi
}

# assert_status <expected> : check the bats `run` status variable.
assert_status() {
  if [[ "${status-}" != "$1" ]]; then
    echo "assert_status failed: got '${status-}', want '$1'" >&2
    echo "--- output ---" >&2
    echo "${output-}" >&2
    return 1
  fi
}

# assert_output_contains <substr> : check the bats `run` output variable.
assert_output_contains() {
  if [[ "${output-}" != *"$1"* ]]; then
    echo "assert_output_contains failed: '$1' not found in:" >&2
    echo "${output-}" >&2
    return 1
  fi
}

# assert_branch_exists / assert_branch_absent : local ref presence.
assert_branch_exists() {
  if ! git rev-parse --verify --quiet "refs/heads/$1" >/dev/null; then
    echo "expected branch to exist: $1" >&2
    return 1
  fi
}
assert_branch_absent() {
  if git rev-parse --verify --quiet "refs/heads/$1" >/dev/null; then
    echo "expected branch to be absent: $1" >&2
    return 1
  fi
}

# assert_sha_eq <rev> <expected_sha> [label] : resolve <rev> and compare.
assert_sha_eq() {
  local actual
  actual=$(git rev-parse "$1")
  assert_eq "$actual" "$2" "${3:-$1}"
}
