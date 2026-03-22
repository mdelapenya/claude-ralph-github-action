#!/usr/bin/env bash
# ralph-loop.sh - The core work/review/decide cycle
#
# Runs iterative cycles of worker -> reviewer -> decision until
# the reviewer SHIPs or max iterations is reached.
#
# Exit codes:
#   0 = SHIPPED
#   2 = MAX_ITERATIONS reached
#   1 = ERROR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/state.sh"

MAX_ITERATIONS="${INPUT_MAX_ITERATIONS:-5}"

iteration="$(state_read_iteration)"

echo "=== Ralph Loop Starting (iteration: ${iteration}, max: ${MAX_ITERATIONS}) ==="

while [[ "${iteration}" -lt "${MAX_ITERATIONS}" ]]; do
  iteration=$((iteration + 1))
  state_write_iteration "${iteration}"

  echo ""
  echo "=========================================="
  echo "  Iteration ${iteration} of ${MAX_ITERATIONS}"
  echo "=========================================="

  # --- WORK PHASE ---
  echo ""
  echo "--- Work Phase ---"

  if ! "${SCRIPT_DIR}/worker.sh"; then
    echo "ERROR: Worker failed on iteration ${iteration}"
    state_write_final_status "ERROR"
    exit 1
  fi

  # Worker is now responsible for ensuring commits are made
  # If no commits, worker should handle it in the next iteration

  # --- REVIEW PHASE ---
  echo ""
  echo "--- Review Phase ---"
  if ! "${SCRIPT_DIR}/reviewer.sh"; then
    echo "ERROR: Reviewer failed on iteration ${iteration}"
    state_write_final_status "ERROR"
    exit 1
  fi

  # --- CHECK PUSH ERRORS ---
  push_error="$(state_read_push_error)"
  if [[ -n "${push_error}" ]]; then
    echo ""
    echo "--- Push Error Detected ---"
    echo "Push error: ${push_error:0:200}..."
    # Append push error to review feedback so the worker knows about it
    existing_feedback="$(state_read_review_feedback)"
    push_feedback="PUSH ERROR: The branch could not be pushed to the remote. ${push_error}"
    if [[ -n "${existing_feedback}" ]]; then
      state_write_review_feedback "${existing_feedback}"$'\n\n'"${push_feedback}"
    else
      state_write_review_feedback "${push_feedback}"
    fi
    # Force REVISE so the loop continues regardless of the review decision
    state_write_review_result "REVISE"
  fi

  # --- DECIDE ---
  result="$(state_read_review_result)"
  echo ""
  echo "--- Decision: ${result} ---"

  if [[ "${result}" == "SHIP" ]]; then
    echo "Reviewer approved! Shipping."
    state_write_final_status "SHIPPED"
    exit 0
  fi

  echo "Reviewer requested revisions. Continuing to next iteration."
  feedback="$(state_read_review_feedback)"
  if [[ -n "${feedback}" ]]; then
    echo "Feedback preview: ${feedback:0:200}..."
  fi
done

echo ""
echo "=== Max iterations (${MAX_ITERATIONS}) reached ==="
state_write_final_status "MAX_ITERATIONS"
exit 2
