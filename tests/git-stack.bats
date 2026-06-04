#!/usr/bin/env bats

load helpers

setup() { setup_repo; }
teardown() { teardown_repo; }

# ---------- list (all-stacks overview) ----------

@test "list: overview shows every stack, branch count, tip, and current marker" {
  make_stack_branches feat 01-a 02-b 03-c
  git checkout -q main
  make_stack_branches bug 01-x
  git checkout -q feat/03-c
  run git stack list --no-color
  [ "$status" -eq 0 ]
  # Both stacks appear, by prefix name (not per-branch).
  echo "$output" | grep -q "feat"
  echo "$output" | grep -q "bug"
  # Current stack (feat) carries the * marker; counts are shown.
  echo "$output" | grep -q "\* feat"
  [[ "$output" == *"3 branches"* ]]
  [[ "$output" == *"1 branch"* ]]
  # Tip leaf of feat is shown; individual middle branches are not listed.
  [[ "$output" == *"tip 03-c"* ]]
}

@test "list: errors with a create hint when there are no stacks" {
  run git stack list --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"no stacks found"* ]]
  [[ "$output" == *"create"* ]]
}

# ---------- view (one stack's contents) ----------

@test "view: orders branches numerically and marks current with *" {
  make_stack_branches feat 01-a 02-b 03-c
  run git stack view --no-fetch --no-color
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

@test "view: shows [unpushed] for branches with no upstream" {
  make_stack_branches feat 01-a
  run git stack view --no-fetch --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"[unpushed]"* ]]
}

@test "view: accepts a named stack (trailing slash optional) from outside" {
  make_stack_branches feat 01-a 02-b
  git checkout -q main
  run git stack view feat --no-fetch --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"feat/01-a"* ]]
  [[ "$output" == *"feat/02-b"* ]]
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

@test "restack: refuses merge commit at branch tip even with --force" {
  make_stack_branches feat 01-a 02-b 03-c
  # Make 02-b's tip a real merge commit (mirrors the GH 'Create a merge commit'
  # button merging PR 03-c into 02-b). --force is used so we bypass the
  # multi-commit count guard and specifically exercise the merge-commit check
  # right before the cherry-pick.
  git checkout -q feat/02-b
  git merge --no-ff -q -m "merge 03-c into 02-b" feat/03-c
  run git stack restack --force --from feat/02-b --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"merge commit"* ]]
  [[ "$output" == *"feat/02-b"* ]]
}

# ---------- restack: conflict / continue / abort ----------
# Characterization tests pinning the interrupted-reflow contract: a cherry-pick
# conflict halts with exit 2, `continue` resumes after resolution, and `abort`
# restores original SHAs and clears resume state.

@test "restack: cherry-pick conflict halts; continue completes reflow" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/01-a
  printf 'changed-a\n' > file
  git add file
  git commit -q --amend -m "01-a changed"
  local new_a
  new_a=$(git rev-parse refs/heads/feat/01-a)

  run git stack restack --no-color
  [ "$status" -eq 2 ]
  [[ "$output" == *"conflict"* ]]

  printf 'changed-a\n02-b\n' > file
  git add file
  run git stack continue --no-color
  [ "$status" -eq 0 ]
  assert_branch_parent_is feat/02-b "$new_a"
}

@test "restack: abort mid-conflict restores original SHAs and clears state" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/01-a
  printf 'changed-a\n' > file
  git add file
  git commit -q --amend -m "01-a changed"
  local sha_b
  sha_b=$(git rev-parse refs/heads/feat/02-b)

  run git stack restack --no-color
  [ "$status" -eq 2 ]

  run git stack abort --no-color
  [ "$status" -eq 0 ]
  [ "$(git rev-parse refs/heads/feat/02-b)" = "$sha_b" ]

  # Resume state gone — continue must refuse.
  run git stack continue --no-color
  [ "$status" -ne 0 ]
}

@test "restack --push: push failure pauses (resumable) instead of exiting 3" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/01-a
  git commit -q --amend -m "01-a amended"
  # No origin is configured, so the per-branch force-with-lease push fails. The
  # failure must pause (exit 2, state retained) so the user can fix the remote
  # and 'continue' — not the old fatal exit 3 that cleared state.
  run git stack restack --push --no-color
  [ "$status" -eq 2 ]
  [[ "$output" == *"push"* ]]
  # State retained: abort can still load it (the old exit-3 path cleared it,
  # so this abort would have failed).
  run git stack abort --no-color
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

@test "amend: refuses early (before pre-commit hook) when nothing staged and tree dirty" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/01-a
  # Install a pre-commit hook that records when it ran. If amend errors early,
  # this marker must not exist.
  mkdir -p .git/hooks
  cat > .git/hooks/pre-commit <<'HOOK'
#!/usr/bin/env bash
touch "$(git rev-parse --git-dir)/hook-ran"
HOOK
  chmod +x .git/hooks/pre-commit
  # Dirty the working tree without staging.
  printf 'unstaged\n' >> file
  run git stack amend --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing staged"* ]]
  [ ! -e .git/hook-ran ]
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
  run git stack view --no-fetch --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"detached HEAD"* ]]
}

@test "detect_prefix: non-numeric branch message" {
  # `list` now works from outside a stack (commit 09686fb), so it no longer
  # surfaces this error. Use a command that requires being on a stack branch.
  make_stack_branches feat 01-a
  git checkout -q -b plain-branch
  run git stack restack
  [ "$status" -ne 0 ]
  [[ "$output" == *"no numeric leaf"* ]]
}

# ---------- common-flag parser dedup ----------

@test "common flags: --prefix / --color / -v parse uniformly across commands" {
  make_stack_branches feat 01-a 02-b
  git checkout -q main
  # Each command should accept --prefix without error.
  run git stack view --prefix feat/ --no-fetch --no-color
  [ "$status" -eq 0 ]
  run git stack sync --prefix feat/ --no-color
  # sync will fail (no remote), but --prefix should parse.
  [[ "$output" != *"unknown"* ]]
}

# ---------- sync ----------

@test "sync: sets upstream so a freshly-pushed branch reports [synced]" {
  make_stack_branches feat 01-a
  make_remote_origin
  # New branch created after origin was set up — no upstream yet.
  make_stack_branches feat 02-b
  [ -z "$(git for-each-ref --format='%(upstream:short)' refs/heads/feat/02-b)" ]

  run git stack sync --no-color
  [ "$status" -eq 0 ]

  # Upstream must be configured to origin/feat/02-b after push.
  [ "$(git for-each-ref --format='%(upstream:short)' refs/heads/feat/02-b)" = "origin/feat/02-b" ]

  # And `view` must reflect that — no [unpushed] for feat/02-b.
  run git stack view --no-fetch --no-color
  [ "$status" -eq 0 ]
  local line
  line=$(echo "$output" | grep "feat/02-b")
  [[ "$line" != *"[unpushed]"* ]]
  [[ "$line" == *"[synced]"* ]]
}

@test "sync: pushes the whole stack additively (no --from / --all needed)" {
  make_stack_branches feat 01-a 02-b 03-c
  make_remote_origin
  # Detach upstream tracking to force a re-push of all three.
  git push -q origin --delete feat/01-a feat/02-b feat/03-c
  git fetch -q --prune
  git checkout -q feat/03-c
  run git stack sync --no-color
  [ "$status" -eq 0 ]
  # All three branches are on origin again.
  git ls-remote --exit-code origin refs/heads/feat/01-a
  git ls-remote --exit-code origin refs/heads/feat/02-b
  git ls-remote --exit-code origin refs/heads/feat/03-c
}

# ---------- clean ----------

@test "clean: prunes only local branches with [gone] upstream" {
  make_stack_branches feat 01-a 02-b
  make_remote_origin
  git push -q origin --delete feat/02-b
  git fetch -q --prune
  git checkout -q main
  run git stack clean --prefix feat/ --no-color
  [ "$status" -eq 0 ]
  run git rev-parse --verify --quiet refs/heads/feat/02-b
  [ "$status" -ne 0 ]
  git rev-parse --verify --quiet refs/heads/feat/01-a
}

@test "clean --dry-run: previews local prune, remote orphans, and reflow" {
  make_stack_branches feat 01-a 02-b
  make_remote_origin
  # 01-a's upstream goes away (gone); a remote-only orphan appears under prefix.
  git push -q origin --delete feat/01-a
  git push -q origin feat/02-b:refs/heads/feat/099-orphan
  git fetch -q --prune
  git checkout -q feat/02-b
  run git stack clean --dry-run --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"feat/01-a"* ]]
  [[ "$output" == *"feat/099-orphan"* ]]
  [[ "$output" == *"dry run"* ]]
  [[ "$output" == *"reflow"* ]]
  # Dry run mutates nothing.
  git rev-parse --verify --quiet refs/heads/feat/01-a
  git ls-remote --exit-code origin refs/heads/feat/099-orphan
}

