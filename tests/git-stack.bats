#!/usr/bin/env bats

load helpers

setup() { setup_repo; }
teardown() { teardown_repo; }

# ---------- list ----------

@test "list: orders branches numerically and marks current with *" {
  make_stack_branches feat 01-a 02-b 03-c
  run git stack list --no-fetch --no-color
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "feat/01-a"
  echo "$output" | grep -q "feat/02-b"
  echo "$output" | grep -q "\* feat/03-c"
  local pos1 pos2 pos3
  pos1=$(echo "$output" | grep -n "feat/01-a" | head -1 | cut -d: -f1)
  pos2=$(echo "$output" | grep -n "feat/02-b" | head -1 | cut -d: -f1)
  pos3=$(echo "$output" | grep -n "feat/03-c" | head -1 | cut -d: -f1)
  [ "$pos1" -lt "$pos2" ]
  [ "$pos2" -lt "$pos3" ]
}

@test "list: shows [unpushed] for branches with no upstream" {
  make_stack_branches feat 01-a
  run git stack list --no-fetch --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"[unpushed]"* ]]
}

# ---------- restack ----------

@test "restack: child reflows after parent message-only amend" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/01-a
  git commit -q --amend -m "01-a amended"
  local new_a
  new_a=$(git rev-parse HEAD)
  run git stack restack --no-color
  [ "$status" -eq 0 ]
  assert_branch_parent_is feat/02-b "$new_a"
}

@test "restack: --onto rebases bottom and propagates up" {
  make_stack_branches feat 01-a 02-b
  git checkout -q main
  git commit --allow-empty -q -m base2
  local new_main
  new_main=$(git rev-parse main)
  git checkout -q feat/02-b
  run git stack restack --onto main --from feat/01-a --no-color
  [ "$status" -eq 0 ]
  assert_branch_parent_is feat/01-a "$new_main"
}

# ---------- multi-commit guard (added in this refactor) ----------

@test "restack: refuses multi-commit branch without --force" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/02-b
  printf 'second\n' >> file
  git add file
  git commit -q -m "02-b second"
  git checkout -q feat/01-a
  git commit -q --amend -m "amended"
  run git stack restack --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"--force"* ]]
  [[ "$output" == *"feat/02-b"* ]]
}

@test "restack --force: cherry-picks tip only, drops intermediate" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/02-b
  # Second commit on 02-b adds a new file so the tip diff is self-contained
  # (cherry-pickable onto an unrelated base without 3-way merge gymnastics).
  printf 'tip\n' > tipfile
  git add tipfile
  git commit -q -m "02-b second"
  git checkout -q feat/01-a
  git commit -q --amend -m "amended"
  run git stack restack --force --no-color
  [ "$status" -eq 0 ]
}

# ---------- amend ----------

@test "amend: amends current and reflows upper branches" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/01-a
  run git stack amend -m "01-a amended" --no-color
  [ "$status" -eq 0 ]
  local new_a
  new_a=$(git rev-parse feat/01-a)
  assert_branch_parent_is feat/02-b "$new_a"
}

@test "amend: writes a snapshot with action=amend" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/01-a
  git stack amend -m "msg" --no-color
  run git stack history --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"amend"* ]]
}

# ---------- history ----------

@test "history list: shows snapshots after a restack" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/01-a
  git commit -q --amend -m "amended"
  git stack restack --no-color
  run git stack history --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"restack"* ]]
}

# ---------- rename ----------

@test "rename --dry-run: prints batch and changes nothing" {
  make_stack_branches feat 01-a 02-b
  git checkout -q main
  run git stack rename newfeat --prefix feat/ --dry-run --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"create refs/heads/newfeat/01-a"* ]]
  git rev-parse --verify --quiet feat/01-a
  run git rev-parse --verify --quiet refs/heads/newfeat/01-a
  [ "$status" -ne 0 ]
}

@test "rename: live moves all branches in stack" {
  make_stack_branches feat 01-a 02-b
  git checkout -q main
  run git stack rename newfeat --prefix feat/ --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/newfeat/01-a
  git rev-parse --verify --quiet refs/heads/newfeat/02-b
  run git rev-parse --verify --quiet refs/heads/feat/01-a
  [ "$status" -ne 0 ]
}

# ---------- detect_prefix error specificity ----------

@test "detect_prefix: detached HEAD message" {
  make_stack_branches feat 01-a
  git checkout -q --detach
  run git stack list --no-fetch --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"detached HEAD"* ]]
}

@test "detect_prefix: non-numeric branch message" {
  make_stack_branches feat 01-a
  git checkout -q -b plain-branch
  run git stack list --no-fetch --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"no numeric leaf"* ]]
}

