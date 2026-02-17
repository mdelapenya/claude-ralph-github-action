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

# Check issue number from event file
TEMP_ISSUE_NUMBER="$(jq -r '.issue.number // empty' "${GITHUB_EVENT_PATH}" 2>/dev/null || echo "")"
if [[ -z "${TEMP_ISSUE_NUMBER}" ]]; then
  echo "❌ Error: Event file does not contain a valid issue number"
  echo "   Fix: Ensure this action is triggered by an issue event"
  exit 1
fi

if ! [[ "${TEMP_ISSUE_NUMBER}" =~ ^[0-9]+$ ]]; then
  echo "❌ Error: Issue number is not numeric: ${TEMP_ISSUE_NUMBER}"
  echo "   Fix: Ensure the event file contains a valid issue.number field"
  exit 1
fi

# --- Extract issue data from GitHub event ---
EVENT_PATH="${GITHUB_EVENT_PATH}"
ISSUE_NUMBER="$(jq -r '.issue.number' "${EVENT_PATH}")"
ISSUE_TITLE="$(jq -r '.issue.title' "${EVENT_PATH}")"
ISSUE_BODY="$(jq -r '.issue.body // ""' "${EVENT_PATH}")"
IS_PULL_REQUEST="$(jq -r '.issue.pull_request // empty' "${EVENT_PATH}")"

# --- Fetch all issue comments to compound the context ---
# Comments provide additional context for agents. To trigger Ralph after adding a comment,
# edit the issue (e.g., update description or title). Ralph will fetch all comments automatically.
echo "💬 Fetching issue comments..."
ISSUE_COMMENTS=""
if command -v gh &> /dev/null; then
  # Fetch comments from the issue, excluding bot comments
  ISSUE_COMMENTS="$(gh issue view "${ISSUE_NUMBER}" --json comments --jq '.comments[] | select(.author.login != "claude-ralph[bot]") | "## Comment by @\(.author.login) on \(.createdAt)\n\n\(.body)\n"' 2>/dev/null || echo "")"
  if [[ -n "${ISSUE_COMMENTS}" ]]; then
    echo "✅ Found $(echo "${ISSUE_COMMENTS}" | grep -c "^## Comment by" || echo 0) user comments"
  else
    echo "ℹ️  No user comments found on issue"
  fi
else
  echo "⚠️  gh command not available, skipping comment fetch"
fi

# --- Reject pull requests ---
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
git config --global user.name "claude-ralph[bot]"
git config --global user.email "claude-ralph[bot]@users.noreply.github.com"
# Docker runs as a different user than the checkout owner; mark workspace as safe
git config --global --add safe.directory "${GITHUB_WORKSPACE}"

# --- Set up working branch ---
WORKSPACE="${GITHUB_WORKSPACE}"
cd "${WORKSPACE}"

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
state_write_iteration "0"

# --- Write PR info for the reviewer agent (validation delegated to reviewer) ---
{
  echo "repo=${GITHUB_REPOSITORY}"
  echo "branch=${BRANCH_NAME}"
  echo "issue_title=${ISSUE_TITLE}"
  echo "merge_strategy=${INPUT_MERGE_STRATEGY:-pr}"
  echo "default_branch=${INPUT_DEFAULT_BRANCH:-}"
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
