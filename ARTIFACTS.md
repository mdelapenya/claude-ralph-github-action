# Cross-Execution Context with GitHub Artifacts

Ralph can preserve context across multiple workflow runs using GitHub Actions artifacts. This enables Ralph to continue from where it left off when an issue is re-triggered (e.g., when requirements change and the issue is edited).

## How It Works

1. **Download phase**: When Ralph starts, it checks for a previous artifact and restores the `.ralph/` state
2. **Work phase**: Ralph processes the task, potentially across multiple iterations
3. **Upload phase**: After completing, the workflow uploads the `.ralph/` directory as an artifact

The next time Ralph is triggered on the same issue, it downloads the previous artifact and continues from the last iteration count and review feedback.

## Setup

Ralph's Docker container handles the download and preparation automatically. However, **artifact upload must be added to your workflow** because Docker container actions cannot call `actions/upload-artifact` directly.

### Add to Your Workflow

Add this step **after** the Ralph action in your workflow file:

```yaml
jobs:
  ralph:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Run Ralph
        uses: your-org/claude-ralph@main
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          github_token: ${{ secrets.GITHUB_TOKEN }}

      # Add this step for cross-execution context
      - name: Upload Ralph context artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: ralph-context-issue-${{ github.event.issue.number }}
          path: .ralph/
          retention-days: 7
          if-no-files-found: ignore
```

### Key Configuration

- **`if: always()`**: Upload the artifact even if Ralph fails, so context is preserved
- **`name`**: Must include the issue number so Ralph can find the right artifact
- **`path: .ralph/`**: The directory containing Ralph's state files
- **`retention-days`**: How long GitHub keeps the artifact (7-90 days)
- **`if-no-files-found: ignore`**: Don't fail if `.ralph/` doesn't exist

## What's Preserved

The artifact contains:

- `iteration.txt` - Last iteration number
- `review-feedback.txt` - Reviewer's feedback for the next iteration
- `work-summary.txt` - Worker's summary of all changes
- `pr-info.txt` - PR metadata (repo, branch, issue)
- `pr-title.txt` - Generated PR title
- `final-status.txt` - Final outcome (SHIPPED/MAX_ITERATIONS/etc)
- Other state files Ralph uses internally

## Use Cases

### 1. Changing Requirements

User initially requests feature A, Ralph creates a PR. User edits the issue to also include feature B. Ralph:
1. Downloads the previous artifact
2. Sees it's on iteration 3 with specific review feedback
3. Continues from iteration 3 to add feature B
4. Final PR includes both features with coherent history

### 2. Resuming After Failure

Ralph hits max iterations (default: 5) and stops. User increases `max_iterations` to 10 and re-labels the issue. Ralph:
1. Downloads the artifact from the previous run
2. Continues from iteration 5 with the reviewer's feedback
3. Has up to 5 more iterations to complete the task

### 3. Iterating on Complex Tasks

For large tasks, the user can:
1. Let Ralph work with lower iterations (e.g., 3)
2. Review the WIP PR
3. Edit the issue with refinement requests
4. Ralph continues with the new requirements, preserving context

## Permissions

GitHub Actions has strict permissions for workflow files:
- The default `GITHUB_TOKEN` **cannot modify workflow files** (`.github/workflows/*.yml`)
- Personal Access Tokens (PAT) may have the `workflows` permission, but it's a security risk to grant it broadly
- **Solution**: Users must manually add the artifact upload step to their workflow files

Ralph's repository cannot auto-update your workflow files for security reasons. This is why you need to add the upload step yourself.

## Disabling Cross-Execution Context

If you don't want this feature:
1. Simply don't add the artifact upload step to your workflow
2. Ralph will work normally, starting fresh on each trigger
3. The artifact download will fail gracefully (non-fatal)

## Troubleshooting

### Artifact not found

If you see `ℹ️  No previous context artifact found`, this means:
- No previous run uploaded an artifact (you haven't added the upload step)
- The artifact expired (default retention: 7 days)
- This is the first run for this issue

This is not an error - Ralph will start fresh.

### Artifact upload fails

If the upload step fails, check:
- The `.ralph/` directory exists (it should if Ralph ran)
- Your GitHub token has sufficient permissions
- You're not hitting artifact storage limits for your account

### Context seems stale

Artifacts are named per-issue (`ralph-context-issue-123`). If you want to force a fresh start:
1. Delete the artifact via GitHub UI: Actions → Artifacts
2. Re-trigger Ralph

Or simply create a new issue instead of editing the existing one.

## Implementation Details

The scripts are located in `scripts/`:
- **`artifact-download.sh`**: Downloads and restores context at startup (called by `entrypoint.sh`)
- **`artifact-upload.sh`**: Prepares context for upload (called by `entrypoint.sh` before exit)

The actual upload is handled by the workflow using `actions/upload-artifact@v4` because Docker container actions cannot access the Actions toolkit directly.
