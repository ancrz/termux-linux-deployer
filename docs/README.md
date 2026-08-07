# docs/ — Reference Scripts & Quick Start

## Quick Start (copy-paste from desktop to tablet)

Ubuntu proot is ALREADY installed. Do NOT run install-ubuntu.sh.
Go directly to the scripts layer:

```bash
# 1. Enter Ubuntu proot (from Termux)
proot-distro login ubuntu

# 2. Install minimum deps + Claude Code
apt update && apt install -y curl git build-essential
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt install -y nodejs
curl -fsSL https://claude.ai/install.sh | bash
export PATH="$HOME/.claude/bin:$HOME/.local/bin:$PATH"

# 3. Clone project and configure
cd ~ && git clone https://github.com/ancrz/termux-linux-deployer.git
cd termux-linux-deployer
cp .env.example .env
nano .env   # Fill: GITHUB_PERSONAL_ACCESS_TOKEN, CS_PASSWORD, GIT_USER_NAME, GIT_USER_EMAIL

# 4. Run full deployer (installs everything: Rust, Go, UV, Gemini, csm, agents, MCPs)
bash scripts/install-all.sh

# 5. Launch Claude Code to continue working
claude
```

Once Claude Code is running, tell it: "Read the CLAUDE.md and continue the project setup."

---

## Reference Scripts (RE Source)

These are the **original functional scripts** from Google Drive (`Dev_Config_Tablet`).
They were the starting point for this project and serve as reverse-engineering source material.

## Scripts

| Script | Purpose | Evolved into |
|--------|---------|-------------|
| `install-ubuntu_proot_distro-termux.sh` | Bootstrap Ubuntu via proot-distro in Termux | `scripts/termux/install-ubuntu.sh` |
| `ubuntu-base-setup.sh` | System packages + dev utilities | `scripts/ubuntu/base-setup.sh` (+ Rust + Go + UV) |
| `dev_gemini-cli.sh` | 4-layer dev stack (system, Python/UV, Node.js, Gemini CLI) | `scripts/ubuntu/setup-node.sh` + `setup-gemini.sh` |
| `manage-codeserver.sh` | code-server lifecycle management (bash) | `cmd/csm/main.go` (rewritten in Go) |

## Continuation Guide

When continuing this project from the tablet (via Claude Code inside proot Ubuntu):

### First-time setup
```bash
# Already inside proot Ubuntu with Claude Code installed
cd ~/termux-linux-deployer

# Configure environment
cp .env.example .env
nano .env   # Fill in: GITHUB_PERSONAL_ACCESS_TOKEN, CS_PASSWORD, GIT_USER_NAME, GIT_USER_EMAIL

# Run the full installer
bash scripts/install-all.sh
```

### What install-all.sh does (in order)
1. **setup-node.sh** — Node.js v22 LTS via NodeSource
2. **setup-gemini.sh** — Python/UV + Gemini CLI (@google/gemini-cli)
3. **setup-claude.sh** — Claude Code (standalone installer, npm fallback)
4. **setup-csm.sh** — Builds `csm` Go binary + installs code-server
5. **setup-pipeline.sh** — Deploys agent configs (CLAUDE.md, GEMINI.md, Archon/Ontos/Pragma/Dokimos/Hermon)
6. **setup-mcp.sh** — GitHub MCP binary (arm64) + skill-swarm

### After setup — start code-server
```bash
csm config    # Generate config from .env
csm start     # Start code-server on port 8443
csm watchdog  # Optional: background supervisor with auto-restart
```

### Fix SSH for remote access
```bash
# Inside proot Ubuntu
apt install -y openssh-server
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo "Port 8022" >> /etc/ssh/sshd_config
passwd   # Set root password
/usr/sbin/sshd

# OR from Termux (not proot):
pkg install openssh -y
passwd
sshd
# SSH runs on port 8022, user is the Termux user
```

### Key paths inside proot
```
/root/.claude/          — Claude Code config + agents
/root/.gemini/          — Gemini CLI config + agents
/root/.config/code-server/  — code-server config
/root/.local/bin/csm    — code-server manager binary
/root/.local/bin/github-mcp-server  — GitHub MCP binary
/root/.local/share/skill-swarm/    — skill-swarm installation
/root/.env              — environment variables (sourced by login wrapper)
```

### Pipeline agents available
Both Claude Code and Gemini CLI are configured with the agentic pipeline:
- **Archon** (opus) — Planning
- **Ontos** (opus) — Structural audit
- **Pragma** (sonnet) — Code execution
- **Dokimos** (sonnet) — Verification
- **Hermon** (sonnet) — Git operations

### Troubleshooting
- **Claude Code hangs**: Check `CLAUDE_CODE_TMPDIR` is set (`echo $CLAUDE_CODE_TMPDIR`)
- **Go build fails**: Ensure `/usr/local/go/bin` is in PATH
- **code-server won't start**: Run `csm status` and `csm logs`
- **MCP not working**: Verify tokens in `.env`, run `setup-mcp.sh` again
- **Scripts are idempotent** — safe to re-run any script at any time
