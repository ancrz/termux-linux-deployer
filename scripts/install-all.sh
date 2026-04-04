#!/bin/bash
# =============================================================================
# install-all.sh — Full installation orchestrator for termux-linux-deployer.
#
# Run this script INSIDE proot-distro Ubuntu after base-setup.sh has completed.
# It sequences all component setup scripts and reports success/failure per step.
# Idempotent: each called script is itself idempotent.
#
# Usage: bash /root/deployer/scripts/install-all.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The deployer root is one level up from scripts/.
# When launched from /root/deployer/scripts/, DEPLOYER_DIR = /root/deployer.
DEPLOYER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source shared library from ubuntu/lib/.
# shellcheck disable=SC1091
source "$DEPLOYER_DIR/scripts/ubuntu/lib/common.sh"

load_env

# --- Pre-flight --------------------------------------------------------------

log_header "termux-linux-deployer: Full Installation"
validate_root

echo ""
log_step "Deployer root: $DEPLOYER_DIR"
log_step "Scripts dir:   $SCRIPT_DIR"
echo ""

# --- Sequential Step Runner --------------------------------------------------

ERRORS=0
STEP_COUNT=0

# run_step: Execute a script and track pass/fail.
# Args: $1 = script path relative to scripts/ubuntu/, $2 = display name
run_step() {
    local script="$1"
    local name="$2"
    STEP_COUNT=$((STEP_COUNT + 1))

    log_header "Step ${STEP_COUNT}: ${name}"

    local script_path="$DEPLOYER_DIR/scripts/ubuntu/${script}"

    if [[ ! -f "$script_path" ]]; then
        log_fail "Script not found: $script_path"
        ERRORS=$((ERRORS + 1))
        return
    fi

    if bash "$script_path"; then
        log_success "${name} completed"
    else
        log_fail "${name} failed (exit code $?)"
        ERRORS=$((ERRORS + 1))
    fi
}

# --- Execute Steps in Dependency Order ----------------------------------------
#
# Dependency graph:
#   base-setup.sh  ──►  setup-node.sh  ──►  setup-gemini.sh
#                                       ──►  setup-claude.sh
#                   ──►  setup-csm.sh   (requires Go from base-setup)
#                   ──►  setup-pipeline.sh
#                   ──►  setup-mcp.sh   (registers with claude from setup-claude)

run_step "setup-node.sh"        "Node.js v${NODE_TARGET_MAJOR:-22} LTS"
run_step "setup-gemini.sh"      "Gemini CLI"
run_step "setup-claude.sh"      "Claude Code"
run_step "setup-csm.sh"         "Code-Server Manager (csm)"
run_step "setup-pipeline.sh"    "Pipeline Agent Configs"
run_step "setup-mcp.sh"         "MCP Servers"
run_step "setup-credentials.sh" "Credentials & GitHub Auth"

# --- Final Summary -----------------------------------------------------------

log_header "Installation Summary"

echo ""
if [[ $ERRORS -eq 0 ]]; then
    log_success "All ${STEP_COUNT} components installed successfully"
    echo ""
    echo "Installed tools:"
    printf "  %-20s %s\n" "Node.js:"      "$(node -v 2>/dev/null || echo 'not found')"
    printf "  %-20s %s\n" "npm:"          "$(npm -v 2>/dev/null || echo 'not found')"
    printf "  %-20s %s\n" "Gemini CLI:"   "$(gemini --version 2>/dev/null || echo 'not found')"
    printf "  %-20s %s\n" "Claude Code:"  "$(claude --version 2>/dev/null || echo 'not found')"
    printf "  %-20s %s\n" "code-server:"  "$(code-server --version 2>/dev/null | head -1 || echo 'not found')"
    printf "  %-20s %s\n" "csm:"          "$(/root/.local/bin/csm --version 2>/dev/null || echo 'not found')"
    echo ""
    log_success "Setup complete. Your development environment is ready."
else
    log_fail "${ERRORS} of ${STEP_COUNT} component(s) failed. Review output above."
    echo ""
    echo "To retry failed steps, re-run this script — it is idempotent."
    exit 1
fi
