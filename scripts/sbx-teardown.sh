#!/usr/bin/env bash
# sbx-teardown.sh - Clean up Docker sbx sandbox resources
#
# Stops and removes the sandbox created by sbx-setup.sh, then logs out.

set -euo pipefail

SBX_SANDBOX_NAME="${SBX_SANDBOX_NAME:-ralph-sandbox}"

# Nothing to tear down if sbx never activated (e.g. degraded on a KVM-less
# runner). sbx itself is already on PATH (added by the install step).
_sbx_info="${RALPH_DIR:-${GITHUB_WORKSPACE:-.}/.ralph}/sbx-info.txt"
if [[ -f "${_sbx_info}" ]]; then
  _sbx_active="$(grep '^sbx_active=' "${_sbx_info}" | cut -d= -f2)"
  if [[ "${_sbx_active}" != "true" ]]; then
    echo "=== sbx Teardown skipped (sandbox was not active) ==="
    exit 0
  fi
fi
unset _sbx_info _sbx_active

echo "=== sbx Teardown ==="

# Stop and remove the sandbox (ignore errors — sandbox may already be gone)
echo "Stopping sandbox: ${SBX_SANDBOX_NAME}"
sbx stop "${SBX_SANDBOX_NAME}" 2>/dev/null || true

echo "Removing sandbox: ${SBX_SANDBOX_NAME}"
sbx rm "${SBX_SANDBOX_NAME}" 2>/dev/null || true

# Logout from Docker Hub
echo "Logging out from sbx..."
sbx logout --yes 2>/dev/null || true

echo "=== sbx Teardown Complete ==="
