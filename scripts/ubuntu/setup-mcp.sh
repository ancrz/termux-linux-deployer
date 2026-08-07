#!/bin/bash
# =============================================================================
# setup-mcp.sh — Install MCP servers and register them with Claude Code.
#
# Installs:
#   1. GitHub MCP Server (Go binary, arm64 release from GitHub).
#   2. skill-swarm (Python, cloned from GitHub + venv).
#   3. Registers all MCPs with Claude Code if claude CLI is available.
#      (Note: Antigravity CLI MCPs are registered declaratively in setup-pipeline.sh)
# Idempotent: checks binary/directory existence before install.
# Must run as root inside proot-distro Ubuntu.
#
# Usage: bash /root/deployer/scripts/setup-mcp.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_env
ensure_path

# --- Configuration -----------------------------------------------------------

GH_MCP_VERSION="${GH_MCP_VERSION:-v0.2.0}"
GH_MCP_BIN="/root/.local/bin/github-mcp-server"
GH_MCP_URL="https://github.com/github/github-mcp-server/releases/download/${GH_MCP_VERSION}/github-mcp-server_Linux_arm64.tar.gz"

SKILL_SWARM_DIR="/root/.local/share/skill-swarm"
SKILL_SWARM_REPO="https://github.com/ancrz/skill-swarm-mcp.git"

# --- Pre-flight --------------------------------------------------------------

log_header "MCP Servers Setup"
validate_root

mkdir -p /root/.local/bin
mkdir -p /root/.local/share

# --- 1. GitHub MCP Server ----------------------------------------------------

log_header "GitHub MCP Server ${GH_MCP_VERSION}"

if [[ ! -f "$GH_MCP_BIN" ]]; then
    log_step "Downloading GitHub MCP Server ${GH_MCP_VERSION} (arm64)"
    curl -L --fail -o /tmp/gh-mcp.tar.gz "$GH_MCP_URL"

    log_step "Extracting GitHub MCP Server"
    tar -xzf /tmp/gh-mcp.tar.gz -C /tmp/

    # The archive contains 'github-mcp-server' at the root.
    if [[ ! -f /tmp/github-mcp-server ]]; then
        log_fail "Expected binary /tmp/github-mcp-server not found after extraction"
        ls /tmp/
        exit 1
    fi

    mv /tmp/github-mcp-server "$GH_MCP_BIN"
    chmod +x "$GH_MCP_BIN"
    rm -f /tmp/gh-mcp.tar.gz
    log_success "GitHub MCP Server installed: $GH_MCP_BIN"
else
    log_success "GitHub MCP Server already installed: $GH_MCP_BIN"
fi

# --- 2. skill-swarm ----------------------------------------------------------

log_header "skill-swarm"

if ! validate_cmd "git"; then
    log_fail "git not found. Run base-setup.sh first."
    exit 1
fi

if [[ ! -d "$SKILL_SWARM_DIR" ]]; then
    log_step "Cloning skill-swarm from ${SKILL_SWARM_REPO}"
    git clone "$SKILL_SWARM_REPO" "$SKILL_SWARM_DIR"
else
    log_step "Updating skill-swarm (fast-forward only)"
    cd "$SKILL_SWARM_DIR"
    git pull --ff-only || log_warn "skill-swarm update failed (network or merge conflict) — using cached version"
fi

log_step "Setting up skill-swarm Python venv"
cd "$SKILL_SWARM_DIR"

if ! validate_cmd "python3"; then
    log_fail "python3 not found. Run base-setup.sh first."
    exit 1
fi

python3 -m venv .venv

# Install as editable package if setup.py/pyproject.toml exists; fall back
# to requirements.txt; log a warning if neither works (non-fatal).
if .venv/bin/pip install -q -e . 2>/dev/null; then
    log_success "skill-swarm installed as editable package"
elif [[ -f requirements.txt ]] && .venv/bin/pip install -q -r requirements.txt 2>/dev/null; then
    log_success "skill-swarm installed from requirements.txt"
else
    log_warn "skill-swarm pip install had issues — MCP server may not start correctly"
fi

log_success "skill-swarm ready: $SKILL_SWARM_DIR"

# --- 3. Register MCPs with Claude Code --------------------------------------

log_header "Claude Code MCP Registration"

if validate_cmd "claude"; then
    log_step "Registering sequential-thinking MCP"
    claude mcp add sequential-thinking -- npx -y @modelcontextprotocol/server-sequential-thinking 2>/dev/null || true

    if [[ -f "$GH_MCP_BIN" ]]; then
        log_step "Registering GitHub MCP Server"
        claude mcp add github-mcp-server -- "$GH_MCP_BIN" stdio 2>/dev/null || true
    fi

    if [[ -f "$SKILL_SWARM_DIR/.venv/bin/python" ]]; then
        log_step "Registering skill-swarm MCP"
        claude mcp add skill-swarm -- "$SKILL_SWARM_DIR/.venv/bin/python" -m skill_swarm.server 2>/dev/null || true
    fi

    log_success "MCPs registered with Claude Code"
    log_step "Current Claude MCP config:"
    claude mcp list 2>/dev/null || true
else
    log_warn "claude CLI not found — MCP registration skipped"
    log_warn "Run setup-claude.sh first, then re-run this script to register MCPs"
fi

log_success "MCP setup complete"
