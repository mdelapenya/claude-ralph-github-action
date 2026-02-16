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

# Read parent issue number to establish sub-issue relationships
if [[ ! -f "${RALPH_DIR}/issue-number.txt" ]]; then
  echo "❌ Error: ${RALPH_DIR}/issue-number.txt not found"
  exit 1
fi

parent_issue_number="$(cat "${RALPH_DIR}/issue-number.txt")"
if [[ -z "${parent_issue_number}" ]]; then
  echo "❌ Error: Could not read parent issue number from ${RALPH_DIR}/issue-number.txt"
  exit 1
fi

# Get the parent issue's node ID for GraphQL API
parent_node_id="$(gh api "repos/${repo}/issues/${parent_issue_number}" --jq '.node_id')"
if [[ -z "${parent_node_id}" ]]; then
  echo "❌ Error: Could not retrieve node ID for parent issue #${parent_issue_number}"
  exit 1
fi

echo "🔀 === Creating Subtask Issues ==="
echo "📦 Repository: ${repo}"
echo "🏷️  Trigger label: ${trigger_label}"
echo "👪 Parent issue: #${parent_issue_number}"
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
  # Temporarily disable errexit to capture both output and exit code
  set +e
  issue_url="$(gh issue create \
    --repo "${repo}" \
    --title "${issue_title}" \
    --body "${issue_body}" \
    --label "${trigger_label}" 2>&1)"
  exit_code=$?
  set -e

  if [[ ${exit_code} -eq 0 ]]; then
    created_issues+=("${issue_url}")
    echo "   ✅ Created: ${issue_url}"

    # Extract issue number from URL (e.g., https://github.com/owner/repo/issues/123 -> 123)
    child_issue_number="${issue_url##*/}"

    # Get the node ID of the newly created issue
    child_node_id="$(gh api "repos/${repo}/issues/${child_issue_number}" --jq '.node_id')"

    if [[ -n "${child_node_id}" ]]; then
      # Establish parent-child relationship via GraphQL API
      # Note: This requires the GraphQL-Features: sub_issues header
      set +e
      gh api graphql -H "GraphQL-Features: sub_issues" -f query="
        mutation {
          addSubIssue(input: {
            issueId: \"${parent_node_id}\",
            subIssueId: \"${child_node_id}\"
          }) {
            issue { title }
            subIssue { title }
          }
        }
      " &>/dev/null
      graphql_exit_code=$?
      set -e

      if [[ ${graphql_exit_code} -eq 0 ]]; then
        echo "   🔗 Linked as sub-issue of #${parent_issue_number}"
      else
        echo "   ⚠️  Warning: Could not establish sub-issue relationship"
      fi
    else
      echo "   ⚠️  Warning: Could not retrieve node ID for new issue"
    fi
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
