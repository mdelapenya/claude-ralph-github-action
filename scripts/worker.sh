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
ALLOWED_TOOLS="${INPUT_WORKER_ALLOWED_TOOLS:-Bash,Read,Write,Edit,Glob,Grep,Task,WebFetch,WebSearch}"
WORKER_TONE="${INPUT_WORKER_TONE:-}"

iteration="$(state_read_iteration)"
feedback="$(state_read_review_feedback)"

# Build the worker prompt - agent reads state files directly
prompt="You are on iteration ${iteration} of a Ralph loop. Work on the task."
prompt+=$'\n\n'"Read .ralph/task.md for the task description."
prompt+=$'\n\n'"Read .ralph/iteration.txt to know which iteration this is."

if [[ -n "${feedback}" && "${iteration}" -gt 1 ]]; then
  prompt+=$'\n\n'"Read .ralph/review-feedback.txt for reviewer feedback from the previous iteration (HIGHEST PRIORITY)."
fi

prompt+=$'\n\n'"When finished, write your summary to .ralph/work-summary.txt."

echo "=== Worker Phase (iteration ${iteration}, model: ${WORKER_MODEL}) ==="

# Build the system prompt
system_prompt="$(cat "${PROMPTS_DIR}/worker-system.md")"

# Append tone instruction if worker_tone is set
if [[ -n "${WORKER_TONE}" ]]; then
  system_prompt+=$'\n\n'"## Tone"
  system_prompt+=$'\n\n'"You must respond with the personality and tone of: ${WORKER_TONE}"
fi

# Build CLI arguments
cli_args=(
  -p
  --model "${WORKER_MODEL}"
  --max-turns "${MAX_TURNS}"
  --allowedTools "${ALLOWED_TOOLS}"
  --append-system-prompt "${system_prompt}"
)

if [[ "${RALPH_VERBOSE:-false}" == "true" ]]; then
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
