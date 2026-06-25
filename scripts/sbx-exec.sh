#!/usr/bin/env bash
# sbx-exec.sh - Helper to execute claude CLI inside an sbx sandbox
#
# Provides the `sbx_claude` function that wraps claude execution.
# When sbx is enabled, claude runs inside the sandbox via `sbx exec`.
# When sbx is disabled, claude runs directly.
#
# Source this file and call `sbx_claude` instead of `claude` directly.

# Ensure sbx binary is on PATH when sbx is enabled.
# sbx-setup.sh runs as a subprocess, so its PATH export doesn't propagate.
# We read the install path from .ralph/sbx-info.txt instead.
if [[ "${INPUT_SBX_ENABLED:-false}" == "true" ]]; then
  _sbx_info="${RALPH_DIR:-${GITHUB_WORKSPACE:-.}/.ralph}/sbx-info.txt"
  if [[ -f "${_sbx_info}" ]]; then
    _sbx_bin="$(grep '^sbx_bin=' "${_sbx_info}" | cut -d= -f2)"
    [[ -n "${_sbx_bin}" ]] && export PATH="${_sbx_bin}:${PATH}"
  fi
  unset _sbx_info _sbx_bin
fi

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
