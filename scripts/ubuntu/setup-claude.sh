#!/bin/bash
# =============================================================================
# setup-claude.sh — Install or upgrade Claude Code CLI.
#
# Installation strategy (multi-fallback):
#   1. Standalone installer (recommended): curl -fsSL https://claude.ai/install.sh | bash
#   2. npm (deprecated fallback): npm install -g @anthropic-ai/claude-code
#   3. npm pinned version (last resort): @anthropic-ai/claude-code@0.2.114
#
# Handles aarch64/proot-specific issues:
#   - TMPDIR setup for /tmp access inside proot.
#   - Smoke-test with timeout to detect broken installs.
# Idempotent: checks current version before acting.
# Must run as root inside proot-distro Ubuntu.
#
# Usage: bash /root/deployer/scripts/setup-claude.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_env
ensure_path

# --- Configuration -----------------------------------------------------------

CLAUDE_INSTALL_URL="https://claude.ai/install.sh"
CLAUDE_PKG="@anthropic-ai/claude-code"   # npm fallback only
SYS_PYTHON="/usr/bin/python3"

# TMPDIR for Claude Code: proot may not expose /tmp correctly.
export CLAUDE_CODE_TMPDIR="${CLAUDE_CODE_TMPDIR:-/tmp/claude}"

# --- Pre-flight --------------------------------------------------------------

log_header "Claude Code Setup"
validate_root
validate_internet

# --- TMPDIR Setup ------------------------------------------------------------

log_step "Ensuring CLAUDE_CODE_TMPDIR exists: ${CLAUDE_CODE_TMPDIR}"
mkdir -p "$CLAUDE_CODE_TMPDIR"
log_success "CLAUDE_CODE_TMPDIR ready"

# --- Version Check -----------------------------------------------------------

DO_INSTALL=0

if ! validate_cmd "claude"; then
    log_warn "Claude Code not installed — will install"
    DO_INSTALL=1
else
    LOCAL_VER="$(claude --version 2>/dev/null || echo 'unknown')"
    log_step "Detected Claude Code: ${LOCAL_VER}"

    # The standalone installer handles self-update. Run it to upgrade.
    log_step "Running installer to check for updates..."
    DO_INSTALL=1
fi

# --- Install with Multi-Fallback ---------------------------------------------

smoke_test() {
    if timeout 15 claude --version &>/dev/null; then
        return 0
    fi
    return 1
}

if [[ "$DO_INSTALL" -eq 1 ]]; then

    # --- Strategy 1: Standalone installer (recommended) ----------------------
    # Security note: curl|bash is the official Anthropic-recommended method.
    # URL is TLS-protected (https://claude.ai). Same pattern used by rustup,
    # uv, code-server. Accepted risk for official installer scripts.
    log_step "Installing Claude Code via standalone installer"
    if curl -fsSL "$CLAUDE_INSTALL_URL" | bash; then
        # Reload PATH to pick up the new binary
        ensure_path
        hash -r 2>/dev/null || true

        if smoke_test; then
            log_success "Claude Code $(claude --version 2>/dev/null) installed via standalone installer"
        else
            log_warn "Standalone installer completed but smoke test failed"
            log_step "Trying npm fallback..."

            # --- Strategy 2: npm latest (deprecated but functional) ----------
            if validate_cmd "npm"; then
                log_step "Installing Claude Code via npm (deprecated fallback)"
                npm install -g "$CLAUDE_PKG"@latest \
                    --python="$SYS_PYTHON" \
                    --foreground-scripts \
                    --no-audit 2>/dev/null || true

                if smoke_test; then
                    log_success "Claude Code $(claude --version 2>/dev/null) installed via npm"
                else
                    log_warn "npm latest failed smoke test — trying pinned version"
                    npm uninstall -g "$CLAUDE_PKG" 2>/dev/null || true

                    # --- Strategy 3: npm pinned (last resort) ----------------
                    log_step "Installing Claude Code 0.2.114 (pinned stable)"
                    npm install -g "$CLAUDE_PKG"@0.2.114 \
                        --python="$SYS_PYTHON" \
                        --foreground-scripts \
                        --no-audit 2>/dev/null || true

                    if smoke_test; then
                        log_success "Claude Code 0.2.114 (pinned) installed via npm"
                    else
                        log_fail "All installation strategies exhausted"
                        log_fail "Claude Code could not be installed on this platform"
                        npm uninstall -g "$CLAUDE_PKG" 2>/dev/null || true
                        exit 1
                    fi
                fi
            else
                log_fail "Standalone installer failed and npm is not available"
                exit 1
            fi
        fi
    else
        log_warn "Standalone installer failed — trying npm fallback"

        if validate_cmd "npm"; then
            npm install -g "$CLAUDE_PKG"@latest \
                --python="$SYS_PYTHON" \
                --foreground-scripts \
                --no-audit 2>/dev/null || true

            if smoke_test; then
                log_success "Claude Code $(claude --version 2>/dev/null) installed via npm fallback"
            else
                log_fail "All installation strategies exhausted"
                npm uninstall -g "$CLAUDE_PKG" 2>/dev/null || true
                exit 1
            fi
        else
            log_fail "curl installer failed and npm not available"
            exit 1
        fi
    fi
else
    log_success "Claude Code is up to date ($(claude --version 2>/dev/null || echo '?'))"
fi

# --- Persist TMPDIR in .bashrc -----------------------------------------------

log_step "Persisting CLAUDE_CODE_TMPDIR in /root/.bashrc"

BASHRC_LINE="export CLAUDE_CODE_TMPDIR=\"${CLAUDE_CODE_TMPDIR}\""
BASHRC_FILE="/root/.bashrc"

if ! grep -qF "CLAUDE_CODE_TMPDIR" "$BASHRC_FILE" 2>/dev/null; then
    echo "$BASHRC_LINE" >> "$BASHRC_FILE"
    log_success "CLAUDE_CODE_TMPDIR persisted in $BASHRC_FILE"
else
    log_success "CLAUDE_CODE_TMPDIR already present in $BASHRC_FILE"
fi

# --- Validation --------------------------------------------------------------

log_header "Validation"

if validate_cmd "claude"; then
    CLAUDE_VER="$(claude --version 2>/dev/null || echo 'version unavailable')"
    log_success "Claude Code: ${CLAUDE_VER}"
else
    log_fail "claude command not found after install attempt"
    exit 1
fi

log_success "Claude Code setup complete"
