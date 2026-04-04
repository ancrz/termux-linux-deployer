#!/bin/bash
# =============================================================================
# setup-gemini.sh — Install or upgrade Gemini CLI and Python via UV.
#
# Covers: Python layer (UV + target Python version) + Gemini CLI layer.
# Node.js is handled by setup-node.sh and must run before this script.
# Idempotent: compares local vs remote npm version; skips if up to date.
# Must run as root inside proot-distro Ubuntu.
#
# Usage: bash /root/deployer/scripts/setup-gemini.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_env
ensure_path

# --- Configuration -----------------------------------------------------------

GEMINI_PKG="@google/gemini-cli"
# Release channels: latest (stable), preview (weekly), nightly (daily/bleeding edge)
GEMINI_CHANNEL="${GEMINI_CHANNEL:-latest}"
SYS_PYTHON="/usr/bin/python3"
PYTHON_VER="${PYTHON_DEFAULT_VERSION:-3.14}"

# --- Pre-flight --------------------------------------------------------------

log_header "Gemini CLI Setup"
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
    # Non-fatal: Gemini CLI can still use the system Python.
    log_warn "Python ${PYTHON_VER} install via UV failed — continuing with system Python"
fi

# --- System Python symlink ---------------------------------------------------

# Gemini CLI's native addon compilation requires a /usr/bin/python3 symlink.
# If it doesn't exist, create one pointing to whatever python3 is on PATH.
if [[ ! -f "$SYS_PYTHON" ]]; then
    log_step "Creating system Python symlink at $SYS_PYTHON"
    PYTHON3_PATH="$(command -v python3 2>/dev/null || true)"
    if [[ -n "$PYTHON3_PATH" ]]; then
        ln -sf "$PYTHON3_PATH" "$SYS_PYTHON"
        log_success "Symlinked $PYTHON3_PATH -> $SYS_PYTHON"
    else
        log_warn "python3 not found on PATH — symlink not created. Gemini native build may fail."
    fi
else
    log_success "System Python symlink already present: $SYS_PYTHON -> $(readlink -f "$SYS_PYTHON" 2>/dev/null || echo '?')"
fi

# --- Layer 4: Gemini CLI -----------------------------------------------------

log_header "Gemini CLI"

DO_INSTALL=0

if ! validate_cmd "gemini"; then
    log_warn "Gemini CLI not installed — will install"
    DO_INSTALL=1
else
    LOCAL_VER="$(gemini --version 2>/dev/null || echo 'unknown')"
    log_step "Checking for updates (local: ${LOCAL_VER})"
    REMOTE_VER="$(npm view "$GEMINI_PKG" version --timeout=5000 2>/dev/null || echo 'unknown')"

    if [[ "$REMOTE_VER" == 'unknown' ]]; then
        log_warn "Could not determine remote version — skipping update check"
    elif [[ "$LOCAL_VER" != "$REMOTE_VER" ]]; then
        log_warn "Update available: ${LOCAL_VER} -> ${REMOTE_VER}"
        DO_INSTALL=1
    else
        log_success "Gemini CLI is up to date (${LOCAL_VER})"
    fi
fi

if [[ "$DO_INSTALL" -eq 1 ]]; then
    log_step "Installing/upgrading Gemini CLI (channel: ${GEMINI_CHANNEL})"
    log_step "Available channels: latest (stable), preview (weekly), nightly (daily)"

    if npm install -g "${GEMINI_PKG}@${GEMINI_CHANNEL}" \
        --python="$SYS_PYTHON" \
        --foreground-scripts \
        --no-audit; then
        log_success "Gemini CLI installed (channel: ${GEMINI_CHANNEL})"
    else
        # Fallback: if chosen channel fails, try stable
        if [[ "$GEMINI_CHANNEL" != "latest" ]]; then
            log_warn "Channel '${GEMINI_CHANNEL}' failed — falling back to 'latest'"
            npm install -g "${GEMINI_PKG}@latest" \
                --python="$SYS_PYTHON" \
                --foreground-scripts \
                --no-audit
            log_success "Gemini CLI installed (fallback: latest)"
        else
            log_fail "Gemini CLI installation failed"
            exit 1
        fi
    fi
fi

# --- Validation --------------------------------------------------------------

log_header "Validation"

if validate_cmd "gemini"; then
    GEMINI_VER="$(gemini --version 2>/dev/null || echo 'version unavailable')"
    log_success "Gemini CLI: ${GEMINI_VER}"
else
    log_fail "gemini command not found after install attempt"
    exit 1
fi

log_success "Gemini setup complete"
