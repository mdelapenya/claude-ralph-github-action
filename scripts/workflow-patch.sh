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
