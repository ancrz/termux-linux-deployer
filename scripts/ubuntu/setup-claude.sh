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
# If installed via standalone, it lives in ~/.local/bin or ~/.claude/bin.
# We must not mix these — the standalone installer creates symlinks that
# conflict with npm's global install path, breaking the claude binary.
#
# Standalone paths (new installer):
#   ~/.local/bin/claude → ~/.local/share/claude/versions/X.Y.Z
# Standalone paths (old installer):
#   ~/.claude/bin/claude
# npm paths:
#   /usr/lib/node_modules/@anthropic-ai/claude-code/ + /usr/bin/claude symlink

INSTALL_METHOD="unknown"
if validate_cmd "claude"; then
    CLAUDE_PATH="$(which claude 2>/dev/null || echo '')"
    if [[ "$CLAUDE_PATH" == *"node_modules"* ]] || [[ "$CLAUDE_PATH" == *"npm"* ]] || [[ "$CLAUDE_PATH" == "/usr/bin/"* ]]; then
        INSTALL_METHOD="npm"
    elif [[ "$CLAUDE_PATH" == *".claude/bin"* ]] || [[ "$CLAUDE_PATH" == *".local/bin/claude"* ]]; then
        # Confirm standalone: check if it's a symlink to .local/share/claude/versions/
        if [[ -L "$CLAUDE_PATH" ]]; then
            LINK_TARGET="$(readlink -f "$CLAUDE_PATH" 2>/dev/null || echo '')"
            if [[ "$LINK_TARGET" == *"claude/versions"* ]]; then
                INSTALL_METHOD="standalone"
            fi
        fi
        # Also standalone if the binary lives in .claude/bin directly
        if [[ "$INSTALL_METHOD" == "unknown" && "$CLAUDE_PATH" == *".claude/bin"* ]]; then
            INSTALL_METHOD="standalone"
        fi
    fi
    log_step "Detected existing installation: method=${INSTALL_METHOD}, path=${CLAUDE_PATH}"
fi

# --- Sanitize Conflicting Install --------------------------------------------
# If both npm and standalone artifacts exist, clean up the one we're NOT going
# to use. npm is the primary strategy, so if npm artifacts exist alongside
# standalone, remove standalone. If only standalone exists, leave it and skip
# npm install (use existing).

sanitize_standalone() {
    log_step "Removing standalone artifacts to prevent symlink conflicts..."
    # New standalone paths
    rm -f "$HOME/.local/bin/claude" 2>/dev/null || true
    rm -rf "$HOME/.local/share/claude" 2>/dev/null || true
    # Old standalone paths
    rm -rf "$HOME/.claude/bin" 2>/dev/null || true
    log_success "Standalone artifacts cleaned"
}

sanitize_npm() {
    log_step "Removing npm artifacts to prevent symlink conflicts..."
    npm uninstall -g "$CLAUDE_PKG" 2>/dev/null || true
    rm -f /usr/bin/claude 2>/dev/null || true
    log_success "npm artifacts cleaned"
}

# Check for mixed state: both npm and standalone artifacts present
HAS_NPM_ARTIFACTS=false
HAS_STANDALONE_ARTIFACTS=false

if [[ -d "/usr/lib/node_modules/@anthropic-ai/claude-code" ]] || [[ -f "/usr/bin/claude" ]]; then
    HAS_NPM_ARTIFACTS=true
fi
if [[ -L "$HOME/.local/bin/claude" && "$(readlink -f "$HOME/.local/bin/claude" 2>/dev/null)" == *"claude/versions"* ]] \
   || [[ -d "$HOME/.claude/bin" && -f "$HOME/.claude/bin/claude" ]]; then
    HAS_STANDALONE_ARTIFACTS=true
fi

