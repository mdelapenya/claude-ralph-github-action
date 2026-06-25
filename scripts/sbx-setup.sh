#!/usr/bin/env bash
# sbx-setup.sh - Install and configure Docker sbx sandboxing
#
# Sets up the Docker sbx sandbox environment:
# 1. Installs sbx from docker/sbx-releases
# 2. Sets up D-Bus and gnome-keyring for headless credential storage
# 3. Logs in to Docker Hub via sbx
# 4. Configures the default network policy
# 5. Creates a sandbox named "ralph-sandbox"
#
# Required env vars:
#   INPUT_DOCKER_HUB_USER   - Docker Hub username
#   INPUT_DOCKER_HUB_TOKEN  - Docker Hub token
#   INPUT_SBX_NETWORK_POLICY - Network policy (deny-all, allow-all, balanced)

set -euo pipefail

SBX_SANDBOX_NAME="ralph-sandbox"
SBX_APP_NAME="claude-ralph"
SBX_NETWORK_POLICY="${INPUT_SBX_NETWORK_POLICY:-balanced}"

# Validate required credentials
if [[ -z "${INPUT_DOCKER_HUB_USER:-}" ]]; then
  echo "ERROR: docker_hub_user input is required when sbx_enabled is true"
  exit 1
fi
if [[ -z "${INPUT_DOCKER_HUB_TOKEN:-}" ]]; then
  echo "ERROR: docker_hub_token input is required when sbx_enabled is true"
  exit 1
fi

# Validate network policy
case "${SBX_NETWORK_POLICY}" in
  deny-all|allow-all|balanced) ;;
  *)
    echo "ERROR: invalid sbx_network_policy '${SBX_NETWORK_POLICY}' — must be deny-all, allow-all, or balanced"
    exit 1
    ;;
esac

echo "=== sbx Setup ==="

# --- Install sbx ---
echo "Installing sbx..."
sbx_tmp="$(mktemp -d)"
# Fetch the latest release version tag from GitHub API
SBX_VERSION="$(curl -fsSL "https://api.github.com/repos/docker/sbx-releases/releases/latest" | jq -r '.tag_name')"
if [[ -z "${SBX_VERSION}" || "${SBX_VERSION}" == "null" ]]; then
  echo "ERROR: failed to determine latest sbx release version"
  rm -rf "${sbx_tmp}"
  exit 1
fi
echo "  Version: ${SBX_VERSION}"
curl -fsSL "https://github.com/docker/sbx-releases/releases/download/${SBX_VERSION}/DockerSandboxes-linux.tar.gz" \
  -o "${sbx_tmp}/docker-sbx.tar.gz"
tar -xzf "${sbx_tmp}/docker-sbx.tar.gz" -C "${sbx_tmp}"

SBX_PREFIX="${HOME}/.docker/sbx"
sudo PREFIX="${SBX_PREFIX}" "${sbx_tmp}/install.sh"
export PATH="${SBX_PREFIX}/bin:${PATH}"
rm -rf "${sbx_tmp}"

echo "  sbx version: $(sbx version 2>&1 || echo 'unknown')"

# --- Set up D-Bus and gnome-keyring for headless credential storage ---
echo "Setting up Secret Service for sbx login..."
sudo apt-get update -qq 2>/dev/null
sudo apt-get install -y -qq gnome-keyring dbus 2>/dev/null

mkdir -p "${HOME}/.local/share/keyrings"
cat > "${HOME}/.local/share/keyrings/login.keyring" <<'KEYRING'
[keyring]
display-name=login
ctime=1750965549
mtime=0
lock-on-idle=false
lock-after=false
KEYRING

DBUS_SESSION_BUS_ADDRESS="$(dbus-daemon --session --print-address --fork)"
export DBUS_SESSION_BUS_ADDRESS

# Persist for subsequent steps in GitHub Actions
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS}" >> "${GITHUB_ENV}"
fi

gnome-keyring-daemon --start --components=secrets >/dev/null

# Wait for Secret Service to register on D-Bus
for _ in $(seq 1 50); do
  if gdbus call --session \
      --dest org.freedesktop.DBus \
      --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.GetNameOwner \
      org.freedesktop.secrets >/dev/null 2>&1; then
    echo "  Secret Service registered on D-Bus"
    break
  fi
  sleep 0.1
done

# --- Log in to Docker Hub via sbx ---
echo "Logging in to Docker Hub via sbx..."
user_clean="$(printf '%s' "${INPUT_DOCKER_HUB_USER}" | tr -d '[:space:]')"
token_clean="$(printf '%s' "${INPUT_DOCKER_HUB_TOKEN}" | tr -d '[:space:]')"
printf '%s' "${token_clean}" | sbx --app-name "${SBX_APP_NAME}" login \
  --username "${user_clean}" --password-stdin
echo "  Docker Hub login successful"

# --- Set the default network policy ---
echo "Setting sbx network policy: ${SBX_NETWORK_POLICY}"
sbx --app-name "${SBX_APP_NAME}" policy set-default "${SBX_NETWORK_POLICY}"

# --- Create the sandbox ---
echo "Creating sbx sandbox: ${SBX_SANDBOX_NAME}"
sbx create --name "${SBX_SANDBOX_NAME}" claude .
echo "  Sandbox created successfully"

# Export variables for downstream scripts
export SBX_SANDBOX_NAME
export SBX_APP_NAME

# Persist SBX env vars for other scripts in the same shell session
if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "SBX_SANDBOX_NAME=${SBX_SANDBOX_NAME}"
    echo "SBX_APP_NAME=${SBX_APP_NAME}"
  } >> "${GITHUB_ENV}"
fi

# Write sandbox info so other scripts can source it
SBX_INFO_FILE="${RALPH_DIR:-${GITHUB_WORKSPACE:-.}/.ralph}/sbx-info.txt"
{
  echo "sandbox_name=${SBX_SANDBOX_NAME}"
  echo "app_name=${SBX_APP_NAME}"
  echo "network_policy=${SBX_NETWORK_POLICY}"
  echo "sbx_bin=${SBX_PREFIX}/bin"
} > "${SBX_INFO_FILE}"

echo "=== sbx Setup Complete ==="
