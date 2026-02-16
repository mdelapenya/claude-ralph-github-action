#!/usr/bin/env bash
# test-squash-merge.sh - Integration test for squash-merge strategy
#
# Exercises the real ralph-loop.sh with INPUT_MERGE_STRATEGY=squash-merge.
# The mock reviewer writes a merge-commit.txt with a fake SHA instead of
# creating a PR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="${SCRIPT_DIR}/../helpers"

# shellcheck source=test/helpers/setup.sh
source "${HELPERS_DIR}/setup.sh"
# shellcheck source=test/helpers/mocks.sh
source "${HELPERS_DIR}/mocks.sh"

test_squash_merge() {
  local tmpdir
  tmpdir="$(create_test_workspace)"
  local workspace="${tmpdir}/workspace"

  # Set merge strategy before setup_test_env so it picks it up
  export INPUT_MERGE_STRATEGY="squash-merge"

  setup_test_env "${tmpdir}"
  setup_mock_binaries

  # Configure mock: reviewer ships with squash-merge
  export MOCK_REVIEW_DECISION="SHIP"
  export MOCK_MERGE_STRATEGY="squash-merge"

  cd "${workspace}"

  # Initialize state
  # shellcheck source=scripts/state.sh
  source "${SCRIPTS_DIR}/state.sh"
  state_init
  state_write_task "Quick Fix" "Small bug fix suitable for squash-merge"
  state_write_iteration "0"

  git checkout -b ralph/issue-42 > /dev/null 2>&1

  export INPUT_MAX_ITERATIONS=5
  local exit_code=0
  "${SCRIPTS_DIR}/ralph-loop.sh" || exit_code=$?

  # --- Assertions ---
  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: expected exit code 0 (SHIPPED), got ${exit_code}"
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

  # Should have merge-commit.txt instead of pr-url.txt
  if [[ ! -f ".ralph/merge-commit.txt" ]]; then
    echo "FAIL: expected .ralph/merge-commit.txt to exist"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  local merge_sha
  merge_sha="$(cat .ralph/merge-commit.txt)"
  if [[ "${merge_sha}" != "abc123def456" ]]; then
    echo "FAIL: expected merge SHA abc123def456, got ${merge_sha}"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # pr-url.txt should NOT exist for squash-merge
  if [[ -f ".ralph/pr-url.txt" ]]; then
    echo "FAIL: pr-url.txt should not exist for squash-merge strategy"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Clean up
  teardown_mock_binaries
  cleanup_test_workspace "${tmpdir}"
  echo "PASS: squash-merge flow produces correct outputs"
}

main() {
  test_squash_merge
}

main "$@"
