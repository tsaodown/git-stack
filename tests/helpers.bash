#!/usr/bin/env bash
# Helpers for git-stack bats tests. Loaded via `load helpers` at the top of
# each .bats file.

GIT_STACK_BIN_DIR="${BATS_TEST_DIRNAME}/../bin"

# Per-test scratch repo. Each test gets its own via setup().
setup_repo() {
  TEST_REPO=$(mktemp -d)
  cd "$TEST_REPO"
  PATH="${GIT_STACK_BIN_DIR}:$PATH"
  export PATH
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
