#!/bin/bash
# =============================================================================
# setup-node.sh — Install or upgrade Node.js LTS via NodeSource.
#
# Idempotent: skips install if the target major version is already active.
# Must run as root inside proot-distro Ubuntu.
#
# Usage: bash /root/deployer/scripts/setup-node.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_env

# --- Configuration -----------------------------------------------------------

# Node.js major version target. Overridable via environment.
NODE_TARGET_MAJOR="${NODE_TARGET_MAJOR:-22}"

# --- Pre-flight --------------------------------------------------------------

log_header "Node.js v${NODE_TARGET_MAJOR} LTS Setup"
validate_root

# --- Idempotency Check -------------------------------------------------------

if validate_cmd "node"; then
    INSTALLED_VER="$(node -v)"
    if [[ "$INSTALLED_VER" == "v${NODE_TARGET_MAJOR}."* ]]; then
        log_success "Node.js ${INSTALLED_VER} already matches target v${NODE_TARGET_MAJOR}.x — skipping install"
        # Always ensure npm retry config is in place.
        log_step "Ensuring npm retry configuration"
        npm config set fetch-retries 5
        npm config set fetch-retry-mintimeout 20000
        log_success "npm retry config set"
        node -v && npm -v
        exit 0
    else
        log_warn "Node.js ${INSTALLED_VER} installed, but target is v${NODE_TARGET_MAJOR}.x — upgrading"
    fi
else
    log_step "Node.js not found — installing v${NODE_TARGET_MAJOR} LTS"
fi

# --- Install via NodeSource --------------------------------------------------

log_header "Installing Node.js v${NODE_TARGET_MAJOR} via NodeSource"

# Ensure the keyrings directory exists (may not be present in minimal images).
mkdir -p /etc/apt/keyrings

log_step "Fetching NodeSource GPG key"
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg --yes

log_step "Adding NodeSource apt repository for Node.js ${NODE_TARGET_MAJOR}.x"
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] \
https://deb.nodesource.com/node_${NODE_TARGET_MAJOR}.x nodistro main" \
    | tee /etc/apt/sources.list.d/nodesource.list

log_step "Refreshing apt and installing nodejs"
apt-get update -qq
apt-get install -y nodejs

# --- npm Configuration -------------------------------------------------------

log_step "Configuring npm retry policy"
npm config set fetch-retries 5
npm config set fetch-retry-mintimeout 20000

# --- Validation --------------------------------------------------------------

log_header "Validation"
NODE_VER="$(node -v)"
NPM_VER="$(npm -v)"

log_success "Node.js ${NODE_VER}"
log_success "npm ${NPM_VER}"

# Confirm the installed major matches what we targeted.
if [[ "$NODE_VER" != "v${NODE_TARGET_MAJOR}."* ]]; then
    log_fail "Installed Node.js ${NODE_VER} does not match target v${NODE_TARGET_MAJOR}.x"
    exit 1
fi

log_success "Node.js setup complete"
