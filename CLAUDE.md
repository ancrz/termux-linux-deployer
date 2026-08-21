# CLAUDE.md — Project Instructions for termux-linux-deployer

## Project Overview

This is a deployment automation project for setting up a full development environment
inside proot-distro Ubuntu on Termux (Samsung Galaxy Tab S10 Ultra, arm64).

## First Run — Self-Configuration

If the pipeline agents are NOT yet deployed, run:
```bash
bash scripts/ubuntu/setup-pipeline.sh
```
This copies agent definitions from `config/claude/agents/` to `~/.claude/agents/`
and `config/claude/CLAUDE.md` to `~/.claude/CLAUDE.md`.

To verify agents are deployed:
```bash
ls ~/.claude/agents/  # Should show: Archon.md Dokimos.md Hermon.md Ontos.md Pragma.md
```

## Agent Pipeline

This project uses the Topos Integrity Protocol with 5 agents:
- **Archon** (opus) — Planning
- **Ontos** (opus) — Structural audit
- **Pragma** (sonnet) — Code execution
- **Dokimos** (sonnet) — Verification
- **Hermon** (sonnet) — Git operations

Agent definitions are in `config/claude/agents/`. The master CLAUDE.md
(pipeline controller) is in `config/claude/CLAUDE.md`.

## Project Structure

```
scripts/termux/     — Termux-side scripts (install, login wrapper)
scripts/ubuntu/     — Ubuntu-side scripts (setup components)
scripts/ubuntu/lib/ — Shared functions (colors, logging, validators)
cmd/csm/            — Go source for code-server manager
config/             — Agent definitions + settings for Claude & Antigravity (agy)
```

## Key Commands

```bash
# Run full setup
bash scripts/install-all.sh

# Individual components
bash scripts/ubuntu/base-setup.sh      # System packages + Rust + Go + UV
bash scripts/ubuntu/setup-node.sh      # Node.js v22
bash scripts/ubuntu/setup-agy.sh       # Antigravity CLI (agy)
bash scripts/ubuntu/setup-claude.sh    # Claude Code
bash scripts/ubuntu/setup-codex.sh     # Codex CLI
bash scripts/ubuntu/setup-csm.sh       # Build csm + install code-server
bash scripts/ubuntu/setup-pipeline.sh  # Deploy agent configs
bash scripts/ubuntu/setup-mcp.sh       # MCP servers

# Code-server management
csm start | stop | restart | status | health | logs | watchdog | purge
```

## Environment

- All sensitive values are in `.env` (copy from `.env.example`)
- Scripts are idempotent — safe to re-run
- HOME=/root inside proot
- All scripts source `scripts/ubuntu/lib/common.sh` for shared functions

## Development Conventions

- Shell scripts: `set -euo pipefail`, English strings, idempotent
- Go: stdlib only, no external deps, `CGO_ENABLED=0` for static binary
- Git: Conventional Commits, Co-Authored-By trailer
- All changes go through the agentic pipeline when modifying code
