#!/usr/bin/env bats
# Unit tests: source bin/git-stack and exercise pure functions directly,
# with no git repo and no gh. Relies on the BASH_SOURCE/$0 guard at the
# bottom of the script so that sourcing does not execute main().

GIT_STACK_BIN="${BATS_TEST_DIRNAME}/../bin/git-stack"

@test "sourcing git-stack does not execute main" {
  run bash -c "source '$GIT_STACK_BIN'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Run a pure function in a subshell that sources the script. Isolates the
# script's `set -euo pipefail` from the bats shell and exercises the function
# under the same options it runs under in production.
placement() {
  run bash -c "source '$GIT_STACK_BIN'; _placement_resolve \"\$@\"" _ "$@"
}

# --- last ---

@test "placement last: empty sparse stack -> leaf 10, base predecessor" {
  placement last "" 3
  [ "$status" -eq 0 ]
  [ "$output" == $'10\t' ]
}

@test "placement last: sparse stack appends next multiple of 10" {
  placement last "" 3 feat/010-auth
  [ "$status" -eq 0 ]
  [ "$output" == $'20\tfeat/010-auth' ]
}

@test "placement last: legacy stack appends last+1" {
  placement last "" 2 feat/01-a feat/02-b
  [ "$status" -eq 0 ]
  [ "$output" == $'3\tfeat/02-b' ]
}

@test "placement last: refuses when next leaf exceeds the 3-digit ceiling" {
  placement last "" 3 feat/990-a
  [ "$status" -ne 0 ]
  [ "$output" == $'ceiling\t1000' ]
}

# --- at ---

@test "placement at: low leaf inserts at front with base predecessor" {
  placement at 7 3 feat/010-a feat/020-b
  [ "$status" -eq 0 ]
  [ "$output" == $'7\t' ]
}

@test "placement at: mid leaf takes the branch below as predecessor" {
  placement at 15 3 feat/010-a feat/020-b
  [ "$status" -eq 0 ]
  [ "$output" == $'15\tfeat/010-a' ]
}

@test "placement at: high leaf appends after the last branch" {
  placement at 30 3 feat/010-a feat/020-b
  [ "$status" -eq 0 ]
  [ "$output" == $'30\tfeat/020-b' ]
}

@test "placement at: refuses a leaf already taken" {
  placement at 10 3 feat/010-a
  [ "$status" -ne 0 ]
  [ "$output" == $'collision\tfeat/010-a' ]
}

@test "placement at: refuses a leaf above the ceiling" {
  placement at 1000 3 feat/010-a
  [ "$status" -ne 0 ]
  [ "$output" == $'ceiling\t1000' ]
}

# --- before ---

@test "placement before: midpoint of the gap below the ref" {
  placement before feat/020-b 3 feat/010-a feat/020-b
  [ "$status" -eq 0 ]
  [ "$output" == $'15\tfeat/010-a' ]
}

@test "placement before: lowest branch uses base predecessor" {
  placement before feat/010-a 3 feat/010-a feat/020-b
  [ "$status" -eq 0 ]
  [ "$output" == $'5\t' ]
}

@test "placement before: refuses when the gap is exhausted" {
  placement before feat/011-b 3 feat/010-a feat/011-b
  [ "$status" -ne 0 ]
  [ "$output" == $'gap-exhausted\t10\t11' ]
}

@test "placement before: refuses an unknown ref" {
  placement before feat/099-x 3 feat/010-a feat/020-b
  [ "$status" -ne 0 ]
  [ "$output" == $'not-found\tfeat/099-x' ]
}

# --- after ---

@test "placement after: midpoint of the gap above the ref" {
  placement after feat/010-a 3 feat/010-a feat/020-b
  [ "$status" -eq 0 ]
  [ "$output" == $'15\tfeat/010-a' ]
}

@test "placement after: last branch appends next multiple of 10" {
  placement after feat/020-b 3 feat/010-a feat/020-b
  [ "$status" -eq 0 ]
  [ "$output" == $'30\tfeat/020-b' ]
}

@test "placement after: last branch in legacy stack appends last+1" {
  placement after feat/02-b 2 feat/01-a feat/02-b
  [ "$status" -eq 0 ]
  [ "$output" == $'3\tfeat/02-b' ]
}

@test "placement after: refuses when the gap is exhausted" {
  placement after feat/010-a 3 feat/010-a feat/011-b
  [ "$status" -ne 0 ]
  [ "$output" == $'gap-exhausted\t10\t11' ]
}

# --- candidate list (interactive picker entry point) ---
# Output: "<predecessor>\t<leaf> <leaf> ..." (empty predecessor = base).

candidates() {
  run bash -c "source '$GIT_STACK_BIN'; _placement_candidates \"\$@\"" _ "$@"
}

@test "candidates after last: open-ended, multiples of 10" {
  candidates feat/020-b after feat/010-a feat/020-b
  [ "$status" -eq 0 ]
  [ "$output" == $'feat/020-b\t30 40 50' ]
}

@test "candidates before a branch: midpoint first, then ascending fill" {
  candidates feat/020-b before feat/010-a feat/020-b
  [ "$status" -eq 0 ]
  [ "$output" == $'feat/010-a\t15 11 12 13 14 16 17 18 19' ]
}

@test "candidates before the lowest branch: base predecessor" {
  candidates feat/010-a before feat/010-a feat/020-b
  [ "$status" -eq 0 ]
  [ "$output" == $'\t5 1 2 3 4 6 7 8 9' ]
}

@test "candidates for a wide gap: curated midpoint + quartiles + eighths" {
  candidates feat/200-b before feat/010-a feat/200-b
  [ "$status" -eq 0 ]
  [ "$output" == $'feat/010-a\t105 58 152 82 128' ]
}

@test "candidates refuses when the gap is exhausted" {
  candidates feat/011-b before feat/010-a feat/011-b
  [ "$status" -ne 0 ]
  [ "$output" == $'gap-exhausted\t10\t11' ]
}

# --- renumber-in-place candidates (leaf picker for move's no-op position) ---
# Output: space-separated leaves near <cur>, within open gap (lo,hi), excluding
# <cur>. hi == -1 means an open upper bound (renumbering the last branch).

renumber_cands() {
  run bash -c "source '$GIT_STACK_BIN'; _renumber_candidates \"\$@\"" _ "$@"
}

@test "renumber candidates: centered on current leaf, current excluded" {
  # First branch 010 with gap (0,15): offers leaves near 10 (incl. 12), not 10.
  renumber_cands 10 0 15
  [ "$status" -eq 0 ]
  [ "$output" == "6 7 8 9 11 12 13" ]
}

@test "renumber candidates: asymmetric gap fills the open side" {
  renumber_cands 10 9 15
  [ "$status" -eq 0 ]
  [ "$output" == "11 12 13 14" ]
}

@test "renumber candidates: open upper bound (last branch)" {
  renumber_cands 20 15 -1
  [ "$status" -eq 0 ]
  [ "$output" == "16 17 18 19 21 22 23" ]
}

@test "renumber candidates: no room yields empty" {
  renumber_cands 11 10 12
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- picker wiring (_pick_position_for_new) ---
# Stubs _pick_one with canned selections to exercise the wiring end-to-end:
# prompt dispatch, "<pred>\t<candidates>" parsing, the empty-predecessor (base)
# case, and setting _PICKED_LEAF_NUM / _PICKED_PREDECESSOR.

pick_position() {
  local ref="$1" pos="$2" leaf="$3"; shift 3
  run env STUB_REF="$ref" STUB_POS="$pos" STUB_LEAF="$leaf" \
    bash -c '
      source "'"$GIT_STACK_BIN"'"
      _pick_one() {
        case "$1" in
          "branch to insert"*)  printf "%s\n" "$STUB_REF" ;;
          "position relative"*) printf "%s\n" "$STUB_POS" ;;
          *)                    printf "%s\n" "$STUB_LEAF" ;;
        esac
      }
      _pick_position_for_new "$@"
      printf "LEAF=%s PRED=%s\n" "$_PICKED_LEAF_NUM" "$_PICKED_PREDECESSOR"
    ' _ "$@"
}

