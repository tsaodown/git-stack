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