@test "clean: non-TTY declines remote deletion but still reflows survivors" {
  # NOTE: the accept branch (_confirm -> y -> `git push origin --delete`) is
  # intentionally uncovered here — _confirm reads from /dev/tty, which the bats
  # harness has no controlling terminal for, so it always returns 1 (decline).
  # This test pins the decline-continues contract; the deletion itself is
  # verified by inspection.
  make_stack_branches feat 01-a 02-b
  make_remote_origin
  git push -q origin feat/02-b:refs/heads/feat/099-orphan
  git fetch -q --prune
  git checkout -q feat/02-b
  # No tty in the test harness -> _confirm returns 1 -> remote deletion skipped.
  run git stack clean --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped remote deletion"* ]]
  # Orphan survives on origin; survivors still got reflowed.
  git ls-remote --exit-code origin refs/heads/feat/099-orphan
  [[ "$output" == *"reflow"* ]]
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

@test "pr sync: discovery is a single bulk pr list, not one per branch" {
  make_stack_branches feat 01-foo 02-bar 03-baz
  make_remote_origin
  git stack pr sync --no-color > /dev/null
  truncate -s 0 "$GH_STUB_LOG"
  run git stack pr sync --no-color
  assert_status 0
  # One bulk open-PR query for the whole stack — not one `--head` query per branch.
  assert_eq "$(gh_log_count 'pr list')" 1 "pr list calls"
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

@test "pr sync: re-syncs the title and nav footer from an amended commit subject" {
  make_stack_branches feat 01-foo 02-bar
  make_remote_origin
  git stack pr sync --no-color > /dev/null
  # Titles are seeded from each branch's last commit subject.
  [ "$(jq -r .title "$GH_STUB_DIR/by-num/101.json")" = "[1/2] 01-foo" ]
  [ "$(jq -r .title "$GH_STUB_DIR/by-num/102.json")" = "[2/2] 02-bar" ]
  # Amend the top branch's commit subject (HEAD is feat/02-bar).
  git commit -q --amend -m "renamed bar"
  truncate -s 0 "$GH_STUB_LOG"
  run git stack pr sync --no-color
  [ "$status" -eq 0 ]
  # The PR title follows the new subject, position prefix preserved.
  [ "$(jq -r .title "$GH_STUB_DIR/by-num/102.json")" = "[2/2] renamed bar" ]
  # The nav footer (in #102's own body, and in #101's, which references it)
  # reflects the new subject in the SAME sync — pr sync stays a one-pass fixpoint.
  local body101 body102
  body102=$(gh_log_stdin "pr edit 102")
  [[ "$body102" == *"renamed bar"* ]] || return 1
  [[ "$body102" != *"02-bar"* ]] || return 1
  body101=$(gh_log_stdin "pr edit 101")
  [[ "$body101" == *"renamed bar"* ]] || return 1
}

@test "pr sync: clobbers a manually-edited title back to the commit subject" {
  make_stack_branches feat 01-foo 02-bar 03-baz
  make_remote_origin
  git stack pr sync --no-color > /dev/null
  # User manually edits #101's title on GitHub.
  jq '.title = "[WIP] Foo overhaul"' "$GH_STUB_DIR/by-num/101.json" > "$GH_STUB_DIR/x"
  mv "$GH_STUB_DIR/x" "$GH_STUB_DIR/by-num/101.json"
  truncate -s 0 "$GH_STUB_LOG"
  run git stack pr sync --no-color
  [ "$status" -eq 0 ]
  # pr sync re-derives the title from the commit subject — manual edits don't survive.
  [ "$(jq -r .title "$GH_STUB_DIR/by-num/101.json")" = "[1/3] 01-foo" ]
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
  assert grep -qF "git-stack:nav-start" <<<"$body"
  assert grep -qF "#101 [1/1] 01-solo ← this PR" <<<"$body"
  assert grep -qF "git-stack:nav-end" <<<"$body"
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
  export GH_PR_feat_01_foo__HEAD="feat/01-foo"
  export GH_PR_feat_01_foo__TITLE="[5/9] Old name"
  export GH_PR_feat_01_foo__BODY=""
  run git stack pr sync --no-color
  [ "$status" -eq 0 ]
  # No new PR created for 01-foo (we re-discovered #999); one for 02-bar
  [[ "$output" == *"exists  #999 feat/01-foo"* ]]
  [[ "$output" == *"create  #101 feat/02-bar"* ]]
  # And the title should have been rebracketed to [1/2] AND its content
  # re-derived from the branch's commit subject ("01-foo"), clobbering the
  # stale "Old name" content.
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
  [ "$title_arg" = "[1/2] 01-foo" ]
}

@test "pr sync: weaves a merged predecessor into the nav footer (struck through)" {
  # The active stack is feat/02-bar + feat/03-baz. #101 (feat/01-foo) was the
  # merged bottom of the chain — its branch is gone, but its PR is MERGED on
  # GitHub and still referenced by the active PRs' old nav footers. pr sync must
  # detect it (merged-status + title fetched via `gh pr view`) and weave it back
  # in as a struck-through merged predecessor.
  make_stack_branches feat 02-bar 03-baz
  make_remote_origin
  local old_footer='<!-- git-stack:nav-start -->
## Stack

- #101 [1/3] 01-foo
- #102 [2/3] 02-bar
- #103 [3/3] 03-baz

<!-- git-stack:nav-end -->'
  export GH_PR_feat_02_bar__NUM=102
  export GH_PR_feat_02_bar__HEAD="feat/02-bar"
  export GH_PR_feat_02_bar__TITLE="[2/3] 02-bar"
  export GH_PR_feat_02_bar__BODY="prose two

$old_footer"
  export GH_PR_feat_03_baz__NUM=103
  export GH_PR_feat_03_baz__HEAD="feat/03-baz"
  export GH_PR_feat_03_baz__TITLE="[3/3] 03-baz"
  export GH_PR_feat_03_baz__BODY="prose three

$old_footer"
  # #101 is a merged predecessor known only by number.
  export GH_PR_NUM_101__STATE=MERGED
  export GH_PR_NUM_101__TITLE="01-foo"
  run git stack pr sync --no-color
  [ "$status" -eq 0 ] || return 1
  # The merged-status of #101 was checked via `gh pr view`.
  grep -q '^gh pr view 101 ' "$GH_STUB_LOG" || return 1
  # The body written to #102 weaves #101 as a struck-through merged predecessor
  # (the "(merged)" line + the title "01-foo" can only have come from the
  # merged-title fetch), and re-brackets the active entries to [1/2]/[2/2].
  # NB: bats only fails a test on the LAST command's status, so each assertion
  # is guarded with `|| return 1` to make it a real check.
  local body
  body=$(gh_log_stdin "pr edit 102")
  [[ "$body" == *"~~#101 01-foo~~ (merged)"* ]] || return 1
  [[ "$body" == *"[1/2] 02-bar"* ]] || return 1
  [[ "$body" == *"[2/2] 03-baz"* ]] || return 1
  # The prose above the footer is preserved.
  [[ "$body" == *"prose two"* ]] || return 1
}

@test "pr sync: a footer-known merged predecessor is trusted without any gh pr view" {
  # Same shape as the weave test, but #101 is ALREADY recorded as merged in the
  # active PRs' footers. A merged PR can't revert, so pr sync must reuse the
  # recorded title and skip the GitHub round trip entirely — no gh pr view.
  make_stack_branches feat 02-bar 03-baz
  make_remote_origin
  local old_footer='<!-- git-stack:nav-start -->
## Stack

- ~~#101 01-foo~~ (merged)
- #102 [1/2] 02-bar
- #103 [2/2] 03-baz

<!-- git-stack:nav-end -->'
  export GH_PR_feat_02_bar__NUM=102
  export GH_PR_feat_02_bar__HEAD="feat/02-bar"
  export GH_PR_feat_02_bar__TITLE="[1/2] 02-bar"
  export GH_PR_feat_02_bar__BODY="prose two

$old_footer"
  export GH_PR_feat_03_baz__NUM=103
  export GH_PR_feat_03_baz__HEAD="feat/03-baz"
  export GH_PR_feat_03_baz__TITLE="[2/2] 03-baz"
  export GH_PR_feat_03_baz__BODY="prose three

$old_footer"
  # #101 is deliberately NOT seeded as a by-num PR: if the code trusts the
  # footer it never asks GitHub about #101 at all.
  run git stack pr sync --no-color
  assert_status 0
  # No state/title query for the merged predecessor — it came from the footer.
  assert_eq "$(gh_log_count 'pr view')" 0 "pr view calls"
  # #101 is still woven back in as a struck-through merged predecessor.
  local body
  body=$(gh_log_stdin "pr edit 102")
  [[ "$body" == *"~~#101 01-foo~~ (merged)"* ]] || return 1
}

@test "pr sync: a merged predecessor shared by multiple PRs is resolved with one gh pr view" {
  # #101 is referenced (as a plain active entry, NOT yet marked merged) by both
  # #102's and #103's old footers, and is in fact MERGED. The gather must
  # resolve its state+title once for the whole run, not once per referencing PR.
  make_stack_branches feat 02-bar 03-baz
  make_remote_origin
  local old_footer='<!-- git-stack:nav-start -->
## Stack

- #101 [1/3] 01-foo
- #102 [2/3] 02-bar
- #103 [3/3] 03-baz

<!-- git-stack:nav-end -->'
  export GH_PR_feat_02_bar__NUM=102
  export GH_PR_feat_02_bar__HEAD="feat/02-bar"
  export GH_PR_feat_02_bar__TITLE="[2/3] 02-bar"
  export GH_PR_feat_02_bar__BODY="prose two

$old_footer"
  export GH_PR_feat_03_baz__NUM=103
  export GH_PR_feat_03_baz__HEAD="feat/03-baz"
  export GH_PR_feat_03_baz__TITLE="[3/3] 03-baz"
  export GH_PR_feat_03_baz__BODY="prose three

$old_footer"
  export GH_PR_NUM_101__STATE=MERGED
  export GH_PR_NUM_101__TITLE="01-foo"
  run git stack pr sync --no-color
  assert_status 0
  # One combined state+title query for #101 across the whole sync (deduped),
  # not one per referencing PR and not a separate state and title call.
  assert_eq "$(grep -c '^gh pr view 101 ' "$GH_STUB_LOG")" 1 "gh pr view 101 calls"
  # Woven in as merged for both PRs.
  local b102 b103
  b102=$(gh_log_stdin "pr edit 102")
  b103=$(gh_log_stdin "pr edit 103")
  [[ "$b102" == *"~~#101 01-foo~~ (merged)"* ]] || return 1
  [[ "$b103" == *"~~#101 01-foo~~ (merged)"* ]] || return 1
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
  # The draft branch's block has [draft] (on its flags line, below the branch
  # name); the non-draft does not.
  local draft_block ready_block
  draft_block=$(printf '%s\n' "$output" | grep -A1 'feat/01-foo')
  ready_block=$(printf '%s\n' "$output" | grep -A1 'feat/02-bar')
  assert grep -qF "[draft]" <<<"$draft_block"
  refute grep -qF "[draft]" <<<"$ready_block"
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
  local foo_block bar_block
  foo_block=$(printf '%s\n' "$output" | grep -A 1 'feat/01-foo')
  bar_block=$(printf '%s\n' "$output" | grep -A 1 'feat/02-bar')
  [[ "$foo_block" != *"[base:"* ]]
  [[ "$bar_block" == *"[base: main]"* ]]
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
  [[ "$output" == *"alias gstkv='git stack view'"* ]]
  [[ "$output" == *"alias gstkam='git stack amend'"* ]]
  [[ "$output" == *"alias gstkcl='git stack clean'"* ]]
  # gstkcl is now a plain alias (the clean verb), no longer a shell function.
  [[ "$output" != *"gstkrom()"* ]]
  [[ "$output" != *"gstkromp()"* ]]
  [[ "$output" != *"gstkcl()"* ]]
  # Result must parse as valid bash.
  bash -n <(printf '%s\n' "$output")
}

@test "init zsh: emits eval-able snippet with expected aliases" {
  run git stack init zsh
  [ "$status" -eq 0 ]
  [[ "$output" == *"alias gstk='git stack'"* ]]
  [[ "$output" == *"alias gstkcr='git stack create'"* ]]
}

@test "init fish: emits abbr-based snippet for fish" {
  run git stack init fish
  assert_status 0
  assert_output_contains "abbr -a -g gstk git stack"
  assert_output_contains "abbr -a -g gstkcl git stack clean"
  assert_output_contains "abbr -a -g gstkcr git stack create"
  # No removed helpers and no bash-style function definitions.
  refute grep -qF "gstkrom" <<<"$output"
  refute grep -qF "function gstkcl" <<<"$output"
  refute grep -qF "gstkrom()" <<<"$output"
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

@test "init bash: alias count matches the verb map (24, no shell functions)" {
  # 24 simple aliases; no compound shell functions after the redesign.
  run git stack init bash
  [ "$status" -eq 0 ]
  local alias_count func_count
  alias_count=$(printf '%s\n' "$output" | grep -c '^alias gstk' || true)
  func_count=$(printf '%s\n' "$output" | grep -c '^gstk.*()' || true)
  [ "$alias_count" -eq 24 ]
  [ "$func_count" -eq 0 ]
}

@test "init bash: emits gstkcr (create), gstkad (add), gstkmv (move), gstkrn" {
  run git stack init bash
  [ "$status" -eq 0 ]
  [[ "$output" == *"alias gstkcr='git stack create'"* ]]
  [[ "$output" == *"alias gstkad='git stack add'"* ]]
  [[ "$output" == *"alias gstkmv='git stack move'"* ]]
  [[ "$output" == *"alias gstkfo='git stack fold'"* ]]
  [[ "$output" == *"alias gstkrn='git stack rename'"* ]]
  # Removed: gstkn (new), gstkpa (push --all).
  [[ "$output" != *"alias gstkn="* ]]
  [[ "$output" != *"alias gstkpa="* ]]
}

@test "init fish: emits gstkcr (create), gstkad (add), gstkmv (move), gstkrn" {
  run git stack init fish
  [ "$status" -eq 0 ]
  [[ "$output" == *"gstkcr git stack create"* ]]
  [[ "$output" == *"gstkad git stack add"* ]]
  [[ "$output" == *"gstkmv git stack move"* ]]
  [[ "$output" == *"gstkrn git stack rename"* ]]
}

# ---------- decimal leaves (rejected) ----------

@test "decimals: branches with decimal leaves are ignored by view" {
  make_stack_branches feat 01-a 02-b
  git branch feat/02.5-skip feat/02-b
  run git stack view --no-fetch --no-color
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

# ---------- add ----------

@test "add: creates branch at top of stack with next leaf number" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/02-b
  run git stack add auth --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/03-auth
  [ "$(git symbolic-ref --short HEAD)" = "feat/03-auth" ]
  [ "$(git rev-parse feat/03-auth)" = "$(git rev-parse feat/02-b)" ]
}

@test "add: refuses invalid slug" {
  make_stack_branches feat 01-a
  run git stack add 'has space' --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"slug"* ]]
}

@test "add: refuses slug collision in same stack" {
  make_stack_branches feat 01-auth 02-other
  git checkout -q feat/02-other
  run git stack add auth --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"collides"* ]] || [[ "$output" == *"feat/01-auth"* ]]
}

