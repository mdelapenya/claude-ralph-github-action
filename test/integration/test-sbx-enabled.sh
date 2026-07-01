#!/usr/bin/env bash
# test-sbx-enabled.sh - Integration test for sbx-enabled flow
#
# Verifies that when INPUT_SBX_ENABLED=true, the worker/reviewer/security-gate
# scripts route claude invocations through `sbx exec` via sbx-exec.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="${SCRIPT_DIR}/../helpers"

# shellcheck source=test/helpers/setup.sh
source "${HELPERS_DIR}/setup.sh"
# shellcheck source=test/helpers/mocks.sh
source "${HELPERS_DIR}/mocks.sh"

test_sbx_enabled_shipped_flow() {
  local tmpdir
  tmpdir="$(create_test_workspace)"
  local workspace="${tmpdir}/workspace"

  export INPUT_SBX_ENABLED="true"
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

  # Write sbx-info.txt so sbx-exec.sh can find the mock sbx on PATH
  # (in real usage, sbx-setup.sh writes this file)
  {
    echo "sandbox_name=ralph-sandbox"
    echo "app_name=claude-ralph"
    echo "network_policy=balanced"
    echo "sbx_bin=$(dirname "$(command -v sbx)")"
  } > "${RALPH_DIR}/sbx-info.txt"

  # Create the branch
  git checkout -b ralph/issue-42 > /dev/null 2>&1

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

  if [[ ! -f "worker-output-1.txt" ]]; then
    echo "FAIL: expected worker-output-1.txt to exist"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Clean up
  teardown_mock_binaries
  cleanup_test_workspace "${tmpdir}"
  echo "PASS: sbx-enabled SHIPPED flow routes claude through sbx exec"
}

main() {
  test_sbx_enabled_shipped_flow
}

main "$@"
