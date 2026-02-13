# Add early input validation to entrypoint.sh

The entrypoint should fail fast with clear error messages instead of failing deep in the worker/reviewer scripts.

  Add validation at the top of entrypoint.sh (after sourcing dependencies, before any work) that checks:

  - ANTHROPIC_API_KEY is set and non-empty
  - GITHUB_EVENT_PATH points to an existing file
  - GITHUB_WORKSPACE is set and is a directory
  - jq is available on PATH (required for event parsing)
  - The event file contains a valid issue number (non-empty, numeric)

  Each check should print a clear error message with the emoji prefix ❌ and exit 1.

  Acceptance criteria:
  - All five checks are present and exit 1 on failure
  - Error messages clearly identify what's wrong and how to fix it
  - Existing tests still work (shellcheck --severity=warning passes)
  - Validation runs before any git operations or Claude CLI calls
