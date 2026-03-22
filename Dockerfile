# Docker Hardened Image (DHI) base — built and pushed by CI; end users never pull this directly.
# Provides non-root runtime, minimal attack surface, and signed provenance.
# Requires Docker Hub credentials (DOCKER_HUB_USER + DOCKER_HUB_TOKEN) in CI to pull.
# Pin by digest after first pull:
#   docker login && docker pull dhi.io/node:22 \
#     && docker inspect dhi.io/node:22 --format '{{index .RepoDigests 0}}'
# Then replace this line with: FROM dhi.io/node:22@sha256:<digest>
FROM dhi.io/node:22

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    jq \
    ca-certificates \
    curl \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends gh \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Pinned 2026-03-22 — bump deliberately after testing
RUN npm install -g @anthropic-ai/claude-code@2.1.81

COPY entrypoint.sh /entrypoint.sh
COPY scripts/ /scripts/
COPY prompts/ /prompts/

RUN chmod +x /entrypoint.sh /scripts/*.sh
# Prevent agents (worker/reviewer) from tampering with scripts or prompts at runtime
RUN chmod -R a-w /scripts /prompts

ENTRYPOINT ["/entrypoint.sh"]
