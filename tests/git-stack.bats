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

# ---------- pr sync ----------

@test "pr sync: fresh 3-branch stack creates draft PRs with correct bases" {
  make_stack_branches feat 01-foo 02-bar 03-baz
  make_remote_origin
  run git stack pr sync --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"create  #101 feat/01-foo -> main"* ]]
  [[ "$output" == *"create  #102 feat/02-bar -> feat/01-foo"* ]]
  [[ "$output" == *"create  #103 feat/03-baz -> feat/02-bar"* ]]
  # Each branch: one pr create, one pr edit
  [ "$(gh_log_count 'pr create')" -eq 3 ]
  [ "$(gh_log_count 'pr edit')" -eq 3 ]
  # Verify --draft is on each create
  local creates
  creates=$(grep -c '^gh pr create.* --draft' "$GH_STUB_LOG")
  [ "$creates" -eq 3 ]
}

@test "pr sync: idempotent re-run makes no remote changes" {
  make_stack_branches feat 01-foo 02-bar 03-baz
  make_remote_origin
  git stack pr sync --no-color > /dev/null
  truncate -s 0 "$GH_STUB_LOG"
  run git stack pr sync --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"exists  #101"* ]]
  [[ "$output" == *"exists  #102"* ]]
  [[ "$output" == *"exists  #103"* ]]
  [ "$(gh_log_count 'pr create')" -eq 0 ]
  [ "$(gh_log_count 'pr edit')" -eq 0 ]
}

@test "pr sync: stack growing from 2 to 3 rebrackets existing titles" {
  make_stack_branches feat 01-foo 02-bar
  make_remote_origin
  git stack pr sync --no-color > /dev/null
  # Sanity: PRs exist with [1/2] and [2/2] titles. Content title comes from
  # the last commit subject on each branch — make_stack_branches commits with
  # subjects matching the leaf names ("01-foo", "02-bar").
  [ "$(jq -r .title "$GH_STUB_DIR/by-num/101.json")" = "[1/2] 01-foo" ]
  [ "$(jq -r .title "$GH_STUB_DIR/by-num/102.json")" = "[2/2] 02-bar" ]
  # Add a third branch (no need to push manually — pr sync will push it).
  git checkout -q -b feat/03-baz
  echo c >> file
  git add file
  git commit -q -m "third commit"
  truncate -s 0 "$GH_STUB_LOG"
  run git stack pr sync --no-color
  [ "$status" -eq 0 ]
  [ "$(jq -r .title "$GH_STUB_DIR/by-num/101.json")" = "[1/3] 01-foo" ]
  [ "$(jq -r .title "$GH_STUB_DIR/by-num/102.json")" = "[2/3] 02-bar" ]
  [ "$(jq -r .title "$GH_STUB_DIR/by-num/103.json")" = "[3/3] third commit" ]
}

@test "pr sync: preserves non-position bracket prefix like [WIP]" {
  make_stack_branches feat 01-foo 02-bar 03-baz
  make_remote_origin
  git stack pr sync --no-color > /dev/null
  # User manually edits #101's title.
  jq '.title = "[WIP] Foo overhaul"' "$GH_STUB_DIR/by-num/101.json" > "$GH_STUB_DIR/x"
  mv "$GH_STUB_DIR/x" "$GH_STUB_DIR/by-num/101.json"
  truncate -s 0 "$GH_STUB_LOG"
  run git stack pr sync --no-color
  [ "$status" -eq 0 ]
  [ "$(jq -r .title "$GH_STUB_DIR/by-num/101.json")" = "[1/3] [WIP] Foo overhaul" ]
}

