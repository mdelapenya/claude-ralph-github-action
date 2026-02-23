#!/usr/bin/env bash
# reviewer.sh - Invokes Claude CLI for the reviewer phase
#
# The reviewer examines the worker's changes and decides SHIP or REVISE.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/state.sh"

PROMPTS_DIR="${PROMPTS_DIR:-/prompts}"
REVIEWER_MODEL="${INPUT_REVIEWER_MODEL:-sonnet}"
MAX_TURNS="${INPUT_MAX_TURNS_REVIEWER:-30}"
REVIEWER_TOOLS="${INPUT_REVIEWER_TOOLS:-Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,Task}"
REVIEWER_TONE="${INPUT_REVIEWER_TONE:-}"

iteration="$(state_read_iteration)"

# Build the reviewer prompt
prompt="You are the reviewer on iteration ${iteration} of a Ralph loop."
prompt+=$'\n\n'"Review the worker's changes against the task requirements."
prompt+=$'\n\n'"1. Read .ralph/task.md for the task description."
prompt+=$'\n\n'"2. Read .ralph/work-summary.txt for the worker's summary."
prompt+=$'\n\n'"3. Examine the actual code changes in the repository."
prompt+=$'\n\n'"4. Write SHIP or REVISE to .ralph/review-result.txt"
prompt+=$'\n\n'"5. If REVISE, write specific feedback to .ralph/review-feedback.txt"

echo "=== Reviewer Phase (iteration ${iteration}, model: ${REVIEWER_MODEL}) ==="

# Build the system prompt
system_prompt="$(cat "${PROMPTS_DIR}/reviewer-system.md")"

# Append tone instruction if reviewer_tone is set
if [[ -n "${REVIEWER_TONE}" ]]; then
  system_prompt+=$'\n\n'"## Tone"
  system_prompt+=$'\n\n'"You must respond with the following personality and tone: ${REVIEWER_TONE}"
fi

# Build CLI arguments
cli_args=(
  -p
  --model "${REVIEWER_MODEL}"
  --max-turns "${MAX_TURNS}"
  --allowedTools "${REVIEWER_TOOLS}"
  --append-system-prompt "${system_prompt}"
)

if [[ "${RALPH_VERBOSE:-false}" == "true" ]]; then
  cli_args+=(--verbose)
fi

# Invoke Claude CLI in print mode with the reviewer system prompt
reviewer_exit=0
claude "${cli_args[@]}" "${prompt}" || reviewer_exit=$?

if [[ ${reviewer_exit} -ne 0 ]]; then
  echo "ERROR: Reviewer Claude CLI exited with code ${reviewer_exit}"
  exit ${reviewer_exit}
fi

# Ensure the review result file exists; default to REVISE if missing
if [[ ! -f "${RALPH_DIR}/review-result.txt" ]]; then
  echo "WARNING: Reviewer did not write review-result.txt, defaulting to REVISE"
  state_write_review_result "REVISE"
  state_write_review_feedback "Reviewer failed to produce a result. Please re-examine the code and ensure it meets the task requirements."
fi

# Post-review safety net: ensure the branch is pushed.
# If the reviewer agent failed to push (e.g., due to workflow file permissions),
# this fallback handles it automatically: generates a patch, posts it to the issue,
# removes workflow changes from the branch, and retries the push.
branch="$(grep '^branch=' "${RALPH_DIR}/pr-info.txt" 2>/dev/null | cut -d= -f2 || echo "")"
repo="$(grep '^repo=' "${RALPH_DIR}/pr-info.txt" 2>/dev/null | cut -d= -f2 || echo "")"
issue_number="$(state_read_issue_number)"
default_branch="$(grep '^default_branch=' "${RALPH_DIR}/pr-info.txt" 2>/dev/null | cut -d= -f2 || echo "")"
default_branch="${default_branch:-main}"

if [[ -n "${branch}" ]]; then
  source "${SCRIPT_DIR}/workflow-patch.sh"
  push_exit=0
  push_with_workflow_fallback "${branch}" "origin/${default_branch}" "${issue_number}" "${repo}" || push_exit=$?
  if [[ ${push_exit} -ne 0 ]]; then
    echo "ERROR: Failed to push branch '${branch}' even after workflow fallback (exit code ${push_exit})."
    exit ${push_exit}
  fi
fi


echo "=== Reviewer Phase Complete ==="
