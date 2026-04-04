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
    pkg install proot-distro -y
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

ROOTFS="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/ubuntu"
DEPLOY_TARGET="$ROOTFS/root/deployer"

_info "Copying deployer files into proot rootfs: $DEPLOY_TARGET"
mkdir -p "$DEPLOY_TARGET/scripts"

# Copy ubuntu-side scripts (not termux/ — those run from Termux).
cp -r "$SCRIPT_DIR/../ubuntu" "$DEPLOY_TARGET/scripts/"

# Copy Go source for csm and config files.
if [[ -d "$PROJECT_DIR/cmd" ]]; then
    cp -r "$PROJECT_DIR/cmd" "$ROOTFS/root/"
    _ok "Copied cmd/ to $ROOTFS/root/"
else
    _warn "cmd/ not found at $PROJECT_DIR/cmd — csm build will fail"
fi

if [[ -d "$PROJECT_DIR/config" ]]; then
    cp -r "$PROJECT_DIR/config" "$DEPLOY_TARGET/"
    _ok "Copied config/ to $DEPLOY_TARGET/"
else
    _warn "config/ not found — setup-pipeline.sh will have nothing to deploy"
fi

# Copy .env.example into proot for reference.
if [[ -f "$PROJECT_DIR/.env.example" ]]; then
    cp "$PROJECT_DIR/.env.example" "$DEPLOY_TARGET/.env.example"
fi

# Copy .env into proot home if it exists on the host.
ENV_FILE="$PROJECT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    cp "$ENV_FILE" "$ROOTFS/root/.env"
    _ok "Copied .env to proot /root/.env"
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
