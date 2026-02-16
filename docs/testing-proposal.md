# Testing Proposal: Validating Claude Ralph Action Outputs

## Overview

This document proposes a comprehensive testing strategy for validating the outputs of the Claude Ralph GitHub Action after each pull request. The goal is to ensure the action functions correctly, produces expected outputs, and handles various scenarios appropriately.

## Current Action Outputs

The Claude Ralph Action provides three outputs (defined in `action.yml`):

| Output | Type | Description |
|--------|------|-------------|
| `pr_url` | string | URL of the created/updated pull request, or merge commit SHA when using squash-merge strategy |
| `iterations` | number | Number of work/review iterations completed |
| `final_status` | string | Final status: `SHIPPED`, `MAX_ITERATIONS`, or `ERROR` |

## Testing Strategy

### 1. Automated Integration Tests (Post-PR Workflow)

Create a new workflow `.github/workflows/test-action-output.yml` that runs after pull requests are merged to validate the action works correctly in different scenarios.

#### Test Scenarios

##### Scenario 1: Basic Issue Processing
- **Setup**: Create a test issue with a simple, well-defined task
- **Trigger**: Label the issue with `ralph`
- **Validations**:
  - Action completes successfully (exit code 0)
  - `final_status` is either `SHIPPED` or `MAX_ITERATIONS`
  - `iterations` is a positive integer ≤ `max_iterations`
  - `pr_url` contains a valid GitHub PR URL or commit SHA
  - Created PR/branch exists and contains commits
  - PR title follows conventional commits format

##### Scenario 2: Multi-Iteration Task
- **Setup**: Create an issue requiring multiple refinements
- **Configuration**: Set `max_iterations: 3`
- **Validations**:
  - `iterations` reflects multiple cycles
  - Work summary contains entries for each iteration
  - Review feedback is properly passed between iterations
  - Final PR contains accumulated commits

##### Scenario 3: Max Iterations Reached
- **Setup**: Create a complex issue with `max_iterations: 1`
- **Validations**:
  - `final_status` equals `MAX_ITERATIONS`
  - PR is still created for human review
  - Exit code is 0 (not treated as failure)
  - Issue has a comment explaining max iterations reached

##### Scenario 4: Squash-Merge Strategy
- **Setup**: Issue with `merge_strategy: squash-merge`
- **Validations**:
  - On SHIP: `pr_url` contains a commit SHA
  - Commit is present on default branch
  - Commit message follows conventional commits format
  - Issue is automatically closed

##### Scenario 5: Error Handling
- **Setup**: Intentional failure scenarios (invalid task, syntax errors)
- **Validations**:
  - `final_status` equals `ERROR`
  - Exit code is non-zero
  - Error is logged in action output
  - Issue has a comment with error details

##### Scenario 6: Re-run on Existing Branch
- **Setup**: Issue that was previously processed
- **Trigger**: Edit issue and re-trigger
- **Validations**:
  - Branch is checked out (not recreated)
  - New commits are added to existing branch
  - No force-push occurs
  - PR is updated, not recreated

#### Test Implementation Structure

