#!/bin/bash
# =============================================================================
# setup-pipeline.sh — Deploy AI agent configs for Claude Code and Gemini CLI.
#
# Copies config/claude/ -> /root/.claude/ and config/gemini/ -> /root/.gemini/.
# Performs envsubst on Gemini settings.json if GITHUB_PERSONAL_ACCESS_TOKEN
# is set (replaces ${VAR} placeholders with live values).
# Idempotent: cp overwrites with latest source on each run.
# Must run as root inside proot-distro Ubuntu.
#
# Usage: bash /root/deployer/scripts/setup-pipeline.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_env

# --- Configuration -----------------------------------------------------------

# Deployer root is the parent of scripts/ubuntu/.
DEPLOYER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CLAUDE_CONFIG_SRC="$DEPLOYER_DIR/config/claude"
GEMINI_CONFIG_SRC="$DEPLOYER_DIR/config/gemini"

CLAUDE_TARGET="/root/.claude"
GEMINI_TARGET="/root/.gemini"

# --- Pre-flight --------------------------------------------------------------

log_header "Pipeline Agent Config Deployment"
validate_root

# --- Claude Code Deployment --------------------------------------------------

log_header "Claude Code Config"

mkdir -p "$CLAUDE_TARGET/agents"

# CLAUDE.md: primary project context file.
if [[ -f "$CLAUDE_CONFIG_SRC/CLAUDE.md" ]]; then
    cp "$CLAUDE_CONFIG_SRC/CLAUDE.md" "$CLAUDE_TARGET/CLAUDE.md"
    log_success "Deployed CLAUDE.md"
else
    log_warn "CLAUDE.md not found in $CLAUDE_CONFIG_SRC — skipping"
fi

# settings.json: Claude Code CLI settings.
if [[ -f "$CLAUDE_CONFIG_SRC/settings.json" ]]; then
    cp "$CLAUDE_CONFIG_SRC/settings.json" "$CLAUDE_TARGET/settings.json"
    log_success "Deployed Claude settings.json"
else
    log_warn "Claude settings.json not found — skipping"
fi

# Agent files: Archon, Ontos, Pragma, Dokimos, Hermon.
DEPLOYED_AGENTS=0
for agent in Archon Ontos Pragma Dokimos Hermon; do
    src="$CLAUDE_CONFIG_SRC/agents/${agent}.md"
    if [[ -f "$src" ]]; then
        cp "$src" "$CLAUDE_TARGET/agents/${agent}.md"
        DEPLOYED_AGENTS=$((DEPLOYED_AGENTS + 1))
    else
        log_warn "Agent file not found: ${src} — skipping"
    fi
done

log_success "Deployed ${DEPLOYED_AGENTS}/5 Claude agent files"

# --- Gemini CLI Deployment ---------------------------------------------------

log_header "Gemini CLI Config"

mkdir -p "$GEMINI_TARGET"

# GEMINI.md: Gemini project context file.
if [[ -f "$GEMINI_CONFIG_SRC/GEMINI.md" ]]; then
    cp "$GEMINI_CONFIG_SRC/GEMINI.md" "$GEMINI_TARGET/GEMINI.md"
    log_success "Deployed GEMINI.md"
else
    log_warn "GEMINI.md not found in $GEMINI_CONFIG_SRC — skipping"
fi

# settings.json: may contain ${VAR} placeholders for tokens.
# Apply envsubst if available and the token is set; otherwise deploy as-is.
if [[ -f "$GEMINI_CONFIG_SRC/settings.json" ]]; then
    if validate_cmd "envsubst" && [[ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]]; then
        envsubst < "$GEMINI_CONFIG_SRC/settings.json" > "$GEMINI_TARGET/settings.json"
        log_success "Gemini settings.json deployed with token substitution"
    else
        cp "$GEMINI_CONFIG_SRC/settings.json" "$GEMINI_TARGET/settings.json"
        if ! validate_cmd "envsubst"; then
            log_warn "envsubst not available — deployed template as-is (install gettext for substitution)"
        elif [[ -z "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]]; then
            log_warn "GITHUB_PERSONAL_ACCESS_TOKEN not set — deployed template as-is"
        fi
    fi
else
    log_warn "Gemini settings.json not found — skipping"
fi

# Agent files: archon, ontos, pragma, dokimos, hermon (lowercase for Gemini).
DEPLOYED_GEMINI_AGENTS=0
for agent in archon ontos pragma dokimos hermon; do
    src="$GEMINI_CONFIG_SRC/${agent}.md"
    if [[ -f "$src" ]]; then
        cp "$src" "$GEMINI_TARGET/${agent}.md"
        DEPLOYED_GEMINI_AGENTS=$((DEPLOYED_GEMINI_AGENTS + 1))
    else
        log_warn "Gemini agent file not found: ${src} — skipping"
    fi
done

log_success "Deployed ${DEPLOYED_GEMINI_AGENTS}/5 Gemini agent files"

# --- Summary -----------------------------------------------------------------

log_header "Deployment Summary"
echo ""
printf "  %-28s %s\n" "Claude config target:" "$CLAUDE_TARGET"
printf "  %-28s %s\n" "Gemini config target:" "$GEMINI_TARGET"
echo ""

log_success "Pipeline agent config deployment complete"
