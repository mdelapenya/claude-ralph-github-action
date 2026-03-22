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

# Include push error context if a previous push failed
push_error="$(state_read_push_error)"
if [[ -n "${push_error}" ]]; then
  prompt+=$'\n\n'"IMPORTANT: The previous push to remote failed. Read .ralph/push-error.txt for details. You must investigate and resolve the push error (e.g., fix conflicting changes, resolve authentication issues, or adjust files that cannot be pushed)."
fi

prompt+=$'\n\n'"When finished, write your summary to .ralph/work-summary.txt."

echo "=== Worker Phase (iteration ${iteration}, model: ${WORKER_MODEL}) ==="

# Read the base branch from pr-info.txt (fall back to "main")
base_branch="main"
if [[ -f "${RALPH_DIR}/pr-info.txt" ]]; then
  base_branch="$(grep '^default_branch=' "${RALPH_DIR}/pr-info.txt" | cut -d= -f2- || true)"
  base_branch="${base_branch:-main}"
fi

# Build the system prompt, replacing __BASE_BRANCH__ placeholder with the actual base branch
system_prompt="$(cat "${PROMPTS_DIR}/worker-system.md")"
system_prompt="${system_prompt//__BASE_BRANCH__/${base_branch}}"

# Append tone instruction if worker_tone is set
if [[ -n "${WORKER_TONE}" ]]; then
  system_prompt+=$'\n\n'"## Tone"
  system_prompt+=$'\n\n'"You must respond with the following personality and tone: ${WORKER_TONE}"
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
worker_exit=0
claude "${cli_args[@]}" "${prompt}" || worker_exit=$?

if [[ ${worker_exit} -ne 0 ]]; then
  echo "ERROR: Worker Claude CLI exited with code ${worker_exit}"
  exit ${worker_exit}
fi

echo "=== Worker Phase Complete ==="
