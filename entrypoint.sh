#!/usr/bin/env bash
# entrypoint.sh - Main orchestration for the Claude Ralph GitHub Action
#
# This script:
# 1. Extracts issue data from the GitHub event
# 2. Sets up git and the working branch
# 3. Initializes .ralph/ state
# 4. Runs the ralph loop
# 5. Pushes and creates/updates a PR
# 6. Comments on the issue

set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-/scripts}"
source "${SCRIPTS_DIR}/state.sh"

# --- Early input validation ---
# Check ANTHROPIC_API_KEY
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "❌ Error: ANTHROPIC_API_KEY environment variable is not set or is empty"
  echo "   Fix: Set ANTHROPIC_API_KEY to a valid Anthropic API key"
  exit 1
fi

# Check GITHUB_EVENT_PATH
if [[ -z "${GITHUB_EVENT_PATH:-}" ]]; then
  echo "❌ Error: GITHUB_EVENT_PATH environment variable is not set"
  echo "   Fix: This action must run in a GitHub Actions workflow context"
  exit 1
fi

if [[ ! -f "${GITHUB_EVENT_PATH}" ]]; then
  echo "❌ Error: GITHUB_EVENT_PATH does not point to an existing file: ${GITHUB_EVENT_PATH}"
  echo "   Fix: Ensure the GitHub event file exists at the specified path"
  exit 1
fi

# Check GITHUB_WORKSPACE
if [[ -z "${GITHUB_WORKSPACE:-}" ]]; then
  echo "❌ Error: GITHUB_WORKSPACE environment variable is not set"
  echo "   Fix: This action must run in a GitHub Actions workflow context"
  exit 1
fi

if [[ ! -d "${GITHUB_WORKSPACE}" ]]; then
  echo "❌ Error: GITHUB_WORKSPACE is not a directory: ${GITHUB_WORKSPACE}"
  echo "   Fix: Ensure GITHUB_WORKSPACE points to a valid directory"
  exit 1
fi

# Check jq availability
if ! command -v jq &> /dev/null; then
  echo "❌ Error: jq command not found on PATH"
  echo "   Fix: Install jq in the Docker image or runner environment"
  exit 1
fi

# Detect whether this is a /ralph-review slash command on a PR comment.
# PR comments come through the issue_comment event with .issue.pull_request set.
# The slash command avoids triggering on every review event and gives the user
# explicit control over when to re-run the loop.
readonly DEFAULT_RALPH_REVIEW_CMD="/ralph-review"
PR_REVIEW_EVENT=false
PR_NUMBER=""
PR_BRANCH=""
TEMP_ISSUE_NUMBER=""
RALPH_REVIEW_CMD="${INPUT_RALPH_REVIEW_COMMAND:-${DEFAULT_RALPH_REVIEW_CMD}}"
# Guard: if the input is explicitly set to "" the :- default above does not fire,
# which would make every PR comment match the command.
if [[ -z "${RALPH_REVIEW_CMD}" ]]; then
  echo "⚠️  Warning: ralph_review_command is empty, defaulting to '${DEFAULT_RALPH_REVIEW_CMD}'"
  RALPH_REVIEW_CMD="${DEFAULT_RALPH_REVIEW_CMD}"
fi
RALPH_REVIEW_ARGS=""

# Helper: extract optional arguments after the slash command (space or newline separator)
_extract_ralph_review_args() {
  local body="$1"
  if [[ "${body}" == "${RALPH_REVIEW_CMD} "* ]]; then
    RALPH_REVIEW_ARGS="${body#"${RALPH_REVIEW_CMD} "}"
  elif [[ "${body}" == "${RALPH_REVIEW_CMD}"$'\n'* ]]; then
    RALPH_REVIEW_ARGS="${body#"${RALPH_REVIEW_CMD}"$'\n'}"
  fi
  if [[ -n "${RALPH_REVIEW_ARGS}" ]]; then
    echo "📝 Ralph review args: ${RALPH_REVIEW_ARGS}"
  fi
}

# Helper: extract issue number from branch name and validate
_extract_issue_from_branch() {
  local branch="$1"
  if [[ "${branch}" =~ ralph/issue-([0-9]+) ]]; then
    TEMP_ISSUE_NUMBER="${BASH_REMATCH[1]}"
  fi
  if [[ -z "${TEMP_ISSUE_NUMBER}" ]]; then
    echo "❌ Error: Cannot determine issue number from PR branch: ${branch}"
    echo "   Fix: The PR branch must follow the pattern 'ralph/issue-NNN'"
    exit 1
  fi
}