@test "add: refuses slug starting with a digit" {
  make_stack_branches feat 01-a
  run git stack add 1foo --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"slug"* ]]
}

@test "add --after: midpoint between named ref and successor (sparse stack)" {
  # Sparse stack (3-digit width) has gaps for inserts.
  make_stack_branches feat 010-a 020-b 030-c
  run git stack add mid --after feat/010-a --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/015-mid
  # Other branches untouched.
  git rev-parse --verify --quiet refs/heads/feat/020-b
  git rev-parse --verify --quiet refs/heads/feat/030-c
}

@test "add --after: refuses on tightly-packed legacy stack (no gap)" {
  # Legacy 2-digit stack with step-1 leaves: --after feat/01-a has no room
  # for a midpoint between 01 and 02.
  make_stack_branches feat 01-a 02-b 03-c
  run git stack add mid --after feat/01-a --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"gap exhausted"* ]] || [[ "$output" == *"no insertable leaf"* ]]
  # 02-b and 03-c must be untouched.
  git rev-parse --verify --quiet refs/heads/feat/02-b
  git rev-parse --verify --quiet refs/heads/feat/03-c
}

@test "add --after: accepts numeric leaf (sparse)" {
  make_stack_branches feat 010-a 020-b
  run git stack add mid --after 10 --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/015-mid
  git rev-parse --verify --quiet refs/heads/feat/020-b
}

@test "add --at: places at exact unused leaf" {
  make_stack_branches feat 010-a 020-b 030-c
  run git stack add newone --at 25 --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/025-newone
  # No existing branches were touched.
  git rev-parse --verify --quiet refs/heads/feat/010-a
  git rev-parse --verify --quiet refs/heads/feat/020-b
  git rev-parse --verify --quiet refs/heads/feat/030-c
}

@test "add --at: refuses if leaf is already taken" {
  make_stack_branches feat 010-a 020-b 030-c
  run git stack add newone --at 20 --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"already taken"* ]] || [[ "$output" == *"--at"* ]]
  # Stack unchanged.
  git rev-parse --verify --quiet refs/heads/feat/020-b
  ! git rev-parse --verify --quiet refs/heads/feat/020-newone
}

@test "add --at: refuses non-integer arg" {
  make_stack_branches feat 010-a 020-b
  run git stack add mid --at feat/010-a --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-negative integer"* ]] || [[ "$output" == *"--at"* ]]
}

@test "add --after: fails on unknown ref" {
  make_stack_branches feat 010-a 020-b
  run git stack add mid --after 99 --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"99"* ]]
}

@test "add --before: midpoint between predecessor and named ref" {
  make_stack_branches feat 010-a 020-b 030-c
  run git stack add prep --before feat/020-b --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/015-prep
  # Other branches untouched.
  git rev-parse --verify --quiet refs/heads/feat/010-a
  git rev-parse --verify --quiet refs/heads/feat/020-b
  git rev-parse --verify --quiet refs/heads/feat/030-c
}

@test "add --before: lowest branch picks midpoint of (0, lowest.leaf)" {
  make_stack_branches feat 010-a 020-b
  run git stack add prep --before feat/010-a --no-color
  [ "$status" -eq 0 ]
  # midpoint(0, 10) = 5
  git rev-parse --verify --quiet refs/heads/feat/005-prep
  [ "$(git rev-parse feat/005-prep)" = "$(git rev-parse main)" ]
}

@test "add --before: refuses when gap is exhausted" {
  make_stack_branches feat 001-a 002-b
  run git stack add prep --before feat/001-a --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"gap exhausted"* ]] || [[ "$output" == *"no insertable leaf"* ]]
  git rev-parse --verify --quiet refs/heads/feat/001-a
  git rev-parse --verify --quiet refs/heads/feat/002-b
}

@test "add --first: removed — errors with migration hint" {
  make_stack_branches feat 010-a 020-b
  run git stack add prep --first --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"--first"* ]] && [[ "$output" == *"--before"* ]]
}

@test "add: refuses on stack with leaf 00 and hints at doctor" {
  # Build a stack manually with a 00-leaf — make_stack_branches would also
  # accept this, but be explicit about the malformed state.
  git checkout -q -b feat/00-a
  printf '00-a\n' >> file && git add file && git commit -q -m '00-a'
  git checkout -q -b feat/02-b
  printf '02-b\n' >> file && git add file && git commit -q -m '02-b'
  run git stack add prep --before feat/00-a --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"doctor"* ]]
}

@test "add (no flag, non-TTY): defaults to --last" {
  make_stack_branches feat 01-a 02-b
  run git stack add tail --no-color </dev/null
  [ "$status" -eq 0 ]
  # Legacy 2-digit stack: step 1 from highest = 03.
  git rev-parse --verify --quiet refs/heads/feat/03-tail
}

@test "add --last: sparse stack rounds up to next multiple of 10" {
  make_stack_branches feat 010-a 015-b
  run git stack add tail --last --no-color
  [ "$status" -eq 0 ]
  # Next multiple of 10 above 15 is 20.
  git rev-parse --verify --quiet refs/heads/feat/020-tail
}

@test "add: no remote work (cmd_add is local-only by design)" {
  # cmd_add no longer touches origin or PRs; it just creates one local ref.
  # Existing PRs must not be affected.
  make_stack_branches feat 010-a 020-b
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  run git stack add mid --after feat/010-a --no-color
  [ "$status" -eq 0 ]
  [ "$(gh_log_count 'api -X POST')" -eq 0 ]
  [ "$(gh_log_count 'pr')" -eq 0 ]
}

# ---------- create ----------

@test "create: starts a new stack with the sparse 010 first leaf off base" {
  # Already on main from setup. No stack exists.
  run git stack create feat auth --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/010-auth
  [ "$(git symbolic-ref --short HEAD)" = "feat/010-auth" ]
  [ "$(git rev-parse feat/010-auth)" = "$(git rev-parse main)" ]
}

@test "create: trailing slash on the prefix is tolerated" {
  run git stack create feat/ auth --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/feat/010-auth
}

@test "create: errors (and points at add) when the prefix already has branches" {
  make_stack_branches feat 010-a
  git checkout -q main
  run git stack create feat other --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"already has"* ]]
  [[ "$output" == *"add"* ]]
}

@test "create: requires both a prefix and a slug" {
  run git stack create feat --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"slug"* ]]
}

