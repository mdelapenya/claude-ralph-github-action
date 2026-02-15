#!/usr/bin/env bash
# create-subtask-issues.sh - Helper for multi-agent support
#
# Allows the worker agent to split a complex task into multiple subtasks
# by creating GitHub issues labeled with the trigger label (e.g., "ralph").
# Each issue will be processed by a separate Ralph action in parallel.
#
# Usage:
#   create-subtask-issues.sh <issue-file-1> [<issue-file-2> ...]
#
# Each issue file should contain:
#   Line 1: Issue title
#   Remaining lines: Issue body (description)
#
# Example:
#   echo "Add user authentication" > issue1.txt
#   echo "Implement JWT-based authentication for the API" >> issue1.txt
#   create-subtask-issues.sh issue1.txt issue2.txt issue3.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/state.sh"

# Ensure we have at least one issue file
if [[ $# -lt 1 ]]; then
  echo "❌ Error: No issue files provided"
  echo "Usage: create-subtask-issues.sh <issue-file-1> [<issue-file-2> ...]"
  exit 1
fi

# Read pr-info.txt to get the repo and trigger label
if [[ ! -f "${RALPH_DIR}/pr-info.txt" ]]; then
  echo "❌ Error: ${RALPH_DIR}/pr-info.txt not found"
  exit 1
fi

repo="$(grep -E '^repo=' "${RALPH_DIR}/pr-info.txt" | cut -d= -f2-)"
if [[ -z "${repo}" ]]; then
  echo "❌ Error: Could not read repo from ${RALPH_DIR}/pr-info.txt"
  exit 1
fi

# Get trigger label from environment or default to "ralph"
trigger_label="${INPUT_TRIGGER_LABEL:-ralph}"

echo "🔀 === Creating Subtask Issues ==="
echo "📦 Repository: ${repo}"
echo "🏷️  Trigger label: ${trigger_label}"
echo ""

created_issues=()

# Process each issue file
for issue_file in "$@"; do
  if [[ ! -f "${issue_file}" ]]; then
    echo "⚠️  Warning: Issue file not found: ${issue_file}, skipping"
    continue
  fi

  # Read the issue title (first line) and body (remaining lines)
  issue_title="$(head -n 1 "${issue_file}")"
  issue_body="$(tail -n +2 "${issue_file}")"

  if [[ -z "${issue_title}" ]]; then
    echo "⚠️  Warning: Issue file ${issue_file} has no title, skipping"
    continue
  fi

  echo "📝 Creating issue: ${issue_title}"

  # Create the issue with the trigger label
  # The gh issue create command returns the URL of the created issue
  issue_url="$(gh issue create \
    --repo "${repo}" \
    --title "${issue_title}" \
    --body "${issue_body}" \
    --label "${trigger_label}" 2>&1)"

  if [[ $? -eq 0 ]]; then
    created_issues+=("${issue_url}")
    echo "   ✅ Created: ${issue_url}"
  else
    echo "   ❌ Failed to create issue: ${issue_url}"
  fi
done

echo ""
echo "🏁 === Summary ==="
echo "Created ${#created_issues[@]} subtask issue(s):"
for issue_url in "${created_issues[@]}"; do
  echo "  - ${issue_url}"
done

if [[ ${#created_issues[@]} -eq 0 ]]; then
  echo "⚠️  No issues were created"
  exit 1
fi

echo ""
echo "✅ Subtask issues created successfully. Each will be processed by a separate Ralph action."