# Helper: check if a body matches the ralph review slash command
_matches_ralph_review_cmd() {
  local body="$1"
  [[ "${body}" == "${RALPH_REVIEW_CMD}" || \
     "${body}" == "${RALPH_REVIEW_CMD} "* || \
     "${body}" == "${RALPH_REVIEW_CMD}"$'\n'* ]]
}

if [[ "${GITHUB_EVENT_NAME:-}" == "issue_comment" ]]; then
  COMMENT_BODY="$(jq -r '.comment.body // ""' "${GITHUB_EVENT_PATH}")"
  IS_PR_COMMENT="$(jq -r '.issue.pull_request // empty' "${GITHUB_EVENT_PATH}")"
  # Match exact command, command + space args, or command + newline args.
  # A bare prefix match (e.g. == "*") would accept "/ralph-review2" as valid.
  if [[ -n "${IS_PR_COMMENT}" ]] && _matches_ralph_review_cmd "${COMMENT_BODY}"; then
    PR_REVIEW_EVENT=true
    PR_NUMBER="$(jq -r '.issue.number' "${GITHUB_EVENT_PATH}")"
    GH_PR_ERR="$(mktemp)"
    PR_BRANCH="$(gh pr view "${PR_NUMBER}" --repo "${GITHUB_REPOSITORY}" --json headRefName --jq '.headRefName' 2>"${GH_PR_ERR}" || true)"
    if [[ -z "${PR_BRANCH}" ]]; then
      echo "❌ Error: Failed to fetch branch for PR #${PR_NUMBER} via gh pr view"
      if [[ -z "${GH_TOKEN:-}" ]]; then
        echo "   Fix: GH_TOKEN is not set — ensure the github_token input is provided"
      else
        GH_ERR_MSG="$(cat "${GH_PR_ERR}" 2>/dev/null || true)"
        echo "   gh error: ${GH_ERR_MSG:0:200}"
        echo "   Fix: Ensure the workflow has 'pull-requests: read' permission (or 'repo' scope if using a PAT) for ${GITHUB_REPOSITORY}"
      fi
      rm -f "${GH_PR_ERR}"
      exit 1
    fi
    rm -f "${GH_PR_ERR}"
    _extract_ralph_review_args "${COMMENT_BODY}"
    _extract_issue_from_branch "${PR_BRANCH}"
  fi
elif [[ "${GITHUB_EVENT_NAME:-}" == "pull_request_review" ]]; then
  # PR review submitted via the Approve/Comment/Request Changes form.
  # The review body is in .review.body (not .comment.body).
  REVIEW_BODY="$(jq -r '.review.body // ""' "${GITHUB_EVENT_PATH}")"
  if _matches_ralph_review_cmd "${REVIEW_BODY}"; then
    PR_REVIEW_EVENT=true
    PR_NUMBER="$(jq -r '.pull_request.number' "${GITHUB_EVENT_PATH}")"
    # The branch is available directly in the event payload for pull_request_review
    PR_BRANCH="$(jq -r '.pull_request.head.ref' "${GITHUB_EVENT_PATH}")"
    if [[ -z "${PR_BRANCH}" || "${PR_BRANCH}" == "null" ]]; then
      echo "❌ Error: Failed to extract branch from pull_request_review event for PR #${PR_NUMBER}"
      echo "   Fix: Ensure the event payload contains .pull_request.head.ref"
      exit 1
    fi
    _extract_ralph_review_args "${REVIEW_BODY}"
    _extract_issue_from_branch "${PR_BRANCH}"
  fi
fi

if [[ "${PR_REVIEW_EVENT}" == "false" ]]; then
  TEMP_ISSUE_NUMBER="$(jq -r '.issue.number // empty' "${GITHUB_EVENT_PATH}" 2>/dev/null || echo "")"
  if [[ -z "${TEMP_ISSUE_NUMBER}" ]]; then
    echo "❌ Error: Event file does not contain a valid issue number"
    echo "   Fix: Ensure this action is triggered by an issue event"
    exit 1
  fi
fi

if ! [[ "${TEMP_ISSUE_NUMBER}" =~ ^[0-9]+$ ]]; then
  echo "❌ Error: Issue number is not numeric: ${TEMP_ISSUE_NUMBER}"
  echo "   Fix: Ensure the event file contains a valid issue.number field"
  exit 1
fi

# --- Extract issue data from GitHub event ---
EVENT_PATH="${GITHUB_EVENT_PATH}"
EVENT_ACTION="$(jq -r '.action // ""' "${EVENT_PATH}")"

