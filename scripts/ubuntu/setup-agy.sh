#!/bin/bash
# =============================================================================
# setup-agy.sh — Install or upgrade Antigravity CLI (agy) and Python via UV.
#
# Covers: Python layer (UV + target Python version) + Antigravity CLI layer.
# Note: agy is a Go binary, but Python is still set up for other tools like skill-swarm.
# Uses Google's official installer inside PRoot. The community installer is kept
# for native Termux, where it provides the required standalone compatibility patch.
# Idempotent: checks local agy version.
# Must run as root inside proot-distro Ubuntu.
#
# Usage: bash /root/deployer/scripts/ubuntu/setup-agy.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_env
ensure_path

# --- Configuration -----------------------------------------------------------

AGY_REPO="${AGY_REPO:-wallentx/antigravity-cli-termux}"
SYS_PYTHON="/usr/bin/python3"
PYTHON_VER="${PYTHON_DEFAULT_VERSION:-3.14}"

# --- Pre-flight --------------------------------------------------------------

log_header "Antigravity CLI (agy) Setup"
validate_root

# --- Layer 2: Python via UV --------------------------------------------------

log_header "Python ${PYTHON_VER} via UV"

if ! validate_cmd "uv"; then
    log_fail "UV not found. Run base-setup.sh first."
    exit 1
fi

log_step "Installing Python ${PYTHON_VER} via UV (non-interactive)"
if uv python install "${PYTHON_VER}"; then
    log_success "Python ${PYTHON_VER} installed"
else
    log_warn "Python ${PYTHON_VER} install via UV failed — continuing with system Python"
fi

# --- System Python symlink ---------------------------------------------------

if [[ ! -f "$SYS_PYTHON" ]]; then
    log_step "Creating system Python symlink at $SYS_PYTHON"
    PYTHON3_PATH="$(command -v python3 2>/dev/null || true)"
    if [[ -n "$PYTHON3_PATH" ]]; then
        ln -sf "$PYTHON3_PATH" "$SYS_PYTHON"
        log_success "Symlinked $PYTHON3_PATH -> $SYS_PYTHON"
    else
        log_warn "python3 not found on PATH — symlink not created."
    fi
else
    log_success "System Python symlink already present: $SYS_PYTHON -> $(readlink -f "$SYS_PYTHON" 2>/dev/null || echo '?')"
fi

# --- Layer 4: Antigravity CLI ------------------------------------------------

log_header "Antigravity CLI (agy)"

DO_INSTALL=0

if ! validate_cmd "agy"; then
    log_warn "Antigravity CLI not installed — will install"
    DO_INSTALL=1
else
    LOCAL_VER="$(agy --version 2>/dev/null || echo 'unknown')"
    log_step "Checking local version (local: ${LOCAL_VER})"
    # Currently no easy way to check remote version for the patched binary.
    # We assume it's up to date unless the user forces it or agy stops working.
    log_success "Antigravity CLI is installed (${LOCAL_VER})"
fi

if [[ "$DO_INSTALL" -eq 1 ]]; then
    if grep -qi 'proot' /proc/version 2>/dev/null; then
        log_step "Installing Antigravity CLI via the official PRoot-compatible installer"
        INSTALL_CMD=(curl -fsSL https://antigravity.google/cli/install.sh)
    else
        log_step "Installing Antigravity CLI via community Termux patcher (${AGY_REPO})"
        INSTALL_CMD=(curl -fsSL "https://raw.githubusercontent.com/${AGY_REPO}/dev/install.sh")
    fi

    if "${INSTALL_CMD[@]}" | bash; then
        log_success "Antigravity CLI installed successfully."
    else
        log_fail "Antigravity CLI installation failed."
        exit 1
    fi
fi

# --- Validation --------------------------------------------------------------

log_header "Validation"

# Ensure agy is on PATH
export PATH="/root/.local/bin:$PATH"

if validate_cmd "agy"; then
    AGY_VER="$(agy --version 2>/dev/null || echo 'version unavailable')"
    log_success "Antigravity CLI: ${AGY_VER}"
else
    log_fail "agy command not found after install attempt. Check PATH or installation logs."
    exit 1
fi

log_success "Antigravity CLI setup complete"
