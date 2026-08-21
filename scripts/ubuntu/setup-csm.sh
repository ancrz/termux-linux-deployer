#!/bin/bash
# =============================================================================
# setup-csm.sh — Build the csm binary and install code-server.
#
# csm (code-server manager) is a Go binary located in cmd/csm/.
# This script compiles it from source and installs it to ~/.local/bin/csm.
# code-server is installed via its official install.sh if not already present.
# Idempotent: rebuilds csm on every run (Go builds are deterministic);
# skips code-server install if already present.
# Must run as root inside proot-distro Ubuntu.
#
# Usage: bash /root/deployer/scripts/setup-csm.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_env
ensure_path

# --- Configuration -----------------------------------------------------------

# Deployer root is two levels above scripts/ubuntu/.
DEPLOYER_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Keep the deployer self-contained: install-ubuntu.sh copies cmd/ here too.
CSM_SRC="$DEPLOYER_DIR/cmd/csm"
# Compatibility with Ubuntu roots provisioned by older installer versions,
# which placed cmd/ directly under /root.
LEGACY_CSM_SRC="$(cd "$DEPLOYER_DIR/.." && pwd)/cmd/csm"
CSM_BIN="/root/.local/bin/csm"

# --- Pre-flight --------------------------------------------------------------

log_header "CSM + Code-Server Setup"
validate_root

# Go must be available to build csm.
if ! validate_cmd "go"; then
    log_fail "Go not found. Run base-setup.sh first."
    exit 1
fi

log_success "Go $(go version)"

# Verify the source directory exists before attempting compilation.
if [[ ! -d "$CSM_SRC" ]]; then
    if [[ -d "$LEGACY_CSM_SRC" ]]; then
        CSM_SRC="$LEGACY_CSM_SRC"
        log_warn "Using legacy csm source path: ${CSM_SRC}"
    else
        log_fail "csm source directory not found: ${CSM_SRC}"
        log_warn "Expected layout: <deployer-root>/cmd/csm"
        exit 1
    fi
fi

# --- Build csm ---------------------------------------------------------------

log_header "Building csm"

mkdir -p /root/.local/bin

if [[ -f "$CSM_BIN" ]]; then
    log_step "Existing csm binary found at $CSM_BIN — rebuilding"
else
    log_step "Building csm from source: $CSM_SRC"
fi

cd "$CSM_SRC"
# Ensure Go is on PATH for the build (ensure_path was called above but
# subshell PATH may differ if Go was just installed in this session).
export PATH="/usr/local/go/bin:$PATH"
go build -o "$CSM_BIN" .

log_success "csm built: $CSM_BIN"
log_success "csm version: $(${CSM_BIN} --version 2>/dev/null || echo '(no --version flag)')"

# --- Install code-server -----------------------------------------------------

log_header "code-server"

if ! validate_cmd "code-server"; then
    log_step "Installing code-server via official installer"
    curl -fsSL https://code-server.dev/install.sh | sh
    log_success "code-server installed: $(code-server --version | head -1)"
else
    log_success "code-server already installed: $(code-server --version | head -1)"
fi

# --- Generate code-server Config via csm ------------------------------------

log_header "code-server Config"

if [[ -n "${CS_PASSWORD:-}" ]]; then
    log_step "Generating code-server config via csm"
    "$CSM_BIN" config
    log_success "code-server config generated"
else
    log_warn "CS_PASSWORD is not set — skipping config generation"
    log_warn "Set CS_PASSWORD in your .env file and re-run this script to generate config"
fi

log_success "CSM + code-server setup complete"
