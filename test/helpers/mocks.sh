#!/usr/bin/env bash
# mocks.sh - Mock functions for claude and gh CLIs

# Mock claude CLI that simulates agent behavior
mock_claude_simple_success() {
  local prompt_file="$1"

  if [[ "${prompt_file}" == *"worker"* ]]; then
    # Simulate worker making a commit
    echo "test" > test-file.txt
    git add test-file.txt
    git commit -m "test: add test file"
    echo -e "## Iteration 1\n- Added test file" > .ralph/work-summary.txt
  elif [[ "${prompt_file}" == *"reviewer"* ]]; then
    # Simulate reviewer shipping
    echo "SHIP" > .ralph/review-result.txt
    echo "test: add test file" > .ralph/pr-title.txt
  fi
}

# Mock gh CLI for PR operations
mock_gh_pr_create() {
  echo "https://github.com/test/repo/pull/999"
}

# Export mocks
export -f mock_claude_simple_success
export -f mock_gh_pr_create