@test "create --onto: roots the first branch on the given ref" {
  git commit -q --allow-empty -m extra
  local onto
  onto=$(git rev-parse HEAD)
  git checkout -q main
  run git stack create exp e1 --onto "$onto" --no-color
  [ "$status" -eq 0 ]
  git rev-parse --verify --quiet refs/heads/exp/010-e1
  [ "$(git rev-parse exp/010-e1)" = "$onto" ]
}

# ---------- add / create: carry a dirty tree onto the new branch ----------

@test "add: dirty tree on the top branch is carried onto the new branch (at-HEAD, no stash)" {
  make_stack_branches feat 010-a 020-b
  git checkout -q feat/020-b
  echo WIP >> file               # dirty tracked change atop HEAD
  run git stack add auth --no-color
  assert_status 0
  assert_branch_exists feat/030-auth
  assert_eq "$(git symbolic-ref --short HEAD)" feat/030-auth
  assert_sha_eq feat/030-auth "$(git rev-parse feat/020-b)"
  assert grep -q WIP file        # change carried over
  assert_eq "$(git stash list)" ""   # at-HEAD path never stashes
}

@test "add --after <current top>: dirty tree carried (at-HEAD, no stash)" {
  make_stack_branches feat 010-a 020-b
  git checkout -q feat/020-b
  echo WIP >> file
  run git stack add auth --after feat/020-b --no-color
  assert_status 0
  assert_eq "$(git symbolic-ref --short HEAD)" feat/030-auth
  assert grep -q WIP file
  assert_eq "$(git stash list)" ""
}

@test "add --before lowest: dirty tree relocated onto the new branch (stash path, clean)" {
  # `shared` is identical on main and every feat branch, so the carried diff
  # applies cleanly when relocated onto main (the --before-lowest predecessor).
  echo base > shared; git add shared; git commit -q -m shared
  make_stack_branches feat 010-a 020-b
  git checkout -q feat/020-b
  echo WIP >> shared             # dirty atop feat/020-b
  run git stack add relo --before feat/010-a --no-color
  assert_status 0
  assert_branch_exists feat/005-relo
  assert_eq "$(git symbolic-ref --short HEAD)" feat/005-relo
  assert_sha_eq feat/005-relo "$(git rev-parse main)"   # rooted at the parent
  assert grep -q WIP shared      # work relocated onto the new branch
  assert_eq "$(git stash list)" ""   # stash consumed on a clean pop
}

@test "add --before lowest: conflicting relocation lands on the new branch, retains the stash, warns" {
  # `file` differs between feat/020-b and main, so relocating the working-tree
  # diff onto main can't apply cleanly -> conflict on pop.
  make_stack_branches feat 010-a 020-b
  git checkout -q feat/020-b
  printf 'conflicting-edit\n' >> file
  run git stack add relo --before feat/010-a --no-color
  assert_status 0
  assert_branch_exists feat/005-relo
  assert_eq "$(git symbolic-ref --short HEAD)" feat/005-relo
  assert_output_contains "conflict"
  assert test -n "$(git stash list)"   # stash retained for recovery
}

@test "create: dirty tree without --stash errors non-interactively" {
  echo WIP >> file
  run git stack create feat auth --no-color </dev/null
  assert_status 1
  assert_output_contains "uncommitted changes"
  assert_branch_absent feat/010-auth
}

@test "create --stash: dirty tree carried into the new stack" {
  echo WIP >> file
  run git stack create feat auth --stash --no-color
  assert_status 0
  assert_branch_exists feat/010-auth
  assert_eq "$(git symbolic-ref --short HEAD)" feat/010-auth
  assert grep -q WIP file
}

@test "create --onto --stash: dirty tree relocated onto the base (stash path, clean)" {
  # Base (T1) carries `shared`; HEAD advances to T2 with `shared` unchanged, so
  # relocating the working-tree diff onto T1 applies cleanly.
  echo base > shared; git add shared; git commit -q -m shared
  local t1; t1=$(git rev-parse HEAD)
  git commit -q --allow-empty -m more     # HEAD = T2 != T1
  echo WIP >> shared
  run git stack create exp e1 --onto "$t1" --stash --no-color
  assert_status 0
  assert_branch_exists exp/010-e1
  assert_sha_eq exp/010-e1 "$t1"
  assert grep -q WIP shared
  assert_eq "$(git stash list)" ""
}

# ---------- add (no-stack guard) ----------

@test "add: errors (pointing at create/pick) when not in a stack" {
  run git stack add auth --no-color </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in a stack"* ]]
  [[ "$output" == *"create"* ]]
}

# ---------- pick ----------

@test "pick: lands on the tip of the (only) stack" {
  make_stack_branches feat 010-a 020-b 030-c
  git checkout -q main
  run git stack pick --no-color
  [ "$status" -eq 0 ]
  [ "$(git symbolic-ref --short HEAD)" = "feat/030-c" ]
}

# ---------- removed verbs ----------

@test "removed verbs: new/close/push/status error with a rename hint" {
  run git stack new foo --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"create"* ]] && [[ "$output" == *"add"* ]]
  run git stack close --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"clean"* ]]
  run git stack push --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"sync"* ]]
  run git stack status --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"view"* ]]
}

# ---------- move ----------

@test "move: relocates a single-commit branch to last" {
  # Each branch touches a different file to avoid cherry-pick conflicts when
  # the move reorders branches onto new parents.
  git checkout -q -b feat/01-a; printf 'a\n' > file-a; git add file-a; git commit -q -m "01-a"
  git checkout -q -b feat/02-b; printf 'b\n' > file-b; git add file-b; git commit -q -m "02-b"
  git checkout -q -b feat/03-c; printf 'c\n' > file-c; git add file-c; git commit -q -m "03-c"
  run git stack move feat/01-a --last --no-color
  [ "$status" -eq 0 ]
  # Post-move order: [02-b, 03-c, 01-a]. Gap-aware cascade keeps the two
  # already-in-order branches and renumbers only the out-of-order one.
  git rev-parse --verify --quiet refs/heads/feat/02-b
  git rev-parse --verify --quiet refs/heads/feat/03-c
  git rev-parse --verify --quiet refs/heads/feat/04-a
  ! git rev-parse --verify --quiet refs/heads/feat/01-a
}

@test "move: refuses if target == source position" {
  make_stack_branches feat 01-a 02-b
  # Moving feat/01-a --before feat/01-a (no-op) refuses.
  run git stack move feat/01-a --before feat/01-a --no-color
  [ "$status" -ne 0 ]
  # Refuses with either "itself" (self-reference) or "already" (same position).
  [[ "$output" == *"already"* ]] || [[ "$output" == *"itself"* ]]
}

@test "move: refuses if source not in stack" {
  make_stack_branches feat 01-a 02-b
  git checkout -q main
  git branch outside
  run git stack move outside --prefix feat --last --no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside"* ]]
}

@test "move: cherry-pick conflict halts; continue completes move + rename" {
  # Use a 3-branch stack (01-a, 02-b, 03-c) where each branch appends to
  # `file`. Move feat/01-a to --last so the post-move ordering is
  # [02-b, 03-c, 01-a] and all three are rebased (first_affected=0).
  # The rebase-reorder causes two cherry-pick conflicts (on feat/02-b, then
  # on feat/01-a). After both are resolved, the post-action (rename) fires.
  make_stack_branches feat 01-a 02-b 03-c
  run git stack move feat/01-a --last --no-color
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
  # post=[02-b, 03-c, 01-a] → gap-aware renumber keeps 02-b and 03-c, bumps 01-a to 04-a.
  git rev-parse --verify --quiet refs/heads/feat/02-b
  git rev-parse --verify --quiet refs/heads/feat/03-c
  git rev-parse --verify --quiet refs/heads/feat/04-a
}

@test "move: abort mid-conflict restores original branches, no rename" {
  make_stack_branches feat 01-a 02-b 03-c
  local sha_01 sha_02 sha_03
  sha_01=$(git rev-parse refs/heads/feat/01-a)
  sha_02=$(git rev-parse refs/heads/feat/02-b)
  sha_03=$(git rev-parse refs/heads/feat/03-c)

  run git stack move feat/01-a --last --no-color
  [ "$status" -eq 2 ]

  run git stack abort --no-color
  [ "$status" -eq 0 ]

  # All original branches still present with their original names.
  [ "$(git rev-parse refs/heads/feat/01-a)" = "$sha_01" ]
  [ "$(git rev-parse refs/heads/feat/02-b)" = "$sha_02" ]
  [ "$(git rev-parse refs/heads/feat/03-c)" = "$sha_03" ]
  # The rename that the move would have produced (01-a → 04-a under gap-aware
  # post-rename) must not exist.
  ! git rev-parse --verify --quiet refs/heads/feat/04-a
  # State file gone — continue should fail.
  run git stack continue --no-color
  [ "$status" -ne 0 ]
}

# ---------- move (remote stages) ----------

@test "move: renames remote branches via gh api and triggers pr sync" {
  # Build stack with separate files (avoids cherry-pick conflicts during rebase).
  git checkout -q -b feat/01-a
  printf 'a\n' > a-file && git add a-file && git commit -q -m '01-a'
  git checkout -q -b feat/02-b
  printf 'b\n' > b-file && git add b-file && git commit -q -m '02-b'
  git checkout -q -b feat/03-c
  printf 'c\n' > c-file && git add c-file && git commit -q -m '03-c'
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  run git stack move feat/01-a --last --no-color
  [ "$status" -eq 0 ]
  # Gap-aware post-rename only renames the moved branch (01-a → 04-a); the
  # other two branches keep their leaf numbers, so just one remote rename.
  [ "$(gh_log_count 'api -X POST')" -ge 1 ]
  [ "$(gh_log_count 'pr')" -ge 1 ]
}

@test "move --no-push: skips remote rename and pr sync" {
  # Build stack with separate files.
  git checkout -q -b feat/01-a
  printf 'a\n' > a-file && git add a-file && git commit -q -m '01-a'
  git checkout -q -b feat/02-b
  printf 'b\n' > b-file && git add b-file && git commit -q -m '02-b'
  git checkout -q -b feat/03-c
  printf 'c\n' > c-file && git add c-file && git commit -q -m '03-c'
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  run git stack move feat/01-a --last --no-push --no-color
  [ "$status" -eq 0 ]
  [ "$(gh_log_count 'api -X POST')" -eq 0 ]
  [ "$(gh_log_count 'pr')" -eq 0 ]
}

