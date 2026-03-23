# Security Policy

## Supported Versions

Only the latest release is actively maintained. Security fixes are not backported to older tags.

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Report vulnerabilities by emailing **mdelapenya@gmail.com** with the subject line `[SECURITY] claude-ralph-github-action`. You should receive a response within 72 hours. Once a fix is confirmed, a new release will be published and a GitHub Security Advisory will be opened to publicly credit the report.

---

## Supply Chain Security

### The Risk

This action runs code in your GitHub Actions runner with access to the secrets you provide (`ANTHROPIC_API_KEY`, `github_token`). If this repository were compromised — through a stolen maintainer credential, a malicious PR, or a Docker Hub account takeover — a consumer pinned to a mutable reference (`@v1`, `@main`, `@latest`) would automatically run the attacker's code on their next workflow execution.

The Docker image used by the action (`docker://mdelapenya/claude-ralph-github-action:latest`) faces the same risk: `latest` resolves at runtime and can be silently swapped.

### How to Protect Yourself

#### 1. Pin to an immutable commit SHA

A git tag (`v1`) is mutable — it can be force-pushed to a different commit. A full SHA cannot be retroactively changed:

```yaml
# UNSAFE — tag can be moved without notice
- uses: mdelapenya/claude-ralph-github-action@v1

# SAFE — SHA is immutable
- uses: mdelapenya/claude-ralph-github-action@f8a8ef2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f  # v1.2.3
```

To find the current SHA for the latest release:

```bash
gh release view --repo mdelapenya/claude-ralph-github-action --json tagName,targetCommitish
```

#### 2. Use Dependabot to keep the pinned SHA current

Add this to `.github/dependabot.yml` to get automatic PRs when a new release is available:

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
```

Dependabot will update the SHA comment and pin in a PR for your review — you get the security of a pin without the maintenance burden of manually tracking new releases.

#### 3. Restrict the action's permissions

Grant only the permissions the action actually needs:

```yaml
permissions:
  contents: write       # create branches, commit, push
  pull-requests: write  # open and update PRs
  issues: write         # comment on issues
```

Do **not** grant `actions: write` or `packages: write` unless you have a specific reason.

#### 4. Use a short-lived PAT or OIDC token instead of a long-lived secret

If you need `workflow` scope (for Ralph to modify `.github/workflows/` files), prefer a fine-grained PAT scoped to a single repository over a classic PAT with broad access.

#### 5. Audit runner logs

When `RALPH_VERBOSE=true`, runner logs will contain full tool-call payloads including file contents. Do not enable this in public repositories or workflows with public log visibility, as it may expose secrets that are referenced in source files.

---

## Threat Model

| Threat | Mitigation |
|--------|-----------|
| Compromised maintainer account pushes malicious code to `main` | Pin to a commit SHA; use Dependabot for updates |
| Docker Hub account takeover replaces the image | Pin the action SHA (the SHA controls which Dockerfile is used) |
| Malicious issue content attempts prompt injection into worker/reviewer agents | All GitHub issue content is wrapped in `<user-input>` tags and treated as untrusted data; agents are instructed not to follow instructions embedded in those tags |
| Malicious code in a PR injects instructions into the security gate | Security gate system prompt has explicit injection detection; any file content resembling instructions triggers a CRITICAL finding and automatic FAIL |
| Worker agent commits secrets to the branch | Security gate checks git history for credential patterns before approving a ship |
| Reviewer agent is manipulated into shipping insecure code | Security gate is a separate, independent agent invocation — it runs after the reviewer, has a different system prompt, and cannot be influenced by the reviewer's reasoning |
| `squash-merge` strategy pushes untrusted code directly to default branch | The security gate blocks ship on any finding of MEDIUM severity or higher; only a clean PASS permits merge |

---

## Security Gate

This action includes a built-in **security gate** — an independent Claude agent that runs after the reviewer approves and before any branch is shipped. It audits the full branch diff for:

- Hardcoded secrets and credentials (including in git history)
- Injection vulnerabilities (command, SQL, path traversal, XSS, SSRF)
- Authentication and authorization issues
- Cryptographic weaknesses
- Shell script safety (unquoted variables, `eval` with external input, insecure temp files)
- Dependency pinning
- Information disclosure
- Privilege and file-system issues

The gate defaults to **FAIL** if it produces no output (fail-safe). Any finding of MEDIUM severity or higher blocks the ship and forces another worker iteration with the findings as feedback. Prompt injection attempts detected in any file the gate reads are themselves treated as a CRITICAL finding.

The gate can be disabled by setting `security_gate_enabled: false`. This is not recommended for production use.
