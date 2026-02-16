#!/usr/bin/env bash
# test-max-iterations.sh - Integration test for MAX_ITERATIONS scenario
#
# Exercises the real ralph-loop.sh with a mock reviewer that always
# returns REVISE, causing the loop to exhaust max iterations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="${SCRIPT_DIR}/../helpers"

# shellcheck source=test/helpers/setup.sh
source "${HELPERS_DIR}/setup.sh"
# shellcheck source=test/helpers/mocks.sh
source "${HELPERS_DIR}/mocks.sh"

test_max_iterations() {
  local tmpdir
  tmpdir="$(create_test_workspace)"
  local workspace="${tmpdir}/workspace"

  setup_test_env "${tmpdir}"
  setup_mock_binaries

  # Configure mock: reviewer always revises
  export MOCK_REVIEW_DECISION="REVISE"

  cd "${workspace}"

  # Initialize state
  # shellcheck source=scripts/state.sh
  source "${SCRIPTS_DIR}/state.sh"
  state_init
  state_write_task "Complex Task" "This task needs multiple iterations"
  state_write_iteration "0"

  git checkout -b ralph/issue-42 > /dev/null 2>&1

  # Run with max 2 iterations
  export INPUT_MAX_ITERATIONS=2
  local exit_code=0
  "${SCRIPTS_DIR}/ralph-loop.sh" || exit_code=$?

  # --- Assertions ---
  if [[ ${exit_code} -ne 2 ]]; then
    echo "FAIL: expected exit code 2 (MAX_ITERATIONS), got ${exit_code}"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  if [[ "$(state_read_final_status)" != "MAX_ITERATIONS" ]]; then
    echo "FAIL: expected final_status=MAX_ITERATIONS, got $(state_read_final_status)"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  if [[ "$(state_read_iteration)" != "2" ]]; then
    echo "FAIL: expected iteration=2, got $(state_read_iteration)"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  if [[ "$(state_read_review_result)" != "REVISE" ]]; then
    echo "FAIL: expected review_result=REVISE, got $(state_read_review_result)"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Worker should have created files for both iterations
  if [[ ! -f "worker-output-1.txt" ]] || [[ ! -f "worker-output-2.txt" ]]; then
    echo "FAIL: expected worker output files for both iterations"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Clean up
  teardown_mock_binaries
  cleanup_test_workspace "${tmpdir}"
  echo "PASS: MAX_ITERATIONS flow produces correct outputs"
}

main() {
  test_max_iterations
}

main "$@"
