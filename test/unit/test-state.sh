#!/usr/bin/env bash
# test-state.sh - Unit tests for state.sh functions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/state.sh
source "${REPO_ROOT}/scripts/state.sh"

test_state_init() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "${tmpdir}"

  state_init

  if [[ ! -d ".ralph" ]]; then
    echo "FAIL: state_init should create .ralph directory"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  cd - > /dev/null
  rm -rf "${tmpdir}"
  echo "PASS: state_init creates .ralph directory"
}

test_state_write_read_iteration() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "${tmpdir}"
  state_init

  state_write_iteration "5"
  local result
  result="$(state_read_iteration)"

  if [[ "${result}" != "5" ]]; then
    echo "FAIL: Expected iteration=5, got=${result}"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  cd - > /dev/null
  rm -rf "${tmpdir}"
  echo "PASS: state_write_iteration and state_read_iteration work correctly"
}

test_state_read_iteration_default() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "${tmpdir}"
  state_init

  # Don't write anything, just read
  local result
  result="$(state_read_iteration)"

  if [[ "${result}" != "0" ]]; then
    echo "FAIL: Expected default iteration=0, got=${result}"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  cd - > /dev/null
  rm -rf "${tmpdir}"
  echo "PASS: state_read_iteration returns 0 by default"
}

test_state_review_result_normalization() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "${tmpdir}"
  state_init

  # Test SHIP normalization
  echo "ship" > .ralph/review-result.txt
  if [[ "$(state_read_review_result)" != "SHIP" ]]; then
    echo "FAIL: Should normalize 'ship' to 'SHIP'"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  # Test REVISE normalization
  echo "revise: needs work" > .ralph/review-result.txt
  if [[ "$(state_read_review_result)" != "REVISE" ]]; then
    echo "FAIL: Should normalize 'revise: needs work' to 'REVISE'"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  # Test default to REVISE
  rm .ralph/review-result.txt
  if [[ "$(state_read_review_result)" != "REVISE" ]]; then
    echo "FAIL: Should default to 'REVISE' when file missing"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  cd - > /dev/null
  rm -rf "${tmpdir}"
  echo "PASS: state_read_review_result normalization works correctly"
}

test_state_write_read_task() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "${tmpdir}"
  state_init

  state_write_task "Test Title" "Test body content"

  if [[ ! -f ".ralph/task.md" ]]; then
    echo "FAIL: task.md should be created"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! grep -q "# Test Title" .ralph/task.md; then
    echo "FAIL: task.md should contain the title"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! grep -q "Test body content" .ralph/task.md; then
    echo "FAIL: task.md should contain the body"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  cd - > /dev/null
  rm -rf "${tmpdir}"
  echo "PASS: state_write_task creates task.md correctly"
}

test_state_write_task_with_comments() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "${tmpdir}"
  state_init

  # Use $'...' ANSI-C quoting to produce real newlines, matching what jq emits in production
  local comments
  comments=$'## Comment by @user1 on 2025-02-16T10:30:00Z\n\nThis is a comment\n\n## Comment by @user2 on 2025-02-16T11:00:00Z\n\nAnother comment'
  state_write_task "Test Title" "Test body content" "${comments}"

  if [[ ! -f ".ralph/task.md" ]]; then
    echo "FAIL: task.md should be created"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! grep -q "# Test Title" .ralph/task.md; then
    echo "FAIL: task.md should contain the title"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! grep -q "Test body content" .ralph/task.md; then
    echo "FAIL: task.md should contain the body"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! grep -q "Issue Comments" .ralph/task.md; then
    echo "FAIL: task.md should contain issue comments section"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  # Verify multi-line structure: comment headers and bodies on separate lines
  if ! grep -q "^## Comment by @user1" .ralph/task.md; then
    echo "FAIL: task.md should contain user1 comment header on its own line"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! grep -q "^This is a comment$" .ralph/task.md; then
    echo "FAIL: task.md should contain user1 comment body on its own line"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! grep -q "^## Comment by @user2" .ralph/task.md; then
    echo "FAIL: task.md should contain user2 comment header"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! grep -q "^Another comment$" .ralph/task.md; then
    echo "FAIL: task.md should contain user2 comment body"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  cd - > /dev/null
  rm -rf "${tmpdir}"
  echo "PASS: state_write_task with comments works correctly"
}

