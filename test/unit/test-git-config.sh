#!/usr/bin/env bash
# test-git-config.sh - Unit tests for git author configuration in entrypoint.sh

set -euo pipefail

# Test that git config uses INPUT_COMMIT_AUTHOR_NAME and INPUT_COMMIT_AUTHOR_EMAIL
# This exercises the git configuration logic from entrypoint.sh

test_git_config_default_values() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "${tmpdir}"
  git init -b main > /dev/null 2>&1

  # Simulate defaults from action.yml (these are what GitHub Actions passes)
  local INPUT_COMMIT_AUTHOR_NAME="claude-ralph[bot]"
  local INPUT_COMMIT_AUTHOR_EMAIL="claude-ralph[bot]@users.noreply.github.com"

  # Apply the same git config logic as entrypoint.sh
  git config user.name "${INPUT_COMMIT_AUTHOR_NAME}"
  git config user.email "${INPUT_COMMIT_AUTHOR_EMAIL}"

  local actual_name actual_email
  actual_name="$(git config user.name)"
  actual_email="$(git config user.email)"

  if [[ "${actual_name}" != "claude-ralph[bot]" ]]; then
    echo "FAIL: Expected user.name='claude-ralph[bot]', got='${actual_name}'"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if [[ "${actual_email}" != "claude-ralph[bot]@users.noreply.github.com" ]]; then
    echo "FAIL: Expected user.email='claude-ralph[bot]@users.noreply.github.com', got='${actual_email}'"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  cd - > /dev/null
  rm -rf "${tmpdir}"
  echo "PASS: git config with default bot identity works correctly"
}

test_git_config_custom_values() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "${tmpdir}"
  git init -b main > /dev/null 2>&1

  # Simulate custom user-provided values
  local INPUT_COMMIT_AUTHOR_NAME="Custom Bot"
  local INPUT_COMMIT_AUTHOR_EMAIL="custom-bot@example.com"

  # Apply the same git config logic as entrypoint.sh
  git config user.name "${INPUT_COMMIT_AUTHOR_NAME}"
  git config user.email "${INPUT_COMMIT_AUTHOR_EMAIL}"

  local actual_name actual_email
  actual_name="$(git config user.name)"
  actual_email="$(git config user.email)"

  if [[ "${actual_name}" != "Custom Bot" ]]; then
    echo "FAIL: Expected user.name='Custom Bot', got='${actual_name}'"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  if [[ "${actual_email}" != "custom-bot@example.com" ]]; then
    echo "FAIL: Expected user.email='custom-bot@example.com', got='${actual_email}'"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  cd - > /dev/null
  rm -rf "${tmpdir}"
  echo "PASS: git config with custom author identity works correctly"
}

test_git_config_commits_use_configured_identity() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "${tmpdir}"
  git init -b main > /dev/null 2>&1

  local INPUT_COMMIT_AUTHOR_NAME="Ralph Test Bot"
  local INPUT_COMMIT_AUTHOR_EMAIL="ralph-test@example.com"

  git config user.name "${INPUT_COMMIT_AUTHOR_NAME}"
  git config user.email "${INPUT_COMMIT_AUTHOR_EMAIL}"

  # Create a commit and verify the author identity
  echo "test" > test.txt
  git add test.txt
  git commit -m "test commit" > /dev/null 2>&1

  local commit_author
  commit_author="$(git log -1 --format='%an <%ae>')"

  if [[ "${commit_author}" != "Ralph Test Bot <ralph-test@example.com>" ]]; then
    echo "FAIL: Expected commit author='Ralph Test Bot <ralph-test@example.com>', got='${commit_author}'"
    cd - > /dev/null
    rm -rf "${tmpdir}"
    return 1
  fi

  cd - > /dev/null
  rm -rf "${tmpdir}"
  echo "PASS: commits use configured author identity"
}

# Run all tests
main() {
  local failed=0

  test_git_config_default_values || failed=$((failed + 1))
  test_git_config_custom_values || failed=$((failed + 1))
  test_git_config_commits_use_configured_identity || failed=$((failed + 1))

  echo ""
  if [[ ${failed} -eq 0 ]]; then
    echo "✅ All git config unit tests passed"
    return 0
  else
    echo "❌ ${failed} git config unit test(s) failed"
    return 1
  fi
}

main "$@"