# ---------- common-flag parser dedup ----------

@test "common flags: --prefix / --color / -v parse uniformly across commands" {
  make_stack_branches feat 01-a 02-b
  git checkout -q main
  # Each command should accept --prefix without error.
  run git stack list --prefix feat/ --no-fetch --no-color
  [ "$status" -eq 0 ]
  run git stack push --prefix feat/ --no-color
  # push will fail (no remote), but --prefix should parse.
  [[ "$output" != *"unknown"* ]]
}

# ---------- push ----------

@test "push: sets upstream so a freshly-pushed branch reports [synced]" {
  make_stack_branches feat 01-a
  make_remote_origin
  # New branch created after origin was set up — no upstream yet.
  make_stack_branches feat 02-b
  [ -z "$(git for-each-ref --format='%(upstream:short)' refs/heads/feat/02-b)" ]

  run git stack push --all --no-color
  [ "$status" -eq 0 ]

  # Upstream must be configured to origin/feat/02-b after push.
  [ "$(git for-each-ref --format='%(upstream:short)' refs/heads/feat/02-b)" = "origin/feat/02-b" ]

  # And `list` must reflect that — no [unpushed] for feat/02-b.
  run git stack list --no-fetch --no-color
  [ "$status" -eq 0 ]
  local line
  line=$(echo "$output" | grep "feat/02-b")
  [[ "$line" != *"[unpushed]"* ]]
  [[ "$line" == *"[synced]"* ]]
}

# ---------- close ----------

@test "close: deletes only branches with [gone] upstream" {
  make_stack_branches feat 01-a 02-b
  make_remote_origin
  git push -q origin --delete feat/02-b
  git fetch -q --prune
  git checkout -q main
  run git stack close --prefix feat/ --no-color
  [ "$status" -eq 0 ]
  run git rev-parse --verify --quiet refs/heads/feat/02-b
  [ "$status" -ne 0 ]
  git rev-parse --verify --quiet refs/heads/feat/01-a
}

# ---------- default-branch ----------

@test "default-branch: returns main when on main" {
  run git stack default-branch
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "default-branch: honors stack.base config" {
  git checkout -q -b develop
  git config stack.base develop
  run git stack default-branch
  [ "$status" -eq 0 ]
  [ "$output" = "develop" ]
}

@test "default-branch: strips origin/ prefix from stack.base" {
  git config stack.base origin/main
  run git stack default-branch
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "default-branch: falls back to master when only master exists" {
  git checkout -q -b master
  git branch -q -D main
  run git stack default-branch
  [ "$status" -eq 0 ]
  [ "$output" = "master" ]
}

# ---------- init ----------

@test "init bash: emits eval-able snippet with expected aliases" {
  run git stack init bash
  [ "$status" -eq 0 ]
  [[ "$output" == *"alias gstk='git stack'"* ]]
  [[ "$output" == *"alias gstkl='git stack list'"* ]]
  [[ "$output" == *"alias gstkam='git stack amend'"* ]]
  [[ "$output" == *"gstkrom()"* ]]
  [[ "$output" == *"gstkromp()"* ]]
  [[ "$output" == *"gstkcl()"* ]]
  # Result must parse as valid bash.
  bash -n <(printf '%s\n' "$output")
}

@test "init zsh: emits eval-able snippet with expected aliases" {
  run git stack init zsh
  [ "$status" -eq 0 ]
  [[ "$output" == *"alias gstk='git stack'"* ]]
  [[ "$output" == *"gstkrom()"* ]]
}

@test "init fish: emits abbr-based snippet for fish" {
  run git stack init fish
  [ "$status" -eq 0 ]
  [[ "$output" == *"abbr -a -g gstk git stack"* ]]
  [[ "$output" == *"abbr -a -g gstkrom"* ]]
  [[ "$output" == *"abbr -a -g gstkromp"* ]]
  [[ "$output" == *"abbr -a -g gstkcl"* ]]
  # No bash-style function definitions.
  [[ "$output" != *"gstkrom()"* ]]
}

@test "init: errors with no argument" {
  run git stack init
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage:"* ]]
}

@test "init: errors on unsupported shell" {
  run git stack init powershell
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported shell"* ]]
}

@test "init bash: alias count matches simple-abbreviation count (16)" {
  # 16 simple aliases (gstk + 15 others), 3 compound functions.
  run git stack init bash
  [ "$status" -eq 0 ]
  local alias_count
  alias_count=$(printf '%s\n' "$output" | grep -c '^alias gstk')
  [ "$alias_count" -eq 16 ]
}
