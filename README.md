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
    types: [labeled, edited]
  pull_request:
    types: [labeled]

permissions:
  contents: write
  pull-requests: write
  issues: write

jobs:
  reject-pr:
    if: github.event_name == 'pull_request' && github.event.label.name == 'ralph'
    runs-on: ubuntu-latest
    steps:
      - name: Comment on PR
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh pr comment "${{ github.event.pull_request.number }}" \
            --repo "${{ github.repository }}" \
            --body "🤖 **Ralph** can only work on issues, not pull requests. Please create an issue and label it with \`ralph\` instead."

  ralph:
    if: >-
      (github.event.action == 'labeled' && github.event.label.name == 'ralph') ||
      (github.event.action == 'edited' && contains(github.event.issue.labels.*.name, 'ralph'))
    runs-on: ubuntu-latest
    timeout-minutes: 60
    concurrency:
      group: ralph-${{ github.event.issue.number }}
      cancel-in-progress: false
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
| `max_turns_reviewer` | No | `30` | Maximum agentic turns per reviewer invocation |
| `trigger_label` | No | `ralph` | Issue label that triggers the loop |
| `base_branch` | No | — | Branch to create the PR against (auto-detected from repository default branch if not specified) |
| `worker_allowed_tools` | No | `Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,Task` | Comma-separated tools the worker can use |
| `reviewer_tools` | No | `Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,Task` | Comma-separated tools the reviewer can use |
| `merge_strategy` | No | `pr` | Merge strategy: `pr` (create a pull request) or `squash-merge` (squash and push directly to default branch) |
| `default_branch` | No | — | Default branch to merge into when using `squash-merge` strategy (auto-detected from repo if not specified) |
| `worker_tone` | No | — | Personality/tone for the worker agent (e.g., "pirate", "formal", "enthusiastic"). If set, the worker will respond with this personality |
| `reviewer_tone` | No | — | Personality/tone for the reviewer agent (e.g., "pirate", "formal", "enthusiastic"). If set, the reviewer will respond with this personality |

## Outputs

| Output | Description |
|--------|-------------|
| `pr_url` | URL of the created/updated pull request, or merge commit SHA when using `squash-merge` |
| `iterations` | Number of work/review iterations completed |
| `final_status` | `SHIPPED`, `MAX_ITERATIONS`, or `ERROR` |

## How It Works

Ralph creates a `.ralph/` directory in the working tree (never committed to the branch) to pass state between agents:

- **`task.md`** — The issue title and body
- **`pr-info.txt`** — Repo, branch, issue title, and existing PR number (if any)
- **`work-summary.txt`** — Worker's summary of changes made
- **`review-result.txt`** — `SHIP` or `REVISE`
- **`review-feedback.txt`** — Reviewer's feedback for the next iteration
- **`pr-title.txt`** — PR title in conventional commits format (set by reviewer)
- **`iteration.txt`** — Current iteration number

The worker agent merges the base branch (resolving any conflicts), implements the task, and commits changes directly. The reviewer agent evaluates the changes, runs tests and linters independently, and decides whether to SHIP or REVISE. If the worker makes no commits in an iteration, the loop continues to the next iteration with feedback instead of aborting.

### PR titles

PR titles follow [conventional commits](https://www.conventionalcommits.org/) format. The **reviewer** agent infers the type from the changes and sets the title:

```
feat: add input validation to entrypoint
fix: resolve git safe directory error
chore: update dependencies
refactor: simplify state management
```

Supported types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`.

If a PR already exists (on re-runs), the reviewer updates the title directly via `gh pr edit`. On the first run, the reviewer writes the title to `.ralph/pr-title.txt` and the orchestration uses it when creating the PR.

### Re-runs and Issue Edits

Ralph triggers in two ways:
- **Label added:** When the `ralph` label is added to an issue (first run or re-trigger by removing and re-adding the label).
- **Issue edited:** When an issue that already has the `ralph` label is edited (title or body changed). This lets you refine requirements and have Ralph re-process the updated task.

In both cases, Ralph detects the existing branch if one exists, checks it out, and continues from where it left off. The worker re-reads the task from the issue (which may have changed) and the branch's commit history to understand what was already done. New commits are added on top — Ralph never force-pushes.

### Merge Strategies

Ralph supports two merge strategies:

#### `pr` (default)
Creates or updates a pull request. The PR remains open for human review and must be manually merged. This is the recommended approach for most use cases.

#### `squash-merge`
When the reviewer approves (SHIP), Ralph squashes all commits into a single commit and pushes directly to the default branch. The issue is automatically closed. The commit message uses the PR title set by the reviewer (in conventional commits format).

Example workflow configuration for squash-merge:

```yaml
- uses: mdelapenya/claude-ralph-github-action@v1
  with:
    anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
    merge_strategy: squash-merge
```

**Note:** With `squash-merge`, if the reviewer requests revisions, max iterations is reached, or the squash-merge fails for any reason, Ralph falls back to creating a PR for human review.

**Security consideration:** The `squash-merge` strategy pushes directly to the default branch, bypassing pull request reviews and any branch protection rules. Only use this for low-risk, well-scoped tasks where you trust the automated review process.

### Agent Tone Configuration

You can configure the personality and tone of both the worker and reviewer agents. This allows agents to communicate in a specific style while still performing their tasks correctly.

**Example workflow configuration:**

```yaml
- uses: mdelapenya/claude-ralph-github-action@v1
  with:
    anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
    worker_tone: "pirate"
    reviewer_tone: "professional and concise"
```

When tone is configured, the agent will respond with that personality throughout its work. For example, a worker with `worker_tone: "pirate"` might write commit messages and summaries in pirate speak, while still producing correct, functional code.

**Use cases:**
- Fun team projects where personality adds engagement
- Formal corporate environments requiring professional tone
- Educational contexts where enthusiastic encouragement is helpful

The tone instruction is appended to the system prompt, so agents maintain their core capabilities while adopting the requested personality.

### Pull requests

Ralph only works on **issues**. If the `ralph` label is added to a pull request, Ralph will post a comment explaining it can only work on issues, and exit without making changes.

### Multi-Agent Support

Ralph supports splitting complex tasks into multiple subtasks that can be processed in parallel. If the worker agent determines that a task is too complex or would benefit from parallel execution, it can create multiple GitHub issues labeled with `ralph`. Each issue will be processed by a separate Ralph action instance concurrently.

**How it works:**

1. The worker agent assesses the task complexity during implementation
2. If appropriate, it creates temporary files describing each subtask (title and body)
3. It invokes the `/scripts/create-subtask-issues.sh` helper script
4. The script creates GitHub issues with the `ralph` label for each subtask
5. GitHub Actions spawns separate Ralph workflows to process each issue in parallel

**When to split tasks:**

- Multiple independent features or components
- Different areas of the codebase that don't depend on each other
- Large scope that would be clearer as separate, focused tasks

**Example:**

If an issue requests "Add user authentication with login, registration, and password reset," the worker might split it into:
- Issue 1: "Add login API endpoint with JWT authentication"
- Issue 2: "Add registration API endpoint with validation"
- Issue 3: "Add password reset flow with email verification"

Each subtask is then processed independently and can be merged separately, allowing for faster parallel execution and clearer code reviews.

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