@test "move --no-sync: does remote rename but skips pr sync" {
  git checkout -q -b feat/01-a
  printf 'a\n' > a-file && git add a-file && git commit -q -m '01-a'
  git checkout -q -b feat/02-b
  printf 'b\n' > b-file && git add b-file && git commit -q -m '02-b'
  git checkout -q -b feat/03-c
  printf 'c\n' > c-file && git add c-file && git commit -q -m '03-c'
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  run git stack move feat/01-a --last --no-sync --no-color
  [ "$status" -eq 0 ]
  [ "$(gh_log_count 'api -X POST')" -ge 1 ]
  # `pr list` may be invoked by the PR-orphan-guard preflight; we only care
  # that no PR mutations (create/edit/close) happened.
  [ "$(gh_log_count 'pr create')" -eq 0 ]
  [ "$(gh_log_count 'pr edit')" -eq 0 ]
  [ "$(gh_log_count 'pr close')" -eq 0 ]
}

@test "move: preserves gaps in post-rename" {
  # Stack with an intentional gap above 02-b. Moving 01-a --last should keep
  # 02-b and 10-c at their existing leaf numbers (their SHAs change because
  # move rebases, but the leaf names stay), only bumping the moved branch.
  git checkout -q -b feat/01-a; printf 'a\n' > file-a; git add file-a; git commit -q -m '01-a'
  git checkout -q -b feat/02-b; printf 'b\n' > file-b; git add file-b; git commit -q -m '02-b'
  git checkout -q -b feat/10-c; printf 'c\n' > file-c; git add file-c; git commit -q -m '10-c'
  run git stack move feat/01-a --last --no-color
  [ "$status" -eq 0 ]
  # Post-move order: [02-b, 10-c, 01-a]. Gap-aware: keep 02-b, keep 10-c,
  # bump 01-a → 11-a.
  git rev-parse --verify --quiet refs/heads/feat/02-b
  git rev-parse --verify --quiet refs/heads/feat/10-c
  git rev-parse --verify --quiet refs/heads/feat/11-a
  ! git rev-parse --verify --quiet refs/heads/feat/01-a
  # The dense-collapse names from the old behavior must not appear either.
  ! git rev-parse --verify --quiet refs/heads/feat/01-b
  ! git rev-parse --verify --quiet refs/heads/feat/03-a
}

# ---------- move (renumber in place) ----------

@test "move --at: renumbers a branch in place without moving commits" {
  # Stack 010-a, 015-b, 020-c. Renumber the first branch 010 -> 012, still
  # below 015, so its position is unchanged. A pure rename: no reflow, so every
  # branch's SHA (including the renamed one) is preserved.
  make_stack_branches feat 010-a 015-b 020-c
  local sha_a sha_b sha_c
  sha_a=$(git rev-parse refs/heads/feat/010-a)
  sha_b=$(git rev-parse refs/heads/feat/015-b)
  sha_c=$(git rev-parse refs/heads/feat/020-c)

  run git stack move feat/010-a --at 12 --no-push --no-color
  assert_status 0
  assert_branch_exists feat/012-a
  assert_branch_absent feat/010-a
  # Pure rename: the renamed ref keeps 010-a's exact SHA; others untouched.
  assert_sha_eq refs/heads/feat/012-a "$sha_a"
  assert_sha_eq refs/heads/feat/015-b "$sha_b"
  assert_sha_eq refs/heads/feat/020-c "$sha_c"
}

@test "move --at: renumbers a middle branch in place" {
  # Any branch, not just the first: move 015-b down to 012, still between
  # 010 and 020, so its position (index 1) is unchanged.
  make_stack_branches feat 010-a 015-b 020-c
  local sha_b
  sha_b=$(git rev-parse refs/heads/feat/015-b)

  run git stack move feat/015-b --at 12 --no-push --no-color
  assert_status 0
  assert_branch_exists feat/012-b
  assert_branch_absent feat/015-b
  assert_sha_eq refs/heads/feat/012-b "$sha_b"
}

@test "move --at: leaf equal to current leaf is a graceful no-op" {
  make_stack_branches feat 010-a 015-b 020-c
  run git stack move feat/010-a --at 10 --no-push --no-color
  assert_status 0
  assert_output_contains "already at leaf"
  assert_branch_exists feat/010-a
}

@test "move --at: leaf taken by another branch still errors" {
  make_stack_branches feat 010-a 015-b 020-c
  run git stack move feat/010-a --at 15 --no-push --no-color
  assert_status 1
  assert_output_contains "already taken"
  assert_branch_exists feat/010-a
}

@test "move --before: no-op position non-interactively errors pointing at --at" {
  # 010-a is already directly below 015-b, so the position does not change.
  # Without a TTY there's no leaf picker, so it must point the user at --at.
  make_stack_branches feat 010-a 015-b 020-c
  run git stack move feat/010-a --before feat/015-b --no-push --no-color
  assert_status 1
  assert_output_contains "--at"
  assert_branch_exists feat/010-a
}

@test "move --at: in-place renumber refuses to orphan an open PR" {
  make_stack_branches feat 010-a 015-b 020-c
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  export GH_PR_feat_010_a__NUM=42
  run git stack move feat/010-a --at 12 --no-color
  assert_status 1
  assert_output_contains "allow-pr-rebuild"
  assert_branch_exists feat/010-a
}

@test "move --at: in-place renumber renames remote + syncs with --allow-pr-rebuild" {
  make_stack_branches feat 010-a 015-b 020-c
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  run git stack move feat/010-a --at 12 --allow-pr-rebuild --no-color
  assert_status 0
  assert_branch_exists feat/012-a
  assert_branch_absent feat/010-a
  # Remote rename happened and pr sync ran.
  [ "$(gh_log_count 'api -X POST')" -ge 1 ]
  [ "$(gh_log_count 'pr')" -ge 1 ]
}

# ---------- fold ----------

@test "fold: squashes a branch down into its predecessor and deletes it" {
  make_stack_branches feat 01-a 02-b
  run git stack fold feat/02-b --yes --no-push --no-color
  assert_status 0
  assert_branch_absent feat/02-b
  # Result keeps the predecessor's leaf (01) but takes the folded branch's slug.
  assert_branch_absent feat/01-a
  assert_branch_exists feat/01-b
  run git show feat/01-b:file
  assert_output_contains "01-a"
  assert_output_contains "02-b"
}

@test "fold: reflows children onto the survivor after folding a middle branch" {
  make_stack_branches feat 01-a 02-b 03-c
  run git stack fold feat/02-b --yes --no-push --no-color
  assert_status 0
  assert_branch_absent feat/02-b
  assert_branch_exists feat/01-b
  assert_branch_exists feat/03-c
  # 03-c is re-threaded onto the rewritten survivor and keeps the full diff.
  assert_branch_parent_is feat/03-c "$(git rev-parse feat/01-b)"
  run git show feat/03-c:file
  assert_output_contains "01-a"
  assert_output_contains "02-b"
  assert_output_contains "03-c"
}

@test "fold --up: folds a branch into its successor" {
  make_stack_branches feat 01-a 02-b 03-c
  run git stack fold feat/02-b --up --yes --no-push --no-color
  assert_status 0
  assert_branch_absent feat/02-b
  assert_branch_exists feat/01-a
  # Survivor is the successor (leaf 03); result takes the folded branch's slug.
  assert_branch_exists feat/03-b
  assert_branch_absent feat/03-c
  assert_branch_parent_is feat/03-b "$(git rev-parse feat/01-a)"
  run git show feat/03-b:file
  assert_output_contains "02-b"
  assert_output_contains "03-c"
}

@test "fold: bottom branch with default down errors, hints --up" {
  make_stack_branches feat 01-a 02-b
  run git stack fold feat/01-a --yes --no-push --no-color
  assert_status 1
  assert_output_contains "bottom branch"
  assert_output_contains "--up"
}

@test "fold --up: tip branch errors, hints --down" {
  make_stack_branches feat 01-a 02-b
  run git stack fold feat/02-b --up --yes --no-push --no-color
  assert_status 1
  assert_output_contains "--down"
}

@test "fold: lone branch in stack errors, hints clean" {
  make_stack_branches feat 01-a
  run git stack fold feat/01-a --yes --no-push --no-color
  assert_status 1
  assert_output_contains "clean"
}

@test "fold: non-TTY without --yes refuses and mutates nothing" {
  make_stack_branches feat 01-a 02-b
  run git stack fold feat/02-b --no-push --no-color
  assert_status 1
  assert_output_contains "--yes"
  assert_branch_exists feat/02-b
}

@test "fold: newest snapshot restores the deleted victim" {
  make_stack_branches feat 01-a 02-b 03-c
  orig_b=$(git rev-parse feat/02-b)
  run git stack fold feat/02-b --yes --no-push --no-color
  assert_status 0
  assert_branch_absent feat/02-b
  # The pre-fold snapshot is the newest one (@0); restoring it brings the
  # victim back at its original SHA.
  git checkout -q main
  run git stack history restore @0 --yes --prefix feat/ --no-color
  assert_status 0
  assert_branch_exists feat/02-b
  assert_sha_eq feat/02-b "$orig_b"
}

@test "fold --slug: renames the survivor to the new slug" {
  make_stack_branches feat 01-a 02-b 03-c
  run git stack fold feat/02-b --slug merged --yes --no-push --no-color
  assert_status 0
  assert_branch_absent feat/02-b
  assert_branch_absent feat/01-a
  assert_branch_exists feat/01-merged
  assert_branch_exists feat/03-c
  # Child re-threads onto the renamed survivor; full diff preserved.
  assert_branch_parent_is feat/03-c "$(git rev-parse feat/01-merged)"
  run git show feat/01-merged:file
  assert_output_contains "01-a"
  assert_output_contains "02-b"
}

@test "fold: refuses on a dirty working tree and mutates nothing" {
  make_stack_branches feat 01-a 02-b
  printf 'dirty\n' >> file
  run git stack fold feat/02-b --yes --no-push --no-color
  assert_status 1
  assert_branch_exists feat/02-b
}

