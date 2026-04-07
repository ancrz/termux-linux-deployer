#!/bin/bash
# =============================================================================
# setup-codex.sh — Install or upgrade Codex CLI.
#
# Covers: Codex CLI npm package (@openai/codex).
# Node.js is handled by setup-node.sh and must run before this script.
# Idempotent: compares local vs remote npm version; skips if up to date.
# Must run as root inside proot-distro Ubuntu.
#
# Usage: bash /root/deployer/scripts/ubuntu/setup-codex.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_env
ensure_path

# --- Configuration -----------------------------------------------------------

CODEX_PKG="@openai/codex"

# --- Pre-flight --------------------------------------------------------------

log_header "Codex CLI Setup"
validate_root

# Node.js must be present before npm operations.
if ! validate_cmd "node"; then
    log_fail "Node.js not found. Run setup-node.sh first."
    exit 1
fi

if ! validate_cmd "npm"; then
    log_fail "npm not found. Ensure setup-node.sh completed successfully."
    exit 1
fi

# --- Codex CLI ---------------------------------------------------------------

log_header "Codex CLI"

DO_INSTALL=0

if ! validate_cmd "codex"; then
    log_warn "Codex CLI not installed — will install"
    DO_INSTALL=1
else
    LOCAL_VER="$(codex --version 2>/dev/null || echo 'unknown')"
    log_step "Checking for updates (local: ${LOCAL_VER})"
    REMOTE_VER="$(npm view "$CODEX_PKG" version --timeout=5000 2>/dev/null || echo 'unknown')"

    if [[ "$REMOTE_VER" == 'unknown' ]]; then
        log_warn "Could not determine remote version — skipping update check"
    elif [[ "$LOCAL_VER" != "$REMOTE_VER" ]]; then
        log_warn "Update available: ${LOCAL_VER} -> ${REMOTE_VER}"
        DO_INSTALL=1
    else
        log_success "Codex CLI is up to date (${LOCAL_VER})"
    fi
fi

if [[ "$DO_INSTALL" -eq 1 ]]; then
    log_step "Installing/upgrading Codex CLI"
    if npm install -g "${CODEX_PKG}@latest" --no-audit; then
        log_success "Codex CLI installed"
    else
        log_fail "Codex CLI installation failed"
        exit 1
    fi
fi

# --- Validation --------------------------------------------------------------

log_header "Validation"

if validate_cmd "codex"; then
    CODEX_VER="$(codex --version 2>/dev/null || echo 'version unavailable')"
    log_success "Codex CLI: ${CODEX_VER}"
else
    log_fail "codex command not found after install attempt"
    exit 1
fi

log_success "Codex setup complete"