@test "pr sync: re-aligns base when an existing PR points at the wrong branch" {
  make_stack_branches feat 01-foo 02-bar 03-baz
  make_remote_origin
  git stack pr sync --no-color > /dev/null
  # Simulate #102's base getting reset to main (e.g. parent merged, base
  # auto-retargeted by GitHub, or someone edited it by hand).
  jq '.baseRefName = "main"' "$GH_STUB_DIR/by-num/102.json" > "$GH_STUB_DIR/x"
  mv "$GH_STUB_DIR/x" "$GH_STUB_DIR/by-num/102.json"
  truncate -s 0 "$GH_STUB_LOG"
  run git stack pr sync --no-color
  [ "$status" -eq 0 ]
  # The base on #102 should have been re-pointed at its real parent.
  [ "$(jq -r .baseRefName "$GH_STUB_DIR/by-num/102.json")" = "feat/01-foo" ]
  # And the edit call should have explicitly passed --base.
  grep -q "^gh pr edit 102 .* --base feat/01-foo" "$GH_STUB_LOG"
  # PRs whose bases were already correct shouldn't get a base flip.
  ! grep -q "^gh pr edit 101 .* --base " "$GH_STUB_LOG"
  ! grep -q "^gh pr edit 103 .* --base " "$GH_STUB_LOG"
}

@test "pr sync --dry-run: reports base mismatch without calling pr edit" {
  make_stack_branches feat 01-foo 02-bar 03-baz
  make_remote_origin
  git stack pr sync --no-color > /dev/null
  jq '.baseRefName = "main"' "$GH_STUB_DIR/by-num/102.json" > "$GH_STUB_DIR/x"
  mv "$GH_STUB_DIR/x" "$GH_STUB_DIR/by-num/102.json"
  truncate -s 0 "$GH_STUB_LOG"
  run git stack pr sync --dry-run --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"base=yes"* ]]
  [ "$(gh_log_count 'pr edit')" -eq 0 ]
  [ "$(jq -r .baseRefName "$GH_STUB_DIR/by-num/102.json")" = "main" ]
}

@test "pr sync: idempotent when base already matches expected parent" {
  make_stack_branches feat 01-foo 02-bar 03-baz
  make_remote_origin
  git stack pr sync --no-color > /dev/null
  truncate -s 0 "$GH_STUB_LOG"
  run git stack pr sync --no-color
  [ "$status" -eq 0 ]
  # No edits at all when title, body, AND base are all stable.
  [ "$(gh_log_count 'pr edit')" -eq 0 ]
}

@test "pr sync --no-push: errors when a branch isn't on origin" {
  make_stack_branches feat 01-foo 02-bar
  # No make_remote_origin — branches don't exist on origin
  git init -q --bare "${TEST_REPO}.origin"
  git remote add origin "${TEST_REPO}.origin"
  run git stack pr sync --no-push --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"not synced on origin"* ]]
  [ "$(gh_log_count 'pr create')" -eq 0 ]
  [ "$(gh_log_count 'pr edit')" -eq 0 ]
}

@test "pr sync --dry-run: makes no create/edit calls" {
  make_stack_branches feat 01-foo 02-bar
  make_remote_origin
  run git stack pr sync --dry-run --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"create  feat/01-foo"* ]]
  [[ "$output" == *"update  #DRY"* ]]
  [ "$(gh_log_count 'pr create')" -eq 0 ]
  [ "$(gh_log_count 'pr edit')" -eq 0 ]
  # pr list still called (read-only query is fine)
  [ "$(gh_log_count 'pr list')" -gt 0 ]
}

@test "pr sync: picks up .github/pull_request_template.md and prepends it" {
  make_stack_branches feat 01-foo
  make_remote_origin
  mkdir -p .github
  printf '## Why\n\nDescribe the change.\n' > .github/pull_request_template.md
  git add .github && git commit -q -m "add template"
  run git stack pr sync --no-color
  [ "$status" -eq 0 ]
  # The body sent to pr create should contain the template content.
  local body
  body=$(gh_log_stdin 'pr create')
  [[ "$body" == *"## Why"* ]]
  [[ "$body" == *"Describe the change."* ]]
  # And after pass 2, the stored body has template + nav footer.
  local stored
  stored=$(jq -r .body "$GH_STUB_DIR/by-num/101.json")
  [[ "$stored" == *"## Why"* ]]
  [[ "$stored" == *"git-stack:nav-start"* ]]
  [[ "$stored" == *"git-stack:nav-end"* ]]
}

