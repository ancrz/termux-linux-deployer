#!/bin/bash
# =============================================================================
# setup-claude.sh — Install or upgrade Claude Code CLI.
#
# Installation strategy (multi-fallback):
#   1. npm (proven on proot aarch64): npm install -g @anthropic-ai/claude-code
#   2. npm pinned (fallback): @anthropic-ai/claude-code@0.2.114
#   3. Standalone installer (last resort): curl -fsSL https://claude.ai/install.sh | bash
#
# IMPORTANT: Do NOT mix npm and standalone installations. The standalone
# installer creates symlinks that conflict with npm's global install path,
# breaking the claude binary. If npm works, never run the standalone installer.
# See: tested 2026-04-04 on Samsung Tab S10 Ultra proot-distro Ubuntu.
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

CLAUDE_PKG="@anthropic-ai/claude-code"
CLAUDE_INSTALL_URL="https://claude.ai/install.sh"  # standalone, last resort only
SYS_PYTHON="/usr/bin/python3"

# TMPDIR for Claude Code: proot may not expose /tmp correctly.
export CLAUDE_CODE_TMPDIR="${CLAUDE_CODE_TMPDIR:-/tmp/claude}"

# --- Pre-flight --------------------------------------------------------------

log_header "Claude Code Setup"
validate_root
validate_internet

# Node.js and npm required for primary install method.
if ! validate_cmd "npm"; then
    log_fail "npm not found. Run setup-node.sh first."
    exit 1
fi

# --- TMPDIR Setup ------------------------------------------------------------

log_step "Ensuring CLAUDE_CODE_TMPDIR exists: ${CLAUDE_CODE_TMPDIR}"
mkdir -p "$CLAUDE_CODE_TMPDIR"
log_success "CLAUDE_CODE_TMPDIR ready"

# --- Detect Install Method ---------------------------------------------------
# If claude was installed via npm, it lives in npm's global prefix.
# If installed via standalone, it lives in ~/.claude/bin.
# We must not mix these — the standalone installer breaks npm symlinks.

INSTALL_METHOD="unknown"
if validate_cmd "claude"; then
    CLAUDE_PATH="$(which claude 2>/dev/null || echo '')"
    if [[ "$CLAUDE_PATH" == *"node_modules"* ]] || [[ "$CLAUDE_PATH" == *"npm"* ]] || [[ "$CLAUDE_PATH" == "/usr/"* ]]; then
        INSTALL_METHOD="npm"
    elif [[ "$CLAUDE_PATH" == *".claude/bin"* ]]; then
        INSTALL_METHOD="standalone"
    fi
    log_step "Detected existing installation: method=${INSTALL_METHOD}, path=${CLAUDE_PATH}"
fi

# --- Version Check -----------------------------------------------------------

DO_INSTALL=0

if ! validate_cmd "claude"; then
    log_warn "Claude Code not installed — will install"
    DO_INSTALL=1
else
    LOCAL_VER="$(claude --version 2>/dev/null || echo 'unknown')"
    REMOTE_VER="$(npm view "$CLAUDE_PKG" version --timeout=5000 2>/dev/null || echo 'unknown')"

    if [[ "$REMOTE_VER" == "unknown" ]]; then
        log_warn "Could not determine remote version — skipping update check"
        log_success "Claude Code: ${LOCAL_VER}"
    elif [[ "$LOCAL_VER" != "$REMOTE_VER" ]]; then
        log_warn "Update available: ${LOCAL_VER} -> ${REMOTE_VER}"
        DO_INSTALL=1
    else
        log_success "Claude Code is up to date (${LOCAL_VER})"
    fi
fi

# --- Install / Update --------------------------------------------------------

smoke_test() {
    if timeout 15 claude --version &>/dev/null; then
        return 0
    fi
    return 1
}

