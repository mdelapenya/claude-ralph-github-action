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
shellcheck --severity=warning entrypoint.sh scripts/*.sh test/*.sh

# Run locally (requires ANTHROPIC_API_KEY)
ANTHROPIC_API_KEY=sk-... ./test/run-local.sh

# Run with verbose Claude CLI output
RALPH_VERBOSE=true ANTHROPIC_API_KEY=sk-... ./test/run-local.sh

# Override models/limits for testing
INPUT_WORKER_MODEL=haiku INPUT_MAX_ITERATIONS=1 ANTHROPIC_API_KEY=sk-... ./test/run-local.sh
```

## Conventions

- All scripts use `set -euo pipefail` and are ShellCheck-clean at `--severity=warning`.
- State is persisted in `.ralph/` files (plain text) in the working tree only (never committed to the branch).
- The `RALPH_VERBOSE` env var adds `--verbose` to claude CLI calls in worker.sh and reviewer.sh.
- Environment variables prefixed `INPUT_` map to action.yml inputs (GitHub Actions convention).