test_state_write_read_issue_number() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "${tmpdir}"
  state_init

  state_write_issue_number "42"
  local result
  result="$(state_read_issue_number)"

  if [[ "${result}" != "42" ]]; then
    echo "FAIL: Expected issue_number=42, got=${result}"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  cd - > /dev/null
  rm -rf "${tmpdir}"
  echo "PASS: state_write_issue_number and state_read_issue_number work correctly"
}

test_state_write_read_work_summary() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "${tmpdir}"
  state_init

  state_write_work_summary "Summary of work"
  local result
  result="$(state_read_work_summary)"

  if [[ "${result}" != "Summary of work" ]]; then
    echo "FAIL: Expected work summary, got=${result}"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  cd - > /dev/null
  rm -rf "${tmpdir}"
  echo "PASS: state_write_work_summary and state_read_work_summary work correctly"
}

test_state_write_read_final_status() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "${tmpdir}"
  state_init

  state_write_final_status "SHIPPED"
  local result
  result="$(state_read_final_status)"

  if [[ "${result}" != "SHIPPED" ]]; then
    echo "FAIL: Expected final_status=SHIPPED, got=${result}"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  cd - > /dev/null
  rm -rf "${tmpdir}"
  echo "PASS: state_write_final_status and state_read_final_status work correctly"
}

test_state_write_task_with_delimiter_in_content() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "${tmpdir}"
  state_init

  # Body contains "EOF" on its own line, which would break a heredoc-based implementation
  local body
  body=$'Here is a code snippet:\n```\nEOF\n```\nEnd of snippet.'
  state_write_task "Delimiter Test" "${body}"

  if [[ ! -f ".ralph/task.md" ]]; then
    echo "FAIL: task.md should be created"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! grep -q "# Delimiter Test" .ralph/task.md; then
    echo "FAIL: task.md should contain the title"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! grep -q "^EOF$" .ralph/task.md; then
    echo "FAIL: task.md should contain literal EOF line from body"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! grep -q "End of snippet" .ralph/task.md; then
    echo "FAIL: task.md should contain content after the EOF line"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  cd - > /dev/null
  rm -rf "${tmpdir}"
  echo "PASS: state_write_task handles delimiter strings in content"
}

test_state_write_task_with_delimiter_in_comments() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "${tmpdir}"
  state_init

  local comments
  comments=$'## Comment by @user1\n\nEOF\nMore text after EOF'
  state_write_task "Comment Delimiter Test" "Normal body" "${comments}"

  if ! grep -q "# Comment Delimiter Test" .ralph/task.md; then
    echo "FAIL: task.md should contain the title"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! grep -q "Issue Comments" .ralph/task.md; then
    echo "FAIL: task.md should contain issue comments section"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! grep -q "More text after EOF" .ralph/task.md; then
    echo "FAIL: task.md should contain content after EOF in comments"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  cd - > /dev/null
  rm -rf "${tmpdir}"
  echo "PASS: state_write_task handles delimiter strings in comments"
}

# Run all tests
main() {
  local failed=0

  test_state_init || failed=$((failed + 1))
  test_state_write_read_iteration || failed=$((failed + 1))
  test_state_read_iteration_default || failed=$((failed + 1))
  test_state_review_result_normalization || failed=$((failed + 1))
  test_state_write_read_task || failed=$((failed + 1))
  test_state_write_task_with_comments || failed=$((failed + 1))
  test_state_write_task_with_delimiter_in_content || failed=$((failed + 1))
  test_state_write_task_with_delimiter_in_comments || failed=$((failed + 1))
  test_state_write_read_issue_number || failed=$((failed + 1))
  test_state_write_read_work_summary || failed=$((failed + 1))
  test_state_write_read_final_status || failed=$((failed + 1))

  echo ""
  if [[ ${failed} -eq 0 ]]; then
    echo "✅ All state.sh unit tests passed"
    return 0
  else
    echo "❌ ${failed} state.sh unit test(s) failed"
    return 1
  fi
}

main "$@"
