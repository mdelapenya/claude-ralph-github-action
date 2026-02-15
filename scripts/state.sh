#!/usr/bin/env bash
# state.sh - .ralph/ state directory read/write helpers
#
# All state is stored in .ralph/ at the repo root in the working tree only.
# State is never committed to the branch. Each function operates on a single state file.

set -euo pipefail

RALPH_DIR=".ralph"

# Ensure the .ralph directory exists
state_init() {
  mkdir -p "${RALPH_DIR}"
}

# Write the task description from the issue
# Args: $1 = issue title, $2 = issue body
state_write_task() {
  local title="$1"
  local body="$2"
  cat > "${RALPH_DIR}/task.md" <<EOF
# ${title}

${body}
EOF
}

# Write the issue number
# Args: $1 = issue number
state_write_issue_number() {
  echo "$1" > "${RALPH_DIR}/issue-number.txt"
}

# Read the issue number
state_read_issue_number() {
  cat "${RALPH_DIR}/issue-number.txt" 2>/dev/null || echo ""
}

# Read the current iteration count
state_read_iteration() {
  cat "${RALPH_DIR}/iteration.txt" 2>/dev/null || echo "0"
}

# Write the current iteration count
# Args: $1 = iteration number
state_write_iteration() {
  echo "$1" > "${RALPH_DIR}/iteration.txt"
}

# Write the worker's summary of changes made
# Args: $1 = summary text
state_write_work_summary() {
  echo "$1" > "${RALPH_DIR}/work-summary.txt"
}

# Read the worker's summary
state_read_work_summary() {
  cat "${RALPH_DIR}/work-summary.txt" 2>/dev/null || echo ""
}

# Write the review result (SHIP or REVISE)
# Args: $1 = result text
state_write_review_result() {
  echo "$1" > "${RALPH_DIR}/review-result.txt"
}

# Read the review result, normalized to SHIP or REVISE
# Returns REVISE if the file is missing or ambiguous
state_read_review_result() {
  local raw
  raw="$(cat "${RALPH_DIR}/review-result.txt" 2>/dev/null || echo "")"
  # Normalize: extract first word, uppercase
  local normalized
  normalized="$(echo "${raw}" | head -1 | tr '[:lower:]' '[:upper:]' | grep -oE '(SHIP|REVISE)' | head -1 || true)"
  if [[ "${normalized}" == "SHIP" ]]; then
    echo "SHIP"
  else
    echo "REVISE"
  fi
}

# Write reviewer feedback for the worker
# Args: $1 = feedback text
state_write_review_feedback() {
  echo "$1" > "${RALPH_DIR}/review-feedback.txt"
}

# Read reviewer feedback
state_read_review_feedback() {
  cat "${RALPH_DIR}/review-feedback.txt" 2>/dev/null || echo ""
}

# Write the final status
# Args: $1 = SHIPPED or MAX_ITERATIONS or ERROR
state_write_final_status() {
  echo "$1" > "${RALPH_DIR}/final-status.txt"
}

# Read the final status
state_read_final_status() {
  cat "${RALPH_DIR}/final-status.txt" 2>/dev/null || echo ""
}