if [[ "${PR_REVIEW_EVENT}" == "true" ]]; then
  # PR review event: fetch issue data from GitHub API using the issue number
  # extracted from the branch name (the issue JSON is not present in this event type)
  echo "🔗 PR review event: PR #${PR_NUMBER} on branch ${PR_BRANCH}"
  echo "📋 Fetching data for issue #${TEMP_ISSUE_NUMBER}..."
  ISSUE_NUMBER="${TEMP_ISSUE_NUMBER}"
  ISSUE_TITLE="$(gh issue view "${ISSUE_NUMBER}" --json title --jq '.title' 2>/dev/null || echo "Issue #${ISSUE_NUMBER}")"
  ISSUE_BODY="$(gh issue view "${ISSUE_NUMBER}" --json body --jq '.body // ""' 2>/dev/null || echo "")"
  IS_PULL_REQUEST=""
  # For pull_request_review events, use the review ID; for issue_comment events, use comment ID
  EVENT_COMMENT_ID="$(jq -r '.comment.id // .review.id // ""' "${EVENT_PATH}")"
else
  ISSUE_NUMBER="$(jq -r '.issue.number' "${EVENT_PATH}")"
  ISSUE_TITLE="$(jq -r '.issue.title' "${EVENT_PATH}")"
  ISSUE_BODY="$(jq -r '.issue.body // ""' "${EVENT_PATH}")"
  IS_PULL_REQUEST="$(jq -r '.issue.pull_request // empty' "${EVENT_PATH}")"
  EVENT_COMMENT_ID="$(jq -r '.comment.id // ""' "${EVENT_PATH}")"
fi

# --- Fetch all issue comments to compound the context ---
# Comments provide additional context for agents. New comments on a labeled issue
# automatically trigger a Ralph run via the issue_comment.created workflow event.
echo "💬 Fetching issue comments..."
ISSUE_COMMENTS=""
if command -v gh &> /dev/null; then
  # Fetch comments from the issue, excluding Ralph-authored comments (identified by marker)
  ISSUE_COMMENTS="$(gh issue view "${ISSUE_NUMBER}" --json comments --jq '.comments[] | select(.body | contains("<!-- ralph-comment-") | not) | "## Comment by @\(.author.login) on \(.createdAt)\n\n\(.body)\n"' 2>/dev/null || echo "")"
  if [[ -n "${ISSUE_COMMENTS}" ]]; then
    echo "✅ Found $(echo "${ISSUE_COMMENTS}" | grep -c "^## Comment by" || echo 0) user comments"
  else
    echo "ℹ️  No user comments found on issue"
  fi
else
  echo "⚠️  gh command not available, skipping comment fetch"
fi

# --- Fetch PR review comments when triggered by a PR review event ---
# Inline code comments and overall review bodies are appended to the task context
# so the worker agent can address the specific feedback from the PR reviewer.
if [[ "${PR_REVIEW_EVENT}" == "true" ]] && command -v gh &> /dev/null; then
  echo "💬 Fetching PR #${PR_NUMBER} review comments..."
  PR_INLINE_COMMENTS="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/comments" \
    --jq '.[] | "### Inline comment by @\(.user.login) on `\(.path)`:\(.line // .original_line // "?"):\n\n\(.body)\n"' \
    2>/dev/null || echo "")"
  PR_REVIEWS="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/reviews" \
    --jq '.[] | select(.body != null and .body != "") | "### Review by @\(.user.login) (\(.state)):\n\n\(.body)\n"' \
    2>/dev/null || echo "")"
  if [[ -n "${PR_INLINE_COMMENTS}" || -n "${PR_REVIEWS}" || -n "${RALPH_REVIEW_ARGS}" ]]; then
    PR_REVIEW_CONTEXT="# PR Review Feedback (PR #${PR_NUMBER})"$'\n'
    PR_REVIEW_CONTEXT+="This run was triggered by the ${RALPH_REVIEW_CMD} slash command on PR #${PR_NUMBER} (branch: ${PR_BRANCH})."$'\n'
    if [[ -n "${RALPH_REVIEW_ARGS}" ]]; then
      PR_REVIEW_CONTEXT+=$'\n## Reviewer Instructions\n\n'"${RALPH_REVIEW_ARGS}"$'\n'
    fi
    if [[ -n "${PR_INLINE_COMMENTS}" ]]; then
      PR_REVIEW_CONTEXT+=$'\n## Inline Code Comments\n\n'"${PR_INLINE_COMMENTS}"
    fi
    if [[ -n "${PR_REVIEWS}" ]]; then
      PR_REVIEW_CONTEXT+=$'\n## Overall Reviews\n\n'"${PR_REVIEWS}"
    fi
    echo "✅ Found PR review context for PR #${PR_NUMBER}"
    if [[ -n "${ISSUE_COMMENTS}" ]]; then
      ISSUE_COMMENTS+=$'\n\n'"${PR_REVIEW_CONTEXT}"
    else
      ISSUE_COMMENTS="${PR_REVIEW_CONTEXT}"
    fi
  else
    echo "ℹ️  No PR review comments found for PR #${PR_NUMBER}"
  fi
