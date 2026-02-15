#!/usr/bin/env bash
# run-local.sh - Build and run the Claude Ralph action locally in Docker
#
# Prerequisites:
#   - Docker
#   - ANTHROPIC_API_KEY environment variable set
#   - GH_TOKEN environment variable set (optional, needed for PR/issue ops)
#
# Usage:
#   ./test/run-local.sh
#   ANTHROPIC_API_KEY=sk-... GH_TOKEN=ghp_... ./test/run-local.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="claude-ralph-local"
TMPDIR=""
ORIGIN_DIR=""

cleanup() {
  if [[ -n "${TMPDIR}" && -d "${TMPDIR}" ]]; then
    rm -rf "${TMPDIR}"
  fi
  if [[ -n "${ORIGIN_DIR}" && -d "${ORIGIN_DIR}" ]]; then
    rm -rf "${ORIGIN_DIR}"
  fi
}
trap cleanup EXIT

# --- Validate prerequisites ---
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "❌ ERROR: ANTHROPIC_API_KEY is not set." >&2
  exit 1
fi

# --- Create a bare repo to act as the fake "origin" remote ---
ORIGIN_DIR="$(mktemp -d)"
git init --bare "${ORIGIN_DIR}"

# --- Create a temporary git repo to act as GITHUB_WORKSPACE ---
TMPDIR="$(mktemp -d)"
git -C "${TMPDIR}" init -b main
git -C "${TMPDIR}" config user.name "test-user"
git -C "${TMPDIR}" config user.email "test@example.com"

# Seed with an initial commit so the branch and remote ref exist
echo "# Test Repo" > "${TMPDIR}/README.md"
git -C "${TMPDIR}" add -A
git -C "${TMPDIR}" commit -m "Initial commit"

# Push to the bare repo so origin/main exists as a real ref
git -C "${TMPDIR}" remote add origin "${ORIGIN_DIR}"
git -C "${TMPDIR}" push origin main

# Rewrite the origin URL to the path where it will be mounted inside the container
git -C "${TMPDIR}" remote set-url origin /origin-repo

echo "📂 Temporary workspace: ${TMPDIR}"
echo "📦 Fake origin repo: ${ORIGIN_DIR}"

# --- Build the Docker image ---
echo ""
echo "🔨 Building Docker image..."
docker build -t "${IMAGE_NAME}" "${REPO_ROOT}"

# --- Run the container ---
echo ""
echo "🚀 Running container..."
docker run --rm \
  -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  -e GH_TOKEN="${GH_TOKEN:-}" \
  -e GITHUB_EVENT_PATH="/tmp/event.json" \
  -e GITHUB_WORKSPACE="/workspace" \
  -e GITHUB_REPOSITORY="test-owner/test-repo" \
  -e GITHUB_OUTPUT="/dev/null" \
  -e INPUT_BASE_BRANCH="main" \
  -e INPUT_WORKER_MODEL="${INPUT_WORKER_MODEL:-sonnet}" \
  -e INPUT_REVIEWER_MODEL="${INPUT_REVIEWER_MODEL:-sonnet}" \
  -e INPUT_MAX_ITERATIONS="${INPUT_MAX_ITERATIONS:-2}" \
  -e INPUT_MAX_TURNS_WORKER="${INPUT_MAX_TURNS_WORKER:-30}" \
  -e INPUT_MAX_TURNS_REVIEWER="${INPUT_MAX_TURNS_REVIEWER:-30}" \
  -e INPUT_WORKER_ALLOWED_TOOLS="Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,Task" \
  -e INPUT_REVIEWER_TOOLS="Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,Task" \
  -e RALPH_VERBOSE="${RALPH_VERBOSE:-true}" \  # Verbose by default in local testing for easier debugging
  -v "${REPO_ROOT}/test/event.json:/tmp/event.json:ro" \
  -v "${TMPDIR}:/workspace" \
  -v "${ORIGIN_DIR}:/origin-repo" \
  "${IMAGE_NAME}"

echo ""
echo "✅ Container finished!"
echo ""
echo "📁 Workspace contents:"
ls -la "${TMPDIR}"
echo ""
echo "📜 Git log:"
git --no-pager -C "${TMPDIR}" log --oneline
