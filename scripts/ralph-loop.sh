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
echo ""
echo "  Configuration:"
echo "  ┌─────────────────────────────────────────────────────────────┐"
printf "  │  %-28s %-30s│\n" "max_iterations:"       "${MAX_ITERATIONS}"
printf "  │  %-28s %-30s│\n" "worker model:"          "${INPUT_WORKER_MODEL:-sonnet}"
printf "  │  %-28s %-30s│\n" "worker max_turns:"      "${INPUT_MAX_TURNS_WORKER:-unlimited}"
printf "  │  %-28s %-30s│\n" "reviewer model:"        "${INPUT_REVIEWER_MODEL:-sonnet}"
printf "  │  %-28s %-30s│\n" "reviewer max_turns:"    "${INPUT_MAX_TURNS_REVIEWER:-unlimited}"
printf "  │  %-28s %-30s│\n" "security_gate_enabled:" "${INPUT_SECURITY_GATE_ENABLED:-true}"
printf "  │  %-28s %-30s│\n" "security gate model:"   "${INPUT_SECURITY_GATE_MODEL:-sonnet}"
printf "  │  %-28s %-30s│\n" "security gate max_turns:" "${INPUT_MAX_TURNS_SECURITY_GATE:-unlimited}"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
state_log_audit "LOOP_START" "max=${MAX_ITERATIONS}"