@test "picker wiring: before a branch sets leaf and in-stack predecessor" {
  pick_position feat/020-b "before feat/020-b" 15 feat/010-a feat/020-b
  [ "$status" -eq 0 ]
  [[ "$output" == *"LEAF=15 PRED=feat/010-a"* ]]
}

@test "picker wiring: after the last branch carries it as predecessor" {
  pick_position feat/020-b "after feat/020-b" 30 feat/010-a feat/020-b
  [ "$status" -eq 0 ]
  [[ "$output" == *"LEAF=30 PRED=feat/020-b"* ]]
}

@test "picker wiring: before the lowest branch leaves an empty (base) predecessor" {
  pick_position feat/010-a "before feat/010-a" 5 feat/010-a feat/020-b
  [ "$status" -eq 0 ]
  [[ "$output" == *"LEAF=5 PRED="* ]]
  [[ "$output" != *"PRED=feat"* ]]
}

# --- reflow engine: position advancement (_engine_next) ---
# Pure dispatch mapping (num_phases, phase_idx, unit_idx, outcome) to a
# directive + next position. The phase reports the outcome of advancing one
# unit; the engine decides where the cursor goes. No git, no state file.
# Output: "<directive>\t<phase_idx>\t<unit_idx>".

engine_next() {
  run bash -c "source '$GIT_STACK_BIN'; _engine_next \"\$@\"" _ "$@"
}

