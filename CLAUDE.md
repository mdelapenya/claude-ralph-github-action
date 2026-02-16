# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Docker-based GitHub Action implementing the "Ralph loop" pattern: iterative work/review/ship cycles on GitHub issues using Claude Code CLI. When an issue is labeled, the action creates a branch, runs a worker agent (writes code) and reviewer agent (evaluates it) in a loop until the reviewer SHIPs or max iterations is reached, then opens a PR.

## Architecture

The orchestration is entirely in bash. The flow is:

**entrypoint.sh** -> extracts issue data, sets up git branch, initializes `.ralph/` state -> calls **ralph-loop.sh**

**ralph-loop.sh** -> iterates: **worker.sh** (claude -p with worker prompt) -> check for commits -> **reviewer.sh** (claude -p with reviewer prompt) -> check SHIP/REVISE -> loop or exit. If the worker makes no commits, the loop continues to the next iteration with feedback instead of aborting.

**state.sh** -> read/write helpers for `.ralph/` directory (task, iteration, review result, feedback, status). State lives in the working tree only and is never committed to the branch.

**pr-manager.sh** -> creates/updates PR via `gh`, comments on the issue with results.

**prompts/** -> system prompts appended to claude CLI calls. Worker gets `worker-system.md`, reviewer gets `reviewer-system.md`.

Key design: the worker and reviewer are invoked via `claude -p` (print/non-interactive mode) with `--allowedTools` to sandbox capabilities. The worker merges the base branch, resolves any conflicts, implements the task, and commits directly. The reviewer evaluates changes, runs tests/linters, and decides SHIP or REVISE.

## Build & Test

```bash
# Build Docker image
docker build -t claude-ralph-test .

# Lint all shell scripts
shellcheck --severity=warning entrypoint.sh scripts/*.sh test/**/*.sh test/*.sh

# Run all unit + integration tests (no API key needed)
bash test/run-all-tests.sh

# Run locally against real Claude (requires ANTHROPIC_API_KEY)
ANTHROPIC_API_KEY=sk-... ./test/run-local.sh

# Run with verbose Claude CLI output
RALPH_VERBOSE=true ANTHROPIC_API_KEY=sk-... ./test/run-local.sh

# Override models/limits for testing
INPUT_WORKER_MODEL=haiku INPUT_MAX_ITERATIONS=1 ANTHROPIC_API_KEY=sk-... ./test/run-local.sh
```

### Test Structure

Tests live in `test/` and are organized as:

- **`test/unit/`** — Unit tests for individual functions (state.sh helpers, output format validation)
- **`test/integration/`** — Integration tests that exercise real scripts (`ralph-loop.sh` -> `worker.sh` -> `reviewer.sh`) with mock `claude` and `gh` binaries
- **`test/helpers/`** — Shared test utilities:
  - `setup.sh` — Workspace creation, environment setup, event JSON generation
  - `mocks.sh` — Mock `claude` and `gh` binaries placed on PATH; configurable via `MOCK_REVIEW_DECISION`, `MOCK_WORKER_FAIL`, `MOCK_MERGE_STRATEGY`
- **`test/run-all-tests.sh`** — Runs all `test/unit/test-*.sh` and `test/integration/test-*.sh` files

Integration tests create isolated temp workspaces with bare git remotes, so `git push` works without network access. Each test configures mock behavior via env vars, runs the real loop scripts, and validates `.ralph/` state files and exit codes.

## Key Features

### State Management
State is persisted in `.ralph/` directory (plain text files) in the working tree only and is never committed to the branch:
- `task.md` — Issue title and body
- `pr-info.txt` — Repo, branch, issue title, and existing PR number
- `work-summary.txt` — Worker's summary of changes made
- `review-result.txt` — `SHIP` or `REVISE`
- `review-feedback.txt` — Reviewer's feedback for the next iteration
- `pr-title.txt` — PR title in conventional commits format (set by reviewer)
- `iteration.txt` — Current iteration number

### PR Titles
PR titles follow [conventional commits](https://www.conventionalcommits.org/) format. The reviewer agent infers the type from changes and sets the title. Supported types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `style`, `perf`, `build`, `ci`, `revert`.

### Merge Strategies
- **`pr` (default)**: Creates/updates a pull request for human review
- **`squash-merge`**: Squashes commits and pushes directly to default branch when reviewer approves

### Re-runs
Ralph triggers on label addition or issue edits. If a branch exists, Ralph checks it out and continues from where it left off, never force-pushing.

### Multi-Agent Support
The worker can split complex tasks into multiple subtasks by creating GitHub issues via `/scripts/create-subtask-issues.sh`. Each subtask is processed by a separate Ralph instance in parallel.

## Conventions

- All scripts use `set -euo pipefail` and are ShellCheck-clean at `--severity=warning`.
- State is persisted in `.ralph/` files (plain text) in the working tree only (never committed to the branch).
- The `RALPH_VERBOSE` env var adds `--verbose` to claude CLI calls in worker.sh and reviewer.sh.
- Environment variables prefixed `INPUT_` map to action.yml inputs (GitHub Actions convention).
- Worker and reviewer agents use `claude -p` (print/non-interactive mode) with `--allowedTools` for sandboxing.
- Worker merges base branch and resolves conflicts at the start of each iteration.
- All commits must follow conventional commits format.
