#!/usr/bin/env bash
# test-reaction.sh - Integration test for +1 reactions on triggering events
#
# Verifies that the worker phase reacts with +1 to the issue or comment
# that triggered the Ralph action on the first iteration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="${SCRIPT_DIR}/../helpers"

# shellcheck source=test/helpers/setup.sh
source "${HELPERS_DIR}/setup.sh"
# shellcheck source=test/helpers/mocks.sh
source "${HELPERS_DIR}/mocks.sh"

test_reaction_on_issue_labeled() {
  local tmpdir
  tmpdir="$(create_test_workspace)"
  local workspace="${tmpdir}/workspace"

  # Use default event (labeled action, no comment)
  setup_test_env "${tmpdir}"
  setup_mock_binaries

  # Set up API call logging
  export MOCK_GH_API_LOG="${tmpdir}/gh-api-calls.log"
  touch "${MOCK_GH_API_LOG}"

  export MOCK_REVIEW_DECISION="SHIP"

  cd "${workspace}"

  # Initialize state (normally done by entrypoint.sh)
  # shellcheck source=scripts/state.sh
  source "${SCRIPTS_DIR}/state.sh"
  state_init
  state_write_task "Test Task" "Implement a simple feature"
  state_write_issue_number "42"
  state_write_event_info "labeled" ""
  state_write_iteration "0"

  # Create the branch
  git checkout -b ralph/issue-42 > /dev/null 2>&1

  # Run the real ralph loop
  export INPUT_MAX_ITERATIONS=1
  local exit_code=0
  "${SCRIPTS_DIR}/ralph-loop.sh" || exit_code=$?

  # --- Assertions ---
  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: expected exit code 0, got ${exit_code}"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Verify the reaction API was called for the issue
  if ! grep -q "repos/test-owner/test-repo/issues/42/reactions" "${MOCK_GH_API_LOG}"; then
    echo "FAIL: expected +1 reaction on issue #42"
    echo "API calls logged:"
    cat "${MOCK_GH_API_LOG}"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Verify no comment reaction was made
  if grep -q "issues/comments/" "${MOCK_GH_API_LOG}"; then
    echo "FAIL: should not react to a comment for a labeled event"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Clean up
  teardown_mock_binaries
  cleanup_test_workspace "${tmpdir}"
  echo "PASS: +1 reaction posted on issue for labeled event"
}

test_reaction_on_comment() {
  local tmpdir
  tmpdir="$(create_test_workspace)"
  local workspace="${tmpdir}/workspace"

  # Configure a comment event
  export MOCK_EVENT_ACTION="created"
  export MOCK_COMMENT_ID="98765"
  setup_test_env "${tmpdir}"
  setup_mock_binaries

  # Set up API call logging
  export MOCK_GH_API_LOG="${tmpdir}/gh-api-calls.log"
  touch "${MOCK_GH_API_LOG}"

  export MOCK_REVIEW_DECISION="SHIP"

  cd "${workspace}"

  # Initialize state (normally done by entrypoint.sh)
  # shellcheck source=scripts/state.sh
  source "${SCRIPTS_DIR}/state.sh"
  state_init
  state_write_task "Test Task" "Implement a simple feature"
  state_write_issue_number "42"
  state_write_event_info "created" "98765"
  state_write_iteration "0"

  # Create the branch
  git checkout -b ralph/issue-42 > /dev/null 2>&1

  # Run the real ralph loop
  export INPUT_MAX_ITERATIONS=1
  local exit_code=0
  "${SCRIPTS_DIR}/ralph-loop.sh" || exit_code=$?

  # --- Assertions ---
  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: expected exit code 0, got ${exit_code}"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Verify the reaction API was called for the comment
  if ! grep -q "repos/test-owner/test-repo/issues/comments/98765/reactions" "${MOCK_GH_API_LOG}"; then
    echo "FAIL: expected +1 reaction on comment #98765"
    echo "API calls logged:"
    cat "${MOCK_GH_API_LOG}"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Verify no issue reaction was made (only comment reaction)
  if grep -q "issues/42/reactions" "${MOCK_GH_API_LOG}"; then
    echo "FAIL: should not react to the issue for a comment event"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Clean up
  unset MOCK_EVENT_ACTION
  unset MOCK_COMMENT_ID
  teardown_mock_binaries
  cleanup_test_workspace "${tmpdir}"
  echo "PASS: +1 reaction posted on comment for comment event"
}

test_no_reaction_on_subsequent_iterations() {
  local tmpdir
  tmpdir="$(create_test_workspace)"
  local workspace="${tmpdir}/workspace"

  setup_test_env "${tmpdir}"
  setup_mock_binaries

  # Set up API call logging
  export MOCK_GH_API_LOG="${tmpdir}/gh-api-calls.log"
  touch "${MOCK_GH_API_LOG}"

  # First iteration: REVISE, second iteration: SHIP
  export MOCK_REVIEW_DECISION="REVISE"

  cd "${workspace}"

  # Initialize state
  # shellcheck source=scripts/state.sh
  source "${SCRIPTS_DIR}/state.sh"
  state_init
  state_write_task "Test Task" "Implement a simple feature"
  state_write_issue_number "42"
  state_write_event_info "labeled" ""
  state_write_iteration "0"

  # Create the branch
  git checkout -b ralph/issue-42 > /dev/null 2>&1

  # Run just 2 iterations (first REVISE, then SHIP)
  export INPUT_MAX_ITERATIONS=2

  # We need the mock to SHIP on iteration 2
  # Override the mock to track which iteration it's on and change behavior
  # For simplicity, just run with REVISE for 2 iterations (max_iterations)
  local exit_code=0
  "${SCRIPTS_DIR}/ralph-loop.sh" || exit_code=$?

  # Count how many reaction API calls were made
  local reaction_count
  reaction_count="$(grep -c "reactions" "${MOCK_GH_API_LOG}" || echo 0)"

  if [[ "${reaction_count}" -ne 1 ]]; then
    echo "FAIL: expected exactly 1 reaction call, got ${reaction_count}"
    echo "API calls logged:"
    cat "${MOCK_GH_API_LOG}"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Clean up
  teardown_mock_binaries
  cleanup_test_workspace "${tmpdir}"
  echo "PASS: reaction only posted on first iteration, not subsequent ones"
}

main() {
  local failed=0

  test_reaction_on_issue_labeled || failed=$((failed + 1))
  test_reaction_on_comment || failed=$((failed + 1))
  test_no_reaction_on_subsequent_iterations || failed=$((failed + 1))

  echo ""
  if [[ ${failed} -eq 0 ]]; then
    echo "✅ All reaction integration tests passed"
    return 0
  else
    echo "❌ ${failed} reaction integration test(s) failed"
    return 1
  fi
}

main "$@"