fi

# --- Reject pull requests labeled with ralph (not PR review events) ---
if [[ -n "${IS_PULL_REQUEST}" ]]; then
  echo "⚠️  Ralph was triggered on a pull request (#${ISSUE_NUMBER}), not an issue. Skipping."
  gh issue comment "${ISSUE_NUMBER}" --body "🤖 **Ralph** can only work on issues, not pull requests. Please label an issue instead." || true
  exit 0
fi

# Auto-detect base branch if not provided
BASE_BRANCH="${INPUT_BASE_BRANCH:-}"
if [[ -z "${BASE_BRANCH}" ]]; then
  echo "🔍 Auto-detecting repository default branch..."
  BASE_BRANCH="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main")"
  echo "✅ Detected default branch: ${BASE_BRANCH}"
fi
BRANCH_NAME="ralph/issue-${ISSUE_NUMBER}"
echo "🤖 === Claude Ralph GitHub Action ==="
echo "📋 Issue: #${ISSUE_NUMBER} - ${ISSUE_TITLE}"
echo "🌿 Branch: ${BRANCH_NAME}"
echo "🏠 Base: ${BASE_BRANCH}"

# --- Configure git ---
git config --global user.name "${INPUT_COMMIT_AUTHOR_NAME}"
git config --global user.email "${INPUT_COMMIT_AUTHOR_EMAIL}"
# Docker runs as a different user than the checkout owner; mark workspace as safe
git config --global --add safe.directory "${GITHUB_WORKSPACE}"

# --- Set up working branch ---
WORKSPACE="${GITHUB_WORKSPACE}"
cd "${WORKSPACE}" || { echo "❌ Error: cannot cd to GITHUB_WORKSPACE: ${WORKSPACE}"; exit 1; }

# Simplified: agents will handle branch context
git fetch origin
if git ls-remote --heads origin "${BRANCH_NAME}" | grep -q "${BRANCH_NAME}"; then
  echo "🔄 Branch ${BRANCH_NAME} exists, checking out..."
  git checkout -B "${BRANCH_NAME}" "origin/${BRANCH_NAME}"
else
  echo "🌱 Creating new branch ${BRANCH_NAME} from ${BASE_BRANCH}..."
  git checkout -B "${BRANCH_NAME}" "origin/${BASE_BRANCH}"
fi

# --- Initialize state ---
state_init
state_write_task "${ISSUE_TITLE}" "${ISSUE_BODY}" "${ISSUE_COMMENTS}"
state_write_issue_number "${ISSUE_NUMBER}"
state_write_event_info "${EVENT_ACTION}" "${EVENT_COMMENT_ID}"
state_write_iteration "0"

# --- Write run provenance for agent commit trailers ---
{
  echo "run_id=${GITHUB_RUN_ID:-unknown}"
  echo "run_url=https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-unknown}"
  echo "base_sha=${GITHUB_SHA:-unknown}"
  echo "repository=${GITHUB_REPOSITORY:-unknown}"
  echo "workflow=${GITHUB_WORKFLOW:-unknown}"
  echo "worker_model=${INPUT_WORKER_MODEL:-sonnet}"
  echo "reviewer_model=${INPUT_REVIEWER_MODEL:-sonnet}"
  echo "commit_author_name=${INPUT_COMMIT_AUTHOR_NAME:-claude-ralph[bot]}"
  echo "commit_author_email=${INPUT_COMMIT_AUTHOR_EMAIL:-claude-ralph[bot]@users.noreply.github.com}"
} > "${RALPH_DIR}/run-info.txt"

# --- Validate merge_strategy before writing pr-info ---
merge_strategy="${INPUT_MERGE_STRATEGY:-pr}"
if [[ "${merge_strategy}" != "pr" && "${merge_strategy}" != "squash-merge" ]]; then
  echo "⚠️  Warning: invalid merge_strategy '${merge_strategy}', defaulting to 'pr'"
  merge_strategy="pr"