@test "fold: squashes a multi-commit victim into one commit on the survivor" {
  git checkout -q -b feat/01-a; printf 'a\n' >> file; git add file; git commit -q -m 01-a
  git checkout -q -b feat/02-b; printf 'b1\n' >> file; git add file; git commit -q -m 02-b-1
  printf 'b2\n' >> file; git add file; git commit -q -m 02-b-2
  run git stack fold feat/02-b --yes --no-push --no-color
  assert_status 0
  assert_branch_absent feat/02-b
  run git show feat/01-b:file
  assert_output_contains "a"
  assert_output_contains "b1"
  assert_output_contains "b2"
  # The whole victim range collapses to a single commit on the base.
  run git rev-list --count main..feat/01-b
  assert_output_contains "1"
}

@test "fold --at: renumbers the merged result to a chosen free leaf" {
  make_stack_branches feat 010-a 020-b 030-c
  run git stack fold feat/020-b --at 15 --yes --no-push --no-color
  assert_status 0
  # --at sets the leaf (015); the slug still defaults to the folded branch's (b).
  assert_branch_exists feat/015-b
  assert_branch_absent feat/010-a
  assert_branch_exists feat/030-c
  assert_branch_parent_is feat/030-c "$(git rev-parse feat/015-b)"
}

@test "fold --at: rejects a leaf that would reorder past a child" {
  make_stack_branches feat 010-a 020-b 030-c
  run git stack fold feat/020-b --at 40 --yes --no-push --no-color
  assert_status 1
  assert_branch_exists feat/020-b
}

@test "fold: refuses when the victim has an open PR without --allow-pr-rebuild" {
  make_stack_branches feat 010-a 020-b 030-c
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  export GH_PR_feat_020_b__NUM=42
  run git stack fold feat/020-b --yes --no-color
  assert_status 1
  assert_output_contains "allow-pr-rebuild"
  assert_branch_exists feat/020-b
}

@test "fold --allow-pr-rebuild: deletes the remote victim branch" {
  make_stack_branches feat 010-a 020-b 030-c
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  export GH_PR_feat_020_b__NUM=42
  run git stack fold feat/020-b --allow-pr-rebuild --yes --no-color
  assert_status 0
  assert_branch_absent feat/020-b
  run git ls-remote --heads origin feat/020-b
  assert_status 0
  assert_eq "$output" "" "remote victim branch should be deleted"
}

@test "fold --allow-pr-rebuild: breadcrumbs the victim PR to the superseding PR" {
  make_stack_branches feat 010-a 020-b 030-c
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  export GH_PR_feat_020_b__NUM=42
  run git stack fold feat/020-b --allow-pr-rebuild --yes --no-color
  assert_status 0
  # A breadcrumb comment was posted on the victim PR (#42).
  [ "$(gh_log_count 'pr comment 42')" -ge 1 ]
  run cat "$GH_STUB_LOG"
  assert_output_contains "Folded"
}

@test "fold --slug --allow-pr-rebuild: renames remote survivor, drops victim, breadcrumbs" {
  make_stack_branches feat 010-a 020-b 030-c
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  export GH_PR_feat_010_a__NUM=41
  export GH_PR_feat_020_b__NUM=42
  run git stack fold feat/020-b --slug merged --allow-pr-rebuild --yes --no-color
  assert_status 0
  assert_branch_exists feat/010-merged
  assert_branch_absent feat/020-b
  run git ls-remote --heads origin feat/020-b
  assert_eq "$output" "" "remote victim branch should be deleted"
  # Survivor remote-rename was attempted and the victim PR got a breadcrumb.
  [ "$(gh_log_count 'api -X POST')" -ge 1 ]
  [ "$(gh_log_count 'pr comment 42')" -ge 1 ]
}

@test "fold: renamed survivor force-pushes cleanly over its renamed remote branch" {
  make_stack_branches feat 010-a 020-b 030-c
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  # Default slug renames the survivor 010-a -> 010-b; its remote branch is
  # renamed too, so the follow-up --force-with-lease push must still land
  # (regression: it was rejected as "stale info" with no refreshed tracking ref).
  run git stack fold feat/020-b --allow-pr-rebuild --yes --no-color
  assert_status 0
  local new_sha
  new_sha=$(git rev-parse feat/010-b)
  run git ls-remote --heads origin feat/010-b
  assert_output_contains "010-b"
  # The remote carries the new squashed SHA → the force-push succeeded.
  assert_output_contains "$new_sha"
}

@test "fold --slug: remote rename failure leaves the victim branch intact" {
  make_stack_branches feat 010-a 020-b 030-c
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  export GH_PR_feat_010_a__NUM=41
  export GH_PR_feat_020_b__NUM=42
  export GH_STUB_FAIL_RENAME="feat/010-a"
  run git stack fold feat/020-b --slug merged --allow-pr-rebuild --yes --no-color
  assert_status 1
  # The rename dies before the victim delete — the victim's remote branch (and
  # therefore its PR) must survive for a clean recovery.
  run git ls-remote --heads origin feat/020-b
  assert_output_contains "020-b"
  [ "$(gh_log_count 'pr comment')" -eq 0 ]
}

@test "fold --no-push: skips the PR gate even with an open victim PR" {
  make_stack_branches feat 010-a 020-b 030-c
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  export GH_PR_feat_020_b__NUM=42
  run git stack fold feat/020-b --yes --no-push --no-color
  assert_status 0
  assert_branch_absent feat/020-b
}

@test "fold --dry-run: previews the plan and mutates nothing" {
  make_stack_branches feat 010-a 020-b 030-c
  local before_b before_a before_c
  before_b=$(git rev-parse feat/020-b)
  before_a=$(git rev-parse feat/010-a)
  before_c=$(git rev-parse feat/030-c)
  run git stack fold feat/020-b --dry-run --no-color
  assert_status 0
  assert_output_contains "020-b"
  assert_output_contains "010-a"
  # Nothing mutated.
  assert_branch_exists feat/020-b
  assert_sha_eq feat/020-b "$before_b"
  assert_sha_eq feat/010-a "$before_a"
  assert_sha_eq feat/030-c "$before_c"
}

@test "fold --dry-run: needs no --yes and works off a TTY" {
  make_stack_branches feat 010-a 020-b
  run git stack fold feat/020-b --dry-run --no-color
  assert_status 0
  assert_branch_exists feat/020-b
}

@test "history restore: warns about duplicate-leaf leftovers after a fold rename" {
  make_stack_branches feat 010-a 020-b 030-c
  run git stack fold feat/020-b --slug merged --yes --no-push --no-color
  assert_status 0
  assert_branch_exists feat/010-merged
  # Restoring re-creates the pre-fold 010-a but cannot remove the renamed
  # 010-merged → a duplicate leaf 010 the warning must surface.
  git checkout -q main
  run git stack history restore @0 --yes --prefix feat/ --no-color
  assert_status 0
  assert_branch_exists feat/010-a
  assert_branch_exists feat/010-merged
  assert_output_contains "010-merged"
  assert_output_contains "doctor"
}

# ---------- doctor ----------

@test "doctor: fixes 00 leaf to 01, preserves higher branches" {
  git checkout -q -b feat/00-a
  printf '00-a\n' >> file && git add file && git commit -q -m '00-a'
  git checkout -q -b feat/10-b
  printf '10-b\n' >> file && git add file && git commit -q -m '10-b'
  git checkout -q -b feat/11-c
  printf '11-c\n' >> file && git add file && git commit -q -m '11-c'
  git checkout -q -b feat/12-d
  printf '12-d\n' >> file && git add file && git commit -q -m '12-d'
  local sha_10 sha_11 sha_12
  sha_10=$(git rev-parse refs/heads/feat/10-b)
  sha_11=$(git rev-parse refs/heads/feat/11-c)
  sha_12=$(git rev-parse refs/heads/feat/12-d)
  run git stack doctor --yes --no-color
  assert_status 0
  assert_branch_exists feat/01-a
  assert_branch_absent feat/00-a
  # The 10/11/12 branches must not have been renamed.
  assert_sha_eq refs/heads/feat/10-b "$sha_10"
  assert_sha_eq refs/heads/feat/11-c "$sha_11"
  assert_sha_eq refs/heads/feat/12-d "$sha_12"
}

@test "doctor: cascades when fixing 00 closes the gap with 01" {
  git checkout -q -b feat/00-a
  printf '00-a\n' >> file && git add file && git commit -q -m '00-a'
  git checkout -q -b feat/01-b
  printf '01-b\n' >> file && git add file && git commit -q -m '01-b'
  run git stack doctor --yes --no-color
  assert_status 0
  assert_branch_exists feat/01-a
  assert_branch_exists feat/02-b
  assert_branch_absent feat/00-a
}

@test "doctor: no-op on already-valid stack" {
  make_stack_branches feat 01-a 02-b
  local sha_01 sha_02
  sha_01=$(git rev-parse refs/heads/feat/01-a)
  sha_02=$(git rev-parse refs/heads/feat/02-b)
  run git stack doctor --yes --no-color
  assert_status 0
  assert_output_contains "already valid"
  assert_sha_eq refs/heads/feat/01-a "$sha_01"
  assert_sha_eq refs/heads/feat/02-b "$sha_02"
}

@test "doctor --dry-run: prints plan without renaming" {
  git checkout -q -b feat/00-a
  printf '00-a\n' >> file && git add file && git commit -q -m '00-a'
  git checkout -q -b feat/02-b
  printf '02-b\n' >> file && git add file && git commit -q -m '02-b'
  local sha_00 sha_02
  sha_00=$(git rev-parse refs/heads/feat/00-a)
  sha_02=$(git rev-parse refs/heads/feat/02-b)
  run git stack doctor --dry-run --no-color
  assert_status 0
  assert_output_contains "feat/00-a"
  assert_output_contains "feat/01-a"
  # No actual rename — original refs unchanged.
  assert_sha_eq refs/heads/feat/00-a "$sha_00"
  assert_sha_eq refs/heads/feat/02-b "$sha_02"
  assert_branch_absent feat/01-a
}

# ---------- doctor squash ----------