while [[ "${iteration}" -lt "${MAX_ITERATIONS}" ]]; do
  iteration=$((iteration + 1))
  state_write_iteration "${iteration}"
  state_log_audit "ITERATION_START" "iteration=${iteration}"

  # Restore writability for files locked in the previous iteration.
  # Use || true so chmod failures (e.g. ownership mismatch) don't abort the loop.
  [[ -f "${RALPH_DIR}/review-result.txt"   ]] && chmod u+w "${RALPH_DIR}/review-result.txt"   2>/dev/null || true
  [[ -f "${RALPH_DIR}/work-summary.txt"    ]] && chmod u+w "${RALPH_DIR}/work-summary.txt"    2>/dev/null || true
  [[ -f "${RALPH_DIR}/review-feedback.txt" ]] && chmod u+w "${RALPH_DIR}/review-feedback.txt" 2>/dev/null || true

  echo ""
  echo "=========================================="
  echo "  Iteration ${iteration} of ${MAX_ITERATIONS}"
  echo "=========================================="

  # --- WORK PHASE ---
  echo ""
  echo "--- Work Phase ---"
  state_log_audit "WORKER_START" "iteration=${iteration}"

  if ! "${SCRIPT_DIR}/worker.sh"; then
    echo "ERROR: Worker failed on iteration ${iteration}"
    state_log_audit "WORKER_END" "iteration=${iteration} status=ERROR"
    state_write_final_status "ERROR"
    exit 1
  fi
  state_log_audit "WORKER_END" "iteration=${iteration} status=ok"

  # Lock work-summary so reviewer gets an immutable snapshot
  [[ -f "${RALPH_DIR}/work-summary.txt" ]] && chmod a-w "${RALPH_DIR}/work-summary.txt"

  # Strip executable bit from any .git/hooks/ files the worker may have created.
  # Hooks run during git operations in the reviewer and security gate phases, so a
  # malicious hook installed by the worker would execute with full runner privileges.
  find .git/hooks -type f ! -name "*.sample" -exec chmod -x {} \; 2>/dev/null || true

  # Worker is now responsible for ensuring commits are made
  # If no commits, worker should handle it in the next iteration

  # --- REVIEW PHASE ---
  echo ""
  echo "--- Review Phase ---"
  state_log_audit "REVIEWER_START" "iteration=${iteration}"
  if ! "${SCRIPT_DIR}/reviewer.sh"; then
    echo "ERROR: Reviewer failed on iteration ${iteration}"
    state_log_audit "REVIEWER_END" "iteration=${iteration} status=ERROR"
    state_write_final_status "ERROR"
    exit 1
  fi
  state_log_audit "REVIEWER_END" "iteration=${iteration} status=ok"

  # Write checksum and lock reviewer outputs
  state_write_checksum "${RALPH_DIR}/review-result.txt"
  [[ -f "${RALPH_DIR}/review-result.txt"   ]] && chmod a-w "${RALPH_DIR}/review-result.txt"
  [[ -f "${RALPH_DIR}/review-feedback.txt" ]] && chmod a-w "${RALPH_DIR}/review-feedback.txt"

  # Integrity gate: abort if review-result.txt was tampered with after the checksum was written
  if ! state_verify_checksum "${RALPH_DIR}/review-result.txt"; then
    state_log_audit "INTEGRITY_VIOLATION" "iteration=${iteration} file=review-result.txt"
    echo "ERROR: review-result.txt checksum mismatch — possible tampering"
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
    chmod u+w "${RALPH_DIR}/review-result.txt" 2>/dev/null || true
    state_write_review_result "REVISE"
  fi

  # --- DECIDE ---
  result="$(state_read_review_result)"
  echo ""
  echo "--- Decision: ${result} ---"
  state_log_audit "DECISION" "iteration=${iteration} result=${result}"

  if [[ "${result}" == "SHIP" ]]; then
    # --- SECURITY GATE ---
    if [[ "${INPUT_SECURITY_GATE_ENABLED:-true}" == "true" ]]; then
      echo ""
      echo "--- Security Gate Phase ---"
      state_log_audit "SECURITY_GATE_START" "iteration=${iteration}"

      # Reset security result so a stale PASS from a prior iteration cannot slip through
      rm -f "${RALPH_DIR}/security-result.txt" "${RALPH_DIR}/security-result.txt.sha256" "${RALPH_DIR}/security-feedback.txt"

      # Remove any symlinks in .ralph/ before the gate writes its verdict.
      # The worker could create .ralph/security-result.txt as a symlink so that the
      # gate's write follows it to an attacker-controlled path.
      state_remove_ralph_symlinks

      # Warn if the diff is large enough to risk exhausting the gate's max-turns budget
      # before the audit is complete (which produces an inconclusive FAIL, not a finding).
      _diff_base="$(grep '^default_branch=' "${RALPH_DIR}/pr-info.txt" 2>/dev/null | cut -d= -f2- || echo "main")"
      _diff_base="${_diff_base:-main}"
      _diff_lines="$(git diff "origin/${_diff_base}..HEAD" 2>/dev/null | wc -l | tr -d ' ')" || _diff_lines=0
      if [[ "${_diff_lines}" -gt 10000 ]]; then
        echo "WARNING: Diff is ${_diff_lines} lines — security gate may exhaust max-turns (${INPUT_MAX_TURNS_SECURITY_GATE:-unlimited}) before completing the audit. Consider setting max_turns_security_gate."
        state_log_audit "SECURITY_GATE_LARGE_DIFF" "iteration=${iteration} lines=${_diff_lines}"
      fi
      unset _diff_base _diff_lines

      # Remove any .claude/ directory the worker may have created to poison the gate's
      # per-project CLAUDE.md instructions. Claude Code loads .claude/CLAUDE.md as
      # project-level instructions before the system prompt; removing it prevents override.
      if [[ -d ".claude" ]]; then
        echo "WARNING: .claude/ directory found in working tree before security gate — removing to prevent prompt poisoning"
        rm -rf ".claude"
        state_log_audit "SECURITY_GATE_CLAUDE_DIR_REMOVED" "iteration=${iteration}"
      fi

      if ! "${SCRIPT_DIR}/security-gate.sh"; then
        echo "ERROR: Security gate failed on iteration ${iteration}"
        state_log_audit "SECURITY_GATE_END" "iteration=${iteration} status=ERROR"
        state_write_final_status "ERROR"
        exit 1
      fi
      state_log_audit "SECURITY_GATE_END" "iteration=${iteration} status=ok"

      # Write checksum and lock the result — mirrors the review-result.txt pattern.
      state_write_checksum "${RALPH_DIR}/security-result.txt"
      [[ -f "${RALPH_DIR}/security-result.txt" ]] && chmod a-w "${RALPH_DIR}/security-result.txt"

      # Integrity check: abort if security-result.txt was tampered with after the gate wrote it.
      if ! state_verify_checksum "${RALPH_DIR}/security-result.txt"; then
        state_log_audit "INTEGRITY_VIOLATION" "iteration=${iteration} file=security-result.txt"
        echo "ERROR: security-result.txt checksum mismatch — possible tampering"
        state_write_final_status "ERROR"
        exit 1
      fi

      # Verify the security gate did not modify any tracked source files.
      # The gate is read-only; any tracked-file modification is an integrity violation.
      gate_modified_files="$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null)"
      if [[ -n "${gate_modified_files}" ]]; then
        state_log_audit "INTEGRITY_VIOLATION" "iteration=${iteration} file=security-gate-modified-tracked-files"
        echo "ERROR: Security gate modified tracked files — integrity violation:"
        echo "${gate_modified_files}"
        state_write_final_status "ERROR"
        exit 1
      fi

      security_result="$(state_read_security_result)"
      echo "--- Security Gate Decision: ${security_result} ---"
      state_log_audit "SECURITY_GATE_DECISION" "iteration=${iteration} result=${security_result}"

      if [[ "${security_result}" == "FAIL" ]]; then
        echo "Security gate blocked ship. Forcing REVISE."
        security_feedback="$(state_read_security_feedback)"
        chmod u+w "${RALPH_DIR}/review-result.txt" 2>/dev/null || true
        state_write_review_result "REVISE"
        existing_feedback="$(state_read_review_feedback)"
        if [[ -n "${existing_feedback}" ]]; then
          chmod u+w "${RALPH_DIR}/review-feedback.txt" 2>/dev/null || true
          state_write_review_feedback "SECURITY GATE BLOCKED SHIP:"$'\n'"${security_feedback}"$'\n\n'"Previous reviewer feedback:"$'\n'"${existing_feedback}"
        else
          chmod u+w "${RALPH_DIR}/review-feedback.txt" 2>/dev/null || true
          state_write_review_feedback "SECURITY GATE BLOCKED SHIP:"$'\n'"${security_feedback}"
        fi
        state_log_audit "SECURITY_GATE_BLOCKED" "iteration=${iteration}"
        echo "Continuing to next iteration with security findings."
        feedback="$(state_read_review_feedback)"
        if [[ -n "${feedback}" ]]; then
          echo "Feedback preview: ${feedback:0:200}..."
        fi
        continue
      fi
    fi

    echo "Reviewer approved! Shipping."
    state_log_audit "LOOP_END" "status=SHIPPED iteration=${iteration}"
    state_write_final_status "SHIPPED"
    exit 0
  fi

  echo "Reviewer requested revisions. Continuing to next iteration."
  state_log_audit "REVISE_CONTINUE" "iteration=${iteration}"
  feedback="$(state_read_review_feedback)"
  if [[ -n "${feedback}" ]]; then
    echo "Feedback preview: ${feedback:0:200}..."
  fi
done

echo ""
echo "=== Max iterations (${MAX_ITERATIONS}) reached ==="
state_log_audit "LOOP_END" "status=MAX_ITERATIONS iteration=${iteration}"
state_write_final_status "MAX_ITERATIONS"
exit 2
