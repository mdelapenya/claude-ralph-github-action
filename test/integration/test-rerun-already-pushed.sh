#!/usr/bin/env bash
# test-rerun-already-pushed.sh - Integration test for re-runs where branch is already pushed
#
# Exercises the real ralph-loop.sh -> worker.sh -> reviewer.sh pipeline
# when the branch has already been pushed to the remote (simulating a re-run).
# Verifies that push_with_workflow_fallback exit code 2 ("already up to date")
# is treated as success, not as an error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="${SCRIPT_DIR}/../helpers"

# shellcheck source=test/helpers/setup.sh
source "${HELPERS_DIR}/setup.sh"
# shellcheck source=test/helpers/mocks.sh
source "${HELPERS_DIR}/mocks.sh"

test_rerun_already_pushed() {
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
  state_write_task "Test Task" "Implement a simple feature"
  state_write_iteration "0"
  state_write_issue_number "42"

  # Write PR info (normally done by entrypoint.sh)
  cat > .ralph/pr-info.txt <<EOF
repo=test-owner/test-repo
branch=ralph/issue-42
issue_title=Test Task
merge_strategy=pr
default_branch=main
pr_number=
EOF

  # Create and push the branch BEFORE the loop starts,
  # simulating a re-run where the branch already exists on the remote
  git checkout -b ralph/issue-42 > /dev/null 2>&1
  echo "previous work" > previous.txt
  git add previous.txt
  git commit -m "feat: previous work" > /dev/null 2>&1
  git push -u origin ralph/issue-42 > /dev/null 2>&1

  # Run the real ralph loop
  export INPUT_MAX_ITERATIONS=1
  local exit_code=0
  "${SCRIPTS_DIR}/ralph-loop.sh" || exit_code=$?

  # --- Assertions ---

  # The loop should complete with SHIP (exit code 0)
  # Before the fix, exit code 2 from push_with_workflow_fallback
  # would propagate through reviewer.sh and fail the loop.
  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: expected exit code 0 (SHIPPED), got ${exit_code}"
    echo "  (exit code 2 means push_with_workflow_fallback 'already up to date' was treated as error)"
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

  # Clean up
  teardown_mock_binaries
  cleanup_test_workspace "${tmpdir}"
  echo "PASS: re-run with already-pushed branch succeeds (exit code 2 treated as success)"
}

main() {
  test_rerun_already_pushed
}

main "$@"