```yaml
name: Test Action Outputs

on:
  pull_request:
    branches: [main]
    types: [closed]
  workflow_dispatch:
    inputs:
      test_scenario:
        description: 'Test scenario to run'
        required: false
        type: choice
        options:
          - all
          - basic
          - multi-iteration
          - max-iterations
          - squash-merge
          - error-handling
          - re-run

permissions:
  contents: write
  pull-requests: write
  issues: write
  actions: read

jobs:
  test-basic-issue:
    if: github.event.pull_request.merged == true || github.event_name == 'workflow_dispatch'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: main

      - name: Create test issue
        id: create-issue
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          issue_number=$(gh issue create \
            --title "Test: Add hello world function" \
            --body "Create a simple hello world function in a new file test-hello.js that exports a function returning 'Hello, World!'" \
            --label "ralph-test" \
            --json number --jq '.number')
          echo "issue_number=${issue_number}" >> $GITHUB_OUTPUT

      - name: Trigger Ralph action
        id: ralph
        uses: ./
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          trigger_label: "ralph-test"
        continue-on-error: true

      - name: Validate outputs
        env:
          PR_URL: ${{ steps.ralph.outputs.pr_url }}
          ITERATIONS: ${{ steps.ralph.outputs.iterations }}
          FINAL_STATUS: ${{ steps.ralph.outputs.final_status }}
          ISSUE_NUMBER: ${{ steps.create-issue.outputs.issue_number }}
        run: |
          echo "=== Ralph Action Outputs ==="
          echo "PR URL: ${PR_URL}"
          echo "Iterations: ${ITERATIONS}"
          echo "Final Status: ${FINAL_STATUS}"

          # Validate outputs are not empty
          if [[ -z "${PR_URL}" ]]; then
            echo "ERROR: pr_url output is empty"
            exit 1
          fi

          if [[ -z "${ITERATIONS}" ]]; then
            echo "ERROR: iterations output is empty"
            exit 1
          fi

          if [[ -z "${FINAL_STATUS}" ]]; then
            echo "ERROR: final_status output is empty"
            exit 1
          fi

          # Validate final_status is one of expected values
          if [[ "${FINAL_STATUS}" != "SHIPPED" ]] && [[ "${FINAL_STATUS}" != "MAX_ITERATIONS" ]] && [[ "${FINAL_STATUS}" != "ERROR" ]]; then
            echo "ERROR: final_status has unexpected value: ${FINAL_STATUS}"
            exit 1
          fi

          # Validate iterations is a positive number
          if ! [[ "${ITERATIONS}" =~ ^[0-9]+$ ]] || [[ "${ITERATIONS}" -lt 1 ]]; then
            echo "ERROR: iterations is not a positive integer: ${ITERATIONS}"
            exit 1
          fi

          # Validate PR URL format (should be GitHub URL or commit SHA)
          if [[ "${PR_URL}" =~ ^https://github.com/ ]]; then
            echo "✓ PR URL is a valid GitHub URL"
            # Extract PR number and verify it exists
            pr_number=$(echo "${PR_URL}" | grep -oP '/pull/\K[0-9]+' || echo "")
            if [[ -n "${pr_number}" ]]; then
              gh pr view "${pr_number}" --json title,state
            fi
          elif [[ "${PR_URL}" =~ ^[0-9a-f]{40}$ ]]; then
            echo "✓ PR URL is a commit SHA (squash-merge strategy)"
            git fetch origin
            git cat-file -t "${PR_URL}" || {
              echo "ERROR: Commit SHA ${PR_URL} does not exist"
              exit 1
            }
          else
            echo "ERROR: pr_url has unexpected format: ${PR_URL}"
            exit 1
          fi

          echo "✓ All output validations passed"

      - name: Cleanup test issue
        if: always()
        env:
          GH_TOKEN: ${{ github.token }}
          ISSUE_NUMBER: ${{ steps.create-issue.outputs.issue_number }}
        run: |
          if [[ -n "${ISSUE_NUMBER}" ]]; then
            gh issue close "${ISSUE_NUMBER}" --comment "Test completed, closing issue"
          fi
```

### 2. Output Validation Checks

#### Required Validations

1. **Output Presence**: All three outputs must be set (non-empty)
2. **Type Validation**:
   - `iterations` must be a positive integer
   - `final_status` must be one of: `SHIPPED`, `MAX_ITERATIONS`, `ERROR`
3. **Consistency Checks**:
   - If `final_status` is `SHIPPED`, `pr_url` must be valid
   - `iterations` must be ≤ configured `max_iterations`
   - If `iterations` equals `max_iterations` and status is not `SHIPPED`, status should be `MAX_ITERATIONS`
4. **Resource Validation**:
   - If `pr_url` is a GitHub URL, the PR must exist and be accessible
   - If `pr_url` is a commit SHA, the commit must exist in the repository
   - Generated branches should exist on remote

### 3. Smoke Tests for Each PR

Add a lightweight smoke test to the CI workflow (`.github/workflows/ci.yml`) that validates the action can be built and basic functionality works:

```yaml
  action-smoke-test:
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    steps:
      - uses: actions/checkout@v4

      - name: Validate action.yml
        run: |
          # Check action.yml is valid YAML
          cat action.yml | python3 -c "import sys, yaml; yaml.safe_load(sys.stdin)"

          # Validate outputs are defined
          for output in pr_url iterations final_status; do
            if ! grep -q "${output}:" action.yml; then
              echo "ERROR: Output ${output} not defined in action.yml"
              exit 1
            fi
          done

      - name: Build Docker image
        run: docker build -t claude-ralph-test .

      - name: Test entrypoint validation
        run: |
          # Test that entrypoint catches missing ANTHROPIC_API_KEY
          docker run --rm -e GITHUB_EVENT_PATH=/dev/null \
            claude-ralph-test 2>&1 | grep -q "ANTHROPIC_API_KEY" || {
            echo "ERROR: Entrypoint should validate ANTHROPIC_API_KEY"
            exit 1
          }
```

