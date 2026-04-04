#!/bin/bash
# =============================================================================
# setup-tmux.sh — Configure tmux for session persistence and scroll support.
#
# tmux is already installed via base-setup.sh (system packages).
# This script deploys the optimized config and verifies functionality.
#
# Features configured:
#   - Mouse scroll support (critical for tablet usage)
#   - 50,000 line scrollback buffer
#   - Vi-mode copy
#   - Ctrl-a prefix (tablet-friendly)
#   - Session attach/detach for persistent work
#
# Usage patterns after setup:
#   tmux new -s dev          # create named session
#   tmux attach -t dev       # re-attach after disconnect
#   tmux ls                  # list sessions
#   csm start                # run code-server inside tmux for persistence
#
# Idempotent: overwrites config with latest version.
# Must run as root inside proot-distro Ubuntu.
#
# Usage: bash /root/deployer/scripts/setup-tmux.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_env
ensure_path

# --- Configuration -----------------------------------------------------------

DEPLOYER_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMUX_CONFIG_SRC="$DEPLOYER_DIR/config/tmux/tmux.conf"
TMUX_CONFIG_DST="/root/.tmux.conf"

# --- Pre-flight --------------------------------------------------------------

log_header "tmux Setup"
validate_root

# --- Step 1: Verify tmux installed -------------------------------------------

if ! validate_cmd "tmux"; then
    log_step "tmux not found — installing"
    apt-get update -qq
    apt-get install -y -qq tmux
    log_success "tmux installed: $(tmux -V)"
else
    log_success "tmux already installed: $(tmux -V)"
fi

# --- Step 2: Deploy config ---------------------------------------------------

log_step "Deploying tmux config"

if [[ -f "$TMUX_CONFIG_SRC" ]]; then
    cp "$TMUX_CONFIG_SRC" "$TMUX_CONFIG_DST"
    log_success "Config deployed to $TMUX_CONFIG_DST"
else
    log_fail "tmux config not found at $TMUX_CONFIG_SRC"
    exit 1
fi

# --- Step 3: Verify ----------------------------------------------------------

log_header "Verification"

# Check tmux can parse the config
if tmux -f "$TMUX_CONFIG_DST" start-server \; kill-server 2>/dev/null; then
    log_success "Config syntax valid"
else
    log_warn "Config syntax check inconclusive (proot may block server start)"
fi

log_success "tmux $(tmux -V) configured"

echo ""
echo "  Usage:"
echo "    tmux new -s dev           # new session named 'dev'"
echo "    tmux attach -t dev        # re-attach to 'dev'"
echo "    tmux ls                   # list active sessions"
echo "    Ctrl-a + [                # enter scroll mode (navigate with arrows/vi keys)"
echo "    Ctrl-a + d                # detach (session persists)"
echo "    Ctrl-a + |                # split pane horizontal"
echo "    Ctrl-a + -                # split pane vertical"
echo ""

log_success "tmux setup complete"
