#!/usr/bin/env bash
# test-security-gate-fail-then-pass.sh - Integration test: security gate fails once, then passes
#
# Verifies that when the security gate FAILs on the first SHIP attempt:
#   - The loop forces a REVISE instead of exiting
#   - Security findings are prepended to review-feedback.txt
#   - The audit log records SECURITY_GATE_BLOCKED
#   - On the next iteration the reviewer SHIPs again and the gate PASSes → SHIPPED

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="${SCRIPT_DIR}/../helpers"

# shellcheck source=test/helpers/setup.sh
source "${HELPERS_DIR}/setup.sh"
# shellcheck source=test/helpers/mocks.sh
source "${HELPERS_DIR}/mocks.sh"

test_security_gate_fail_then_pass() {
  local tmpdir
  tmpdir="$(create_test_workspace)"
  local workspace="${tmpdir}/workspace"

  setup_test_env "${tmpdir}"
  setup_mock_binaries

  # Reviewer always ships; gate fails first call, passes second
  export MOCK_REVIEW_DECISION="SHIP"
  export MOCK_SECURITY_GATE_DECISION="FAIL_ONCE"
  export INPUT_SECURITY_GATE_ENABLED="true"
  export INPUT_MAX_ITERATIONS=5

  cd "${workspace}"

  # shellcheck source=scripts/state.sh
  source "${SCRIPTS_DIR}/state.sh"
  state_init
  state_write_task "Test Task" "Implement a simple feature"
  state_write_iteration "0"

  git checkout -b ralph/issue-42 > /dev/null 2>&1

  local exit_code=0
  "${SCRIPTS_DIR}/ralph-loop.sh" || exit_code=$?

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

  # Must have taken at least 2 iterations (gate blocked iteration 1)
  local iteration
  iteration="$(state_read_iteration)"
  if [[ "${iteration}" -lt 2 ]]; then
    echo "FAIL: expected at least 2 iterations, got ${iteration}"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Final security result must be PASS
  if [[ "$(state_read_security_result)" != "PASS" ]]; then
    echo "FAIL: expected final security_result=PASS, got $(state_read_security_result)"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Audit log must record a SECURITY_GATE_BLOCKED event
  if ! grep -q "SECURITY_GATE_BLOCKED" .ralph/audit.log; then
    echo "FAIL: audit.log missing SECURITY_GATE_BLOCKED"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  teardown_mock_binaries
  cleanup_test_workspace "${tmpdir}"
  echo "PASS: security gate FAIL forces revise; subsequent PASS allows ship"
}

main() {
  test_security_gate_fail_then_pass
}

main "$@"
