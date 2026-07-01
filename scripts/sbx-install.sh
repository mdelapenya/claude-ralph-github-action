#!/usr/bin/env bash
# sbx-install.sh - Download, verify, and install the Docker sbx binary
#
# Run as a dedicated composite-action step (see action.yml), separate from the
# runtime configuration in sbx-setup.sh. Installs sbx into ${HOME}/.docker/sbx
# and adds it to PATH for subsequent workflow steps via GITHUB_PATH.
#
# Optional env vars:
#   INPUT_SBX_VERSION - Pinned sbx release tag (defaults to a known-good version)
#   INPUT_SBX_SHA256  - Expected SHA-256 of the linux tarball (required when
#                       overriding INPUT_SBX_VERSION, since the release ships no
#                       .sha256 sidecar)

set -euo pipefail

# install.sh writes an AppArmor profile to /etc/apparmor.d/, which needs root.
# On GitHub-hosted runners the runner user has passwordless sudo; fall back to no
# sudo when already root or when sudo is unavailable.
SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

# Known-good version and its tarball checksum. The docker/sbx-releases project
# does not publish a .sha256 sidecar next to the release asset, so we pin the
# checksum here for the default version. When a different version is pinned via
# INPUT_SBX_VERSION, the caller must supply INPUT_SBX_SHA256 to keep verification.
DEFAULT_SBX_VERSION="v0.34.0"
DEFAULT_SBX_SHA256="e47f4b3b22a2d3f481549d2577a3a470fd61f6bf5e1eb01be1fb1555574cbac8"

echo "=== sbx Install ==="

sbx_tmp="$(mktemp -d)"
# Use the pinned version from the action input (never fetch latest dynamically)
SBX_VERSION="${INPUT_SBX_VERSION:-${DEFAULT_SBX_VERSION}}"
echo "  Version: ${SBX_VERSION}"

# Resolve the expected checksum. The release provides no .sha256 sidecar, so we
# rely on a pinned value: the caller-supplied INPUT_SBX_SHA256, or the built-in
# default when running the default version. Refuse to proceed unverified.
expected_checksum="${INPUT_SBX_SHA256:-}"
if [[ -z "${expected_checksum}" ]]; then
  if [[ "${SBX_VERSION}" == "${DEFAULT_SBX_VERSION}" ]]; then
    expected_checksum="${DEFAULT_SBX_SHA256}"
  else
    echo "ERROR: no SHA-256 pinned for sbx ${SBX_VERSION}"
    echo "  Set the sbx_sha256 input to the tarball checksum when overriding sbx_version."
    rm -rf "${sbx_tmp}"
    exit 1
  fi
fi

sbx_tarball="${sbx_tmp}/docker-sbx.tar.gz"
curl -fsSL "https://github.com/docker/sbx-releases/releases/download/${SBX_VERSION}/DockerSandboxes-linux.tar.gz" \
  -o "${sbx_tarball}"

# Verify tarball integrity against the pinned SHA-256 checksum
actual_checksum="$(sha256sum "${sbx_tarball}" | awk '{print $1}')"
if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
  echo "ERROR: SHA-256 checksum mismatch for sbx tarball"
  echo "  Expected: ${expected_checksum}"
  echo "  Actual:   ${actual_checksum}"
  rm -rf "${sbx_tmp}"
  exit 1
fi
echo "  Checksum verified: ${actual_checksum}"

# The tarball extracts into a top-level docker-sbx/ directory containing
# install.sh, the sbx binary, and supporting files.
tar -xzf "${sbx_tarball}" -C "${sbx_tmp}"

# Install as root so install.sh can write the AppArmor profile to /etc/apparmor.d/.
# `env PREFIX=...` sets the variable for the (possibly sudo-elevated) install.sh.
SBX_PREFIX="${HOME}/.docker/sbx"
${SUDO} env PREFIX="${SBX_PREFIX}" "${sbx_tmp}/docker-sbx/install.sh"
export PATH="${SBX_PREFIX}/bin:${PATH}"
rm -rf "${sbx_tmp}"

# Make sbx available to subsequent workflow steps (idiomatic PATH propagation).
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${SBX_PREFIX}/bin" >> "${GITHUB_PATH}"
fi

echo "  sbx version: $(sbx version 2>&1 || echo 'unknown')"
echo "=== sbx Install Complete ==="
