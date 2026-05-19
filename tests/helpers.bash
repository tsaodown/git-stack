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