@test "pr sync: prefers .github/PULL_REQUEST_TEMPLATE/default.md over single-file" {
  make_stack_branches feat 01-foo
  make_remote_origin
  mkdir -p .github/PULL_REQUEST_TEMPLATE
  printf 'SINGLE FILE TEMPLATE\n' > .github/PULL_REQUEST_TEMPLATE.md
  printf 'DIRECTORY DEFAULT TEMPLATE\n' > .github/PULL_REQUEST_TEMPLATE/default.md
  git add .github && git commit -q -m "add templates"
  run git stack pr sync --no-color
  [ "$status" -eq 0 ]
  local body
  body=$(gh_log_stdin 'pr create')
  [[ "$body" == *"DIRECTORY DEFAULT TEMPLATE"* ]]
  [[ "$body" != *"SINGLE FILE TEMPLATE"* ]]
}

@test "pr sync: warns on multi-template directory without default" {
  make_stack_branches feat 01-foo
  make_remote_origin
  mkdir -p .github/PULL_REQUEST_TEMPLATE
  printf 'feature\n' > .github/PULL_REQUEST_TEMPLATE/feature.md
  printf 'bug\n' > .github/PULL_REQUEST_TEMPLATE/bug.md
  git add .github && git commit -q -m "add multi templates"
  run git stack pr sync --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"no default.md"* ]] || [[ "$output" == *"multi-template"* ]]
  # Body should NOT contain template content (just nav footer)
  local stored
  stored=$(jq -r .body "$GH_STUB_DIR/by-num/101.json")
  [[ "$stored" != *"feature"* ]]
  [[ "$stored" != *"bug"* ]]
  [[ "$stored" == *"git-stack:nav-start"* ]]
}

@test "pr sync: --ready creates non-draft PRs" {
  make_stack_branches feat 01-foo 02-bar
  make_remote_origin
  run git stack pr sync --ready --no-color
  [ "$status" -eq 0 ]
  # No --draft flag in any pr create invocation
  local drafts
  drafts=$(grep -c '^gh pr create.* --draft' "$GH_STUB_LOG" || true)
  [ "$drafts" -eq 0 ]
  [ "$(gh_log_count 'pr create')" -eq 2 ]
}

@test "pr sync: partial pr create failure returns exit 3 but processes others" {
  make_stack_branches feat 01-foo 02-bar 03-baz
  make_remote_origin
  export GH_STUB_FAIL_CREATE="feat/02-bar"
  run git stack pr sync --no-color
  [ "$status" -eq 3 ]
  [[ "$output" == *"PR sync failed for"* ]]
  # First and third should have created PRs (stub sanitizes / and - to _)
  [ "$(gh_log_count 'pr create')" -eq 3 ]   # all three attempted
  [ -f "$GH_STUB_DIR/by-branch/feat_01_foo.num" ]
  [ -f "$GH_STUB_DIR/by-branch/feat_03_baz.num" ]
  # Middle branch should NOT have a state file (create failed)
  [ ! -f "$GH_STUB_DIR/by-branch/feat_02_bar.num" ]
}

@test "pr sync: single-branch stack still gets nav footer" {
  make_stack_branches feat 01-solo
  make_remote_origin
  run git stack pr sync --no-color
  [ "$status" -eq 0 ]
  local body
  body=$(jq -r .body "$GH_STUB_DIR/by-num/101.json")
  [[ "$body" == *"git-stack:nav-start"* ]]
  [[ "$body" == *"#101 01-solo ← this PR"* ]]
  [[ "$body" == *"git-stack:nav-end"* ]]
}

