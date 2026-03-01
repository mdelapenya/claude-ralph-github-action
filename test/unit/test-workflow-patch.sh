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

# Helper: install a pre-receive hook on the bare repo that rejects
# pushes containing workflow files in the tree
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

# Helper: create a simple mock gh that logs calls to a file
_setup_mock_gh() {
  local mock_dir="$1"
  local log_file="$2"
  mkdir -p "${mock_dir}"
  cat > "${mock_dir}/gh" <<MOCK
#!/bin/bash
echo "\$*" >> "${log_file}"
# Return empty for API calls that check for existing comments (jq queries)
if [[ "\$1" == "api" ]] && [[ "\$*" == *"--jq"* ]]; then
  exit 0
fi
echo "mock-ok"
MOCK
  chmod +x "${mock_dir}/gh"
  export PATH="${mock_dir}:${PATH}"
}

test_push_fallback_already_pushed() {
  local tmpdir
  tmpdir="$(_create_repo_without_workflow_changes)"
  cd "${tmpdir}/workspace"

  # Push the branch first so it's already up to date
  git push origin feature-branch > /dev/null 2>&1

  local exit_code=0
  push_with_workflow_fallback "feature-branch" "origin/main" "42" "test/repo" 2>/dev/null || exit_code=$?

  if [[ ${exit_code} -ne 2 ]]; then
    echo "FAIL: push_with_workflow_fallback should return 2 when already pushed, got ${exit_code}"
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf "${tmpdir}"
  echo "PASS: push_with_workflow_fallback returns 2 when branch is already up to date"
}

test_push_fallback_normal_push() {
  local tmpdir
  tmpdir="$(_create_repo_without_workflow_changes)"
  cd "${tmpdir}/workspace"

  local exit_code=0
  push_with_workflow_fallback "feature-branch" "origin/main" "42" "test/repo" 2>/dev/null || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: push_with_workflow_fallback should return 0 on successful push, got ${exit_code}"
    rm -rf "${tmpdir}"
    return 1
  fi

  # Verify push succeeded
  local local_head remote_head
  local_head="$(git rev-parse HEAD)"
  remote_head="$(git rev-parse "origin/feature-branch" 2>/dev/null || echo "")"
  if [[ "${local_head}" != "${remote_head}" ]]; then
    echo "FAIL: branch should have been pushed"
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf "${tmpdir}"
  echo "PASS: push_with_workflow_fallback succeeds on normal push"
}

test_push_fallback_handles_workflow_rejection() {
  local tmpdir
  tmpdir="$(_create_repo_with_workflow_changes)"
  cd "${tmpdir}/workspace"

  # Install pre-receive hook that rejects workflow files
  _install_workflow_rejection_hook "${tmpdir}/remote.git"

  # Set up mock gh to track calls
  local original_path="${PATH}"
  local gh_log="${tmpdir}/gh-calls.log"
  touch "${gh_log}"
  _setup_mock_gh "${tmpdir}/mock-bin" "${gh_log}"

  local exit_code=0
  push_with_workflow_fallback "feature-branch" "origin/main" "42" "test/repo" 2>/dev/null || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: push_with_workflow_fallback should return 0 after fallback, got ${exit_code}"
    export PATH="${original_path}"
    rm -rf "${tmpdir}"
    return 1
  fi

  # Verify push succeeded (after removing workflow files)
  local local_head remote_head
  local_head="$(git rev-parse HEAD)"
  remote_head="$(git rev-parse "origin/feature-branch" 2>/dev/null || echo "")"
  if [[ "${local_head}" != "${remote_head}" ]]; then
    echo "FAIL: branch should have been pushed after workflow removal"
    export PATH="${original_path}"
    rm -rf "${tmpdir}"
    return 1
  fi

  # Verify workflow files were removed
  if has_workflow_changes "origin/main"; then
    echo "FAIL: workflow changes should have been removed"
    export PATH="${original_path}"
    rm -rf "${tmpdir}"
    return 1
  fi

  # Verify gh was called to post a comment
  if [[ ! -s "${gh_log}" ]]; then
    echo "FAIL: gh should have been called to post a comment"
    export PATH="${original_path}"
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! grep -q "issue comment" "${gh_log}"; then
    echo "FAIL: gh should have been called with 'issue comment', got: $(cat "${gh_log}")"
    export PATH="${original_path}"
    rm -rf "${tmpdir}"
    return 1
  fi

  # Verify the removal commit exists
  local last_commit
  last_commit="$(git log -1 --format="%s")"
  if [[ "${last_commit}" != *"remove workflow changes"* ]]; then
    echo "FAIL: expected removal commit, got: ${last_commit}"
    export PATH="${original_path}"
    rm -rf "${tmpdir}"
    return 1
  fi

  export PATH="${original_path}"
  rm -rf "${tmpdir}"
  echo "PASS: push_with_workflow_fallback handles workflow rejection correctly"
}

test_push_fallback_updates_existing_comment() {
  local tmpdir
  tmpdir="$(_create_repo_with_workflow_changes)"
  cd "${tmpdir}/workspace"

  # Install pre-receive hook that rejects workflow files
  _install_workflow_rejection_hook "${tmpdir}/remote.git"

  # Set up mock gh that returns an existing comment ID for the API call
  local original_path="${PATH}"
  local gh_log="${tmpdir}/gh-calls.log"
  touch "${gh_log}"
  local mock_dir="${tmpdir}/mock-bin"
  mkdir -p "${mock_dir}"
  cat > "${mock_dir}/gh" <<MOCK
#!/bin/bash
echo "\$*" >> "${gh_log}"
# Return a comment ID when checking for existing workflow patch comments
if [[ "\$*" == *"ralph-comment-workflow-patch"* ]]; then
  echo "12345"
else
  echo "mock-ok"
fi
MOCK
  chmod +x "${mock_dir}/gh"
  export PATH="${mock_dir}:${PATH}"

  local exit_code=0
  push_with_workflow_fallback "feature-branch" "origin/main" "42" "test/repo" 2>/dev/null || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: push_with_workflow_fallback should return 0, got ${exit_code}"
    export PATH="${original_path}"
    rm -rf "${tmpdir}"
    return 1
  fi

  # Verify gh was called with PATCH to update existing comment
  if ! grep -q "PATCH" "${gh_log}"; then
    echo "FAIL: gh should have been called with PATCH to update existing comment, calls: $(cat "${gh_log}")"
    export PATH="${original_path}"
    rm -rf "${tmpdir}"
    return 1
  fi

  export PATH="${original_path}"
  rm -rf "${tmpdir}"
  echo "PASS: push_with_workflow_fallback updates existing patch comment"
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
  test_push_fallback_already_pushed || failed=$((failed + 1))
  test_push_fallback_normal_push || failed=$((failed + 1))
  test_push_fallback_handles_workflow_rejection || failed=$((failed + 1))
  test_push_fallback_updates_existing_comment || failed=$((failed + 1))

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
