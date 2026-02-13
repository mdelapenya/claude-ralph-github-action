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
source "${SCRIPTS_DIR}/pr-manager.sh"

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

BASE_BRANCH="${INPUT_BASE_BRANCH:-main}"
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

# Check if the ralph branch already exists on the remote
if git ls-remote --heads origin "${BRANCH_NAME}" | grep -q "${BRANCH_NAME}"; then
  echo "🔄 Branch ${BRANCH_NAME} exists, checking out and merging base..."
  git fetch origin "${BRANCH_NAME}"
  git checkout -B "${BRANCH_NAME}" "origin/${BRANCH_NAME}"
  # Merge base branch to pick up any new changes
  git fetch origin "${BASE_BRANCH}"
  git merge "origin/${BASE_BRANCH}" --no-edit || {
    echo "⚠️  Merge conflict with ${BASE_BRANCH}. Attempting to continue."
    git merge --abort 2>/dev/null || true
    # Reset to base and re-apply; this is a simplification
    echo "🔁 Resetting to base branch and re-running from scratch."
    git reset --hard "origin/${BASE_BRANCH}"
  }
else
  echo "🌱 Creating new branch ${BRANCH_NAME} from ${BASE_BRANCH}..."
  git checkout -B "${BRANCH_NAME}" "origin/${BASE_BRANCH}"
fi

# --- Initialize state ---
state_init
state_write_task "${ISSUE_TITLE}" "${ISSUE_BODY}"
state_write_issue_number "${ISSUE_NUMBER}"

# Preserve iteration count from previous runs (cross-run persistence)
current_iteration="$(state_read_iteration)"
if [[ -z "${current_iteration}" || "${current_iteration}" == "0" ]]; then
  state_write_iteration "0"
fi

state_commit "ralph: initialize state for issue #${ISSUE_NUMBER}"

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
  state_commit "ralph: set final status ${final_status}"
fi

iteration="$(state_read_iteration)"
echo ""
echo "🏁 === Ralph Loop Finished: ${final_status} (${iteration} iterations) ==="

# --- Push branch ---
echo ""
echo "⬆️  Pushing branch ${BRANCH_NAME}..."
git push --force-with-lease origin "${BRANCH_NAME}"

# --- Create or update PR ---
echo ""
echo "🔀 Managing pull request..."
pr_url=""
pr_url="$(pr_create_or_update "${BRANCH_NAME}" "${BASE_BRANCH}" "${ISSUE_NUMBER}" "${ISSUE_TITLE}" "${final_status}")" || {
  echo "⚠️  PR management failed"
  pr_url=""
}

# Extract just the URL (last line of output from pr_create_or_update)
if [[ -n "${pr_url}" ]]; then
  pr_url="$(echo "${pr_url}" | tail -1)"
fi

# --- Comment on issue ---
echo ""
echo "💬 Commenting on issue #${ISSUE_NUMBER}..."
issue_comment "${ISSUE_NUMBER}" "${final_status}" "${pr_url}" || {
  echo "⚠️  Issue comment failed"
}

# --- Set outputs ---
{
  echo "pr_url=${pr_url}"
  echo "iterations=${iteration}"
  echo "final_status=${final_status}"
} >> "${GITHUB_OUTPUT}"

echo ""
echo "✅ === Done ==="
echo "🔗 PR: ${pr_url}"
echo "📊 Status: ${final_status}"
echo "🔢 Iterations: ${iteration}"

# Exit with appropriate code
case "${final_status}" in
  SHIPPED)        exit 0 ;;
  MAX_ITERATIONS) exit 0 ;;  # Not a failure, just needs human review
  *)              exit 1 ;;
esac
