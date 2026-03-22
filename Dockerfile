# node:22-slim is the official public Node.js image on Docker Hub — no credentials required
# to pull in CI or by end users. Pinned by digest for supply-chain integrity: any change to
# the upstream image requires a deliberate update here.
# Pinned 2026-03-22 — update deliberately: https://hub.docker.com/_/node
FROM node:22-slim@sha256:4f77a690f2f8946ab16fe1e791a3ac0667ae1c3575c3e4d0d4589e9ed5bfaf3d

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
