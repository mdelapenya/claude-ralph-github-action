#!/usr/bin/env bash
# test-workflow-patch.sh - Unit tests for workflow-patch.sh functions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/workflow-patch.sh
source "${REPO_ROOT}/scripts/workflow-patch.sh"

# Helper: create a git repo with a main branch and a working branch
# that has workflow file changes
_create_repo_with_workflow_changes() {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Create a bare repo as remote
  local bare_repo="${tmpdir}/remote.git"
  git init --bare -b main "${bare_repo}" > /dev/null 2>&1

  # Create working repo
  local workspace="${tmpdir}/workspace"
  mkdir -p "${workspace}"
  cd "${workspace}"
  git init -b main > /dev/null 2>&1
  git config user.name "Test User"
  git config user.email "test@example.com"

  # Initial commit with a README
  echo "# Test" > README.md
  git add README.md
  git commit -m "Initial commit" > /dev/null 2>&1

  # Wire up remote
  git remote add origin "${bare_repo}"
  git push -u origin main > /dev/null 2>&1

  # Create working branch
  git checkout -b feature-branch > /dev/null 2>&1

  # Add workflow file changes
  mkdir -p .github/workflows
  cat > .github/workflows/ci.yml <<'EOF'
name: CI
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "Hello"
EOF
  git add .github/workflows/ci.yml
  git commit -m "feat: add CI workflow" > /dev/null 2>&1

  echo "${tmpdir}"
}

# Helper: create a git repo WITHOUT workflow file changes
_create_repo_without_workflow_changes() {
  local tmpdir
  tmpdir="$(mktemp -d)"

  local bare_repo="${tmpdir}/remote.git"
  git init --bare -b main "${bare_repo}" > /dev/null 2>&1

  local workspace="${tmpdir}/workspace"
  mkdir -p "${workspace}"
  cd "${workspace}"
  git init -b main > /dev/null 2>&1
  git config user.name "Test User"
  git config user.email "test@example.com"

  echo "# Test" > README.md
  git add README.md
  git commit -m "Initial commit" > /dev/null 2>&1

  git remote add origin "${bare_repo}"
  git push -u origin main > /dev/null 2>&1

  git checkout -b feature-branch > /dev/null 2>&1

  # Add a non-workflow change
  echo "some code" > app.sh
  git add app.sh
  git commit -m "feat: add app" > /dev/null 2>&1

  echo "${tmpdir}"
}

test_has_workflow_changes_detects_changes() {
  local tmpdir
  tmpdir="$(_create_repo_with_workflow_changes)"
  cd "${tmpdir}/workspace"

  if ! has_workflow_changes "origin/main"; then
    echo "FAIL: has_workflow_changes should detect workflow file changes"
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf "${tmpdir}"
  echo "PASS: has_workflow_changes detects workflow file changes"
}

test_has_workflow_changes_no_changes() {
  local tmpdir
  tmpdir="$(_create_repo_without_workflow_changes)"
  cd "${tmpdir}/workspace"

  if has_workflow_changes "origin/main"; then
    echo "FAIL: has_workflow_changes should return false when no workflow files changed"
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf "${tmpdir}"
  echo "PASS: has_workflow_changes returns false when no workflow files changed"
}

test_list_workflow_changes() {
  local tmpdir
  tmpdir="$(_create_repo_with_workflow_changes)"
  cd "${tmpdir}/workspace"

  local changed_files
  changed_files="$(list_workflow_changes "origin/main")"

  if [[ "${changed_files}" != *".github/workflows/ci.yml"* ]]; then
    echo "FAIL: list_workflow_changes should list .github/workflows/ci.yml, got: ${changed_files}"
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf "${tmpdir}"
  echo "PASS: list_workflow_changes lists modified workflow files"
}

test_generate_workflow_patch() {
  local tmpdir
  tmpdir="$(_create_repo_with_workflow_changes)"
  cd "${tmpdir}/workspace"

  local patch
  patch="$(generate_workflow_patch "origin/main")"

  if [[ -z "${patch}" ]]; then
    echo "FAIL: generate_workflow_patch should produce a non-empty patch"
    rm -rf "${tmpdir}"
    return 1
  fi

  if [[ "${patch}" != *"diff --git"* ]]; then
    echo "FAIL: patch should contain 'diff --git' header"
    rm -rf "${tmpdir}"
    return 1
  fi

  if [[ "${patch}" != *".github/workflows/ci.yml"* ]]; then
    echo "FAIL: patch should reference the workflow file"
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf "${tmpdir}"
  echo "PASS: generate_workflow_patch produces a valid git diff"
}