@test "engine next: unit-done advances to the next unit in the same phase" {
  engine_next 3 0 0 unit-done
  [ "$status" -eq 0 ]
  [ "$output" == $'advance\t0\t1' ]
}

@test "engine next: phase-complete moves to the start of the next phase" {
  engine_next 3 0 2 phase-complete
  [ "$status" -eq 0 ]
  [ "$output" == $'next-phase\t1\t0' ]
}

@test "engine next: phase-complete on the last phase is done" {
  engine_next 3 2 0 phase-complete
  [ "$status" -eq 0 ]
  [ "$output" == $'done\t2\t0' ]
}

@test "engine next: paused holds the position unchanged" {
  engine_next 3 1 2 paused
  [ "$status" -eq 0 ]
  [ "$output" == $'paused\t1\t2' ]
}

# --- pr-sync reconciler: nav-footer PR-number extraction ---
# Pure filter (stdin -> stdout): emit the PR number of each structural stack
# entry inside the nav block, one per line. ONLY the first "#N" on a line is a
# stack member; later "#N" tokens are title text (e.g. a Revert/Reapply title
# embeds the original "(#1234)") and must NOT be harvested, or every sync
# re-seeds bogus merged-predecessor entries from them.

extract_nav() {
  run bash -c "source '$GIT_STACK_BIN'; _pr_extract_nav_pr_nums" <<< "$1"
}

@test "extract nav nums: only the leading entry number per line (title #refs ignored)" {
  extract_nav '## ignore me #999 outside the block
<!-- git-stack:nav-start -->
## Stack

- ~~#3818 [1/2] update DARCS endpoint~~ (merged)
- ~~#3858 [2/3] Reapply "update DARCS endpoint (#3818)"~~ (merged)
- ~~#3884 [1/3] Revert "Reapply "...(#3818)" (#3858)"~~ (merged)
- #3900 [1/2] split DARCS config-keys call
- #3843 [2/2] flip monitors out of shadow ← this PR

<!-- git-stack:nav-end -->
trailing #777 outside the block'
  [ "$status" -eq 0 ]
  [ "$output" == $'3818\n3858\n3884\n3900\n3843' ]
}

