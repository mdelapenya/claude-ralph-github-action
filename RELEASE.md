# Release Process

This project uses [Release Drafter](https://github.com/release-drafter/release-drafter) to automate release notes and a release workflow to maintain floating major version tags.

## How It Works

### 1. PR Labels Drive Release Notes

When pull requests are merged to `main`, Release Drafter automatically updates a **draft release** on GitHub with categorized notes. Label your PRs to control where they appear:

| Label | Release Notes Category |
|-------|----------------------|
| `ralph` | Ralph Shipped This |
| `enhancement`, `feature` | New Loop Powers |
| `bug`, `fix` | Bug Squashed by the Loop |
| `prompts`, `agents` | Worker & Reviewer Tuning |
| `chore`, `dependencies` | Under the Hood |
| `skip-changelog` | Excluded from release notes |

### 2. Version Bumps Are Label-Driven

The version in the draft release is resolved from PR labels:

| Label | Bump | Example |
|-------|------|---------|
| `major` | Major | `v1.2.3` -> `v2.0.0` |
| `minor` | Minor | `v1.2.3` -> `v1.3.0` |
| `patch` | Patch | `v1.2.3` -> `v1.2.4` |
| _(none)_ | Patch (default) | `v1.2.3` -> `v1.2.4` |

## Performing a Release

### Step 1: Review the Draft Release

Go to [Releases](../../releases) on GitHub. You should see a **Draft** release at the top with auto-generated notes from all merged PRs since the last release.

- Review the release notes for accuracy
- Edit the notes if needed (add context, fix typos, reorder items)
- Verify the version number is correct (adjust the tag if the auto-resolved version isn't right)

### Step 2: Publish the Release

Click **Publish release**. This does two things:

1. Creates the semver git tag (e.g., `v1.2.0`) pointing at the `main` branch HEAD
2. Publishes the release on GitHub with the notes you reviewed

### Step 3: Floating Tag Update (Automatic)

The `release.yml` workflow triggers automatically when the release is published. It:

1. Parses the major version from the tag (`v1.2.0` -> `v1`)
2. Force-pushes the `v1` tag to point at the same commit

This means users referencing `uses: mdelapenya/claude-ralph-github-action@v1` will automatically get the latest release without changing their workflows.

**No manual action is needed for this step.**

### Step 4: Verify

After the release workflow completes:

- Check the [Actions tab](../../actions/workflows/release.yml) to confirm the workflow succeeded
- Verify the `v1` tag points to the correct commit:
  ```bash
  git fetch --tags --force
  git log --oneline -1 v1
  git log --oneline -1 v1.2.0  # should match
  ```

## First Release

For the very first release of a new major version:

1. Ensure the draft release exists (merge at least one PR to `main`)
2. Edit the draft to set the tag to `v1.0.0`
3. Publish — the release workflow will create both `v1.0.0` and `v1` tags

## Rollback

If a release is bad, you can point the major version tag back to a previous release:

```bash
git tag -fa v1 v1.1.0 -m "Rollback v1 to v1.1.0"
git push origin v1 --force
```

This immediately rolls back all users referencing `@v1`.

## CLI Alternative

You can also publish from the command line instead of the GitHub UI:

```bash
# Publish the draft release (creates the semver tag)
gh release edit v1.2.0 --draft=false

# Or create a release from scratch
gh release create v1.2.0 --title "v1.2.0" --generate-notes
```

The release workflow will handle the floating tag update in either case.