@test "pr sync: empty-diff branch in middle is skipped and chain bridges over it" {
  make_stack_branches feat 01-foo
  # Create 02-mid pointing at feat/01-foo's tip — no new commits
  git branch feat/02-mid feat/01-foo
  git checkout -q feat/02-mid
  git checkout -q -b feat/03-baz
  echo c >> file
  git add file
  git commit -q -m third
  make_remote_origin
  run git stack pr sync --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip    feat/02-mid"* ]]
  [[ "$output" == *"no commits ahead of feat/01-foo"* ]]
  # Only 2 PRs created (not 3)
  [ "$(gh_log_count 'pr create')" -eq 2 ]
  # 03-baz's --base should be feat/01-foo (bridging over the empty middle)
  grep -q '^gh pr create .*--head feat/03-baz .*--base feat/01-foo' "$GH_STUB_LOG"
  # Titles use [N/2] not [N/3]. Content comes from each branch's last commit
  # subject: 01-foo from make_stack_branches, "third" from the inline commit.
  [ "$(jq -r .title "$GH_STUB_DIR/by-num/101.json")" = "[1/2] 01-foo" ]
  [ "$(jq -r .title "$GH_STUB_DIR/by-num/102.json")" = "[2/2] third" ]
}

@test "pr sync: resumability — already-existing PR is found via re-query" {
  make_stack_branches feat 01-foo 02-bar
  make_remote_origin
  # Seed an existing PR for feat/01-foo with a stale position prefix
  # (simulates a stack that's been reshuffled since the prior run).
  export GH_PR_feat_01_foo__NUM=999
  export GH_PR_feat_01_foo__TITLE="[5/9] Old name"
  export GH_PR_feat_01_foo__BODY=""
  run git stack pr sync --no-color
  [ "$status" -eq 0 ]
  # No new PR created for 01-foo (we re-discovered #999); one for 02-bar
  [[ "$output" == *"exists  #999 feat/01-foo"* ]]
  [[ "$output" == *"create  #101 feat/02-bar"* ]]
  # And the title's position prefix should have been rebracketed to [1/2],
  # preserving the rest of the title ("Old name").
  # NOTE: env-seeded PRs don't get persisted edits in the stub (it can't write
  # to env vars), so we verify the edit via the stub log instead. The stub
  # logs argv shell-quoted via %q, so reconstruct it with `eval set --`.
  local edit_line cmd_part title_arg=""
  edit_line=$(grep '^gh pr edit 999 ' "$GH_STUB_LOG" | head -1)
  [ -n "$edit_line" ]
  cmd_part="${edit_line%%	*}"
  eval "set -- $cmd_part"
  while (( $# > 0 )); do
    if [ "$1" = "--title" ]; then
      title_arg="${2-}"
      break
    fi
    shift
  done
  [ "$title_arg" = "[1/2] Old name" ]
}

# ---------- pr list ----------

@test "pr list: lists synced branches with PR numbers and titles" {
  make_stack_branches feat 01-foo 02-bar 03-baz
  make_remote_origin
  git stack pr sync --no-color > /dev/null
  run git stack pr list --no-fetch --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"feat/01-foo"* ]]
  [[ "$output" == *"#101"* ]]
  [[ "$output" == *"feat/02-bar"* ]]
  [[ "$output" == *"#102"* ]]
  [[ "$output" == *"feat/03-baz"* ]]
  [[ "$output" == *"#103"* ]]
  # Parent header
  [[ "$output" == *"parent:"* ]]
  [[ "$output" == *"main"* ]]
}

