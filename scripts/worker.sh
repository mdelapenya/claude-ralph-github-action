#!/usr/bin/env bash
# worker.sh - Invokes Claude CLI for the worker phase
#
# The worker reads the task and any previous reviewer feedback,
# makes code changes, and writes a summary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/state.sh"

PROMPTS_DIR="${PROMPTS_DIR:-/prompts}"
WORKER_MODEL="${INPUT_WORKER_MODEL:-sonnet}"
MAX_TURNS="${INPUT_MAX_TURNS_WORKER:-30}"
ALLOWED_TOOLS="${INPUT_WORKER_ALLOWED_TOOLS:-Bash,Read,Write,Edit,Glob,Grep}"

iteration="$(state_read_iteration)"
feedback="$(state_read_review_feedback)"

# Build the worker prompt
prompt="You are on iteration ${iteration} of a Ralph loop. Work on the task."
prompt+=$'\n\n'"Read .ralph/task.md for the task description."
prompt+=$'\n\n'"Read .ralph/context.md for branch context (whether this is a fresh start or continuation of previous work, and any merge conflicts to resolve)."

if [[ -n "${feedback}" && "${iteration}" -gt 1 ]]; then
  prompt+=$'\n\n'"IMPORTANT: The reviewer provided feedback on your previous iteration. Read .ralph/review-feedback.txt and address it as your highest priority."
fi

prompt+=$'\n\n'"When finished, write your summary to .ralph/work-summary.txt."

echo "=== Worker Phase (iteration ${iteration}, model: ${WORKER_MODEL}) ==="

# Build CLI arguments
cli_args=(
  -p
  --model "${WORKER_MODEL}"
  --max-turns "${MAX_TURNS}"
  --allowedTools "${ALLOWED_TOOLS}"
  --append-system-prompt "$(cat "${PROMPTS_DIR}/worker-system.md")"
)

if [[ "${RALPH_VERBOSE:-true}" != "false" ]]; then
  cli_args+=(--verbose)
fi

# Invoke Claude CLI in print mode with the worker system prompt
claude "${cli_args[@]}" "${prompt}"

worker_exit=$?

if [[ ${worker_exit} -ne 0 ]]; then
  echo "ERROR: Worker Claude CLI exited with code ${worker_exit}"
  exit ${worker_exit}
fi

echo "=== Worker Phase Complete ==="
