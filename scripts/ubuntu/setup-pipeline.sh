#!/bin/bash
# =============================================================================
# setup-pipeline.sh — Install the canonical Topos pipeline globally.
#
# The source is pipeline-agentic, never a project-local .claude/.gemini/
# configuration. It is copied into each CLI's user scope after the three agent
# CLIs have been installed. Re-running is safe: only pipeline-owned files are
# replaced; settings are merged or retained.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env
ensure_path

DEPLOYER_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLAUDE_CONFIG_SRC="$DEPLOYER_DIR/config/claude"
AGY_CONFIG_SRC="$DEPLOYER_DIR/config/agy"

find_pipeline_source() {
    local candidate
    for candidate in \
        "${PIPELINE_SOURCE_DIR:-}" \
        "$DEPLOYER_DIR/pipeline-agentic" \
        "$(dirname "$DEPLOYER_DIR")/pipeline-agentic" \
        "$HOME/Documents/workspaces/pipeline-agentic"; do
        if [[ -n "$candidate" && -f "$candidate/claude/CLAUDE.md" \
            && -f "$candidate/gemini/gemini-cli/GEMINI.md" \
            && -f "$candidate/codex/AGENTS.md" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

copy_pipeline_file() {
    local source_file="$1"
    local destination="$2"
    local temp_file
    temp_file="$(mktemp "${destination}.XXXXXX")"
    # Allows a legacy source checkout with a historical /home/ancruz path to
    # remain portable while the canonical repository is being updated.
    sed "s#${PIPELINE_LEGACY_HOME:-/home/ancruz}#${HOME}#g" "$source_file" > "$temp_file"
    mv "$temp_file" "$destination"
}

write_agy_agent() {
    local role="$1"
    local role_file="$2"
    local agent_dir="$HOME/.gemini/config/agents/$role"
    local description
    case "$role" in
        archon) description="Plans work before implementation." ;;
        graphos) description="Weaves knowledge and sequential rollups." ;;
        ontos) description="Audits plans for structural integrity." ;;
        pragma) description="Implements an approved plan." ;;
        dokimos) description="Verifies implementation and tests." ;;
        hermon) description="Commits only verified work." ;;
    esac
    mkdir -p "$agent_dir"
    {
        printf '%s\n' '---'
        printf 'name: %s\n' "$role"
        printf 'description: %s\n' "$description"
        printf 'enable_write_tools: true\n'
        printf 'enable_mcp_tools: true\n'
        printf 'enable_subagent_tools: true\n'
        printf '%s\n\n' '---'
        cat "$role_file"
    } > "$agent_dir/agent.md"
}

log_header "Global Topos Pipeline Deployment"
validate_root

PIPELINE_SOURCE="$(find_pipeline_source)" || {
    log_fail "pipeline-agentic source was not found"
    log_step "Expected: $DEPLOYER_DIR/pipeline-agentic or ~/Documents/workspaces/pipeline-agentic"
    log_step "Set PIPELINE_SOURCE_DIR to an explicit canonical checkout and retry."
    exit 1
}

for cli in claude agy codex; do
    if ! validate_cmd "$cli"; then
        log_fail "$cli is required before pipeline injection"
        exit 1
    fi
done

log_step "Canonical source: $PIPELINE_SOURCE"

log_header "Claude Code — user-wide agents"
mkdir -p "$HOME/.claude/agents"
copy_pipeline_file "$PIPELINE_SOURCE/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
for agent in Archon Graphos Ontos Pragma Dokimos Hermon; do
    copy_pipeline_file "$PIPELINE_SOURCE/claude/${agent}.md" "$HOME/.claude/agents/${agent}.md"
done

