#!/bin/bash
# =============================================================================
# setup-credentials.sh — Configure git identity and service authentication.
#
# Handles:
#   - Git global identity (user.name, user.email from .env)
#   - GitHub authentication (gh auth or git-credentials for private repos)
#   - GitHub CLI installation if missing
#
# Claude Code and Gemini CLI handle their own auth interactively on first run.
# This script prepares everything else so those first-run flows succeed.
#
# Idempotent: skips steps already configured.
# Must run as root inside proot-distro Ubuntu.
#
# Usage: bash /root/deployer/scripts/setup-credentials.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_env
ensure_path

# --- Pre-flight --------------------------------------------------------------

log_header "Credentials & Authentication Setup"
validate_root

# --- Step 1: Git Identity ----------------------------------------------------

log_header "Step 1: Git Identity"

if [[ -n "${GIT_USER_NAME:-}" ]]; then
    git config --global user.name "$GIT_USER_NAME"
    log_success "git user.name = $GIT_USER_NAME"
else
    CURRENT_NAME="$(git config --global user.name 2>/dev/null || echo '')"
    if [[ -n "$CURRENT_NAME" ]]; then
        log_success "git user.name already set: $CURRENT_NAME"
    else
        log_warn "GIT_USER_NAME not set in .env and no global git config found"
        log_warn "Set it in .env or run: git config --global user.name 'your name'"
    fi
fi

if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
    git config --global user.email "$GIT_USER_EMAIL"
    log_success "git user.email = $GIT_USER_EMAIL"
else
    CURRENT_EMAIL="$(git config --global user.email 2>/dev/null || echo '')"
    if [[ -n "$CURRENT_EMAIL" ]]; then
        log_success "git user.email already set: $CURRENT_EMAIL"
    else
        log_warn "GIT_USER_EMAIL not set in .env and no global git config found"
    fi
fi

# --- Step 2: GitHub CLI (gh) -------------------------------------------------

log_header "Step 2: GitHub CLI"

if ! validate_cmd "gh"; then
    log_step "Installing GitHub CLI (gh)"
    # Official install: https://github.com/cli/cli/blob/trunk/docs/install_linux.md
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq gh
    log_success "GitHub CLI installed: $(gh --version | head -1)"
else
    log_success "GitHub CLI already installed: $(gh --version | head -1)"
fi

# --- Step 3: GitHub Authentication -------------------------------------------

log_header "Step 3: GitHub Authentication"

if gh auth status &>/dev/null; then
    log_success "GitHub CLI already authenticated"
    gh auth status 2>&1 | head -3
else
    if [[ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]]; then
        log_step "Authenticating GitHub CLI with token from .env"
        echo "${GITHUB_PERSONAL_ACCESS_TOKEN}" | gh auth login --with-token
        log_success "GitHub CLI authenticated via token"
    else
        log_warn "GITHUB_PERSONAL_ACCESS_TOKEN not set in .env"
        log_warn "Run manually: gh auth login"
    fi
fi

# --- Step 4: Git Credential Helper -------------------------------------------

log_header "Step 4: Git Credential Helper"

# Ensure git can push/pull to private repos without re-prompting.
CURRENT_HELPER="$(git config --global credential.helper 2>/dev/null || echo '')"

if [[ -z "$CURRENT_HELPER" ]]; then
    if [[ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" && -n "${GITHUB_USERNAME:-}" ]]; then
        git config --global credential.helper store
        CRED_FILE="$HOME/.git-credentials"
        # Only write if not already present
        CRED_LINE="https://${GITHUB_USERNAME}:${GITHUB_PERSONAL_ACCESS_TOKEN}@github.com"
        if ! grep -qF "github.com" "$CRED_FILE" 2>/dev/null; then
            echo "$CRED_LINE" > "$CRED_FILE"
            chmod 600 "$CRED_FILE"
            log_success "Git credential store configured for github.com"
        else
            log_success "Git credentials for github.com already stored"
        fi
    else
        log_warn "Cannot configure git credentials: GITHUB_USERNAME or GITHUB_PERSONAL_ACCESS_TOKEN missing"
        log_warn "Set both in .env or run: gh auth setup-git"
    fi
else
    log_success "Git credential helper already configured: $CURRENT_HELPER"
fi

# --- Step 5: Auth Reminders --------------------------------------------------

log_header "Step 5: Interactive Auth (manual)"

echo ""
echo "  The following tools require interactive authentication on first use:"
echo ""
echo "  Claude Code:"
echo "    Run 'claude' and follow the OAuth/API key prompt."
echo ""
echo "  Gemini CLI:"
echo "    Run 'gemini auth' to authenticate with Google."
echo ""
echo "  Google Workspace MCP:"
echo "    Run 'npx google-workspace-mcp auth' for one-time OAuth."
echo ""

log_success "Credentials setup complete"
