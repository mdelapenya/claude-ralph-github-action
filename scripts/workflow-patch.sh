#!/usr/bin/env bash
# workflow-patch.sh - Detect workflow file changes and generate a patch
#
# When a push fails because GitHub restricts modifications to .github/workflows/
# via the default GITHUB_TOKEN, this script:
#   1. Detects which workflow files were changed
#   2. Generates a git diff patch for those changes
#   3. Outputs a formatted comment body suitable for posting on an issue
#
# Usage:
#   workflow-patch.sh <base_branch>
#
# Exit codes:
#   0 = workflow changes detected, patch printed to stdout
#   1 = error
#   2 = no workflow changes detected

set -euo pipefail

WORKFLOW_DIR=".github/workflows"

# Detect if any workflow files were changed compared to the base branch
# Args: $1 = base branch (e.g., "origin/main")
# Returns: 0 if changes exist, 1 otherwise
has_workflow_changes() {
  local base="$1"
  local changed_files
  changed_files="$(git diff "${base}" --name-only -- "${WORKFLOW_DIR}" 2>/dev/null || echo "")"
  [[ -n "${changed_files}" ]]
}

# List the workflow files that were changed
# Args: $1 = base branch
list_workflow_changes() {
  local base="$1"
  git diff "${base}" --name-only -- "${WORKFLOW_DIR}" 2>/dev/null || echo ""
}

# Generate a git diff patch for workflow file changes
# Args: $1 = base branch
generate_workflow_patch() {
  local base="$1"
  git diff "${base}" -- "${WORKFLOW_DIR}" 2>/dev/null || echo ""
}

# Format the patch as a GitHub issue comment body
# Args: $1 = base branch
format_patch_comment() {
  local base="$1"
  local changed_files
  local patch

  changed_files="$(list_workflow_changes "${base}")"
  patch="$(generate_workflow_patch "${base}")"

  if [[ -z "${patch}" ]]; then
    return 2
  fi

  cat <<EOF
⚠️ **Workflow file changes could not be pushed** due to GitHub token permission restrictions.

The following workflow files were modified but could not be included in the push:

$(echo "${changed_files}" | sed 's/^/- `/' | sed 's/$/`/')

<details>
<summary>📋 Click to expand the patch</summary>

Apply this patch locally with:
\`\`\`bash
git checkout <branch-name>
git apply <<'PATCH'
${patch}
PATCH
\`\`\`

Or save the patch to a file and apply it:
\`\`\`bash
curl -sL "<patch-url>" | git apply
\`\`\`

</details>

<!-- ralph-comment-workflow-patch -->
EOF
}

# Remove workflow file changes from the current branch
# Args: $1 = base branch (e.g., "origin/main")
remove_workflow_changes() {
  local base="$1"
  local changed_files
  changed_files="$(list_workflow_changes "${base}")"

  if [[ -z "${changed_files}" ]]; then
    return 0
  fi

  # Restore workflow files to the base branch state
  echo "${changed_files}" | while IFS= read -r file; do
    if git show "${base}:${file}" > /dev/null 2>&1; then
      # File exists on base branch, restore it
      git checkout "${base}" -- "${file}"
    else
      # File is new (doesn't exist on base), remove it
      git rm -f "${file}" > /dev/null 2>&1 || rm -f "${file}"
      git add "${file}" > /dev/null 2>&1 || true
    fi
  done

  git commit -m "chore: remove workflow changes that cannot be pushed (patch posted to issue)" > /dev/null 2>&1
}

# Attempt to push the branch. If push fails due to workflow changes,
# generate a patch, post it to the issue, remove workflow changes, and retry.
#
# Args:
#   $1 = branch name (e.g., "ralph/issue-42")
#   $2 = base branch (e.g., "origin/main")
#   $3 = issue number
#   $4 = repo (e.g., "owner/repo")
#
# Exit codes:
#   0 = push succeeded (possibly after workflow patch fallback)
#   1 = push failed for reasons other than workflow changes
#   2 = no unpushed changes (branch already up to date)
push_with_workflow_fallback() {
  local branch="$1"
  local base="$2"
  local issue_number="$3"
  local repo="$4"

  # Check if there are unpushed commits
  git fetch origin > /dev/null 2>&1 || true
  local local_head remote_head
  local_head="$(git rev-parse HEAD)"
  remote_head="$(git rev-parse "origin/${branch}" 2>/dev/null || echo "")"

  if [[ "${local_head}" == "${remote_head}" ]]; then
    echo "Branch ${branch} is already up to date with remote." >&2
    return 2
  fi

  # Attempt to push
  echo "Pushing branch ${branch}..." >&2
  local push_exit=0
  git push origin "${branch}" 2>&1 || push_exit=$?

  if [[ ${push_exit} -eq 0 ]]; then
    echo "Push succeeded." >&2
    return 0
  fi

  echo "Push failed (exit code ${push_exit}). Checking for workflow changes..." >&2

  # Check if there are workflow changes
  if ! has_workflow_changes "${base}"; then
    echo "Push failed but no workflow changes detected." >&2
    return 1
  fi

  echo "Workflow changes detected. Generating patch and posting to issue..." >&2

  # Generate the patch comment
  local patch_comment
  patch_comment="$(format_patch_comment "${base}")" || true

  if [[ -z "${patch_comment}" ]]; then
    echo "WARNING: Failed to generate patch comment." >&2
    return 1
  fi

  # Post or update the patch comment on the issue
  if command -v gh &> /dev/null && [[ -n "${issue_number}" ]] && [[ -n "${repo}" ]]; then
    # Check if a patch comment already exists (avoid duplicates)
    local existing_comment_id=""
    existing_comment_id="$(gh api "repos/${repo}/issues/${issue_number}/comments" \
      --jq '.[] | select(.body | contains("<!-- ralph-comment-workflow-patch -->")) | .id' \
      2>/dev/null | tail -1 || echo "")"

    if [[ -n "${existing_comment_id}" ]]; then
      echo "Updating existing workflow patch comment (ID: ${existing_comment_id})..." >&2
      gh api "repos/${repo}/issues/comments/${existing_comment_id}" \
        -X PATCH -f body="${patch_comment}" > /dev/null 2>&1 || true
    else
      echo "Posting workflow patch comment to issue #${issue_number}..." >&2
      gh issue comment "${issue_number}" --repo "${repo}" --body "${patch_comment}" > /dev/null 2>&1 || true
    fi
  fi

  # Remove workflow changes and retry push
  echo "Removing workflow changes from branch..." >&2
  remove_workflow_changes "${base}"

  echo "Retrying push after removing workflow changes..." >&2
  git push origin "${branch}" 2>&1 || {
    echo "WARNING: Push still failed after removing workflow changes." >&2
    return 1
  }

  echo "Push succeeded after removing workflow changes and posting patch." >&2
  return 0
}

# Main: generate and print the formatted patch comment
main() {
  local base="${1:-origin/main}"

  if ! has_workflow_changes "${base}"; then
    echo "No workflow file changes detected." >&2
    exit 2
  fi

  format_patch_comment "${base}"
}

# Only run main when executed directly (not when sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
