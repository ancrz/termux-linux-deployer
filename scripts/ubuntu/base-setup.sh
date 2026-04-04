#!/bin/bash
# =============================================================================
# base-setup.sh — Ubuntu base environment setup for termux-linux-deployer.
#
# Installs: essential system packages, Rust (via rustup), Go, and UV.
# Idempotent: checks before every install/upgrade; safe to re-run.
# Must run as root inside proot-distro Ubuntu.
#
# Usage: bash /root/deployer/scripts/base-setup.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_env

# --- Configuration -----------------------------------------------------------

# Go version: overridable via environment (e.g., export GO_VERSION=1.24.2)
GO_VERSION="${GO_VERSION:-1.24.2}"

# Merged package list: base utilities + Layer 1 dev packages from dev_gemini-cli.sh
SYSTEM_PACKAGES=(
    build-essential
    cmake
    make
    python3
    python3-pip
    python3-venv
    pkg-config
    libsecret-1-dev
    curl
    wget
    net-tools
    iputils-ping
    dnsutils
    git
    unzip
    zip
    tar
    procps
    htop
    tree
    tmux
    jq
    gnupg
    ca-certificates
    p7zip-full
    gettext
)

# --- Pre-flight Checks -------------------------------------------------------

log_header "Pre-flight Checks"
validate_root
validate_internet

# --- Step 1: System Packages -------------------------------------------------

log_header "Step 1: System Packages"
smart_install_packages "${SYSTEM_PACKAGES[@]}"

# --- Step 2: Rust via rustup -------------------------------------------------

log_header "Step 2: Rust Toolchain"

ensure_path

if ! validate_cmd "rustc"; then
    log_step "Installing Rust via rustup (non-interactive)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    # Load cargo env so rustc/cargo are available in this session immediately.
    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
    fi
    log_success "Rust $(rustc --version)"
else
    log_step "Rust already installed — updating to stable"
    rustup update stable 2>/dev/null || true
    log_success "Rust $(rustc --version)"
fi

# --- Step 3: Go --------------------------------------------------------------

log_header "Step 3: Go ${GO_VERSION}"

ensure_path

_install_go() {
    local version="$1"
    local tarball="go${version}.linux-arm64.tar.gz"
    local download_url="https://go.dev/dl/${tarball}"

    log_step "Downloading Go ${version} from ${download_url}"
    curl -LO "$download_url"

    log_step "Extracting Go ${version} to /usr/local"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "${tarball}"
    rm -f "${tarball}"
}

if ! validate_cmd "go"; then
    log_step "Go not found — installing Go ${GO_VERSION}"
    _install_go "$GO_VERSION"
else
    INSTALLED_GO="$(go version | awk '{print $3}' | sed 's/go//')"
    if [[ "$INSTALLED_GO" != "$GO_VERSION" ]]; then
        log_step "Upgrading Go ${INSTALLED_GO} -> ${GO_VERSION}"
        _install_go "$GO_VERSION"
    else
        log_success "Go ${INSTALLED_GO} is already at the target version"
    fi
fi

# Reload PATH so go binary is reachable in this session.
ensure_path
log_success "Go $(go version)"

# --- Step 4: UV (Python package manager) ------------------------------------

log_header "Step 4: UV Python Manager"

ensure_path

if ! validate_cmd "uv"; then
    log_step "Installing UV via astral.sh installer"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # UV installs itself into ~/.local/bin or ~/.cargo/bin depending on the
    # platform. Try both env shims.
    if [[ -f "$HOME/.local/bin/env" ]]; then
        # shellcheck disable=SC1091
        source "$HOME/.local/bin/env"
    elif [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
    fi
    # Refresh PATH to pick up the new uv binary.
    ensure_path
    log_success "UV $(uv --version) installed"
else
    log_success "UV already installed: $(uv --version)"
    # Attempt a self-update; failure is non-fatal (network restrictions, etc.)
    uv self update >/dev/null 2>&1 || true
fi

# --- Step 5: Persist PATH in /root/.bashrc -----------------------------------

log_header "Step 5: Persist PATH"

# SC2016: Single quotes are intentional — $HOME and $PATH must expand at
# login time (when .bashrc is sourced), not at script execution time.
# shellcheck disable=SC2016
BASHRC_LINE='export PATH="/usr/local/go/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"'
BASHRC_FILE="/root/.bashrc"

# Idempotent: only append if the exact line is not already present.
if ! grep -qF "$BASHRC_LINE" "$BASHRC_FILE" 2>/dev/null; then
    echo "$BASHRC_LINE" >> "$BASHRC_FILE"
    log_success "PATH line appended to $BASHRC_FILE"
else
    log_success "PATH line already present in $BASHRC_FILE"
fi

# --- Final Summary -----------------------------------------------------------

log_header "Installation Summary"

# Reload PATH one final time so all version checks reflect the installed tools.
ensure_path

echo ""
printf "  %-20s %s\n" "Package manager:" "$(dpkg --version | head -1)"
printf "  %-20s %s\n" "Rust:" "$(rustc --version 2>/dev/null || echo 'not found')"
printf "  %-20s %s\n" "Cargo:" "$(cargo --version 2>/dev/null || echo 'not found')"
printf "  %-20s %s\n" "Go:" "$(go version 2>/dev/null || echo 'not found')"
printf "  %-20s %s\n" "UV:" "$(uv --version 2>/dev/null || echo 'not found')"
printf "  %-20s %s\n" "Python3 (system):" "$(python3 --version 2>/dev/null || echo 'not found')"
echo ""

log_success "Base setup complete. Run install-all.sh to continue."