if [[ "$HAS_NPM_ARTIFACTS" == true && "$HAS_STANDALONE_ARTIFACTS" == true ]]; then
    log_warn "CONFLICT: Both npm and standalone Claude installs detected!"
    log_warn "npm artifacts:        /usr/lib/node_modules/@anthropic-ai/claude-code"
    log_warn "standalone artifacts: $HOME/.local/bin/claude or $HOME/.claude/bin/claude"
    # npm is primary strategy — clean standalone
    sanitize_standalone
    INSTALL_METHOD="npm"
    log_success "Conflict resolved: using npm installation"
elif [[ "$HAS_STANDALONE_ARTIFACTS" == true && "$HAS_NPM_ARTIFACTS" == false ]]; then
    log_step "Standalone-only install detected — will use existing if functional"
fi

# --- Smoke Test (defined early — used by version check and install) ----------

smoke_test() {
    if timeout 15 claude --version &>/dev/null; then
        return 0
    fi
    return 1
}

# --- Version Check -----------------------------------------------------------

DO_INSTALL=0

if ! validate_cmd "claude"; then
    log_warn "Claude Code not installed — will install"
    DO_INSTALL=1
else
    LOCAL_VER="$(claude --version 2>/dev/null || echo 'unknown')"

    # Claude Code auto-updates on each run (both npm and standalone).
    # Only force reinstall if the binary is broken, not just outdated.
    # The CLI handles its own updates — we just need to ensure it works.
    if smoke_test; then
        log_success "Claude Code: ${LOCAL_VER} (auto-updates on next run)"
    else
        log_warn "Claude Code installed but smoke test failed — will reinstall"
        DO_INSTALL=1
    fi
fi

# --- Install / Update --------------------------------------------------------

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

# If standalone was used, persist its PATH (covers both old and new paths)
if [[ "${INSTALL_METHOD}" == "standalone" ]] || [[ -d "$HOME/.claude/bin" ]] || [[ -L "$HOME/.local/bin/claude" ]]; then
    # New standalone: ~/.local/bin (already in PATH via base-setup)
    # Old standalone: ~/.claude/bin (needs explicit PATH entry)
    if [[ -d "$HOME/.claude/bin" ]]; then
        CLAUDE_PATH_LINE='export PATH="$HOME/.claude/bin:$PATH"'
        if ! grep -qF ".claude/bin" "$BASHRC_FILE" 2>/dev/null; then
            echo "$CLAUDE_PATH_LINE" >> "$BASHRC_FILE"
            log_success "~/.claude/bin added to PATH in $BASHRC_FILE"
        fi
    fi
fi

# --- Validation --------------------------------------------------------------

log_header "Validation"

if validate_cmd "claude"; then
    CLAUDE_VER="$(claude --version 2>/dev/null || echo 'version unavailable')"
    FINAL_PATH="$(which claude 2>/dev/null || echo 'unknown')"
    FINAL_METHOD="unknown"
    if [[ -L "$FINAL_PATH" ]]; then
        LINK_TARGET="$(readlink -f "$FINAL_PATH" 2>/dev/null || echo '')"
        if [[ "$LINK_TARGET" == *"claude/versions"* ]]; then
            FINAL_METHOD="standalone"
        elif [[ "$LINK_TARGET" == *"node_modules"* ]]; then
            FINAL_METHOD="npm"
        fi
    elif [[ "$FINAL_PATH" == "/usr/bin/claude" ]]; then
        FINAL_METHOD="npm"
    fi
    log_success "Claude Code: ${CLAUDE_VER}"
    log_success "Binary at: ${FINAL_PATH} (method: ${FINAL_METHOD})"
    log_success "Auto-update: Claude CLI updates itself on each interactive run"
    if [[ "$FINAL_METHOD" == "standalone" ]]; then
        log_warn "CAUTION: Do NOT run 'npm install -g @anthropic-ai/claude-code' — it will break the standalone symlink"
    elif [[ "$FINAL_METHOD" == "npm" ]]; then
        log_warn "CAUTION: Do NOT run the standalone installer (claude.ai/install.sh) — it will break the npm symlink"
    fi
else
    log_fail "claude command not found after install attempt"
    exit 1
fi

log_success "Claude Code setup complete"
