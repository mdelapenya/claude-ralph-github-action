#!/usr/bin/env bash
# setup.sh - Test workspace and environment setup utilities

set -euo pipefail

# Create an isolated test workspace with a git repo and a bare remote
# Prints the workspace path to stdout
create_test_workspace() {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Create a bare repo to act as the remote (so `git push` works)
  local bare_repo="${tmpdir}/remote.git"
  git init --bare -b main "${bare_repo}" > /dev/null 2>&1

  # Create the working repo
  local workspace="${tmpdir}/workspace"
  mkdir -p "${workspace}"
  cd "${workspace}"
  git init -b main > /dev/null 2>&1
  git config user.name "Test User"
  git config user.email "test@example.com"

  # Initial commit
  echo "# Test" > README.md
  git add README.md
  git commit -m "Initial commit" > /dev/null 2>&1

  # Wire up the bare repo as origin so push works
  git remote add origin "${bare_repo}"
  git push -u origin main > /dev/null 2>&1

  echo "${tmpdir}"
}

# Remove the test workspace
# Args: $1 = path returned by create_test_workspace
cleanup_test_workspace() {
  local workspace="$1"
  if [[ -n "${workspace}" && -d "${workspace}" ]]; then
    rm -rf "${workspace}"
  fi
}

# Set all environment variables needed by the real scripts
# Args: $1 = tmpdir (root returned by create_test_workspace)
setup_test_env() {
  local tmpdir="$1"
  local workspace="${tmpdir}/workspace"

  # Repo root for SCRIPTS_DIR / PROMPTS_DIR
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

  export SCRIPTS_DIR="${repo_root}/scripts"
  export PROMPTS_DIR="${repo_root}/prompts"

  export ANTHROPIC_API_KEY="test-key-not-real"
  export GITHUB_WORKSPACE="${workspace}"
  export GITHUB_REPOSITORY="test-owner/test-repo"
  export GITHUB_OUTPUT="${tmpdir}/github-output.txt"
  touch "${GITHUB_OUTPUT}"

  # Action inputs (defaults match action.yml)
  export INPUT_MAX_ITERATIONS="${INPUT_MAX_ITERATIONS:-5}"
  export INPUT_WORKER_MODEL="${INPUT_WORKER_MODEL:-sonnet}"
  export INPUT_REVIEWER_MODEL="${INPUT_REVIEWER_MODEL:-sonnet}"
  export INPUT_MAX_TURNS_WORKER="${INPUT_MAX_TURNS_WORKER:-30}"
  export INPUT_MAX_TURNS_REVIEWER="${INPUT_MAX_TURNS_REVIEWER:-30}"
  export INPUT_MERGE_STRATEGY="${INPUT_MERGE_STRATEGY:-pr}"
  export INPUT_WORKER_ALLOWED_TOOLS="${INPUT_WORKER_ALLOWED_TOOLS:-Bash,Read,Write,Edit,Glob,Grep,Task,WebFetch,WebSearch}"
  export INPUT_REVIEWER_TOOLS="${INPUT_REVIEWER_TOOLS:-Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,Task}"
  export INPUT_WORKER_TONE="${INPUT_WORKER_TONE:-}"
  export INPUT_REVIEWER_TONE="${INPUT_REVIEWER_TONE:-}"
  export INPUT_SECURITY_GATE_ENABLED="${INPUT_SECURITY_GATE_ENABLED:-true}"
  export INPUT_SECURITY_GATE_MODEL="${INPUT_SECURITY_GATE_MODEL:-sonnet}"
  export INPUT_MAX_TURNS_SECURITY_GATE="${INPUT_MAX_TURNS_SECURITY_GATE:-20}"
  export INPUT_SECURITY_GATE_TOOLS="${INPUT_SECURITY_GATE_TOOLS:-Bash,Read,Write,Glob,Grep}"
  export INPUT_SECURITY_GATE_TONE="${INPUT_SECURITY_GATE_TONE:-}"
  export RALPH_VERBOSE="${RALPH_VERBOSE:-false}"

  # Create event JSON
  create_event_json "${tmpdir}"
  export GITHUB_EVENT_PATH="${tmpdir}/event.json"
}