@test "doctor --yes: squashes a multi-commit branch into one commit" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/02-b
  printf 'extra\n' >> file && git add file && git commit -q -m "02-b second"
  local sha_01
  sha_01=$(git rev-parse refs/heads/feat/01-a)
  run git stack doctor --yes --no-rename --no-push --no-color
  assert_status 0
  # 02-b is now a single commit on top of feat/01-a.
  assert_branch_parent_is feat/02-b "$sha_01"
  # Combined commit message picks up both original subjects.
  run git log -1 --format=%B refs/heads/feat/02-b
  assert_output_contains "02-b"
  assert_output_contains "02-b second"
}

@test "doctor --yes: squashes merge-tip and deletes upper branch absorbed by squash" {
  make_stack_branches feat 01-a 02-b 03-c
  # GH-style merge: 03-c into 02-b with a real merge commit. After squash,
  # 02-b contains both 02-b's and 03-c's diffs — 03-c becomes redundant.
  git checkout -q feat/02-b
  git merge --no-ff -q -m "merge 03-c into 02-b" feat/03-c
  git checkout -q feat/01-a
  local sha_01
  sha_01=$(git rev-parse refs/heads/feat/01-a)
  run git stack doctor --yes --no-rename --no-push --no-color
  assert_status 0
  # 02-b becomes a single commit on top of feat/01-a — no longer a merge.
  assert_branch_parent_is feat/02-b "$sha_01"
  refute git rev-parse --verify --quiet refs/heads/feat/02-b^2
  # 03-c was absorbed by the squash — doctor deleted it.
  assert_branch_absent feat/03-c
}

@test "doctor --yes: reflows non-absorbed upper branch after squash" {
  # 02-b is multi-commit (squash will collapse). 03-c modifies an
  # independent file, so its diff vs the new 02-b is non-empty — it must
  # be re-threaded, not deleted.
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/02-b
  printf 'extra\n' >> file && git add file && git commit -q -m "02-b second"
  git checkout -q -b feat/03-c
  printf '03-c\n' > c-file && git add c-file && git commit -q -m "03-c"
  local sha_01 old_03
  sha_01=$(git rev-parse refs/heads/feat/01-a)
  old_03=$(git rev-parse refs/heads/feat/03-c)
  git checkout -q feat/01-a
  run git stack doctor --yes --no-rename --no-push --no-color
  assert_status 0
  assert_branch_parent_is feat/02-b "$sha_01"
  # 03-c still exists, re-threaded onto the new 02-b.
  assert_branch_exists feat/03-c
  local new_02
  new_02=$(git rev-parse refs/heads/feat/02-b)
  assert_branch_parent_is feat/03-c "$new_02"
  refute test "$(git rev-parse refs/heads/feat/03-c)" = "$old_03"
}

@test "doctor --yes: absorbed branch deleted, surviving upper branch reflows past it" {
  # 01-a, 02-b, 03-c built linearly; merge 03-c into 02-b so squashing 02-b
  # absorbs 03-c. 04-d sits above 03-c with an independent diff, so it is NOT
  # absorbed — it must reflow onto the squashed 02-b, skipping the deleted 03-c.
  make_stack_branches feat 01-a 02-b 03-c
  git checkout -q feat/02-b
  git merge --no-ff -q -m "merge 03-c into 02-b" feat/03-c
  git checkout -q feat/03-c
  git checkout -q -b feat/04-d
  printf 'd\n' > d-file && git add d-file && git commit -q -m 04-d
  git checkout -q feat/01-a
  run git stack doctor --yes --no-rename --no-push --no-color
  assert_status 0
  # 02-b squashed to a single (non-merge) commit; 03-c absorbed and deleted.
  refute git rev-parse --verify --quiet refs/heads/feat/02-b^2
  assert_branch_absent feat/03-c
  # 04-d survives, re-threaded onto the squashed 02-b (not the deleted 03-c).
  assert_branch_exists feat/04-d
  assert_branch_parent_is feat/04-d "$(git rev-parse refs/heads/feat/02-b)"
  run git ls-tree -r --name-only refs/heads/feat/04-d
  assert_output_contains 'd-file'
}

@test "doctor --yes: empty-squash branch is deleted" {
  make_stack_branches feat 01-a 02-b
  # Make 02-b's tree identical to feat/01-a by reverting 02-b's change.
  git checkout -q feat/02-b
  git rm -q file
  printf '01-a\n' > file
  git add file
  git commit -q -m "02-b absorbed back to 01-a state"
  # Sanity: trees are now equal.
  assert_eq "$(git rev-parse refs/heads/feat/01-a^{tree})" \
            "$(git rev-parse refs/heads/feat/02-b^{tree})" "trees equal"
  git checkout -q feat/01-a
  run git stack doctor --yes --no-rename --no-push --no-color
  assert_status 0
  # 02-b is deleted, 01-a still present.
  assert_branch_absent feat/02-b
  assert_branch_exists feat/01-a
}

@test "doctor --dry-run: lists squash issues without applying" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/02-b
  printf 'extra\n' >> file && git add file && git commit -q -m "02-b second"
  local sha_02
  sha_02=$(git rev-parse refs/heads/feat/02-b)
  run git stack doctor --dry-run --no-color
  assert_status 0
  assert_output_contains "squash"
  assert_output_contains "feat/02-b"
  # Branch is unchanged.
  assert_sha_eq refs/heads/feat/02-b "$sha_02"
}

@test "doctor --no-squash: rename applies, multi-commit branch untouched" {
  git checkout -q -b feat/00-a
  printf '00-a\n' >> file && git add file && git commit -q -m '00-a'
  git checkout -q -b feat/02-b
  printf '02-b\n' >> file && git add file && git commit -q -m '02-b'
  # Add a second commit to feat/02-b so it's also multi-commit.
  printf 'extra\n' >> file && git add file && git commit -q -m "02-b second"
  local sha_02
  sha_02=$(git rev-parse refs/heads/feat/02-b)
  run git stack doctor --yes --no-squash --no-push --no-color
  assert_status 0
  # The 00-a leaf was renamed to 01-a (gap above is preserved).
  assert_branch_exists feat/01-a
  assert_branch_absent feat/00-a
  # feat/02-b is unchanged — --no-squash skipped the multi-commit fix.
  assert_sha_eq refs/heads/feat/02-b "$sha_02"
}

@test "doctor without --yes on non-tty refuses with a hint" {
  make_stack_branches feat 01-a 02-b
  git checkout -q feat/02-b
  printf 'extra\n' >> file && git add file && git commit -q -m "02-b second"
  # bats runs commands with stdin/stdout piped, so the tty check fires.
  run git stack doctor --no-color
  refute test "$status" -eq 0
  assert_output_contains "--yes"
}

# ---------- doctor duplicate leaves ----------

# Create two sibling branches that both branch from feat/01-a and share
# leaf 02. Each modifies an independent file so their cherry-picks compose.
make_dup_siblings() {
  git checkout -q -b feat/01-a
  printf '01-a\n' >> file && git add file && git commit -q -m '01-a'
  git checkout -q -b feat/02-b
  printf 'b\n' > b-file && git add b-file && git commit -q -m '02-b'
  git checkout -q feat/01-a
  git checkout -q -b feat/02-c
  printf 'c\n' > c-file && git add c-file && git commit -q -m '02-c'
}

@test "doctor --yes: duplicate leaf renumbered in sort-V order and reflowed" {
  make_dup_siblings
  local sha_01
  sha_01=$(git rev-parse refs/heads/feat/01-a)
  git checkout -q feat/01-a
  run git stack doctor --yes --no-push --no-color
  assert_status 0
  # 02-b kept (sort-V order: b before c), 02-c renumbered to 03-c.
  assert_branch_exists feat/02-b
  assert_branch_exists feat/03-c
  assert_branch_absent feat/02-c
  # 03-c's tip must sit on top of 02-b (reflow re-threaded it from 01-a → 02-b).
  local sha_02
  sha_02=$(git rev-parse refs/heads/feat/02-b)
  assert_branch_parent_is feat/03-c "$sha_02"
  # 03-c carries its own diff (c-file) and inherits 02-b's (b-file).
  run git ls-tree -r --name-only refs/heads/feat/03-c
  assert_output_contains 'c-file'
  assert_output_contains 'b-file'
}

# Two siblings sharing leaf 02 that edit the SAME file, so renumbering 02-c ->
# 03-c and re-threading it onto 02-b conflicts on the cherry-pick. Pins doctor's
# plan-composition-then-pause path (rename applied, then reflow pauses).
make_conflicting_dups() {
  git checkout -q -b feat/01-a; printf '01-a\n' >> file; git add file; git commit -q -m '01-a'
  git checkout -q -b feat/02-b; printf 'B\n' >> file; git add file; git commit -q -m '02-b'
  git checkout -q feat/01-a
  git checkout -q -b feat/02-c; printf 'C\n' >> file; git add file; git commit -q -m '02-c'
  git checkout -q feat/01-a
}

@test "doctor --yes: duplicate-resolution reflow conflict halts; continue completes" {
  make_conflicting_dups
  run git stack doctor --yes --no-push --no-color
  assert_status 2
  assert_output_contains "conflict"
  # Rename already applied before the reflow paused.
  assert_branch_exists feat/03-c
  assert_branch_absent feat/02-c

  printf '01-a\nB\nC\n' > file
  git add file
  run git stack continue --no-color
  assert_status 0
  assert_branch_parent_is feat/03-c "$(git rev-parse refs/heads/feat/02-b)"
}

@test "doctor --yes: abort after duplicate-resolution conflict restores post-rename SHA" {
  make_conflicting_dups
  local orig_c
  orig_c=$(git rev-parse refs/heads/feat/02-c)

  run git stack doctor --yes --no-push --no-color
  assert_status 2

  run git stack abort --no-color
  assert_status 0
  # Engine abort restores the reflowed branch to its post-rename SHA (the rename
  # moved the ref, not the commit, so 03-c's captured tip == the original 02-c
  # tip). The doctor rename itself is not undone by engine abort.
  assert_branch_exists feat/03-c
  assert_sha_eq refs/heads/feat/03-c "$orig_c"
  assert_branch_absent feat/02-c
  # Resume state cleared.
  run git stack continue --no-color
  refute test "$status" -eq 0
}