fi
if [[ "${merge_strategy}" == "squash-merge" ]]; then
  echo "⚠️  WARNING: merge_strategy=squash-merge is configured."
  echo "   The reviewer agent will push directly to the default branch on SHIP,"
  echo "   bypassing branch protection rules and PR review requirements."
  echo "   Ensure this is intentional for this repository."
fi

# --- Write PR info for the reviewer agent ---
{
  echo "repo=${GITHUB_REPOSITORY}"
  echo "branch=${BRANCH_NAME}"
  echo "issue_title=${ISSUE_TITLE}"
  echo "merge_strategy=${merge_strategy}"
  echo "default_branch=${INPUT_DEFAULT_BRANCH:-${BASE_BRANCH}}"
  # Check if a PR already exists for this branch
  existing_pr_number="$(gh pr list --repo "${GITHUB_REPOSITORY}" --head "${BRANCH_NAME}" --json number --jq '.[0].number' 2>/dev/null || echo "")"
  if [[ -n "${existing_pr_number}" ]]; then
    echo "pr_number=${existing_pr_number}"
  else
    echo "pr_number="
  fi
} > "${RALPH_DIR}/pr-info.txt"

# --- Comment on issue to indicate start (delegated to reviewer) ---
# Initial comment now posted by the reviewer agent on first iteration

# --- Run the Ralph loop ---
echo ""
echo "🔁 === Starting Ralph Loop ==="

loop_exit=0
"${SCRIPTS_DIR}/ralph-loop.sh" || loop_exit=$?

# Determine final status
final_status="$(state_read_final_status)"
if [[ -z "${final_status}" ]]; then
  case ${loop_exit} in
    0) final_status="SHIPPED" ;;
    2) final_status="MAX_ITERATIONS" ;;
    *) final_status="ERROR" ;;
  esac
  state_write_final_status "${final_status}"
fi

iteration="$(state_read_iteration)"
echo ""
echo "🏁 === Ralph Loop Finished: ${final_status} (${iteration} iterations) ==="

# Branch cleanup, PR creation, issue commenting, merge handling, and branch push are now delegated to the reviewer agent
# Check if squash-merge was completed or if PR was created
effective_strategy="pr"
pr_url_or_sha=""
if [[ -f ".ralph/merge-commit.txt" ]]; then
  pr_url_or_sha="$(cat .ralph/merge-commit.txt)"
  if [[ -n "${pr_url_or_sha}" ]]; then
    effective_strategy="squash-merge"
    echo "✅ Squash-merge completed by reviewer: ${pr_url_or_sha}"
  fi
elif [[ -f ".ralph/pr-url.txt" ]]; then
  pr_url_or_sha="$(cat .ralph/pr-url.txt)"
  if [[ -n "${pr_url_or_sha}" ]]; then
    echo "✅ PR created/updated by reviewer: ${pr_url_or_sha}"
  fi
fi

# --- Write GitHub Step Summary ---
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Claude Ralph Run Summary"
    echo ""
    echo "| Field | Value |"
    echo "|-------|-------|"
    echo "| Status | \`${final_status}\` |"
    echo "| Iterations | ${iteration} |"
    echo "| Issue | [#${ISSUE_NUMBER}](https://github.com/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}) |"
    echo "| Worker Model | \`${INPUT_WORKER_MODEL:-sonnet}\` |"
    echo "| Reviewer Model | \`${INPUT_REVIEWER_MODEL:-sonnet}\` |"
    echo "| Run ID | [\`${GITHUB_RUN_ID:-unknown}\`](https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-}) |"
    if [[ -n "${pr_url_or_sha}" ]]; then
      echo "| Result | ${effective_strategy}: ${pr_url_or_sha} |"
    fi
    if [[ -f ".ralph/audit.log" ]]; then
      echo ""
      echo "### Phase Audit Log"
      echo '```'
      cat ".ralph/audit.log"
      echo '```'
    fi
  } >> "${GITHUB_STEP_SUMMARY}"
fi

# --- Set outputs ---
{
  echo "pr_url=${pr_url_or_sha}"
  echo "iterations=${iteration}"
  echo "final_status=${final_status}"
} >> "${GITHUB_OUTPUT}"

echo ""
echo "✅ === Done ==="
echo "📊 Status: ${final_status}"
echo "🔢 Iterations: ${iteration}"
if [[ -n "${pr_url_or_sha}" ]]; then
  echo "🔗 ${effective_strategy}: ${pr_url_or_sha}"
fi

# Exit with appropriate code
case "${final_status}" in
  SHIPPED)        exit 0 ;;
  MAX_ITERATIONS) exit 0 ;;  # Not a failure, just needs human review
  *)              exit 1 ;;
esac
