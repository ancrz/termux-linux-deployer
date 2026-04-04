#!/bin/bash
# =============================================================================
# setup-extensions.sh — Install code-server extensions from profile.
#
# Thin wrapper around: csm extensions install
# The Go binary reads config/csm/profile-extensions.json and installs
# all extensions that are not yet present. Profile-based, idempotent.
#
# Falls back to direct code-server CLI if csm is not built yet.
#
# Usage: bash /root/deployer/scripts/setup-extensions.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_env
ensure_path

log_header "Code-Server Extension Setup (Profile-Based)"
validate_root

DEPLOYER_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROFILE="$DEPLOYER_DIR/config/csm/profile-extensions.json"

if ! validate_cmd "code-server"; then
    log_fail "code-server not found. Run setup-csm.sh first."
    exit 1
fi

# Primary: use csm Go binary (profile-based, with categories and sync)
if validate_cmd "csm"; then
    log_step "Using csm extensions install (Go native)"
    csm extensions install "$PROFILE"
    exit $?
fi

# Fallback: direct code-server CLI if csm not available
log_warn "csm binary not found — falling back to direct install"

if [[ ! -f "$PROFILE" ]]; then
    log_fail "Profile not found: $PROFILE"
    exit 1
fi

# Parse extensions from JSON (requires jq)
if ! validate_cmd "jq"; then
    log_fail "jq not found and csm not available. Install jq or build csm first."
    exit 1
fi

EXTENSIONS=$(jq -r '.categories[].extensions[]' "$PROFILE")
TOTAL=$(echo "$EXTENSIONS" | wc -l)
INSTALLED=0
FAILED=0

log_step "Installing ${TOTAL} extensions from profile..."

while IFS= read -r ext; do
    log_step "Installing: ${ext}"
    if code-server --install-extension "$ext" --force 2>&1 | tail -1; then
        INSTALLED=$((INSTALLED + 1))
    else
        log_warn "Failed: ${ext}"
        FAILED=$((FAILED + 1))
    fi
done <<< "$EXTENSIONS"

log_header "Summary"
printf "  %-16s %d\n" "Total:" "$TOTAL"
printf "  %-16s %d\n" "Installed:" "$INSTALLED"
printf "  %-16s %d\n" "Failed:" "$FAILED"

log_success "Extension setup complete"