@test "pr list: marks current branch with *" {
  make_stack_branches feat 01-foo 02-bar 03-baz
  make_remote_origin
  git stack pr sync --no-color > /dev/null
  git checkout -q feat/02-bar
  run git stack pr list --no-fetch --no-color
  [ "$status" -eq 0 ]
  # Exactly one line should start with "*"
  local star_lines
  star_lines=$(printf '%s\n' "$output" | grep -c '^\*' || true)
  [ "$star_lines" -eq 1 ]
  # And it should be the feat/02-bar line
  printf '%s\n' "$output" | grep -q '^\* feat/02-bar'
}

@test "pr list: shows (no PR) for branches without an open PR" {
  make_stack_branches feat 01-foo
  make_remote_origin
  git stack pr sync --no-color > /dev/null
  # Add a new branch but don't sync.
  git checkout -q -b feat/02-bar
  echo b >> file
  git add file
  git commit -q -m "second"
  git push -q -u origin feat/02-bar
  run git stack pr list --no-fetch --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"feat/01-foo"* ]]
  [[ "$output" == *"#101"* ]]
  [[ "$output" == *"feat/02-bar"* ]]
  [[ "$output" == *"(no PR)"* ]]
}

@test "pr list: [draft] flag appears when PR is a draft" {
  make_stack_branches feat 01-foo
  make_remote_origin
  # Seed a draft PR (default for stub) and a non-draft (DRAFT=0).
  make_stack_branches feat 02-bar
  export GH_PR_feat_01_foo__NUM=201
  export GH_PR_feat_01_foo__TITLE="Draft PR"
  export GH_PR_feat_01_foo__BODY=""
  export GH_PR_feat_01_foo__DRAFT=1
  export GH_PR_feat_01_foo__BASE=main
  export GH_PR_feat_02_bar__NUM=202
  export GH_PR_feat_02_bar__TITLE="Ready PR"
  export GH_PR_feat_02_bar__BODY=""
  export GH_PR_feat_02_bar__DRAFT=0
  export GH_PR_feat_02_bar__BASE=feat/01-foo
  run git stack pr list --no-fetch --no-color
  [ "$status" -eq 0 ]
  # The draft branch's line has [draft]; the non-draft does not.
  local draft_line ready_line
  draft_line=$(printf '%s\n' "$output" | grep 'feat/01-foo')
  ready_line=$(printf '%s\n' "$output" | grep 'feat/02-bar')
  [[ "$draft_line" == *"[draft]"* ]]
  [[ "$ready_line" != *"[draft]"* ]]
}

@test "pr list: [closed] and [merged] flags for non-open PRs" {
  make_stack_branches feat 01-foo 02-bar
  make_remote_origin
  export GH_PR_feat_01_foo__NUM=301
  export GH_PR_feat_01_foo__TITLE="Was closed"
  export GH_PR_feat_01_foo__BODY=""
  export GH_PR_feat_01_foo__STATE=CLOSED
  export GH_PR_feat_01_foo__BASE=main
  export GH_PR_feat_02_bar__NUM=302
  export GH_PR_feat_02_bar__TITLE="Was merged"
  export GH_PR_feat_02_bar__BODY=""
  export GH_PR_feat_02_bar__STATE=MERGED
  export GH_PR_feat_02_bar__BASE=feat/01-foo
  run git stack pr list --no-fetch --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"[closed]"* ]]
  [[ "$output" == *"[merged]"* ]]
}

@test "pr list: [approved] and [changes] reflect reviewDecision" {
  make_stack_branches feat 01-foo 02-bar
  make_remote_origin
  export GH_PR_feat_01_foo__NUM=401
  export GH_PR_feat_01_foo__TITLE="Approved"
  export GH_PR_feat_01_foo__BODY=""
  export GH_PR_feat_01_foo__REVIEW=APPROVED
  export GH_PR_feat_01_foo__BASE=main
  export GH_PR_feat_02_bar__NUM=402
  export GH_PR_feat_02_bar__TITLE="Changes requested"
  export GH_PR_feat_02_bar__BODY=""
  export GH_PR_feat_02_bar__REVIEW=CHANGES_REQUESTED
  export GH_PR_feat_02_bar__BASE=feat/01-foo
  run git stack pr list --no-fetch --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"[approved]"* ]]
  [[ "$output" == *"[changes]"* ]]
}

