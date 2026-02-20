#!/usr/bin/env bash
# test-workflow-push-fallback.sh - Integration test for workflow push fallback
#
# Exercises the real ralph-loop.sh -> worker.sh -> reviewer.sh pipeline
# when the branch contains workflow file changes that cannot be pushed
# due to a pre-receive hook (simulating GitHub token restrictions).
# Verifies that the fallback in reviewer.sh:
#   1. Detects unpushed workflow changes
#   2. Posts the patch as a comment via gh
#   3. Removes workflow changes from the branch
#   4. Successfully pushes the branch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="${SCRIPT_DIR}/../helpers"

# shellcheck source=test/helpers/setup.sh
source "${HELPERS_DIR}/setup.sh"
# shellcheck source=test/helpers/mocks.sh
source "${HELPERS_DIR}/mocks.sh"

# Install a pre-receive hook on the bare repo that rejects pushes
# containing workflow files in the tree
_install_workflow_rejection_hook() {
  local bare_repo="$1"
  mkdir -p "${bare_repo}/hooks"
  cat > "${bare_repo}/hooks/pre-receive" <<'HOOK'
#!/bin/bash
while read oldrev newrev refname; do
  if git ls-tree -r --name-only "$newrev" 2>/dev/null | grep -q "^\.github/workflows/"; then
    echo "ERROR: Push rejected - workflow file modifications are not allowed" >&2
    exit 1
  fi
done
HOOK
  chmod +x "${bare_repo}/hooks/pre-receive"
}

test_workflow_push_fallback() {
  local tmpdir
  tmpdir="$(create_test_workspace)"
  local workspace="${tmpdir}/workspace"
  local bare_repo="${tmpdir}/remote.git"

  setup_test_env "${tmpdir}"
  setup_mock_binaries

  # Configure mock: reviewer ships on first iteration
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

  # Add workflow file changes BEFORE the loop starts
  mkdir -p .github/workflows
  cat > .github/workflows/ci.yml <<'YAML'
name: CI
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "Hello"
YAML
  git add .github/workflows/ci.yml
  git commit -m "feat: add CI workflow" > /dev/null 2>&1

  # Install pre-receive hook AFTER the initial setup
  # (so main branch push during setup is not affected)
  _install_workflow_rejection_hook "${bare_repo}"

  # Run the real ralph loop (1 iteration)
  export INPUT_MAX_ITERATIONS=1
  local exit_code=0
  "${SCRIPTS_DIR}/ralph-loop.sh" || exit_code=$?

  # --- Assertions ---

  # The loop should complete with SHIP (exit code 0)
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

  # Workflow files should have been removed from the branch
  if has_workflow_changes "origin/main" 2>/dev/null; then
    echo "FAIL: workflow changes should have been removed from the branch"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Branch should have been pushed to the remote
  local local_head remote_head
  local_head="$(git rev-parse HEAD)"
  remote_head="$(git rev-parse "origin/ralph/issue-42" 2>/dev/null || echo "")"
  if [[ "${local_head}" != "${remote_head}" ]]; then
    echo "FAIL: branch should have been pushed after workflow removal (local=${local_head}, remote=${remote_head})"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # A commit removing workflow changes should exist
  local remove_commit
  remove_commit="$(git log --oneline | grep "remove workflow changes" || echo "")"
  if [[ -z "${remove_commit}" ]]; then
    echo "FAIL: expected a commit that removes workflow changes"
    teardown_mock_binaries
    cleanup_test_workspace "${tmpdir}"
    return 1
  fi

  # Clean up
  teardown_mock_binaries
  cleanup_test_workspace "${tmpdir}"
  echo "PASS: workflow push fallback handles push failure in full loop"
}

# Source workflow-patch.sh for has_workflow_changes check in assertions
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/workflow-patch.sh
source "${REPO_ROOT}/scripts/workflow-patch.sh"

main() {
  test_workflow_push_fallback
}

main "$@"
