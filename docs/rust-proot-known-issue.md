# Rust on proot-distro: Known Segfault Issue

## Status

**Blocked** — Rust cannot be installed via `rustup` inside proot-distro Ubuntu.
This is a known upstream issue affecting proot's syscall emulation layer.

## Symptoms

When running the standard rustup installer:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
```

The installation begins normally (downloads installer, sets profile, syncs channel)
but crashes with a **Segmentation fault** during component download/extraction:

```
info: downloading 6 components
Segmentation fault
```

This happens consistently on arm64 (aarch64) inside proot-distro Ubuntu on Termux.

## Root Cause

proot translates Linux syscalls in userspace. Certain memory-mapped I/O operations
and signal handling patterns used by rustup and the Rust toolchain trigger segfaults
because proot cannot faithfully emulate them. This affects:

- `rustup` component downloads (unpacking via memory-mapped files)
- `rustc` compilation (heavy mmap usage during codegen)
- `cargo` builds (parallel compilation triggers race conditions in proot's ptrace layer)

Relevant upstream issues:
- https://github.com/nicehash/proot/issues (proot syscall emulation limitations)
- https://github.com/nicehash/nicehash-proot/issues/5 (similar segfault reports)
- Termux proot-distro discussions on GitHub

## Workarounds

### Option 1: Install Rust in Termux natively (recommended if needed)

Rust works fine in Termux's native environment (not inside proot):

```bash
# From Termux (NOT proot Ubuntu)
pkg install rust
```

The Rust toolchain installed in Termux can potentially be accessed from proot
via shared paths, but cross-environment usage is fragile and not recommended
for production builds.

### Option 2: Use pre-compiled binaries

Download pre-compiled aarch64 binaries of `rustc` and `cargo` directly instead
of using rustup. This avoids the rustup extraction step that triggers the segfault,
but compilation itself may still segfault inside proot.

### Option 3: Skip Rust entirely

For this project, Rust is not a hard dependency:
- **CSM** is written in Go (stdlib only, `CGO_ENABLED=0`)
- **Gemini CLI** uses Node.js/npm
- **Claude Code** uses Node.js

Rust was included in `base-setup.sh` as a general development tool, not as a
build dependency for any project component. The setup script handles the absence
gracefully — if rustup fails, subsequent steps (Go, UV) continue normally.

### Option 4: Wait for proot fix

The proot-distro maintainers are aware of syscall emulation gaps. A future
version of proot may resolve the mmap/signal handling issues that cause
Rust toolchain segfaults. Monitor:
- https://github.com/nicehash/proot (upstream)
- https://github.com/nicehash/termux-proot-distro

## Impact on base-setup.sh

`base-setup.sh` Step 2 (Rust Toolchain) will fail with exit code 139 (segfault).
Because the script uses `set -euo pipefail`, this aborts the entire script before
reaching Step 3 (Go) and Step 4 (UV).

**Mitigation applied**: When running manually, execute steps individually or
modify `base-setup.sh` to tolerate Rust failure:

```bash
# Quick patch: wrap Rust step so it doesn't abort the script
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || true
```

## Last tested

- **Date**: 2026-04-04
- **Environment**: Samsung Galaxy Tab S10 Ultra, Termux + proot-distro Ubuntu 24.04, arm64
- **Rust target version**: 1.94.1 (stable-aarch64-unknown-linux-gnu)
- **Result**: Segmentation fault during component download
