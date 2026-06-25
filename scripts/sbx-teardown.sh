#!/usr/bin/env bash
# sbx-teardown.sh - Clean up Docker sbx sandbox resources
#
# Stops and removes the sandbox created by sbx-setup.sh, then logs out.

set -euo pipefail

SBX_SANDBOX_NAME="${SBX_SANDBOX_NAME:-ralph-sandbox}"
SBX_APP_NAME="${SBX_APP_NAME:-claude-ralph}"

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