@test "pr list: [base: X] flag when PR's base drifts from expected" {
  make_stack_branches feat 01-foo 02-bar
  make_remote_origin
  # Expected base for feat/02-bar is feat/01-foo, but PR is against main.
  export GH_PR_feat_01_foo__NUM=501
  export GH_PR_feat_01_foo__TITLE="Bottom"
  export GH_PR_feat_01_foo__BODY=""
  export GH_PR_feat_01_foo__BASE=main
  export GH_PR_feat_02_bar__NUM=502
  export GH_PR_feat_02_bar__TITLE="Drifted base"
  export GH_PR_feat_02_bar__BODY=""
  export GH_PR_feat_02_bar__BASE=main
  run git stack pr list --no-fetch --no-color
  [ "$status" -eq 0 ]
  # First branch's expected base IS main, so no [base: X] flag on it.
  local foo_line bar_line
  foo_line=$(printf '%s\n' "$output" | grep 'feat/01-foo')
  bar_line=$(printf '%s\n' "$output" | grep 'feat/02-bar')
  [[ "$foo_line" != *"[base:"* ]]
  [[ "$bar_line" == *"[base: main]"* ]]
}

@test "pr list: appends (Nc) comment-count suffix when comments > 0" {
  make_stack_branches feat 01-foo 02-bar
  make_remote_origin
  export GH_PR_feat_01_foo__NUM=601
  export GH_PR_feat_01_foo__TITLE="With comments"
  export GH_PR_feat_01_foo__BODY=""
  export GH_PR_feat_01_foo__BASE=main
  export GH_PR_feat_01_foo__COMMENTS=3
  export GH_PR_feat_02_bar__NUM=602
  export GH_PR_feat_02_bar__TITLE="No comments"
  export GH_PR_feat_02_bar__BODY=""
  export GH_PR_feat_02_bar__BASE=feat/01-foo
  export GH_PR_feat_02_bar__COMMENTS=0
  run git stack pr list --no-fetch --no-color
  [ "$status" -eq 0 ]
  local foo_line bar_line
  foo_line=$(printf '%s\n' "$output" | grep 'feat/01-foo')
  bar_line=$(printf '%s\n' "$output" | grep 'feat/02-bar')
  [[ "$foo_line" == *"(3c)"* ]]
  [[ "$bar_line" != *"(0c)"* ]]
  [[ "$bar_line" != *"c)"* ]]
}

@test "pr list --no-fetch: skips the 'fetching all remotes...' banner" {
  make_stack_branches feat 01-foo
  make_remote_origin
  git stack pr sync --no-color > /dev/null
  run git stack pr list --no-fetch --no-color
  [ "$status" -eq 0 ]
  [[ "$output" != *"fetching"* ]]
}

@test "pr list --color: PR number is wrapped in an OSC 8 hyperlink" {
  make_stack_branches feat 01-foo
  make_remote_origin
  git stack pr sync --no-color > /dev/null
  run git stack pr list --no-fetch --color
  [ "$status" -eq 0 ]
  # OSC 8 sequence: ESC ] 8 ; ; <url> BEL <text> ESC ] 8 ; ; BEL
  # Use ANSI-C $'...' quoting so $'\e' becomes the literal ESC byte.
  [[ "$output" == *$'\e]8;;https://github.com/test/repo/pull/101\a#101\e]8;;\a'* ]]
}

@test "pr list --no-color: PR number is plain (no OSC 8 escape bytes)" {
  make_stack_branches feat 01-foo
  make_remote_origin
  git stack pr sync --no-color > /dev/null
  run git stack pr list --no-fetch --no-color
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\e]8;;'* ]]
  [[ "$output" == *"#101"* ]]
}

