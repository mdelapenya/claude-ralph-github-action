#!/usr/bin/env bash
# test-security-gate-pass.sh - Integration test: reviewer SHIPs, security gate PASSes
#
# Verifies that when the reviewer approves and the security gate passes,
# the loop exits with SHIPPED and the audit log records the gate phases.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="${SCRIPT_DIR}/../helpers"

# shellcheck source=test/helpers/setup.sh
source "${HELPERS_DIR}/setup.sh"
# shellcheck source=test/helpers/mocks.sh
source "${HELPERS_DIR}/mocks.sh"

test_security_gate_pass() {
  local tmpdir
  tmpdir="$(create_test_workspace)"
  local workspace="${tmpdir}/workspace"

  setup_test_env "${tmpdir}"
  setup_mock_binaries

  export MOCK_REVIEW_DECISION="SHIP"
  export MOCK_SECURITY_GATE_DECISION="PASS"
  export INPUT_SECURITY_GATE_ENABLED="true"

  cd "${workspace}"

  # shellcheck source=scripts/state.sh
  source "${SCRIPTS_DIR}/state.sh"
  state_init
  state_write_task "Test Task" "Implement a simple feature"
  state_write_iteration "0"

  git checkout -b ralph/issue-42 > /dev/null 2>&1

  export INPUT_MAX_ITERATIONS=5
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

  # Security gate result must be PASS
  if [[ "$(state_read_security_result)" != "PASS" ]]; then
    echo "FAIL: expected security_result=PASS, got $(state_read_security_result)"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Audit log must record the gate phases
  if ! grep -q "SECURITY_GATE_START" .ralph/audit.log; then
    echo "FAIL: audit.log missing SECURITY_GATE_START"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  if ! grep -q "SECURITY_GATE_DECISION.*PASS" .ralph/audit.log; then
    echo "FAIL: audit.log missing SECURITY_GATE_DECISION with PASS"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  teardown_mock_binaries
  cleanup_test_workspace "${tmpdir}"
  echo "PASS: security gate PASS allows ship"
}

main() {
  test_security_gate_pass
}

main "$@"