# CLI settings are deployment settings, not pipeline prompts. Merge them so
# existing authentication, user preferences, and manually registered MCPs live.
if [[ -f "$CLAUDE_CONFIG_SRC/settings.json" ]]; then
    mkdir -p "$HOME/.claude"
    source_json="$(cat "$CLAUDE_CONFIG_SRC/settings.json")"
    if [[ -f "$HOME/.claude/settings.json" ]] && validate_cmd jq; then
        settings_tmp="$(mktemp "$HOME/.claude/.settings.json.XXXXXX")"
        if printf '%s\n%s\n' "$(cat "$HOME/.claude/settings.json")" "$source_json" | jq -s '.[0] * .[1]' > "$settings_tmp"; then
            mv "$settings_tmp" "$HOME/.claude/settings.json"
        else
            rm -f "$settings_tmp"
            log_warn "Could not merge Claude settings; leaving current file intact"
        fi
    elif [[ ! -f "$HOME/.claude/settings.json" ]]; then
        printf '%s\n' "$source_json" > "$HOME/.claude/settings.json"
    fi
fi
log_success "Installed CLAUDE.md and 6 user-level agents"

log_header "Antigravity CLI — global rules and agents"
mkdir -p "$HOME/.gemini/config/agents"
copy_pipeline_file "$PIPELINE_SOURCE/gemini/gemini-cli/GEMINI.md" "$HOME/.gemini/GEMINI.md"
for role in archon graphos ontos pragma dokimos hermon; do
    role_source="$PIPELINE_SOURCE/gemini/gemini-cli/${role}.md"
    copy_pipeline_file "$role_source" "$HOME/.gemini/${role}.md"
    write_agy_agent "$role" "$HOME/.gemini/${role}.md"
done

# agy 1.x retains its CLI state in this directory. Keep user settings and
# supply the same global rules there for compatibility with earlier releases.
mkdir -p "$HOME/.gemini/antigravity-cli"
copy_pipeline_file "$HOME/.gemini/GEMINI.md" "$HOME/.gemini/antigravity-cli/AGENTS.md"
# Older installer revisions registered the same pipeline roles as JSON below
# antigravity-cli. Current agy discovers Markdown agents from ~/.gemini/config.
# Keep a recoverable backup but remove the stale registrations from discovery.
for role in archon graphos ontos pragma dokimos hermon; do
    legacy_agent="$HOME/.gemini/antigravity-cli/agents/${role}/agent.json"
    if [[ -f "$legacy_agent" ]]; then
        legacy_backup="$HOME/.gemini/antigravity-cli/agents.disabled/${role}.agent.json"
        mkdir -p "$(dirname "$legacy_backup")"
        mv "$legacy_agent" "$legacy_backup"
        rmdir "$HOME/.gemini/antigravity-cli/agents/${role}" 2>/dev/null || true
        log_step "Retired legacy agy agent registration: $role"
    fi
done
if [[ -f "$AGY_CONFIG_SRC/settings.json" && ! -f "$HOME/.gemini/antigravity-cli/settings.json" ]]; then
    cp "$AGY_CONFIG_SRC/settings.json" "$HOME/.gemini/antigravity-cli/settings.json"
fi
if [[ -f "$AGY_CONFIG_SRC/mcp_config.json" && ! -f "$HOME/.gemini/config/mcp_config.json" ]]; then
    mkdir -p "$HOME/.gemini/config"
    cp "$AGY_CONFIG_SRC/mcp_config.json" "$HOME/.gemini/config/mcp_config.json"
fi
log_success "Installed GEMINI.md, 6 role files and 6 global agents"
log_step "Workflow templates remain in the canonical source for Antigravity's Customizations UI."

log_header "Codex — global AGENTS.md"
mkdir -p "$HOME/.codex/agentic-pipeline/roles"
copy_pipeline_file "$PIPELINE_SOURCE/codex/AGENTS.md" "$HOME/.codex/AGENTS.md"
for role in archon graphos ontos pragma dokimos hermon; do
    copy_pipeline_file "$PIPELINE_SOURCE/gemini/gemini-cli/${role}.md" \
        "$HOME/.codex/agentic-pipeline/roles/${role}.md"
done
log_success "Installed global AGENTS.md and 6 canonical role prompts"

log_header "Deployment Summary"
printf '  %-28s %s\n' "Canonical source:" "$PIPELINE_SOURCE"
printf '  %-28s %s\n' "Claude global context:" "$HOME/.claude/CLAUDE.md"
printf '  %-28s %s\n' "Agy global context:" "$HOME/.gemini/GEMINI.md"
printf '  %-28s %s\n' "Codex global context:" "$HOME/.codex/AGENTS.md"
log_success "Global pipeline injection complete"
