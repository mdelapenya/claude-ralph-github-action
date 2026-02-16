#!/usr/bin/env bash
# artifact-download.sh - Download previous Ralph context from GitHub Actions artifacts
#
# This script attempts to download the most recent artifact for the current issue,
# allowing Ralph to continue from where a previous execution left off when an issue
# is re-triggered (e.g., after editing).
#
# Args: $1 = issue number
# Exit codes:
#   0 = artifact downloaded successfully
#   1 = no artifact found or download failed (not an error, just means this is the first run)

set -euo pipefail

ISSUE_NUMBER="${1:-}"
if [[ -z "${ISSUE_NUMBER}" ]]; then
  echo "Usage: $0 <issue_number>"
  exit 1
fi

ARTIFACT_NAME="ralph-context-issue-${ISSUE_NUMBER}"
RALPH_DIR=".ralph"

echo "🔍 Checking for previous Ralph context artifact: ${ARTIFACT_NAME}"

# Check if gh CLI is available
if ! command -v gh &> /dev/null; then
  echo "⚠️  gh CLI not found, skipping artifact download"
  exit 1
fi

# Try to download the artifact
# The artifact list command returns JSON with all artifacts matching the name
artifact_id=""
artifact_id="$(gh api \
  "/repos/${GITHUB_REPOSITORY}/actions/artifacts?name=${ARTIFACT_NAME}" \
  --jq '.artifacts | sort_by(.created_at) | reverse | .[0].id' 2>/dev/null || echo "")"

if [[ -z "${artifact_id}" || "${artifact_id}" == "null" ]]; then
  echo "ℹ️  No previous context artifact found (this may be the first run for this issue)"
  exit 1
fi

echo "📦 Found artifact ID: ${artifact_id}"
echo "⬇️  Downloading previous context..."

# Download the artifact to a temporary location
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

if ! gh api "/repos/${GITHUB_REPOSITORY}/actions/artifacts/${artifact_id}/zip" > "${temp_dir}/artifact.zip" 2>/dev/null; then
  echo "⚠️  Failed to download artifact"
  exit 1
fi

# Extract the artifact
if ! unzip -q "${temp_dir}/artifact.zip" -d "${temp_dir}" 2>/dev/null; then
  echo "⚠️  Failed to extract artifact"
  exit 1
fi

# Copy the .ralph directory contents if they exist
if [[ -d "${temp_dir}/.ralph" ]]; then
  mkdir -p "${RALPH_DIR}"
  cp -r "${temp_dir}/.ralph/"* "${RALPH_DIR}/" 2>/dev/null || true
  echo "✅ Previous context restored from artifact"

  # Show what was restored
  if [[ -f "${RALPH_DIR}/iteration.txt" ]]; then
    prev_iteration="$(cat "${RALPH_DIR}/iteration.txt")"
    echo "   Previous iteration: ${prev_iteration}"
  fi
  if [[ -f "${RALPH_DIR}/final-status.txt" ]]; then
    prev_status="$(cat "${RALPH_DIR}/final-status.txt")"
    echo "   Previous status: ${prev_status}"
  fi

  exit 0
else
  echo "⚠️  Artifact does not contain .ralph directory"
  exit 1
fi
