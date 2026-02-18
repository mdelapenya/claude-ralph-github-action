#!/usr/bin/env bash
# mocks.sh - Mock binaries for integration tests
#
# Creates mock `claude` and `gh` executables in a temp bin directory
# and prepends it to PATH so real scripts pick them up.
#
# Configurable via env vars:
#   MOCK_REVIEW_DECISION  - "SHIP" (default) or "REVISE"
#   MOCK_WORKER_FAIL      - if "true", mock claude exits 1 for worker calls
#   MOCK_MERGE_STRATEGY   - if "squash-merge", reviewer writes merge-commit.txt

set -euo pipefail

_MOCK_BIN_DIR=""
_MOCK_ORIGINAL_PATH=""

# Create mock binaries and prepend to PATH
setup_mock_binaries() {
  _MOCK_BIN_DIR="$(mktemp -d)"
  _MOCK_ORIGINAL_PATH="${PATH}"
  export PATH="${_MOCK_BIN_DIR}:${PATH}"

  _create_mock_claude
  _create_mock_gh
}

# Restore original PATH and clean up
teardown_mock_binaries() {
  if [[ -n "${_MOCK_ORIGINAL_PATH}" ]]; then
    export PATH="${_MOCK_ORIGINAL_PATH}"
  fi
  if [[ -n "${_MOCK_BIN_DIR}" && -d "${_MOCK_BIN_DIR}" ]]; then
    rm -rf "${_MOCK_BIN_DIR}"
  fi
}

# Create the mock claude binary
_create_mock_claude() {
  cat > "${_MOCK_BIN_DIR}/claude" <<'MOCK_CLAUDE'
#!/usr/bin/env bash
# Mock claude CLI for integration tests
#
# Determines worker vs reviewer by inspecting the prompt argument
# (the last positional arg passed by worker.sh / reviewer.sh).

set -euo pipefail

# Extract the prompt text (last argument)
prompt="${!#}"

# Check reviewer FIRST — the reviewer prompt contains "worker" (in "Review
# the worker's changes"), so checking worker first would misroute it.
if [[ "${prompt}" == *"You are the reviewer"* ]] || [[ "${prompt}" == *"Review the worker"* ]]; then
  # --- Reviewer mode ---
  decision="${MOCK_REVIEW_DECISION:-SHIP}"

  echo "${decision}" > .ralph/review-result.txt

  if [[ "${decision}" == "SHIP" ]]; then
    echo "feat: add worker output" > .ralph/pr-title.txt

    # Handle merge strategy
    if [[ "${MOCK_MERGE_STRATEGY:-pr}" == "squash-merge" ]]; then
      # Simulate squash-merge: write a fake merge commit SHA
      echo "abc123def456" > .ralph/merge-commit.txt
      echo "Mock reviewer: SHIP with squash-merge"
    else
      # Simulate PR creation: push branch and write PR URL
      git push origin HEAD 2>/dev/null || true
      echo "https://github.com/test/repo/pull/999" > .ralph/pr-url.txt
      echo "Mock reviewer: SHIP with PR"
    fi
  else
    echo "Please fix the issues found in the code." > .ralph/review-feedback.txt
    echo "Mock reviewer: REVISE"
  fi

elif [[ "${prompt}" == *"Work on the task"* ]] || [[ "${prompt}" == *"You are on iteration"* ]]; then
  # --- Worker mode ---
  if [[ "${MOCK_WORKER_FAIL:-false}" == "true" ]]; then
    echo "Mock worker: simulating failure"
    exit 1
  fi

  iteration="1"
  if [[ -f .ralph/iteration.txt ]]; then
    iteration="$(cat .ralph/iteration.txt)"
  fi

  # Create a file and commit it (simulating worker making changes)
  echo "change from iteration ${iteration}" > "worker-output-${iteration}.txt"
  git add "worker-output-${iteration}.txt"
  git commit -m "feat: add worker output for iteration ${iteration}"

  # Write work summary
  echo "## Iteration ${iteration}" > .ralph/work-summary.txt
  echo "- Added worker-output-${iteration}.txt" >> .ralph/work-summary.txt

  echo "Mock worker: committed changes for iteration ${iteration}"

else
  echo "Mock claude: unknown prompt context"
  echo "Prompt was: ${prompt}"
  exit 1
fi
MOCK_CLAUDE

  chmod +x "${_MOCK_BIN_DIR}/claude"
}

# Create the mock gh binary
_create_mock_gh() {
  cat > "${_MOCK_BIN_DIR}/gh" <<'MOCK_GH'
#!/usr/bin/env bash
# Mock gh CLI for integration tests

set -euo pipefail

# Handle common gh subcommands
case "${1:-}" in
  pr)
    case "${2:-}" in
      create)
        echo "https://github.com/test/repo/pull/999"
        ;;
      list)
        # Return empty JSON array (no existing PRs)
        echo "[]"
        ;;
      edit)
        echo "PR updated"
        ;;
      *)
        echo "mock gh pr: unknown subcommand ${2:-}"
        ;;
    esac
    ;;
  issue)
    case "${2:-}" in
      comment)
        echo "Comment posted"
        ;;
      view)
        # Return empty comments
        echo ""
        ;;
      *)
        echo "mock gh issue: unknown subcommand ${2:-}"
        ;;
    esac
    ;;
  repo)
    case "${2:-}" in
      view)
        echo "main"
        ;;
      *)
        echo "mock gh repo: unknown subcommand ${2:-}"
        ;;
    esac
    ;;
  api)
    # Log API calls for test verification
    log_file="${MOCK_GH_API_LOG:-/dev/null}"
    echo "gh api $*" >> "${log_file}"
    # Return a minimal JSON response for reactions
    echo '{"id":1,"content":"+1"}'
    ;;
  *)
    echo "mock gh: unknown command ${1:-}"
    ;;
esac
MOCK_GH

  chmod +x "${_MOCK_BIN_DIR}/gh"
}

export -f setup_mock_binaries
export -f teardown_mock_binaries
export -f _create_mock_claude
export -f _create_mock_gh