### 4. Manual Testing Checklist

Before major releases, manually verify:

- [ ] Action works with all supported Claude models (sonnet, opus, haiku)
- [ ] Both merge strategies (`pr` and `squash-merge`) work correctly
- [ ] Multi-agent splitting functionality works
- [ ] Re-runs preserve branch state correctly
- [ ] Error scenarios are handled gracefully
- [ ] Output values are correctly propagated to `GITHUB_OUTPUT`
- [ ] Permissions requirements are correct
- [ ] Documentation matches actual behavior

### 5. Metrics and Monitoring

Consider tracking these metrics over time:

- Average iterations per issue
- Success rate (SHIPPED vs MAX_ITERATIONS vs ERROR)
- Time to completion
- PR quality metrics (review cycles, merge rate)

## Implementation Timeline

1. **Phase 1** (Week 1): Implement basic output validation tests
   - Create test workflow skeleton
   - Add basic scenario (simple issue)
   - Add output format validation

2. **Phase 2** (Week 2): Expand test coverage
   - Add multi-iteration scenario
   - Add max iterations scenario
   - Add error handling tests

3. **Phase 3** (Week 3): Advanced scenarios
   - Add squash-merge tests
   - Add re-run tests
   - Add smoke tests to CI

4. **Phase 4** (Week 4): Monitoring and refinement
   - Add metrics collection
   - Document test scenarios
   - Create manual testing checklist

## Testing Best Practices

1. **Isolation**: Each test should create and clean up its own resources
2. **Idempotency**: Tests should be safe to run multiple times
3. **Fast Feedback**: Basic validations should run quickly
4. **Clear Reporting**: Test results should clearly indicate what failed and why
5. **Cost Awareness**: Minimize API usage in tests (use haiku model, low iteration limits)
6. **Real Conditions**: Test against actual GitHub API and repository state

## Security Considerations

- Test workflows should use separate API keys if possible (with usage limits)
- Test issues/PRs should be clearly labeled to avoid confusion
- Cleanup should be robust to prevent resource leaks
- Test data should not contain sensitive information

## Success Criteria

The testing strategy is successful when:

1. Every PR to main is validated against the action outputs
2. Breaking changes are caught before merge
3. Test failures provide actionable debugging information
4. Tests complete within reasonable time (< 10 minutes for full suite)
5. False positive rate is < 5%

## Appendix: Example Test Workflow Structure

```yaml
name: Test Action Outputs

on:
  pull_request:
    branches: [main]
    types: [closed]
  workflow_dispatch:

jobs:
  test-matrix:
    if: github.event.pull_request.merged == true || github.event_name == 'workflow_dispatch'
    strategy:
      fail-fast: false
      matrix:
        scenario:
          - name: basic-issue
            title: "Test: Add hello world function"
            body: "Create a simple function"
            model: haiku
            max_iterations: 3
            merge_strategy: pr
            expected_status: SHIPPED

          - name: max-iterations
            title: "Test: Complex refactoring"
            body: "Refactor the entire codebase"
            model: haiku
            max_iterations: 1
            merge_strategy: pr
            expected_status: MAX_ITERATIONS

    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: main

      - name: Run test scenario
        uses: ./.github/actions/test-scenario
        with:
          scenario: ${{ matrix.scenario.name }}
          title: ${{ matrix.scenario.title }}
          body: ${{ matrix.scenario.body }}
          model: ${{ matrix.scenario.model }}
          max_iterations: ${{ matrix.scenario.max_iterations }}
          merge_strategy: ${{ matrix.scenario.merge_strategy }}
          expected_status: ${{ matrix.scenario.expected_status }}
```

## Conclusion

This proposal provides a comprehensive approach to testing the Claude Ralph Action outputs. By implementing automated tests that validate outputs after each PR, we can ensure the action continues to work correctly as the codebase evolves. The testing strategy balances thoroughness with practicality, focusing on the most critical scenarios while remaining cost-effective with API usage.
