#!/bin/bash
# Install the native interactive Bash profile for the Termux/PRoot stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

DEPLOYER_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROFILE_SRC="$DEPLOYER_DIR/config/shell/termux-stack.sh"
PROFILE_DIR="$HOME/.config/termux-linux-deployer"
PROFILE_TARGET="$PROFILE_DIR/termux-stack.sh"
BASHRC_LINE='[ -f "$HOME/.config/termux-linux-deployer/termux-stack.sh" ] && . "$HOME/.config/termux-linux-deployer/termux-stack.sh"'

log_header "Interactive Bash Profile"
validate_root

if [[ ! -f "$PROFILE_SRC" ]]; then
    log_fail "Shell profile not found: $PROFILE_SRC"
    exit 1
fi

mkdir -p "$PROFILE_DIR"
cp "$PROFILE_SRC" "$PROFILE_TARGET"
chmod 0644 "$PROFILE_TARGET"

if ! grep -qF "$BASHRC_LINE" "$HOME/.bashrc" 2>/dev/null; then
    printf '\n%s\n' "$BASHRC_LINE" >> "$HOME/.bashrc"
    log_success "Enabled stack profile in $HOME/.bashrc"
else
    log_success "Stack profile is already enabled in $HOME/.bashrc"
fi

log_success "Run 'source ~/.bashrc', then use 'stack' for the interactive menu"
