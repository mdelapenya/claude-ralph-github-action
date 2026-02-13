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
  state_commit "ralph: start iteration ${iteration}"

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
    state_commit "ralph: worker error on iteration ${iteration}"
    exit 1
  fi

  # Commit worker changes (code only, exclude .ralph/ state)
  git add -A -- ':!.ralph'
  if ! git diff --cached --quiet; then
    git commit -m "ralph: worker changes (iteration ${iteration})"
  else
    echo "❌ Worker made no changes on iteration ${iteration}. Aborting."
    state_write_final_status "ERROR"
    exit 1
  fi

  # --- REVIEW PHASE ---
  echo ""
  echo "--- Review Phase ---"
  if ! "${SCRIPT_DIR}/reviewer.sh"; then
    echo "ERROR: Reviewer failed on iteration ${iteration}"
    state_write_final_status "ERROR"
    state_commit "ralph: reviewer error on iteration ${iteration}"
    exit 1
  fi

  # Commit review state
  state_commit "ralph: review complete (iteration ${iteration})"

  # --- DECIDE ---
  result="$(state_read_review_result)"
  echo ""
  echo "--- Decision: ${result} ---"

  if [[ "${result}" == "SHIP" ]]; then
    echo "Reviewer approved! Shipping."
    state_write_final_status "SHIPPED"
    state_commit "ralph: SHIPPED on iteration ${iteration}"
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
state_commit "ralph: max iterations reached"
exit 2