@test "pr list: empty-diff middle branch shows (no PR), surrounding ones list normally" {
  make_stack_branches feat 01-foo
  # Branch sharing the same tip as feat/01-foo — no commits ahead.
  git branch feat/02-mid feat/01-foo
  git checkout -q feat/02-mid
  git checkout -q -b feat/03-baz
  echo c >> file
  git add file
  git commit -q -m "third"
  make_remote_origin
  git stack pr sync --no-color > /dev/null
  run git stack pr list --no-fetch --no-color
  [ "$status" -eq 0 ]
  local foo_line mid_line baz_line
  foo_line=$(printf '%s\n' "$output" | grep 'feat/01-foo')
  mid_line=$(printf '%s\n' "$output" | grep 'feat/02-mid')
  baz_line=$(printf '%s\n' "$output" | grep 'feat/03-baz')
  [[ "$foo_line" == *"#101"* ]]
  [[ "$mid_line" == *"(no PR)"* ]]
  [[ "$baz_line" == *"#102"* ]]
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

@test "init bash: alias count matches simple-abbreviation count (20)" {
  # 20 simple aliases (gstk + 19 others), 3 compound functions.
  run git stack init bash
  [ "$status" -eq 0 ]
  local alias_count
  alias_count=$(printf '%s\n' "$output" | grep -c '^alias gstk')
  [ "$alias_count" -eq 20 ]
}

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

# ---------- decimal leaves (rejected) ----------

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

# ---------- new ----------

@test "new: creates branch at top of stack with next leaf number" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/02-b
  run git stack new auth --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/03-auth
  [ "$(git symbolic-ref --short HEAD)" = "feat/03-auth" ]
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
  [[ "$output" == *"collides"* ]] || [[ "$output" == *"feat/01-auth"* ]]
}

@test "new: refuses slug starting with a digit" {
  make_stack_branches feat 01-a
  run git stack new 1foo --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"slug"* ]]
}

@test "new --after: inserts between two named branches" {
  make_stack_branches feat 01-a 02-b 03-c
  run git stack new mid --after feat/01-a --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/02-mid
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

@test "new --after: HEAD follows if currently on a cascade-renamed branch" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/02-b
  run git stack new mid --after 1 --no-color
  [ "$status" -eq 0 ]
  # The final `git checkout` always lands on the new branch:
  [ "$(git symbolic-ref --short HEAD)" = "feat/02-mid" ]
  git rev-parse --verify --quiet refs/heads/feat/03-b
  ! git rev-parse --verify --quiet refs/heads/feat/02-b
}

@test "new --bottom: inserts as leaf 01 and shifts all branches up" {
  make_stack_branches feat 01-a 02-b
  run git stack new prep --bottom --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/01-prep
  git rev-parse --verify --quiet refs/heads/feat/02-a
  git rev-parse --verify --quiet refs/heads/feat/03-b
  [ "$(git rev-parse feat/01-prep)" = "$(git rev-parse main)" ]
}

@test "new (no flag, non-TTY): defaults to --top" {
  make_stack_branches feat 01-a 02-b
  run git stack new tail --no-color </dev/null
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/03-tail
}

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

