#!/usr/bin/env bash
# test-security-gate-disabled.sh - Integration test: security gate disabled
#
# Verifies that when INPUT_SECURITY_GATE_ENABLED=false, the loop ships without
# invoking the security gate and leaves no security-result.txt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="${SCRIPT_DIR}/../helpers"

# shellcheck source=test/helpers/setup.sh
source "${HELPERS_DIR}/setup.sh"
# shellcheck source=test/helpers/mocks.sh
source "${HELPERS_DIR}/mocks.sh"

test_security_gate_disabled() {
  local tmpdir
  tmpdir="$(create_test_workspace)"
  local workspace="${tmpdir}/workspace"

  setup_test_env "${tmpdir}"
  setup_mock_binaries

  export MOCK_REVIEW_DECISION="SHIP"
  export INPUT_SECURITY_GATE_ENABLED="false"
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

  # security-result.txt must NOT exist when the gate is disabled
  if [[ -f ".ralph/security-result.txt" ]]; then
    echo "FAIL: security-result.txt should not exist when gate is disabled"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Audit log must NOT contain any security gate phases
  if grep -q "SECURITY_GATE" .ralph/audit.log 2>/dev/null; then
    echo "FAIL: audit.log should not contain SECURITY_GATE entries when gate is disabled"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  teardown_mock_binaries
  cleanup_test_workspace "${tmpdir}"
  echo "PASS: disabled security gate skips audit and ships normally"
}

main() {
  test_security_gate_disabled
}

main "$@"
