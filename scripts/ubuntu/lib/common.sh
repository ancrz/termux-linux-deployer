#!/bin/bash
# =============================================================================
# common.sh — Shared library for termux-linux-deployer Ubuntu scripts.
#
# USAGE: Source this file; do NOT execute it directly.
#   source "$SCRIPT_DIR/lib/common.sh"          # from scripts/ubuntu/
#   source "$SCRIPT_DIR/../lib/common.sh"        # from sub-dirs of ubuntu/
#
# Provides: color palette, logging functions, validation helpers,
#           smart_install_packages, ensure_path, load_env.
# =============================================================================
# Guard: abort if sourced with bash -e active and a helper fails unexpectedly.
# Individual callers set -euo pipefail in their own headers.

# --- Color Palette -----------------------------------------------------------
# All variables exported for use by sourcing scripts (hence SC2034 suppressed).
# shellcheck disable=SC2034
BOLD='\033[1m'
# shellcheck disable=SC2034
BLUE='\033[1;34m'
CYAN='\033[0;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
PURPLE='\033[1;35m'
NC='\033[0m'  # No Color / Reset

# --- Logging Functions -------------------------------------------------------

# log_header: Major section divider.
log_header() {
    echo -e "\n${BOLD}${PURPLE}=== $1 ===${NC}"
}

# log_step: In-progress action.
log_step() {
    echo -e "${CYAN}[-->]${NC} $1"
}

# log_success: Completed action.
log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

# log_fail: Fatal failure. Callers decide whether to exit.
log_fail() {
    echo -e "${RED}[FAIL]${NC} $1" >&2
}

# log_warn: Non-fatal warning.
log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# --- Validation Helpers ------------------------------------------------------

# validate_cmd: Return 0 if command exists, 1 otherwise.
validate_cmd() {
    command -v "$1" &>/dev/null
}

# validate_root: Exit with error message if not running as root.
validate_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_fail "This script must run as root (uid=0). Current uid=$(id -u)."
        exit 1
    fi
}

# validate_internet: Test internet connectivity using curl, falling back to wget.
# Exits with error if neither succeeds.
validate_internet() {
    log_step "Checking internet connectivity"
    if curl -s --head --max-time 10 https://www.google.com | grep -q "200\|301\|302"; then
        log_success "Internet connectivity confirmed (curl)"
        return 0
    fi
    # curl failed; try wget as fallback
    if validate_cmd "wget" && wget -q --spider --timeout=10 https://www.google.com 2>/dev/null; then
        log_success "Internet connectivity confirmed (wget)"
        return 0
    fi
    log_fail "No internet connectivity. Check your network and try again."
    exit 1
}

# --- Package Management ------------------------------------------------------

# smart_install_packages: Install or upgrade packages that are missing or
# have upgradable versions available.
#
# Usage: smart_install_packages pkg1 pkg2 pkg3 ...
#
# Strategy:
#   1. Find packages from the list that are not installed at all.
#   2. Refresh apt package lists.
#   3. Find packages from the list that are installed but upgradable.
#   4. Deduplicate and run apt-get install only if the combined list is non-empty.
#   5. Cleanup apt cache afterwards.
smart_install_packages() {
    local -a PACKAGES=("$@")

    if [[ ${#PACKAGES[@]} -eq 0 ]]; then
        log_warn "smart_install_packages: no packages provided"
        return 0
    fi

    log_step "Checking package states for: ${PACKAGES[*]}"

    # Step 1: Collect missing packages (not installed at all).
    local -a MISSING=()
    for pkg in "${PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            MISSING+=("$pkg")
        fi
    done

    # Step 2: Refresh apt package index.
    log_step "Refreshing apt package index"
    apt-get update -qq

    # Step 3: Collect upgradable packages from our list.
    local -a UPGRADABLE=()
    local UPGRADABLE_LIST
    UPGRADABLE_LIST=$(apt list --upgradable 2>/dev/null | awk -F/ '{print $1}' || true)

    for pkg in ${UPGRADABLE_LIST}; do
        # Only track packages that are in our requested list.
        # SC2076: Quoting the RHS is intentional — we want literal string matching,
        # not regex matching, for package names.
        # shellcheck disable=SC2076
        if [[ " ${PACKAGES[*]} " =~ " ${pkg} " ]]; then
            UPGRADABLE+=("$pkg")
        fi
    done

    # Step 4: Deduplicate and install.
    local -a TO_PROCESS=()
    if [[ ${#MISSING[@]} -gt 0 || ${#UPGRADABLE[@]} -gt 0 ]]; then
        # Do not use Bash process substitution here: PRoot may not expose the
        # temporary /dev/fd descriptor it requires. Real files work reliably.
        local packages_tmp packages_sorted_tmp
        packages_tmp="$(mktemp /tmp/deployer-packages.XXXXXX)"
        packages_sorted_tmp="$(mktemp /tmp/deployer-packages-sorted.XXXXXX)"

        printf '%s\n' "${MISSING[@]}" "${UPGRADABLE[@]}" > "$packages_tmp"
        if ! sort -u "$packages_tmp" > "$packages_sorted_tmp"; then
            rm -f "$packages_tmp" "$packages_sorted_tmp"
            log_fail "Could not deduplicate package list"
            return 1
        fi
        mapfile -t TO_PROCESS < "$packages_sorted_tmp"
        rm -f "$packages_tmp" "$packages_sorted_tmp"
    fi

    if [[ ${#TO_PROCESS[@]} -gt 0 ]]; then
        log_step "Installing/upgrading: ${TO_PROCESS[*]}"
        apt-get install -y "${TO_PROCESS[@]}"
        log_success "Package operation complete: ${TO_PROCESS[*]}"
    else
        log_success "All requested packages are already installed and up to date"
    fi

    # Step 5: Cleanup.
    apt-get clean
    apt-get autoremove -y -qq
}

# --- Path Management ---------------------------------------------------------

# ensure_path: Export the canonical PATH used by this deployer stack.
# Safe to call multiple times (idempotent via PATH prepend).
ensure_path() {
    export PATH="/usr/local/go/bin:${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
}

# --- Environment Loading -----------------------------------------------------

# validate_env: Check .env file for dangerous patterns before sourcing.
# Rejects lines with backticks, $(), pipes, semicolons outside of assignments.
validate_env() {
    local env_file="$1"
    local line_num=0
    local errors=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Must be a valid KEY=VALUE assignment
        if ! [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            log_fail ".env:${line_num}: invalid format (expected KEY=VALUE)"
            errors=$((errors + 1))
            continue
        fi
        # Reject dangerous shell constructs in the value
        local value="${line#*=}"
        if [[ "$value" =~ \`|\$\(|\; ]] && [[ ! "$value" =~ ^\$\{ ]]; then
            log_fail ".env:${line_num}: dangerous pattern detected"
            errors=$((errors + 1))
        fi
    done < "$env_file"
    return $errors
}

# load_env: Source $HOME/.env if it exists and export all variables.
# Variables already in the environment take precedence (set +a pattern).
load_env() {
    local ENV_FILE="${HOME}/.env"
    if [[ -f "$ENV_FILE" ]]; then
        log_step "Loading environment from $ENV_FILE"
        if ! validate_env "$ENV_FILE"; then
            log_fail "Refusing to source $ENV_FILE due to validation errors above."
            return 1
        fi
        set -a
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +a
    else
        log_warn "No .env file found at $ENV_FILE — running with current environment only"
    fi
}
