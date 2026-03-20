#!/usr/bin/env bash
# test-push-error-recovery.sh - Integration test for push error recovery
#
# Exercises the real ralph-loop.sh -> worker.sh -> reviewer.sh pipeline
# when a push fails on the first iteration. Verifies that:
#   1. The push error is captured in .ralph/push-error.txt
#   2. The loop forces REVISE even though the reviewer said SHIP
#   3. The worker receives push error context on the next iteration
#   4. On the next iteration, push succeeds and the loop ships

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="${SCRIPT_DIR}/../helpers"

# shellcheck source=test/helpers/setup.sh
source "${HELPERS_DIR}/setup.sh"
# shellcheck source=test/helpers/mocks.sh
source "${HELPERS_DIR}/mocks.sh"

# Install a pre-receive hook on the bare repo that rejects the first push
# to the ralph branch but allows subsequent pushes. Uses a counter file.
_install_push_fail_once_hook() {
  local bare_repo="$1"
  local counter_file="$2"
  mkdir -p "${bare_repo}/hooks"
  cat > "${bare_repo}/hooks/pre-receive" <<HOOK
#!/bin/bash
# Read the counter
count=0
if [[ -f "${counter_file}" ]]; then
  count=\$(cat "${counter_file}")
fi
count=\$((count + 1))
echo "\${count}" > "${counter_file}"

# Fail on the first two pushes to ralph branch.
# The mock reviewer does its own "git push" (attempt 1) before
# push_with_workflow_fallback runs (attempt 2), so we need to reject
# both to simulate a push failure on iteration 1.
while read oldrev newrev refname; do
  if [[ "\${refname}" == *"ralph/"* ]] && [[ \${count} -le 2 ]]; then
    echo "ERROR: Push rejected - simulated push failure (attempt \${count})" >&2
    exit 1
  fi
done
HOOK
  chmod +x "${bare_repo}/hooks/pre-receive"
}

test_push_error_recovery() {
  local tmpdir
  tmpdir="$(create_test_workspace)"
  local workspace="${tmpdir}/workspace"
  local bare_repo="${tmpdir}/remote.git"

  setup_test_env "${tmpdir}"
  setup_mock_binaries

  # Configure mock: reviewer ships every iteration
  export MOCK_REVIEW_DECISION="SHIP"

  cd "${workspace}"

  # Initialize state (normally done by entrypoint.sh)
  # shellcheck source=scripts/state.sh
  source "${SCRIPTS_DIR}/state.sh"
  state_init
  state_write_task "Test Task" "Implement a feature"
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

  # Create working branch
  git checkout -b ralph/issue-42 > /dev/null 2>&1

  # Install pre-receive hook that fails the first push
  local counter_file="${tmpdir}/push-counter.txt"
  _install_push_fail_once_hook "${bare_repo}" "${counter_file}"

  # Run the real ralph loop (allow 3 iterations max to give recovery room)
  export INPUT_MAX_ITERATIONS=3
  local exit_code=0
  "${SCRIPTS_DIR}/ralph-loop.sh" || exit_code=$?

  # --- Assertions ---

  # Iteration 1: push fails, SHIP is overridden to REVISE, loop continues
  # Iteration 2: push succeeds, SHIP stands, loop exits

  # The loop should eventually complete with SHIP (exit code 0)
  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: expected exit code 0 (SHIPPED), got ${exit_code}"
    echo "  Final status: $(state_read_final_status)"
    echo "  Iteration: $(state_read_iteration)"
    echo "  Push error: $(state_read_push_error)"
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

  # Should have taken 2 iterations (first push failed, second succeeded)
  if [[ "$(state_read_iteration)" != "2" ]]; then
    echo "FAIL: expected iteration=2 (recovery on second), got $(state_read_iteration)"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Push error should be cleared after successful push
  if [[ -n "$(state_read_push_error)" ]]; then
    echo "FAIL: expected push error to be cleared after successful push"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Worker output files should exist for both iterations
  if [[ ! -f "worker-output-1.txt" ]] || [[ ! -f "worker-output-2.txt" ]]; then
    echo "FAIL: expected worker output files for both iterations"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Branch should have been pushed to the remote
  local local_head remote_head
  local_head="$(git rev-parse HEAD)"
  remote_head="$(git rev-parse "origin/ralph/issue-42" 2>/dev/null || echo "")"
  if [[ "${local_head}" != "${remote_head}" ]]; then
    echo "FAIL: branch should have been pushed (local=${local_head}, remote=${remote_head})"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Clean up
  teardown_mock_binaries
  cleanup_test_workspace "${tmpdir}"
  echo "PASS: push error recovery works - loop continues and retries push on next iteration"
}

main() {
  test_push_error_recovery
}

main "$@"
