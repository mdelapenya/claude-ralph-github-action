#!/usr/bin/env bash
# sbx-exec.sh - Helper to execute claude CLI inside an sbx sandbox
#
# Provides the `sbx_claude` function that wraps claude execution.
# When sbx is enabled, claude runs inside the sandbox via `sbx exec`.
# When sbx is disabled, claude runs directly.
#
# Source this file and call `sbx_claude` instead of `claude` directly.

# Execute claude, optionally inside an sbx sandbox.
# All arguments are passed through to the claude CLI.
# Returns the exit code of the claude invocation.
sbx_claude() {
  if [[ "${INPUT_SBX_ENABLED:-false}" == "true" ]]; then
    local sandbox_name="${SBX_SANDBOX_NAME:-ralph-sandbox}"
    sbx exec "${sandbox_name}" claude "$@"
  else
    claude "$@"
  fi
}