if [[ "$DO_INSTALL" -eq 1 ]]; then

    # --- Strategy 1: npm latest (proven on proot aarch64) --------------------
    # npm install is the safest method on this platform. Tested and working.
    log_step "Installing Claude Code via npm (primary method)"
    if npm install -g "$CLAUDE_PKG"@latest \
            --python="$SYS_PYTHON" \
            --foreground-scripts \
            --no-audit; then

        ensure_path
        hash -r 2>/dev/null || true

        if smoke_test; then
            log_success "Claude Code $(claude --version 2>/dev/null) installed via npm"
        else
            log_warn "npm latest installed but smoke test failed"
            log_step "Trying pinned version..."
            npm uninstall -g "$CLAUDE_PKG" 2>/dev/null || true

            # --- Strategy 2: npm pinned (known working on arm64) -------------
            log_step "Installing Claude Code 0.2.114 (pinned stable)"
            npm install -g "$CLAUDE_PKG"@0.2.114 \
                --python="$SYS_PYTHON" \
                --foreground-scripts \
                --no-audit

            if smoke_test; then
                log_success "Claude Code 0.2.114 (pinned) installed via npm"
            else
                log_warn "npm pinned also failed — trying standalone installer as last resort"
                npm uninstall -g "$CLAUDE_PKG" 2>/dev/null || true

                # --- Strategy 3: Standalone (LAST RESORT) --------------------
                # WARNING: Do not use if npm install succeeded previously.
                # The standalone installer creates ~/.claude/bin/claude which
                # conflicts with npm's /usr/lib/node_modules/.bin/claude symlink.
                # Only used when npm methods have completely failed.
                log_step "Installing Claude Code via standalone installer (last resort)"
                # Security note: curl|bash is official Anthropic method, TLS-protected.
                if curl -fsSL "$CLAUDE_INSTALL_URL" | bash; then
                    ensure_path
                    export PATH="$HOME/.claude/bin:$PATH"
                    hash -r 2>/dev/null || true

                    if smoke_test; then
                        log_success "Claude Code $(claude --version 2>/dev/null) installed via standalone"
                    else
                        log_fail "All installation strategies exhausted"
                        log_fail "Claude Code could not be installed on this platform"
                        exit 1
                    fi
                else
                    log_fail "All installation strategies exhausted"
                    exit 1
                fi
            fi
        fi
    else
        log_warn "npm install command failed — trying standalone installer"
        # Security note: curl|bash is official Anthropic method, TLS-protected.
        if curl -fsSL "$CLAUDE_INSTALL_URL" | bash; then
            ensure_path
            export PATH="$HOME/.claude/bin:$PATH"
            hash -r 2>/dev/null || true

            if smoke_test; then
                log_success "Claude Code $(claude --version 2>/dev/null) installed via standalone"
            else
                log_fail "All installation strategies exhausted"
                exit 1
            fi
        else
            log_fail "All installation strategies exhausted"
            exit 1
        fi
    fi
else
    log_success "Claude Code is up to date ($(claude --version 2>/dev/null || echo '?'))"
fi

# --- Persist env vars in .bashrc ---------------------------------------------

BASHRC_FILE="/root/.bashrc"

# TMPDIR
TMPDIR_LINE="export CLAUDE_CODE_TMPDIR=\"${CLAUDE_CODE_TMPDIR}\""
if ! grep -qF "CLAUDE_CODE_TMPDIR" "$BASHRC_FILE" 2>/dev/null; then
    echo "$TMPDIR_LINE" >> "$BASHRC_FILE"
    log_success "CLAUDE_CODE_TMPDIR persisted in $BASHRC_FILE"
else
    log_success "CLAUDE_CODE_TMPDIR already present in $BASHRC_FILE"
fi

# If standalone was used, persist its PATH
if [[ "${INSTALL_METHOD}" == "standalone" ]] || [[ -d "$HOME/.claude/bin" ]]; then
    CLAUDE_PATH_LINE='export PATH="$HOME/.claude/bin:$PATH"'
    if ! grep -qF ".claude/bin" "$BASHRC_FILE" 2>/dev/null; then
        echo "$CLAUDE_PATH_LINE" >> "$BASHRC_FILE"
        log_success "~/.claude/bin added to PATH in $BASHRC_FILE"
    fi
fi

# --- Validation --------------------------------------------------------------

log_header "Validation"

if validate_cmd "claude"; then
    CLAUDE_VER="$(claude --version 2>/dev/null || echo 'version unavailable')"
    CLAUDE_PATH="$(which claude 2>/dev/null || echo 'unknown')"
    log_success "Claude Code: ${CLAUDE_VER}"
    log_success "Binary at: ${CLAUDE_PATH}"
    log_warn "IMPORTANT: Do NOT run 'claude install' — it conflicts with npm installation"
else
    log_fail "claude command not found after install attempt"
    exit 1
fi

log_success "Claude Code setup complete"
