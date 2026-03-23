#!/usr/bin/env bash
# test-pr-review-submitted.sh - Integration test for pull_request_review event
#
# Verifies that the Ralph loop processes a task triggered by a /ralph-review
# slash command submitted via the GitHub PR review form (Approve/Comment/Request
# Changes), which fires a pull_request_review event instead of issue_comment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="${SCRIPT_DIR}/../helpers"

# shellcheck source=test/helpers/setup.sh
source "${HELPERS_DIR}/setup.sh"
# shellcheck source=test/helpers/mocks.sh
source "${HELPERS_DIR}/mocks.sh"

test_pr_review_submitted_event() {
  local tmpdir
  tmpdir="$(create_test_workspace)"
  local workspace="${tmpdir}/workspace"

  setup_test_env "${tmpdir}"
  setup_mock_binaries

  # Configure mock: reviewer ships on first iteration
  export MOCK_REVIEW_DECISION="SHIP"

  cd "${workspace}"

  # Initialize state (normally done by entrypoint.sh)
  # shellcheck source=scripts/state.sh
  source "${SCRIPTS_DIR}/state.sh"
  state_init

  # Write task.md with PR review feedback — this is what entrypoint.sh produces
  # when triggered by a pull_request_review event with /ralph-review in the body
  local pr_review_context
  pr_review_context="$(cat <<'EOF'
# PR Review Feedback (PR #999)
This run was triggered by the /ralph-review slash command on PR #999 (branch: ralph/issue-42).

## Reviewer Instructions

Please focus on error handling improvements.

## Inline Code Comments

### Inline comment by @reviewer on `src/main.sh`:42:

This function should be refactored for clarity.

## Overall Reviews

### Review by @reviewer (CHANGES_REQUESTED):

Please address the naming issues and add error handling.
EOF
)"

  state_write_task "Implement feature X" "Add support for feature X as described." "${pr_review_context}"
  state_write_iteration "0"
  state_write_issue_number "42"
  state_write_event_info "submitted" "2001"

  # Write pr-info.txt as entrypoint.sh would
  {
    echo "repo=test-owner/test-repo"
    echo "branch=ralph/issue-42"
    echo "issue_title=Implement feature X"
    echo "merge_strategy=pr"
    echo "default_branch=main"
    echo "pr_number=999"
  } > "${RALPH_DIR}/pr-info.txt"

  # Create and push the ralph branch (simulating prior run that opened the PR)
  git checkout -b ralph/issue-42 > /dev/null 2>&1
  git push origin ralph/issue-42 > /dev/null 2>&1

  # Run the real ralph loop
  export INPUT_MAX_ITERATIONS=5
  local exit_code=0
  "${SCRIPTS_DIR}/ralph-loop.sh" || exit_code=$?

  # --- Assertions ---
  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: expected exit code 0, got ${exit_code}"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  if [[ "$(state_read_final_status)" != "SHIPPED" ]]; then
    echo "FAIL: expected final_status=SHIPPED, got $(state_read_final_status)"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  if [[ "$(state_read_review_result)" != "SHIP" ]]; then
    echo "FAIL: expected review_result=SHIP, got $(state_read_review_result)"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  if [[ "$(state_read_iteration)" != "1" ]]; then
    echo "FAIL: expected iteration=1, got $(state_read_iteration)"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Verify task.md contains PR review context
  if ! grep -q "PR Review Feedback" "${RALPH_DIR}/task.md"; then
    echo "FAIL: task.md should contain PR review feedback section"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  if ! grep -q "ralph-review" "${RALPH_DIR}/task.md"; then
    echo "FAIL: task.md should mention the /ralph-review slash command"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  if ! grep -q "CHANGES_REQUESTED" "${RALPH_DIR}/task.md"; then
    echo "FAIL: task.md should contain review state from pull_request_review event"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  if [[ ! -f "worker-output-1.txt" ]]; then
    echo "FAIL: expected worker-output-1.txt to exist after loop"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Clean up
  teardown_mock_binaries
  cleanup_test_workspace "${tmpdir}"
  echo "PASS: pull_request_review event runs loop with review context in task.md"
}

test_pr_review_event_json_helper() {
  # Test the event JSON helper produces valid JSON with correct fields
  local tmpdir
  tmpdir="$(mktemp -d)"

  create_ralph_review_pr_review_event_json "${tmpdir}" 123 "ralph/issue-55" "/ralph-review focus on tests" "changes_requested"

  local event_file="${tmpdir}/pr-review-event.json"
  if [[ ! -f "${event_file}" ]]; then
    echo "FAIL: pr-review-event.json was not created"
    rm -rf "${tmpdir}"
    return 1
  fi

  # Validate JSON is parseable
  if ! jq empty "${event_file}" 2>/dev/null; then
    echo "FAIL: pr-review-event.json is not valid JSON"
    rm -rf "${tmpdir}"
    return 1
  fi

  # Check key fields
  local action review_body pr_number branch
  action="$(jq -r '.action' "${event_file}")"
  review_body="$(jq -r '.review.body' "${event_file}")"
  pr_number="$(jq -r '.pull_request.number' "${event_file}")"
  branch="$(jq -r '.pull_request.head.ref' "${event_file}")"

  if [[ "${action}" != "submitted" ]]; then
    echo "FAIL: expected action=submitted, got ${action}"
    rm -rf "${tmpdir}"
    return 1
  fi

  if [[ "${review_body}" != "/ralph-review focus on tests" ]]; then
    echo "FAIL: expected review body '/ralph-review focus on tests', got '${review_body}'"
    rm -rf "${tmpdir}"
    return 1
  fi

  if [[ "${pr_number}" != "123" ]]; then
    echo "FAIL: expected PR number 123, got ${pr_number}"
    rm -rf "${tmpdir}"
    return 1
  fi

  if [[ "${branch}" != "ralph/issue-55" ]]; then
    echo "FAIL: expected branch ralph/issue-55, got ${branch}"
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf "${tmpdir}"
  echo "PASS: pull_request_review event JSON helper produces correct output"
}

main() {
  test_pr_review_event_json_helper
  test_pr_review_submitted_event
}

main "$@"