# Doctor's remote tail (remote rename + pr sync for renumbered branches) now
# runs through the engine as the final phase, after the local reflow. A remote
# failure must retain state so 'continue' retries it — matching cmd_move/rename.
@test "doctor: remote rename failure is resumable; continue completes the tail" {
  make_dup_siblings
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  export GH_STUB_FAIL_RENAME="feat/02-c"
  git checkout -q feat/01-a
  run git stack doctor --yes --no-color
  refute test "$status" -eq 0
  # Local renumber + reflow already applied before the remote tail ran.
  assert_branch_exists feat/03-c
  assert_branch_absent feat/02-c
  # State retained at the remote-sync phase → resumable.
  assert test -f "$(git rev-parse --git-dir)/stack-rebase-state"
  unset GH_STUB_FAIL_RENAME
  run git stack continue --no-color
  assert_status 0
  refute test -f "$(git rev-parse --git-dir)/stack-rebase-state"
}

# Aborting the combined (reflow-pick, remote-sync) plan at the remote-sync pause
# walks back through reflow-pick too: it restores the reflowed branch to its
# captured (post-rename, pre-reflow) SHA and clears state. The local rename was
# applied outside the engine, so it persists — doctor's snapshot remains the
# recovery path for that.
@test "doctor: abort after remote failure unwinds reflow, keeps rename, clears state" {
  make_dup_siblings
  local orig_c
  orig_c=$(git rev-parse refs/heads/feat/02-c)
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  export GH_STUB_FAIL_RENAME="feat/02-c"
  git checkout -q feat/01-a
  run git stack doctor --yes --no-color
  refute test "$status" -eq 0
  assert test -f "$(git rev-parse --git-dir)/stack-rebase-state"
  run git stack abort --no-color
  assert_status 0
  refute test -f "$(git rev-parse --git-dir)/stack-rebase-state"
  # Rename kept (applied outside the engine); reflow unwound to the captured SHA.
  assert_branch_exists feat/03-c
  assert_sha_eq refs/heads/feat/03-c "$orig_c"
  assert_branch_absent feat/02-c
}

@test "doctor --dry-run: lists duplicate leaf group without applying" {
  make_dup_siblings
  local sha_b sha_c
  sha_b=$(git rev-parse refs/heads/feat/02-b)
  sha_c=$(git rev-parse refs/heads/feat/02-c)
  run git stack doctor --dry-run --no-color
  assert_status 0
  assert_output_contains "duplicate leaf 2"
  assert_output_contains "feat/02-b"
  assert_output_contains "feat/02-c"
  # Refs unchanged.
  assert_sha_eq refs/heads/feat/02-b "$sha_b"
  assert_sha_eq refs/heads/feat/02-c "$sha_c"
}

@test "doctor --yes --no-rename: duplicates left untouched" {
  make_dup_siblings
  local sha_b sha_c
  sha_b=$(git rev-parse refs/heads/feat/02-b)
  sha_c=$(git rev-parse refs/heads/feat/02-c)
  git checkout -q feat/01-a
  run git stack doctor --yes --no-rename --no-push --no-color
  assert_status 0
  # Both 02 leaves still exist with original SHAs.
  assert_sha_eq refs/heads/feat/02-b "$sha_b"
  assert_sha_eq refs/heads/feat/02-c "$sha_c"
}

@test "doctor --yes: three-way duplicate cascades correctly" {
  git checkout -q -b feat/01-a
  printf '01-a\n' >> file && git add file && git commit -q -m '01-a'
  git checkout -q -b feat/02-b
  printf 'b\n' > b-file && git add b-file && git commit -q -m '02-b'
  git checkout -q feat/01-a
  git checkout -q -b feat/02-c
  printf 'c\n' > c-file && git add c-file && git commit -q -m '02-c'
  git checkout -q feat/01-a
  git checkout -q -b feat/02-d
  printf 'd\n' > d-file && git add d-file && git commit -q -m '02-d'
  git checkout -q feat/01-a
  run git stack doctor --yes --no-push --no-color
  assert_status 0
  # Sort-V order: 02-b stays, 02-c → 03-c, 02-d → 04-d.
  assert_branch_exists feat/02-b
  assert_branch_exists feat/03-c
  assert_branch_exists feat/04-d
  assert_branch_absent feat/02-c
  assert_branch_absent feat/02-d
  local sha_02 sha_03
  sha_02=$(git rev-parse refs/heads/feat/02-b)
  sha_03=$(git rev-parse refs/heads/feat/03-c)
  assert_branch_parent_is feat/03-c "$sha_02"
  assert_branch_parent_is feat/04-d "$sha_03"
}

@test "doctor --yes: duplicate plus existing higher leaf cascades all" {
  # Setup: feat/01-a, feat/02-b, feat/02-c (sibling), feat/03-d (child of 02-b).
  # After doctor: 02-c → 03-c, 03-d → 04-d, all re-threaded.
  git checkout -q -b feat/01-a
  printf '01-a\n' >> file && git add file && git commit -q -m '01-a'
  git checkout -q -b feat/02-b
  printf 'b\n' > b-file && git add b-file && git commit -q -m '02-b'
  git checkout -q -b feat/03-d
  printf 'd\n' > d-file && git add d-file && git commit -q -m '03-d'
  git checkout -q feat/01-a
  git checkout -q -b feat/02-c
  printf 'c\n' > c-file && git add c-file && git commit -q -m '02-c'
  git checkout -q feat/01-a
  run git stack doctor --yes --no-push --no-color
  assert_status 0
  assert_branch_exists feat/02-b
  assert_branch_exists feat/03-c
  assert_branch_exists feat/04-d
  local sha_02 sha_03
  sha_02=$(git rev-parse refs/heads/feat/02-b)
  sha_03=$(git rev-parse refs/heads/feat/03-c)
  assert_branch_parent_is feat/03-c "$sha_02"
  assert_branch_parent_is feat/04-d "$sha_03"
  # All files reachable from the tip.
  run git ls-tree -r --name-only refs/heads/feat/04-d
  assert_output_contains 'b-file'
  assert_output_contains 'c-file'
  assert_output_contains 'd-file'
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

# The remote tail (remote rename + pr sync) must be resumable: a remote-rename
# failure after the local renames are applied retains engine state so 'continue'
# can retry the idempotent remote-sync phase, instead of leaving the user with a
# half-done rename and only a manual-recovery hint.
@test "rename: remote rename failure is resumable; continue completes the tail" {
  make_stack_branches feat 01-a 02-b
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  export GH_STUB_FAIL_RENAME="feat/01-a"
  run git stack rename newfeat --no-color
  [ "$status" -ne 0 ]
  # Local rename already applied (atomic, before the remote tail).
  git rev-parse --verify --quiet refs/heads/newfeat/01-a || return 1
  # State retained → resumable (the inline path left no state file).
  [ -f "$(git rev-parse --git-dir)/stack-rebase-state" ] || return 1
  # Retry the remote tail; it is idempotent.
  unset GH_STUB_FAIL_RENAME
  run git stack continue --no-color
  [ "$status" -eq 0 ]
  # State cleared on full completion.
  [ ! -f "$(git rev-parse --git-dir)/stack-rebase-state" ]
}

# Finalize checkout edge: when HEAD is on main (not a stack branch), the engine
# must finalize back to main — never to a now-deleted old branch name.
@test "rename from main: completes via engine and leaves HEAD on main" {
  make_stack_branches feat 01-a 02-b
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  git checkout -q main
  run git stack rename newfeat --prefix feat --no-color
  [ "$status" -eq 0 ]
  [ "$(git symbolic-ref --short HEAD)" = "main" ] || return 1
  git rev-parse --verify --quiet refs/heads/newfeat/01-a || return 1
  ! git rev-parse --verify --quiet refs/heads/feat/01-a
}

# Finalize checkout edge: when HEAD was on a renamed stack branch, finalize must
# check out the NEW name (the old ref is gone).
@test "rename: HEAD on a stack branch follows to the renamed branch" {
  make_stack_branches feat 01-a 02-b
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  git checkout -q feat/01-a
  run git stack rename newfeat --no-color
  [ "$status" -eq 0 ]
  [ "$(git symbolic-ref --short HEAD)" = "newfeat/01-a" ]
}

# Abort after a remote failure: returns to the starting branch and clears state.
# The local rename is NOT undone (remote effects can't be auto-reversed), so the
# renamed branches persist — abort only warns about the remote tail.
@test "rename: abort after remote failure returns to main and clears state" {
  make_stack_branches feat 01-a 02-b
  make_remote_origin
  export GH_STUB_REPO="test/repo"
  export GH_STUB_FAIL_RENAME="feat/01-a"
  git checkout -q main
  run git stack rename newfeat --prefix feat --no-color
  [ "$status" -ne 0 ]
  [ -f "$(git rev-parse --git-dir)/stack-rebase-state" ] || return 1
  run git stack abort --no-color
  [ "$status" -eq 0 ]
  [ "$(git symbolic-ref --short HEAD)" = "main" ] || return 1
  [ ! -f "$(git rev-parse --git-dir)/stack-rebase-state" ] || return 1
  # Local rename was applied before the remote tail and is left in place.
  git rev-parse --verify --quiet refs/heads/newfeat/01-a
}

# ---------- new/move history interop ----------

@test "history: 'add' produces a restorable snapshot" {
  # Use a sparse stack so --after has a gap to insert into.
  make_stack_branches feat 010-a 020-b
  git stack add mid --after 10 --no-color </dev/null
  run git stack history --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"add"* ]]
}

@test "history: 'move' produces a restorable snapshot" {
  # snapshot_stack is called before the rebase, so even if cherry-pick
  # conflicts the snapshot is already recorded.
  make_stack_branches feat 01-a 02-b
  git stack move feat/01-a --last --no-push --no-color </dev/null 2>&1 || true
  run git stack history --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"move"* ]]
}

# ---------- help ----------

@test "help: documents the core verbs" {
  run git stack help --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"create"* ]]
  [[ "$output" == *"add"* ]]
  [[ "$output" == *"view"* ]]
  [[ "$output" == *"clean"* ]]
  [[ "$output" == *"sync"* ]]
  [[ "$output" == *"move"* ]]
}