@test "extract nav nums: nothing outside the fenced block is harvested" {
  extract_nav '#111 before
- #222 still before the block'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- pr-sync reconciler: merged-predecessor lineage guard ---
# Pure: from an old nav-footer's PR numbers, return those no longer in the
# active stack that are CANDIDATES for merged-predecessor weaving — but only
# when the old footer is from this stack's lineage (another old-footer PR is
# still active, or self appears in the old footer). No gh. One num per line.
# Usage: _merged_predecessor_candidates <self_num> <active_nums_csv> <old_num>...

mpc() {
  run bash -c "source '$GIT_STACK_BIN'; _merged_predecessor_candidates \"\$@\"" _ "$@"
}

@test "merged candidates: no lineage signal yields nothing" {
  # self=101 not in the old footer; old footer=[201]; only 101 is active.
  # 201 is non-active but neither guard signal holds, so it is not mined.
  mpc 101 "101" 201
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "merged candidates: self in footer unlocks candidates" {
  mpc 101 "101" 101 201
  [ "$status" -eq 0 ]
  [ "$output" == "201" ]
}

@test "merged candidates: another still-active footer PR unlocks candidates" {
  mpc 101 "101,102" 102 201
  [ "$status" -eq 0 ]
  [ "$output" == "201" ]
}

@test "merged candidates: excludes active and self, lists multiple in order" {
  mpc 101 "101" 101 201 202
  [ "$status" -eq 0 ]
  [ "$output" == $'201\n202' ]
}

@test "merged candidates: a repeated old-footer number is mined only once" {
  # Defense-in-depth: even if the same merged predecessor shows up several times
  # in the old footer, it must be emitted once — never multiplied across syncs.
  mpc 101 "101" 101 201 201 202 201
  [ "$status" -eq 0 ]
  [ "$output" == $'201\n202' ]
}

# --- pr-sync reconciler: nav-footer weave + strikethrough on position change ---
# Pure: assemble a PR nav-footer's body triples. Output is one TAB-separated
# triple per line "<branch>\t<num>\t<display_title>"; an empty branch field
# marks a merged predecessor (the renderer strikes it through). Active entries
# get a "[pos/N]" prefix, struck through as "~~[old]~~ [new]" only when the
# entry's number is in <old_nums_csv> (this PR's prior footer) AND its bracketed
# position actually moved. No gh, no git.
# Usage: _pr_weave_footer_triples <old_nums_csv> [<m_num> <m_title>]... -- <a_branch> <a_num> <a_title>...

weave() {
  run bash -c "source '$GIT_STACK_BIN'; _pr_weave_footer_triples \"\$@\"" _ "$@"
}

@test "weave: fresh footer (nothing in old footer) gets plain [N/M] prefixes" {
  weave "" -- feat/010-a 101 "auth" feat/020-b 102 "[9/9] login"
  [ "$status" -eq 0 ]
  [ "$output" == $'feat/010-a\t101\t[1/2] auth\nfeat/020-b\t102\t[2/2] login' ]
}

@test "weave: position change on an in-old-footer PR strikes through the old prefix" {
  # #102 was [3/3] in its own old footer, now [2/2]; struck through. #101 holds
  # its [1/2] position, so it stays plain even though it is in the old footer.
  weave "101,102" -- feat/010-a 101 "[1/2] auth" feat/020-b 102 "[3/3] login"
  [ "$status" -eq 0 ]
  [ "$output" == $'feat/010-a\t101\t[1/2] auth\nfeat/020-b\t102\t~~[3/3]~~ [2/2] login' ]
}

@test "weave: position change is NOT struck through when the PR is not in the old footer" {
  # #102 moved [3/3]->[2/2] but isn't in the old footer (fresh to this PR), so no
  # strikethrough. #101 holds [1/2] and stays plain.
  weave "101" -- feat/010-a 101 "[1/2] auth" feat/020-b 102 "[3/3] login"
  [ "$status" -eq 0 ]
  [ "$output" == $'feat/010-a\t101\t[1/2] auth\nfeat/020-b\t102\t[2/2] login' ]
}

@test "weave: number membership is exact (#10 in old footer does not match #100)" {
  # old footer has #10 only; #100 moved position. #100 must NOT be struck through.
  weave "10" -- feat/010-a 100 "[3/9] auth"
  [ "$status" -eq 0 ]
  [ "$output" == $'feat/010-a\t100\t[1/1] auth' ]
}

@test "weave: merged predecessors are emitted first as empty-branch triples" {
  weave "101" 55 "old base" -- feat/010-a 101 "[1/1] auth"
  [ "$status" -eq 0 ]
  [ "$output" == $'\t55\told base\nfeat/010-a\t101\t[1/1] auth' ]
}

# --- pr-sync reconciler: PR-reference linkification ---
# Pure: rewrite every "#<digits>" in <text> to an explicit markdown link
# [#N](https://github.com/<repo>/pull/N). A bare "#N" renders as a js-issue-link
# that GitHub expands to the PR title client-side (unreadable nav); an explicit
# link keeps the literal "#N" text AND stays clickable. A "#" not followed by a
# digit is left alone; an empty repo passes the text through unchanged.

mdlink() {
  run bash -c "source '$GIT_STACK_BIN'; _md_link_pr_refs \"\$@\"" _ "$@"
}

@test "md link: a structural #N becomes an explicit pull link" {
  mdlink datavant/healthsource '#3818'
  [ "$status" -eq 0 ]
  [ "$output" == '[#3818](https://github.com/datavant/healthsource/pull/3818)' ]
}

@test "md link: refs embedded in a revert title are linkified in place" {
  mdlink datavant/healthsource 'Revert "foo (#3818)" (#3858)'
  [ "$status" -eq 0 ]
  [ "$output" == 'Revert "foo ([#3818](https://github.com/datavant/healthsource/pull/3818))" ([#3858](https://github.com/datavant/healthsource/pull/3858))' ]
}

@test "md link: a # not followed by a digit is left untouched" {
  mdlink datavant/healthsource 'C# at # and ## headings'
  [ "$status" -eq 0 ]
  [ "$output" == 'C# at # and ## headings' ]
}

@test "md link: empty repo passes text through unchanged" {
  mdlink '' '#3818 stays bare'
  [ "$status" -eq 0 ]
  [ "$output" == '#3818 stays bare' ]
}

# --- pr-sync reconciler: nav-footer rendering ---
# _pr_render_nav_footer <repo> <self> then (branch, num, title) triples. An
# empty branch marks a merged predecessor (strikethrough); a branch equal to
# <self> gets the "← this PR" marker. Every #N is linkified.

render() {
  run bash -c "source '$GIT_STACK_BIN'; _pr_render_nav_footer \"\$@\"" _ "$@"
}

@test "render: merged predecessor strikes through and linkifies structural + embedded refs" {
  render datavant/healthsource feat/self \
    "" 3858 'Reapply "foo (#3818)"'
  [ "$status" -eq 0 ]
  [[ "$output" == *'- ~~[#3858](https://github.com/datavant/healthsource/pull/3858) Reapply "foo ([#3818](https://github.com/datavant/healthsource/pull/3818))"~~ (merged)'* ]]
}

@test "render: the self entry gets a linkified number and the this-PR marker" {
  render datavant/healthsource feat/self feat/self 3843 '[2/2] flip monitors'
  [ "$status" -eq 0 ]
  [[ "$output" == *'- [#3843](https://github.com/datavant/healthsource/pull/3843) [2/2] flip monitors ← this PR'* ]]
}

# --- pr-sync reconciler: round-trip-tolerant body normalization ---
# Pure filter (stdin -> stdout): strip CR, drop trailing blank lines. Used
# comparison-only so a GitHub body round-trip (CRLF, trailing newline) does not
# emit a spurious body_changed edit. Never sent to gh.

# Run the filter on a literal body and assert its exact output. Uses `run` so a
# missing function surfaces as a non-zero status / wrong output (not a false
# pass from two empty strings comparing equal).
normalize() {
  run bash -c "source '$GIT_STACK_BIN'; _pr_body_normalize" <<< "$1"
}

@test "body normalize: CRLF normalizes to LF (round-trip CRLF body is not a spurious change)" {
  normalize $'line one\r\nline two\r\n'
  [ "$status" -eq 0 ]
  [ "$output" == $'line one\nline two' ]
}

@test "body normalize: trailing blank/whitespace lines are trimmed" {
  normalize $'content\n\n  \n'
  [ "$status" -eq 0 ]
  [ "$output" == "content" ]
}

@test "body normalize: internal blank lines and indentation are preserved" {
  normalize $'a\n\n    b'
  [ "$status" -eq 0 ]
  [ "$output" == $'a\n\n    b' ]
}

# --- doctor scan: pure squash-kind classification ---
#
# Maps a branch's git facts (vs its predecessor) to a squash issue kind, with
# no git access. Args:
#   <b_tree> <b_count> <prev_tree> <prev_count> <b_has_merge>
# Prints absorbed|merge|multi|both and returns 0 when a fix is needed; returns 1
# (no output) when the branch is clean.
squash_kind() {
  run bash -c "source '$GIT_STACK_BIN'; _doctor_squash_kind_pure \"\$@\"" _ "$@"
}

@test "squash kind: multi-commit (count diff > 1, distinct trees, no merge) -> multi" {
  squash_kind treeB 5 treeA 3 0
  [ "$status" -eq 0 ]
  [ "$output" == "multi" ]
}

@test "squash kind: equal trees dominate -> absorbed (even with merge + multi)" {
  squash_kind same 9 same 3 1
  [ "$status" -eq 0 ]
  [ "$output" == "absorbed" ]
}

@test "squash kind: merge tip, single commit ahead -> merge" {
  squash_kind treeB 4 treeA 3 1
  [ "$status" -eq 0 ]
  [ "$output" == "merge" ]
}

@test "squash kind: merge tip AND multi-commit -> both" {
  squash_kind treeB 6 treeA 3 1
  [ "$status" -eq 0 ]
  [ "$output" == "both" ]
}

@test "squash kind: single commit, distinct trees, no merge -> clean (rc 1, no output)" {
  squash_kind treeB 4 treeA 3 0
  [ "$status" -eq 1 ]
  [ "$output" == "" ]
}

# --- doctor scan: stack shape -> ordered issue list (pure) ---
#
# Composes squash + duplicate + rename issues from pre-gathered facts, no git.
# Args: <prefix> <base_tree> <base_count> -- <name> <tree> <merge> <count> ...
# Emits one TSV issue per line, kind tag first:
#   squash<TAB><branch_idx><TAB><kind>
#   dup<TAB><leaf_num><TAB><idx_csv>
#   rename<TAB><old_branch><TAB><new_branch>
scan() {
  run bash -c "source '$GIT_STACK_BIN'; _doctor_scan \"\$@\"" _ "$@"
}

@test "scan: multi-commit + duplicate leaf yields squash, dup, and rename issues" {
  # feat/01-a clean; feat/02-b multi (5-3>1); feat/02-c dup leaf 2 (clean squash).
  scan feat/ t0 2 -- \
    feat/01-a t1 0 3 \
    feat/02-b t2 0 5 \
    feat/02-c t3 0 6
  [ "$status" -eq 0 ]
  [ "$output" == $'squash\t1\tmulti\ndup\t2\t1,2\nrename\tfeat/02-c\tfeat/03-c' ]
}

@test "scan: clean linear stack yields no issues" {
  scan feat/ t0 2 -- \
    feat/010-a t1 0 3 \
    feat/020-b t2 0 4
  [ "$status" -eq 0 ]
  [ "$output" == "" ]
}

@test "scan: absorbed branch (tree equals predecessor) is a squash/absorbed issue" {
  # feat/020-b's tree equals feat/010-a's tree -> absorbed.
  scan feat/ t0 2 -- \
    feat/010-a t1 0 3 \
    feat/020-b t1 0 4
  [ "$status" -eq 0 ]
  [ "$output" == $'squash\t1\tabsorbed' ]
}