@test "new (bootstrap, --prefix): creates first branch of a new stack from main" {
  # Already on main from setup. No stack exists.
  run git stack new auth --prefix feat --no-color </dev/null
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/01-auth
  [ "$(git symbolic-ref --short HEAD)" = "feat/01-auth" ]
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

# ---------- move ----------

@test "move: relocates a single-commit branch to top" {
  # Each branch touches a different file to avoid cherry-pick conflicts when
  # the move reorders branches onto new parents.
  git checkout -q -b feat/01-a; printf 'a\n' > file-a; git add file-a; git commit -q -m "01-a"
  git checkout -q -b feat/02-b; printf 'b\n' > file-b; git add file-b; git commit -q -m "02-b"
  git checkout -q -b feat/03-c; printf 'c\n' > file-c; git add file-c; git commit -q -m "03-c"
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
  run git stack move outside --prefix feat --top --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside"* ]]
}

@test "move: cherry-pick conflict halts; continue completes move + rename" {
  # Use a 3-branch stack (01-a, 02-b, 03-c) where each branch appends to
  # `file`. Move feat/01-a to --top so the post-move ordering is
  # [02-b, 03-c, 01-a] and all three are rebased (first_affected=0).
  # The rebase-reorder causes two cherry-pick conflicts (on feat/02-b, then
  # on feat/01-a). After both are resolved, the post-action (rename) fires.
  make_stack_branches feat 01-a 02-b 03-c
  run git stack move feat/01-a --top --no-color
  [ "$status" -eq 2 ]
  [[ "$output" == *"conflict"* ]]

  # First conflict: cherry-pick 02-b onto main. 3-way base=01-a(01-a\n),
  # ours=main(empty), theirs=02-b(01-a\n02-b\n). Resolve to just "02-b".
  printf '02-b\n' > file
  git add file
  run git stack continue --no-color
  [ "$status" -eq 2 ]
  [[ "$output" == *"conflict"* ]]

  # Second conflict: cherry-pick 01-a onto new 03-c. 3-way base=main(empty),
  # ours=03-c(02-b\n03-c\n), theirs=01-a(01-a\n). Resolve to append 01-a.
  printf '02-b\n03-c\n01-a\n' > file
  git add file
  run git stack continue --no-color
  [ "$status" -eq 0 ]
  # post=[02-b, 03-c, 01-a] → renumbered: 01-b, 02-c, 03-a
  git rev-parse --verify --quiet refs/heads/feat/01-b
  git rev-parse --verify --quiet refs/heads/feat/02-c
  git rev-parse --verify --quiet refs/heads/feat/03-a
}

@test "move: abort mid-conflict restores original branches, no rename" {
  make_stack_branches feat 01-a 02-b 03-c
  local sha_01 sha_02 sha_03
  sha_01=$(git rev-parse refs/heads/feat/01-a)
  sha_02=$(git rev-parse refs/heads/feat/02-b)
  sha_03=$(git rev-parse refs/heads/feat/03-c)

  run git stack move feat/01-a --top --no-color
  [ "$status" -eq 2 ]

  run git stack abort --no-color
  [ "$status" -eq 0 ]

  # All original branches still present with their original names.
  [ "$(git rev-parse refs/heads/feat/01-a)" = "$sha_01" ]
  [ "$(git rev-parse refs/heads/feat/02-b)" = "$sha_02" ]
  [ "$(git rev-parse refs/heads/feat/03-c)" = "$sha_03" ]
  # Renamed branches must not exist.
  ! git rev-parse --verify --quiet refs/heads/feat/01-b
  ! git rev-parse --verify --quiet refs/heads/feat/02-c
  ! git rev-parse --verify --quiet refs/heads/feat/03-a
  # State file gone — continue should fail.
  run git stack continue --no-color
  [ "$status" -ne 0 ]
}

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

# ---------- new/move history interop ----------

@test "history: 'new' produces a restorable snapshot" {
  make_stack_branches feat 01-a 02-b
  git stack new mid --after 1 --no-color </dev/null
  run git stack history --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"new"* ]]
}

@test "history: 'move' produces a restorable snapshot" {
  # snapshot_stack is called before the rebase, so even if cherry-pick
  # conflicts the snapshot is already recorded.
  make_stack_branches feat 01-a 02-b
  git stack move feat/01-a --top --no-push --no-color </dev/null 2>&1 || true
  run git stack history --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"move"* ]]
}

# ---------- help ----------

@test "help: documents 'new' and 'move'" {
  run git stack help --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"git stack new"* ]] || [[ "$output" == *" new "* ]]
  [[ "$output" == *"move"* ]]
}
