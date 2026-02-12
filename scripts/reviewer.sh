#!/usr/bin/env bash
# reviewer.sh - Invokes Claude CLI for the reviewer phase
#
# The reviewer examines the worker's changes and decides SHIP or REVISE.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/state.sh"

PROMPTS_DIR="${PROMPTS_DIR:-/prompts}"
REVIEWER_MODEL="${INPUT_REVIEWER_MODEL:-sonnet}"
MAX_TURNS="${INPUT_MAX_TURNS_REVIEWER:-10}"
REVIEWER_TOOLS="${INPUT_REVIEWER_TOOLS:-Read,Glob,Grep,Write}"

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

# Build CLI arguments
cli_args=(
  -p
  --model "${REVIEWER_MODEL}"
  --max-turns "${MAX_TURNS}"
  --allowedTools "${REVIEWER_TOOLS}"
  --append-system-prompt "$(cat "${PROMPTS_DIR}/reviewer-system.md")"
)

if [[ "${RALPH_VERBOSE:-false}" == "true" ]]; then
  cli_args+=(--verbose)
fi

# Invoke Claude CLI in print mode with the reviewer system prompt
claude "${cli_args[@]}" "${prompt}"

reviewer_exit=$?

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

echo "=== Reviewer Phase Complete ==="
