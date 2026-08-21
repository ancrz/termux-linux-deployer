#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# install-ubuntu.sh — Install Ubuntu via proot-distro and run base setup.
#
# Run this script from Termux (NOT from inside proot).
# It provisions the Ubuntu rootfs and copies deployer scripts into it,
# then runs base-setup.sh inside proot automatically.
#
# Usage:
#   bash scripts/termux/install-ubuntu.sh          # normal install
#   bash scripts/termux/install-ubuntu.sh --fresh  # remove + reinstall
#
# After this script completes:
#   bash scripts/termux/login-ubuntu.sh            # enter proot shell
# Then inside proot:
#   bash /root/deployer/scripts/install-all.sh     # install remaining tools
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Minimal inline banner (common.sh is Ubuntu-side only; this script is Termux).
echo ""
echo "#########################################################"
echo "#   termux-linux-deployer: Ubuntu proot Installer       #"
echo "#########################################################"
echo ""

# --- Helper: simple logging --------------------------------------------------

_info()    { echo "[INFO]  $*"; }
_ok()      { echo "[OK]    $*"; }
_warn()    { echo "[WARN]  $*"; }
_fail()    { echo "[FAIL]  $*" >&2; }

# --- Step 1: Ensure proot-distro is installed --------------------------------

_info "Checking proot-distro availability"

if ! command -v proot-distro &>/dev/null; then
    _info "proot-distro not found — installing via pkg"
    pkg install proot-distro termux-api -y 2>/dev/null || pkg install proot-distro -y
fi

_ok "proot-distro is available"

# --- Step 2: Handle existing Ubuntu installation -----------------------------

UBUNTU_INSTALLED=0
if proot-distro list 2>/dev/null | grep -q "ubuntu.*installed"; then
    UBUNTU_INSTALLED=1
fi

if [[ "$UBUNTU_INSTALLED" -eq 1 ]]; then
    if [[ "${1:-}" == "--fresh" ]]; then
        _info "Removing existing Ubuntu installation (--fresh flag set)"
        proot-distro remove ubuntu || true
        UBUNTU_INSTALLED=0
    else
        _info "Ubuntu is already installed."
        _info "To enter Ubuntu, run:  bash scripts/termux/login-ubuntu.sh"
        _info "To reinstall cleanly:  bash scripts/termux/install-ubuntu.sh --fresh"
        exit 0
    fi
fi

# --- Step 3: Install Ubuntu --------------------------------------------------

_info "Installing Ubuntu via proot-distro (this may take several minutes)"
proot-distro install ubuntu
_ok "Ubuntu rootfs installed"

# --- Step 4: Copy deployer files into rootfs ---------------------------------

# proot-distro currently stores rootfs files under containers/, while older
# releases used installed-rootfs/. Support both layouts for repeatable setup.
PROOT_DATA_DIR="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/proot-distro"
if [[ -d "$PROOT_DATA_DIR/containers/ubuntu/rootfs" ]]; then
    ROOTFS="$PROOT_DATA_DIR/containers/ubuntu/rootfs"
elif [[ -d "$PROOT_DATA_DIR/installed-rootfs/ubuntu" ]]; then
    ROOTFS="$PROOT_DATA_DIR/installed-rootfs/ubuntu"
else
    _fail "Ubuntu rootfs not found under $PROOT_DATA_DIR"
    exit 1
fi
DEPLOY_TARGET="$ROOTFS/root/deployer"

_info "Copying deployer files into proot rootfs: $DEPLOY_TARGET"
mkdir -p "$DEPLOY_TARGET/scripts"

# Copy ubuntu-side scripts (not termux/ — those run from Termux).
cp -r "$SCRIPT_DIR/../ubuntu" "$DEPLOY_TARGET/scripts/"

# Copy Go source for csm and config files.
if [[ -d "$PROJECT_DIR/cmd" ]]; then
    cp -r "$PROJECT_DIR/cmd" "$DEPLOY_TARGET/"
    _ok "Copied cmd/ to $DEPLOY_TARGET/"
