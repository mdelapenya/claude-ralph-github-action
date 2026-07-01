#!/usr/bin/env bash
# sbx-setup.sh - Configure the Docker sbx sandbox at runtime
#
# The sbx binary itself is installed by scripts/sbx-install.sh (a dedicated
# composite-action step). This script assumes sbx is already on PATH and:
# 1. Sets up D-Bus and gnome-keyring for headless credential storage
# 2. Logs in to Docker Hub via sbx
# 3. Configures the default network policy
# 4. Creates a sandbox named "ralph-sandbox"
#
# Required env vars:
#   INPUT_DOCKER_HUB_USER   - Docker Hub username
#   INPUT_DOCKER_HUB_TOKEN  - Docker Hub token
#   INPUT_SBX_NETWORK_POLICY - Network policy (deny-all, allow-all, balanced)

set -euo pipefail

SBX_SANDBOX_NAME="ralph-sandbox"
SBX_APP_NAME="claude-ralph"
SBX_NETWORK_POLICY="${INPUT_SBX_NETWORK_POLICY:-balanced}"

# This action runs on the runner host (composite action). System package installs
# and device permission changes need root; on GitHub-hosted runners the runner
# user has passwordless sudo. Fall back to no sudo when already root or when sudo
# is unavailable (e.g. a container-based runner).
SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

SBX_INFO_FILE="${RALPH_DIR:-${GITHUB_WORKSPACE:-.}/.ralph}/sbx-info.txt"

# Record that sbx could not be activated and let the run continue unsandboxed.
# sbx-exec.sh reads sbx_active and runs claude directly when it is false.
_degrade_and_skip() {
  echo "⚠️  $1"
  echo "   Claude will run WITHOUT the sbx sandbox for this run."
  mkdir -p "$(dirname "${SBX_INFO_FILE}")"
  {
    echo "sbx_active=false"
    echo "skip_reason=$1"
  } > "${SBX_INFO_FILE}"
  exit 0
}

# sbx requires a Linux host with KVM. Degrade gracefully anywhere it is missing
# (non-Linux runners, or Linux runners without nested virtualization) so the
# loop still runs — just unsandboxed.
if [[ "$(uname -s)" != "Linux" ]]; then
  _degrade_and_skip "sbx requires Linux, but this runner is $(uname -s)."
fi
if [[ ! -e /dev/kvm ]]; then
  _degrade_and_skip "/dev/kvm is not available on this runner, so sbx cannot start its micro-VM."
fi
# sbx is installed by the "Install sbx" composite step (scripts/sbx-install.sh),
# which adds it to PATH via GITHUB_PATH. If it is missing here, that step did not
# run (e.g. sbx-setup.sh invoked outside the action) — degrade rather than fail.
if ! command -v sbx >/dev/null 2>&1; then
  _degrade_and_skip "sbx binary not found on PATH; the install step did not run."
fi

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
echo "  sbx version: $(sbx version 2>&1 || echo 'unknown')"

# --- Set up D-Bus and gnome-keyring for headless credential storage ---
# e2fsprogs provides mkfs.ext4, which sbx needs to build the sandbox filesystem.
echo "Setting up Secret Service for sbx login..."
${SUDO} apt-get update -qq 2>/dev/null
${SUDO} apt-get install -y -qq gnome-keyring dbus libglib2.0-bin e2fsprogs 2>/dev/null

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

# Write sandbox info so other scripts can source it. sbx is already on PATH
# (added by the install step via GITHUB_PATH), so no sbx_bin is recorded here.
{
  echo "sbx_active=true"
  echo "sandbox_name=${SBX_SANDBOX_NAME}"
  echo "app_name=${SBX_APP_NAME}"
  echo "network_policy=${SBX_NETWORK_POLICY}"
} > "${SBX_INFO_FILE}"

echo "=== sbx Setup Complete ==="
