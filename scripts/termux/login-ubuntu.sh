#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# login-ubuntu.sh — Enter the Ubuntu proot shell with environment propagation.
#
# Reads .env from the project root, propagates all defined variables via
# proot-distro's --env flags, and exec's into the Ubuntu proot session.
#
# Usage:
#   bash scripts/termux/login-ubuntu.sh           # interactive shell
#   bash scripts/termux/login-ubuntu.sh -- bash /path/to/script.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"

# --- Load .env ---------------------------------------------------------------

if [[ -f "$ENV_FILE" ]]; then
    # Validate .env before sourcing (inline — cannot source common.sh from Termux)
    INVALID_LINES=0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] || [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if ! [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            echo "[WARN] .env: invalid line: $line"
            INVALID_LINES=$((INVALID_LINES + 1))
        fi
        value="${line#*=}"
        if [[ "$value" =~ \`|\$\( ]]; then
            echo "[ERROR] .env: dangerous pattern: $line"
            INVALID_LINES=$((INVALID_LINES + 1))
        fi
    done < "$ENV_FILE"
    if [ "$INVALID_LINES" -gt 0 ]; then
        echo "[ERROR] .env has $INVALID_LINES invalid line(s). Fix before continuing."
        exit 1
    fi
    # Export all variables found in .env into the current shell.
    # set -a causes subsequent variable assignments to be marked for export.
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
else
    echo "[WARN] No .env file found at $ENV_FILE"
    echo "       Copy .env.example to .env and fill in values."
    echo "       Continuing with current environment only."
fi

# --- Build --env flags for proot-distro login --------------------------------

# Always propagate HOME and TMPDIR.
ENV_FLAGS="--env HOME=/root"
ENV_FLAGS+=" --env TMPDIR=${TMPDIR:-/tmp}"

# The full set of variables declared in .env.example.
# Each variable is only forwarded if it is defined and non-empty.
FORWARD_VARS=(
    GITHUB_PERSONAL_ACCESS_TOKEN
    GITHUB_USERNAME
    CS_PASSWORD
    CS_PORT
    CS_CERT_MODE
    CS_CERT_FILE
    CS_HEARTBEAT_INTERVAL
    CS_MEMORY_LIMIT
    CS_DISABLE_FILE_DOWNLOADS
    GIT_USER_NAME
    GIT_USER_EMAIL
    GOOGLE_CLIENT_ID
    GOOGLE_CLIENT_SECRET
    SKILL_SWARM_GITHUB_TOKEN
    WORKSPACE_DIR
    NODE_TARGET_MAJOR
    PYTHON_DEFAULT_VERSION
    GO_VERSION
    CLAUDE_CODE_TMPDIR
    GH_MCP_VERSION
)

for var in "${FORWARD_VARS[@]}"; do
    # Indirect expansion: ${!var} dereferences the variable named by $var.
    # Check if the variable is set AND non-empty before forwarding.
    if [[ -n "${!var+x}" ]] && [[ -n "${!var}" ]]; then
        ENV_FLAGS+=" --env ${var}=${!var}"
    fi
done

# --- Enter proot -------------------------------------------------------------

# exec replaces this shell process; the proot session becomes the foreground
# process directly without an extra wrapper shell layer.
# "$@" forwards any additional arguments (e.g., -- bash /some/script.sh).
# SC2086: $ENV_FLAGS is intentionally unquoted — it contains multiple
# space-separated '--env KEY=VAL' arguments that must word-split into
# distinct argv entries for proot-distro. Quoting would pass them as
# a single argument and break all env var forwarding.
# IMPORTANT: --no-kill-on-exit keeps code-server alive when you exit this shell.
# LIMITATION: This does NOT survive Android killing Termux (OOM, swipe-away).
# For background persistence, run 'termux-wake-lock' before starting sessions.
# If Termux is killed, csm watchdog will recover code-server on next login.
# shellcheck disable=SC2086
exec proot-distro login ubuntu --no-kill-on-exit $ENV_FLAGS "$@"
