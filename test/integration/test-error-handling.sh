#!/usr/bin/env bash
# test-error-handling.sh - Integration test for the ERROR scenario
#
# Exercises the real ralph-loop.sh with a mock claude binary that
# fails during the worker phase, causing an ERROR exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="${SCRIPT_DIR}/../helpers"

# shellcheck source=test/helpers/setup.sh
source "${HELPERS_DIR}/setup.sh"
# shellcheck source=test/helpers/mocks.sh
source "${HELPERS_DIR}/mocks.sh"

test_error_handling() {
  local tmpdir
  tmpdir="$(create_test_workspace)"
  local workspace="${tmpdir}/workspace"

  setup_test_env "${tmpdir}"
  setup_mock_binaries

  # Configure mock: worker fails
  export MOCK_WORKER_FAIL="true"

  cd "${workspace}"

  # Initialize state
  # shellcheck source=scripts/state.sh
  source "${SCRIPTS_DIR}/state.sh"
  state_init
  state_write_task "Broken Task" "This will fail"
  state_write_iteration "0"

  git checkout -b ralph/issue-42 > /dev/null 2>&1

  export INPUT_MAX_ITERATIONS=3
  local exit_code=0
  "${SCRIPTS_DIR}/ralph-loop.sh" || exit_code=$?

  # --- Assertions ---
  if [[ ${exit_code} -ne 1 ]]; then
    echo "FAIL: expected exit code 1 (ERROR), got ${exit_code}"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  if [[ "$(state_read_final_status)" != "ERROR" ]]; then
    echo "FAIL: expected final_status=ERROR, got $(state_read_final_status)"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Should fail on the first iteration
  if [[ "$(state_read_iteration)" != "1" ]]; then
    echo "FAIL: expected iteration=1 (failed on first), got $(state_read_iteration)"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Clean up
  teardown_mock_binaries
  cleanup_test_workspace "${tmpdir}"
  echo "PASS: ERROR flow produces correct outputs"
}

main() {
  test_error_handling
}

main "$@"