else
    _warn "cmd/ not found at $PROJECT_DIR/cmd — csm build will fail"
fi

if [[ -d "$PROJECT_DIR/config" ]]; then
    cp -r "$PROJECT_DIR/config" "$DEPLOY_TARGET/"
    _ok "Copied config/ to $DEPLOY_TARGET/"
else
    _warn "config/ not found — setup-pipeline.sh will have nothing to deploy"
fi

# The Topos pipeline is intentionally kept as a sibling source repository.
# Bundle that canonical checkout into the fresh rootfs so the Ubuntu-side
# installer can inject global Claude, Antigravity and Codex configuration
# without network access or a project-local fallback.
PIPELINE_SOURCE_HOST="${PIPELINE_SOURCE_DIR:-$(dirname "$PROJECT_DIR")/pipeline-agentic}"
if [[ -f "$PIPELINE_SOURCE_HOST/claude/CLAUDE.md" \
      && -f "$PIPELINE_SOURCE_HOST/gemini/gemini-cli/GEMINI.md" \
      && -f "$PIPELINE_SOURCE_HOST/codex/AGENTS.md" ]]; then
    cp -r "$PIPELINE_SOURCE_HOST" "$DEPLOY_TARGET/pipeline-agentic"
    _ok "Copied canonical pipeline-agentic source to $DEPLOY_TARGET/pipeline-agentic"
else
    _warn "pipeline-agentic not found or incomplete at: $PIPELINE_SOURCE_HOST"
    _warn "install-all.sh will stop at global pipeline injection until it is supplied."
fi

# Copy .env.example into proot for reference.
if [[ -f "$PROJECT_DIR/.env.example" ]]; then
    cp "$PROJECT_DIR/.env.example" "$DEPLOY_TARGET/.env.example"
fi

# Copy .env into proot home if it exists on the host.
ENV_FILE="$PROJECT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    # Validate .env before copying (inline — warn and skip copy on bad content)
    _ENV_INVALID=0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] || [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if ! [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            _warn ".env: invalid line format: $line"
            _ENV_INVALID=$((_ENV_INVALID + 1))
        fi
        _val="${line#*=}"
        if [[ "$_val" =~ \`|\$\( ]]; then
            _warn ".env: dangerous pattern detected: $line"
            _ENV_INVALID=$((_ENV_INVALID + 1))
        fi
    done < "$ENV_FILE"
    if [ "$_ENV_INVALID" -gt 0 ]; then
        _warn ".env has ${_ENV_INVALID} invalid line(s) — skipping copy to proot."
        _warn "Fix .env before running install-all.sh inside proot."
    else
        cp "$ENV_FILE" "$ROOTFS/root/.env"
        _ok "Copied .env to proot /root/.env"
    fi
else
    _warn ".env not found — create one from .env.example before running install-all.sh"
fi

_ok "Deployer files copied to proot"

# --- Step 5: Run base-setup.sh inside proot ----------------------------------

_info "Running base-setup.sh inside Ubuntu proot..."
echo ""
proot-distro login ubuntu -- bash /root/deployer/scripts/ubuntu/base-setup.sh
echo ""
_ok "Base setup complete"

# --- Final Instructions ------------------------------------------------------

echo ""
echo "Ubuntu installed and base setup complete."
echo ""
echo "Next steps:"
echo "  1. Enter proot Ubuntu:"
echo "       bash scripts/termux/login-ubuntu.sh"
echo ""
echo "  2. Inside proot, run the full installer:"
echo "       bash /root/deployer/scripts/install-all.sh"
echo ""
echo "  Note: If you have not created a .env file yet:"
echo "       cp $PROJECT_DIR/.env.example $PROJECT_DIR/.env"
echo "       # Edit .env with your credentials"
echo ""
