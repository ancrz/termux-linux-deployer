# ADR: Migration from Gemini CLI to Antigravity CLI (agy)

## Context
The `termux-linux-deployer` project orchestrates a full development environment inside a proot-distro Ubuntu instance on Android (Termux). The AI assistant CLI originally used was `gemini-cli` (`@google/gemini-cli`), which was a Node.js/npm-based application.

Google recently rebranded and released the successor to this tool as **Antigravity CLI** (`agy`), which is built in Go.

## Problem
When attempting to run the official Google arm64 binary for Antigravity CLI on an Android device (e.g., Samsung Galaxy Tab S10 Ultra), the binary immediately crashes with `Signal 6 (Aborted)` and `FATAL: TCMalloc: could not allocate memory`.

This occurs because:
1. The official Go binary relies on `TCMalloc`.
2. `TCMalloc` assumes a 48-bit Virtual Address (VA) space, which is standard for desktop/server Linux environments.
3. Android/Termux environments typically provide only a 39-bit Virtual Address space.
4. The binary also attempts to use `faccessat2` syscalls, which are not universally supported on Android kernels and cannot be reliably emulated by `proot`.

## Decision
We decided to deprecate the npm-based `gemini-cli` and migrate to Antigravity CLI (`agy`) to maintain alignment with Google's official product roadmap.

To solve the Termux compatibility issues, we adopted a community-maintained patcher (`wallentx/antigravity-cli-termux`). 

The new setup script (`scripts/ubuntu/setup-agy.sh`) uses this patcher to:
1. Download the official arm64 binary.
2. Apply a binary patch to adjust TCMalloc's virtual memory expectations from 48-bit to 39-bit.
3. Apply bypasses for missing Android syscalls.

## Consequences
* **Positive:** The project now uses the official, most up-to-date agentic AI CLI provided by Google.
* **Positive:** The integration works flawlessly on the Samsung Galaxy Tab S10 Ultra within the `proot` environment.
* **Negative (Mitigated):** We rely on a community patcher to modify the official binary. If Google changes the binary signature or structure significantly, the patcher may temporarily break until updated by the community. 

This change preserves the core philosophy of the deployer: ensuring a robust, desktop-class development environment on mobile hardware despite Android kernel limitations.
