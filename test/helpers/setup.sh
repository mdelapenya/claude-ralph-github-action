#!/usr/bin/env bash
# setup.sh - Test setup utilities

create_test_workspace() {
  local tmpdir
  tmpdir="$(mktemp -d)"

  cd "${tmpdir}"
  git init -b main
  git config user.name "Test User"
  git config user.email "test@example.com"

  # Create initial commit
  echo "# Test" > README.md
  git add README.md
  git commit -m "Initial commit"

  echo "${tmpdir}"
}

cleanup_test_workspace() {
  local workspace="$1"
  rm -rf "${workspace}"
}

export -f create_test_workspace
export -f cleanup_test_workspace
