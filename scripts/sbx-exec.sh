#!/usr/bin/env bash
# sbx-exec.sh - Helper to execute claude CLI inside an sbx sandbox
#
# Provides the `sbx_claude` function that wraps claude execution.
# When sbx is enabled, claude runs inside the sandbox via `sbx exec`.
# When sbx is disabled, claude runs directly.
#
# Source this file and call `sbx_claude` instead of `claude` directly.

# Determine whether the sbx sandbox is actually active for this run.
# sbx-setup.sh writes sbx_active=false when it degrades — e.g. on a runner
# without /dev/kvm — so Claude falls back to running directly. The sbx binary is
# on PATH already (added by the install step via GITHUB_PATH, inherited here).
SBX_ACTIVE="false"
if [[ "${INPUT_SBX_ENABLED:-true}" == "true" ]]; then
  _sbx_info="${RALPH_DIR:-${GITHUB_WORKSPACE:-.}/.ralph}/sbx-info.txt"
  if [[ -f "${_sbx_info}" ]]; then
    _sbx_active="$(grep '^sbx_active=' "${_sbx_info}" | cut -d= -f2)"
    [[ "${_sbx_active}" == "true" ]] && SBX_ACTIVE="true"
  fi
  unset _sbx_info _sbx_active
fi

# Execute claude, optionally inside an sbx sandbox.
# All arguments are passed through to the claude CLI.
# Returns the exit code of the claude invocation.
sbx_claude() {
  if [[ "${SBX_ACTIVE}" == "true" ]]; then
    local sandbox_name="${SBX_SANDBOX_NAME:-ralph-sandbox}"
    sbx exec "${sandbox_name}" claude "$@"
  else
    claude "$@"
  fi
}
