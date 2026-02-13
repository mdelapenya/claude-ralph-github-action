# Claude Ralph GitHub Action

A GitHub Action that implements the **Ralph loop** pattern: iterative work/review/ship cycles on GitHub issues using [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code).

When you label an issue, Ralph:
1. Creates a branch and reads the issue description
2. Runs a **worker** agent that writes code to address the issue
3. Runs a **reviewer** agent that evaluates the changes
4. If the reviewer says **REVISE**, loops back to step 2 with feedback
5. If the reviewer says **SHIP**, pushes the branch and opens a PR

## Quick Start

1. Add `ANTHROPIC_API_KEY` as a [repository secret](https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions)

2. Create `.github/workflows/ralph.yml`:

```yaml
name: Ralph Loop

on:
  issues:
    types: [labeled]

permissions:
  contents: write
  pull-requests: write
  issues: write

jobs:
  ralph:
    if: github.event.label.name == 'ralph'
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4

      - uses: mdelapenya/claude-ralph-github-action@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
```

3. Create a `ralph` label in your repository
4. Label any issue with `ralph` to trigger the loop

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `anthropic_api_key` | Yes | — | Anthropic API key for Claude CLI |
| `github_token` | No | `${{ github.token }}` | GitHub token for PR and issue operations |
| `worker_model` | No | `sonnet` | Claude model for the worker phase |
| `reviewer_model` | No | `sonnet` | Claude model for the review phase |
| `max_iterations` | No | `5` | Maximum number of work/review cycles |
| `max_turns_worker` | No | `30` | Maximum agentic turns per worker invocation |
| `max_turns_reviewer` | No | `10` | Maximum agentic turns per reviewer invocation |
| `trigger_label` | No | `ralph` | Issue label that triggers the loop |
| `base_branch` | No | `main` | Branch to create the PR against |
| `worker_allowed_tools` | No | `Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,Task` | Comma-separated tools the worker can use |
| `reviewer_tools` | No | `Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,Task` | Comma-separated tools the reviewer can use |

## Outputs

| Output | Description |
|--------|-------------|
| `pr_url` | URL of the created or updated pull request |
| `iterations` | Number of work/review iterations completed |
| `final_status` | `SHIPPED`, `MAX_ITERATIONS`, or `ERROR` |

## How It Works

Ralph creates a `.ralph/` directory on the working branch to persist state across iterations:

- **`task.md`** — The issue title and body
- **`work-summary.txt`** — Worker's summary of changes made
- **`review-result.txt`** — `SHIP` or `REVISE`
- **`review-feedback.txt`** — Reviewer's feedback for the next iteration
- **`iteration.txt`** — Current iteration number

The worker agent can read/write code but cannot create commits or PRs. The reviewer agent can only read files and write its verdict. The orchestration scripts handle git operations, PR management, and issue comments.

### Re-runs

If the `ralph` label is removed and re-added, Ralph detects the existing branch, checks it out, and continues from where it left off. The worker receives a context file with the branch's commit history so it understands what was already done. New commits are added on top — Ralph never force-pushes.

### Pull requests

Ralph only works on **issues**. If the `ralph` label is added to a pull request, Ralph will post a comment explaining it can only work on issues, and exit without making changes.

## Local Testing

```bash
# Requires Docker and an Anthropic API key
ANTHROPIC_API_KEY=sk-... ./test/run-local.sh

# With verbose Claude CLI output
RALPH_VERBOSE=true ANTHROPIC_API_KEY=sk-... ./test/run-local.sh

# Override defaults
INPUT_WORKER_MODEL=haiku INPUT_MAX_ITERATIONS=1 ANTHROPIC_API_KEY=sk-... ./test/run-local.sh
```

## License

[MIT](LICENSE)
