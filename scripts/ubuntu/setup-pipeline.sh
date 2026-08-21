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
DEPLOYER_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

CLAUDE_CONFIG_SRC="$DEPLOYER_DIR/config/claude"
AGY_CONFIG_SRC="$DEPLOYER_DIR/config/agy"

CLAUDE_TARGET="/root/.claude"
AGY_TARGET="/root/.gemini/antigravity-cli"

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

# statusline-command.sh: custom Claude Code status line.
if [[ -f "$CLAUDE_CONFIG_SRC/statusline-command.sh" ]]; then
    cp "$CLAUDE_CONFIG_SRC/statusline-command.sh" "$CLAUDE_TARGET/statusline-command.sh"
    chmod +x "$CLAUDE_TARGET/statusline-command.sh"
    log_success "Deployed statusline-command.sh"
else
    log_warn "statusline-command.sh not found — skipping"
fi

# settings.json: Claude Code CLI settings + MCP servers.
# Uses jq merge: source config is the base, existing user config is overlaid.
# This preserves MCP servers registered via 'claude mcp add' while ensuring
# the source plugins/MCPs are always present. envsubst replaces token placeholders.
if [[ -f "$CLAUDE_CONFIG_SRC/settings.json" ]]; then
    if validate_cmd "envsubst" && [[ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]]; then
        SOURCE_JSON="$(envsubst < "$CLAUDE_CONFIG_SRC/settings.json")"
    else
        SOURCE_JSON="$(cat "$CLAUDE_CONFIG_SRC/settings.json")"
        if [[ -z "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]]; then
            log_warn "GITHUB_PERSONAL_ACCESS_TOKEN not set — MCP tokens will have placeholders"
        fi
    fi

    if [[ -f "$CLAUDE_TARGET/settings.json" ]] && validate_cmd "jq"; then
        # Merge: source * existing → source keys win, existing extras preserved
        EXISTING_JSON="$(cat "$CLAUDE_TARGET/settings.json")"
        settings_tmp="$(mktemp "$CLAUDE_TARGET/.settings.json.XXXXXX")"
        if printf '%s\n%s\n' "$EXISTING_JSON" "$SOURCE_JSON" | jq -s '.[0] * .[1]' > "$settings_tmp"; then
            mv "$settings_tmp" "$CLAUDE_TARGET/settings.json"
            log_success "Merged Claude settings.json (preserved existing + applied source)"
        else
            rm -f "$settings_tmp"
            log_fail "Could not merge Claude settings.json"
            exit 1
        fi
    else
        echo "$SOURCE_JSON" > "$CLAUDE_TARGET/settings.json"
        log_success "Deployed Claude settings.json (fresh install)"
    fi
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

# --- Antigravity CLI (agy) Deployment ----------------------------------------

log_header "Antigravity CLI (agy) Config"

mkdir -p "$AGY_TARGET"
mkdir -p "$AGY_TARGET/agents"

# AGENTS.md: Antigravity project context file.
if [[ -f "$AGY_CONFIG_SRC/AGENTS.md" ]]; then
    cp "$AGY_CONFIG_SRC/AGENTS.md" "$AGY_TARGET/AGENTS.md"
    log_success "Deployed AGENTS.md"
else
    log_warn "AGENTS.md not found in $AGY_CONFIG_SRC — skipping"
fi

# settings.json
if [[ -f "$AGY_CONFIG_SRC/settings.json" ]]; then
    cp "$AGY_CONFIG_SRC/settings.json" "$AGY_TARGET/settings.json"
    log_success "Antigravity settings.json deployed"
else
    log_warn "Antigravity settings.json not found — skipping"
fi

# mcp_config.json: may contain ${VAR} placeholders for tokens.
if [[ -f "$AGY_CONFIG_SRC/mcp_config.json" ]]; then
    if validate_cmd "envsubst" && [[ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]]; then
        envsubst < "$AGY_CONFIG_SRC/mcp_config.json" > "$AGY_TARGET/mcp_config.json"
        log_success "Antigravity mcp_config.json deployed with token substitution"
    else
        cp "$AGY_CONFIG_SRC/mcp_config.json" "$AGY_TARGET/mcp_config.json"
        if ! validate_cmd "envsubst"; then
            log_warn "envsubst not available — deployed template as-is"
        elif [[ -z "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]]; then
            log_warn "GITHUB_PERSONAL_ACCESS_TOKEN not set — deployed template as-is"
        fi
    fi
else
    log_warn "Antigravity mcp_config.json not found — skipping"
fi

# Agent files: archon, ontos, pragma, dokimos, hermon.
DEPLOYED_AGY_AGENTS=0
for agent in archon ontos pragma dokimos hermon; do
    src="$AGY_CONFIG_SRC/agents/${agent}/agent.json"
    if [[ -f "$src" ]]; then
        mkdir -p "$AGY_TARGET/agents/${agent}"
        cp "$src" "$AGY_TARGET/agents/${agent}/agent.json"
        DEPLOYED_AGY_AGENTS=$((DEPLOYED_AGY_AGENTS + 1))
    else
        log_warn "Antigravity agent file not found: ${src} — skipping"
    fi
done

log_success "Deployed ${DEPLOYED_AGY_AGENTS}/5 Antigravity agent files"

# --- Git Identity ------------------------------------------------------------

if validate_cmd "git"; then
    if [[ -n "${GIT_USER_NAME:-}" ]]; then
        git config --global user.name "$GIT_USER_NAME"
        log_success "Git user.name set to: $GIT_USER_NAME"
    fi
    if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
        git config --global user.email "$GIT_USER_EMAIL"
        log_success "Git user.email set to: $GIT_USER_EMAIL"
    fi
fi

# --- Summary -----------------------------------------------------------------

log_header "Deployment Summary"
echo ""
printf "  %-28s %s\n" "Claude config target:" "$CLAUDE_TARGET"
printf "  %-28s %s\n" "  CLAUDE.md:" "$([ -f "$CLAUDE_TARGET/CLAUDE.md" ] && echo 'OK' || echo 'MISSING')"
printf "  %-28s %s\n" "  settings.json:" "$([ -f "$CLAUDE_TARGET/settings.json" ] && echo 'OK' || echo 'MISSING')"
printf "  %-28s %s\n" "  agents:" "${DEPLOYED_AGENTS}/5"
echo ""
printf "  %-28s %s\n" "Antigravity config target:" "$AGY_TARGET"
printf "  %-28s %s\n" "  AGENTS.md:" "$([ -f "$AGY_TARGET/AGENTS.md" ] && echo 'OK' || echo 'MISSING')"
printf "  %-28s %s\n" "  settings.json:" "$([ -f "$AGY_TARGET/settings.json" ] && echo 'OK' || echo 'MISSING')"
printf "  %-28s %s\n" "  mcp_config.json:" "$([ -f "$AGY_TARGET/mcp_config.json" ] && echo 'OK' || echo 'MISSING')"
printf "  %-28s %s\n" "  agents:" "${DEPLOYED_AGY_AGENTS}/5"
echo ""

log_success "Pipeline agent config deployment complete"
log_step "Claude Code will auto-detect agents at ~/.claude/agents/ on next launch"
