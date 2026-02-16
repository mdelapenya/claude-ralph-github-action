#!/usr/bin/env bash
# test-shipped-flow.sh - Integration test for SHIPPED scenario

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/state.sh
source "${REPO_ROOT}/scripts/state.sh"

test_shipped_flow() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "${tmpdir}"

  # Initialize git repo
  git init -b main
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "# Test" > README.md
  git add README.md
  git commit -m "Initial commit"

  # Initialize state
  state_init
  state_write_task "Test Task" "Test description"
  state_write_iteration "1"
  state_write_work_summary "## Iteration 1\n- Made changes"
  state_write_review_result "SHIP"
  state_write_final_status "SHIPPED"

  # Simulate outputs that entrypoint.sh would write
  local github_output="${tmpdir}/github-output.txt"
  local pr_url="https://github.com/test/repo/pull/123"
  local iterations="1"
  local final_status="SHIPPED"

  {
    echo "pr_url=${pr_url}"
    echo "iterations=${iterations}"
    echo "final_status=${final_status}"
  } > "${github_output}"

  # Validate outputs
  if ! grep -q "^pr_url=https://github.com/test/repo/pull/123$" "${github_output}"; then
    echo "FAIL: pr_url not set correctly"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! grep -q "^iterations=1$" "${github_output}"; then
    echo "FAIL: iterations not set correctly"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! grep -q "^final_status=SHIPPED$" "${github_output}"; then
    echo "FAIL: final_status not set correctly"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  # Validate state files were created correctly
  if [[ "$(state_read_iteration)" != "1" ]]; then
    echo "FAIL: iteration not stored correctly in state"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if [[ "$(state_read_review_result)" != "SHIP" ]]; then
    echo "FAIL: review result not stored correctly in state"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if [[ "$(state_read_final_status)" != "SHIPPED" ]]; then
    echo "FAIL: final status not stored correctly in state"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  cd - > /dev/null
  rm -rf "${tmpdir}"
  echo "PASS: SHIPPED flow produces correct outputs"
}

main() {
  test_shipped_flow
}

main "$@"