test_format_patch_comment() {
  local tmpdir
  tmpdir="$(_create_repo_with_workflow_changes)"
  cd "${tmpdir}/workspace"

  local comment
  comment="$(format_patch_comment "origin/main")"

  if [[ -z "${comment}" ]]; then
    echo "FAIL: format_patch_comment should produce a non-empty comment"
    rm -rf "${tmpdir}"
    return 1
  fi

  if [[ "${comment}" != *"Workflow file changes could not be pushed"* ]]; then
    echo "FAIL: comment should contain the warning header"
    rm -rf "${tmpdir}"
    return 1
  fi

  if [[ "${comment}" != *".github/workflows/ci.yml"* ]]; then
    echo "FAIL: comment should list the changed file"
    rm -rf "${tmpdir}"
    return 1
  fi

  if [[ "${comment}" != *"git apply"* ]]; then
    echo "FAIL: comment should include apply instructions"
    rm -rf "${tmpdir}"
    return 1
  fi

  if [[ "${comment}" != *"ralph-comment-workflow-patch"* ]]; then
    echo "FAIL: comment should contain the ralph marker"
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf "${tmpdir}"
  echo "PASS: format_patch_comment produces a properly formatted comment"
}

test_format_patch_comment_no_changes() {
  local tmpdir
  tmpdir="$(_create_repo_without_workflow_changes)"
  cd "${tmpdir}/workspace"

  local exit_code=0
  format_patch_comment "origin/main" > /dev/null 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 2 ]]; then
    echo "FAIL: format_patch_comment should exit with code 2 when no workflow changes, got ${exit_code}"
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf "${tmpdir}"
  echo "PASS: format_patch_comment exits with code 2 when no workflow changes"
}

test_remove_workflow_changes() {
  local tmpdir
  tmpdir="$(_create_repo_with_workflow_changes)"
  cd "${tmpdir}/workspace"

  # Verify the workflow file exists before removal
  if [[ ! -f ".github/workflows/ci.yml" ]]; then
    echo "FAIL: workflow file should exist before removal"
    rm -rf "${tmpdir}"
    return 1
  fi

  remove_workflow_changes "origin/main"

  # After removal, check there are no workflow changes vs base
  if has_workflow_changes "origin/main"; then
    echo "FAIL: has_workflow_changes should return false after remove_workflow_changes"
    rm -rf "${tmpdir}"
    return 1
  fi

  # Verify the commit was created
  local last_commit
  last_commit="$(git log -1 --format="%s")"
  if [[ "${last_commit}" != *"remove workflow changes"* ]]; then
    echo "FAIL: remove_workflow_changes should create a commit, got: ${last_commit}"
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf "${tmpdir}"
  echo "PASS: remove_workflow_changes removes workflow file changes and commits"
}

test_script_exit_code_no_changes() {
  local tmpdir
  tmpdir="$(_create_repo_without_workflow_changes)"
  cd "${tmpdir}/workspace"

  local exit_code=0
  "${REPO_ROOT}/scripts/workflow-patch.sh" "origin/main" > /dev/null 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 2 ]]; then
    echo "FAIL: script should exit with code 2 when no workflow changes, got ${exit_code}"
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf "${tmpdir}"
  echo "PASS: script exits with code 2 when no workflow changes"
}

test_script_exit_code_with_changes() {
  local tmpdir
  tmpdir="$(_create_repo_with_workflow_changes)"
  cd "${tmpdir}/workspace"

  local exit_code=0
  "${REPO_ROOT}/scripts/workflow-patch.sh" "origin/main" > /dev/null 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: script should exit with code 0 when workflow changes exist, got ${exit_code}"
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf "${tmpdir}"
  echo "PASS: script exits with code 0 when workflow changes exist"
}

# Run all tests
main() {
  local failed=0

  test_has_workflow_changes_detects_changes || failed=$((failed + 1))
  test_has_workflow_changes_no_changes || failed=$((failed + 1))
  test_list_workflow_changes || failed=$((failed + 1))
  test_generate_workflow_patch || failed=$((failed + 1))
  test_format_patch_comment || failed=$((failed + 1))
  test_format_patch_comment_no_changes || failed=$((failed + 1))
  test_remove_workflow_changes || failed=$((failed + 1))
  test_script_exit_code_no_changes || failed=$((failed + 1))
  test_script_exit_code_with_changes || failed=$((failed + 1))

  echo ""
  if [[ ${failed} -eq 0 ]]; then
    echo "✅ All workflow-patch.sh unit tests passed"
    return 0
  else
    echo "❌ ${failed} workflow-patch.sh unit test(s) failed"
    return 1
  fi
}

main "$@"
