#!/usr/bin/env bash
# test-pr-review-submitted.sh - Integration test for /ralph-review via PR review form
#
# Verifies that the Ralph loop processes a task triggered by a pull_request_review
# event (submitted via the Approve/Comment/Request changes form) containing the
# /ralph-review slash command in the review body.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="${SCRIPT_DIR}/../helpers"

# shellcheck source=test/helpers/setup.sh
source "${HELPERS_DIR}/setup.sh"
# shellcheck source=test/helpers/mocks.sh
source "${HELPERS_DIR}/mocks.sh"

test_ralph_review_via_pr_review_form() {
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
  # when triggered by a /ralph-review slash command via the PR review form
  local pr_review_context
  pr_review_context="$(cat <<'EOF'
# PR Review Feedback (PR #999)
This run was triggered by the /ralph-review slash command on PR #999 (branch: ralph/issue-42). Address all reviewer feedback below.

## Overall Reviews

### Review by @reviewer (CHANGES_REQUESTED):

Please fix the error handling in the main function.
EOF
)"

  state_write_task "Implement feature Y" "Add support for feature Y." "${pr_review_context}"
  state_write_iteration "0"
  state_write_issue_number "42"
  state_write_event_info "submitted" "2001"

  # Write pr-info.txt as entrypoint.sh would
  {
    echo "repo=test-owner/test-repo"
    echo "branch=ralph/issue-42"
    echo "issue_title=Implement feature Y"
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

  if [[ ! -f "worker-output-1.txt" ]]; then
    echo "FAIL: expected worker-output-1.txt to exist after loop"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Clean up
  teardown_mock_binaries
  cleanup_test_workspace "${tmpdir}"
  echo "PASS: /ralph-review via PR review form runs loop with review context in task.md"
}

main() {
  test_ralph_review_via_pr_review_form
}

main "$@"