# Write a valid GitHub event JSON file
# Args: $1 = tmpdir to write event.json into
# Configurable via env vars:
#   MOCK_ISSUE_NUMBER      - issue number (default: 42)
#   MOCK_ISSUE_TITLE       - issue title
#   MOCK_ISSUE_BODY        - issue body
#   MOCK_EVENT_ACTION      - event action (default: "labeled")
#   MOCK_COMMENT_ID        - if set, includes a comment object in the event
create_event_json() {
  local tmpdir="$1"
  local issue_number="${MOCK_ISSUE_NUMBER:-42}"
  local issue_title="${MOCK_ISSUE_TITLE:-Test issue title}"
  local issue_body="${MOCK_ISSUE_BODY:-Test issue body with requirements}"
  local event_action="${MOCK_EVENT_ACTION:-labeled}"
  local comment_id="${MOCK_COMMENT_ID:-}"

  local comment_block=""
  if [[ -n "${comment_id}" ]]; then
    comment_block="$(cat <<COMMENT
  "comment": {
    "id": "${comment_id}",
    "user": {
      "login": "testuser",
      "type": "User"
    },
    "body": "Test comment body"
  },
COMMENT
)"
  fi

  local label_block=""
  if [[ "${event_action}" == "labeled" ]]; then
    label_block="$(cat <<LABEL
  "label": {
    "name": "ralph"
  },
LABEL
)"
  fi

  cat > "${tmpdir}/event.json" <<EOF
{
  "action": "${event_action}",
${label_block}
${comment_block}
  "issue": {
    "number": ${issue_number},
    "title": "${issue_title}",
    "body": "${issue_body}"
  },
  "repository": {
    "full_name": "test-owner/test-repo",
    "default_branch": "main"
  }
}
EOF
}

# Write a GitHub issue_comment event JSON for a /ralph-review slash command on a PR.
# This is the event produced when a user types "/ralph-review" as a PR comment.
# PR comments go through the issue_comment event with .issue.pull_request set.
# Args: $1 = tmpdir to write into
#       $2 = pr number (default: 999)
#       $3 = issue number (default: 42)
#       $4 = command body (default: "/ralph-review")
create_ralph_review_slash_command_event_json() {
  local tmpdir="$1"
  local pr_number="${2:-999}"
  local issue_number="${3:-42}"
  local command_body="${4:-/ralph-review}"

  cat > "${tmpdir}/ralph-review-event.json" <<EOF
{
  "action": "created",
  "comment": {
    "id": 1001,
    "user": {
      "login": "reviewer",
      "type": "User"
    },
    "body": "${command_body}"
  },
  "issue": {
    "number": ${pr_number},
    "pull_request": {
      "url": "https://api.github.com/repos/test-owner/test-repo/pulls/${pr_number}",
      "html_url": "https://github.com/test-owner/test-repo/pull/${pr_number}"
    }
  },
  "repository": {
    "full_name": "test-owner/test-repo",
    "default_branch": "main"
  }
}
EOF
}

# Write a GitHub pull_request_review event JSON for a /ralph-review slash command
# submitted via the Approve/Comment/Request Changes review form.
# Args: $1 = tmpdir to write into
#       $2 = pr number (default: 999)
#       $3 = branch name (default: "ralph/issue-42")
#       $4 = review body (default: "/ralph-review")
#       $5 = review state (default: "commented")
create_ralph_review_pr_review_event_json() {
  local tmpdir="$1"
  local pr_number="${2:-999}"
  local branch="${3:-ralph/issue-42}"
  local review_body="${4:-/ralph-review}"
  local review_state="${5:-commented}"

  cat > "${tmpdir}/pr-review-event.json" <<EOF
{
  "action": "submitted",
  "review": {
    "id": 2001,
    "user": {
      "login": "reviewer",
      "type": "User"
    },
    "body": "${review_body}",
    "state": "${review_state}"
  },
  "pull_request": {
    "number": ${pr_number},
    "head": {
      "ref": "${branch}"
    },
    "html_url": "https://github.com/test-owner/test-repo/pull/${pr_number}"
  },
  "repository": {
    "full_name": "test-owner/test-repo",
    "default_branch": "main"
  }
}
EOF
}

export -f create_test_workspace
export -f cleanup_test_workspace
export -f setup_test_env
export -f create_event_json
export -f create_ralph_review_slash_command_event_json
export -f create_ralph_review_pr_review_event_json
