#!/usr/bin/env bash
# artifact-upload.sh - Prepare Ralph context for artifact upload
#
# This script prepares the .ralph/ directory for upload as an artifact by the
# workflow. The actual upload must be done by the workflow using
# actions/upload-artifact@v4, as Docker container actions cannot upload artifacts
# directly.
#
# The workflow should call this script and then use actions/upload-artifact to
# upload the .ralph/ directory.
#
# Args: $1 = issue number
# Exit codes:
#   0 = context prepared successfully
#   1 = preparation failed

set -euo pipefail

ISSUE_NUMBER="${1:-}"
if [[ -z "${ISSUE_NUMBER}" ]]; then
  echo "Usage: $0 <issue_number>"
  exit 1
fi

ARTIFACT_NAME="ralph-context-issue-${ISSUE_NUMBER}"
RALPH_DIR=".ralph"

if [[ ! -d "${RALPH_DIR}" ]]; then
  echo "⚠️  No .ralph directory found, skipping artifact preparation"
  exit 1
fi

echo "📦 Preparing Ralph context for artifact upload: ${ARTIFACT_NAME}"

# Create a marker file with the artifact name so the workflow knows to upload
echo "${ARTIFACT_NAME}" > "${RALPH_DIR}/.artifact-name"

# Show what will be uploaded
echo "   Contents to be uploaded:"
ls -1 "${RALPH_DIR}" | sed 's/^/     - /'

echo "✅ Ralph context prepared"
echo "   The workflow should now upload .ralph/ as artifact: ${ARTIFACT_NAME}"

exit 0
