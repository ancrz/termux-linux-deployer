# Pipeline Management Reference

## Overview

termux-linux-deployer is a deployment automation pipeline for a full development
environment inside proot-distro Ubuntu on Termux (Samsung Galaxy Tab S10 Ultra, arm64).

This document covers the pipeline architecture, execution order, resilience
mechanisms, and operational decisions made during development.

---

## Execution Order

The pipeline runs in strict dependency order. `install-all.sh` orchestrates
everything after `base-setup.sh` provides the foundation.

```
[TERMUX NATIVE]
  1. install-ubuntu.sh        Bootstrap proot-distro Ubuntu (one-time)
  2. login-ubuntu.sh           Enter proot, propagate .env vars

[UBUNTU PROOT]
  3. install-all.sh            Orchestrator — runs steps 3a-3i:
     ├─ 3a. base-setup.sh          System packages, Go, UV (Rust skipped*)
     ├─ 3b. setup-node.sh          Node.js v22 LTS via NodeSource
     ├─ 3c. setup-gemini.sh        Gemini CLI via npm
     ├─ 3d. setup-claude.sh        Claude Code (npm primary, standalone fallback)
     ├─ 3e. setup-csm.sh           Compile Go binary + install code-server
     ├─ 3f. setup-pipeline.sh      Deploy agents + merge settings.json
     ├─ 3g. setup-mcp.sh           GitHub MCP + skill-swarm + registration
     ├─ 3h. setup-credentials.sh   Git identity, gh auth, credential store
     └─ 3i. setup-extensions.sh    Profile-based extension install with retry
```

*Rust skipped due to proot segfault — see `docs/rust-proot-known-issue.md`.

### Dependency Graph

```
base-setup.sh (Go, UV, system packages)
    │
    ├── setup-node.sh (Node.js v22)
    │   ├── setup-gemini.sh (npm)
    │   └── setup-claude.sh (npm/standalone)
    │       └── setup-mcp.sh (claude mcp add)
    │
    ├── setup-csm.sh (Go build + code-server)
    │   └── setup-extensions.sh (csm extensions install)
    │
    ├── setup-pipeline.sh (agents + settings)
    └── setup-credentials.sh (git + gh)
```

---

## Resilience Mechanisms

### 1. Rust Tolerance (base-setup.sh)

proot-distro's syscall emulation causes `rustup` to segfault during
component download. The script catches this and continues:

```bash
if curl ... | sh -s -- -y; then
    # success
else
    log_warn "Rust installation failed (likely proot segfault). Skipping."
fi
```

Impact: None. No project component depends on Rust.

### 2. Extension Deferred Retry (csm Go binary)

code-server extensions with native binaries (Rust-based LSPs, heavy
extensions) intermittently fail with `double free or corruption` due
to proot's memory allocation emulation.

Strategy:
- **Round 1**: attempt all extensions, failures go to deferred queue
- **Rounds 2-5**: retry deferred, with internet pre-check per round
- **Error classification**: `proot crash`, `network`, or `generic`
- **Stop conditions**: all installed, no progress in a round, or max 5 rounds
- **Delay**: 3s between retry rounds

```
Round 1: 13 installed, 8 deferred (proot crash)
Round 2: 7 installed, 1 deferred (proot crash)
Round 3: 0 installed, 1 deferred → no progress, stop
Result: 20/21 installed, 1 permanent failure (tamasfe.even-better-toml)
```

### 3. Claude Install Sanitization (setup-claude.sh)

Two install methods exist (npm and standalone) that create conflicting
symlinks. The script:

1. **Detects** existing install method by tracing symlinks
2. **Sanitizes** if both coexist (removes standalone artifacts, keeps npm)
3. **Warns** user which method NOT to mix
4. **Respects** CLI auto-update (only reinstalls if binary is broken)

Install priority: npm → npm pinned (0.2.114) → standalone (last resort)

### 4. Settings Merge (setup-pipeline.sh)

Claude `settings.json` uses `jq` merge instead of copy:
```bash
jq -s '.[0] * .[1]' existing.json source.json > target.json
```

This preserves MCPs registered via `claude mcp add` while ensuring
source plugins and MCP servers are always present. Token placeholders
are substituted via `envsubst`.

### 5. CSM Adaptive Startup (cmd/csm/main.go)

code-server on proot can take 8-12s to respond on first boot.
Instead of a single health check after 5s, CSM uses adaptive retry:

```
Health check 1/5 (3s) — not ready
Health check 2/5 (6s) — not ready
Health check 3/5 (9s) — healthy ✓
```

### 6. CSM Watchdog with Persistent Log

The watchdog loop writes to both stdout and `~/.config/code-server/watchdog.log`
with ISO timestamps. Events are preserved across sessions for debugging
overnight restarts.

---

## CSM (Code Server Manager)

Static Go binary (`CGO_ENABLED=0`, stdlib only). Replaces the legacy
bash script `docs/manage-codeserver.sh`.

### Commands

| Command | Description |
|---------|-------------|
| `csm install` | Download code-server via official script |
| `csm config` | Create dirs + write config.yaml from env |
| `csm start` | Launch background process, adaptive health check |
| `csm stop` | SIGTERM → 5s wait → SIGKILL |
| `csm restart` | stop + start |
| `csm status` | Process state + health endpoint |
| `csm health` | HTTP GET /healthz, exit 0/1 |
| `csm logs [N]` | Last N lines of log (default 50) |
| `csm watchdog` | Background supervisor with backoff + persistent log |
| `csm purge` | Remove all config/data (interactive confirm) |
| `csm extensions install [profile]` | Profile-based install with retry |
| `csm extensions list` | List installed extensions |
| `csm extensions sync [profile]` | Install missing, report extras |

### Watchdog Backoff Schedule

```
Failure 1-2:  log warning, continue checking
Failure 3:    restart code-server
  → backoff 30s
Failure 3 again: restart
  → backoff 60s
Failure 3 again: restart
  → backoff 120s
Failure 3 again: restart
  → backoff 300s (max)
```

Healthy check resets all counters. SIGTERM/SIGINT handled for clean shutdown.

---

## MCP Server Registration

### Claude Code

MCPs are registered via `claude mcp add` (setup-mcp.sh) AND via
settings.json merge (setup-pipeline.sh). Both methods coexist:

| Server | Source | Transport |
|--------|--------|-----------|
| sequential-thinking | npx | stdio |
| github-mcp-server | Go binary (arm64) | stdio |
| skill-swarm | Python venv | stdio |
| google-workspace-mcp | npx | stdio |

### Gemini CLI

MCPs are defined in `~/.gemini/settings.json` with token substitution
via `envsubst`. Same four servers.

---

## Extension Profile

Extensions are managed via `config/csm/profile-extensions.json`.
Categories: lang-python, lang-go, lang-config, web, productivity, appearance.

21 extensions total. Excluded list documents extensions incompatible
with proot (Docker, K8s, browser-dependent).

---

## Agent Pipeline (Topos Integrity Protocol)

5-stage pipeline deployed to both Claude Code and Gemini CLI:

| Agent | Model | Role |
|-------|-------|------|
| Archon | opus | Planning — dependency graph, risk assessment |
| Ontos | opus | Structural audit — ontological validation |
| Pragma | sonnet | Code execution — implements validated plans |
| Dokimos | sonnet | Verification — test generation and RCA |
| Hermon | sonnet | Git operations — commits, branches, push |

Files deployed to `~/.claude/agents/` and `~/.gemini/` by setup-pipeline.sh.

---

## Known Issues

| Issue | Status | Workaround |
|-------|--------|------------|
| Rust segfault in proot | Permanent (proot limitation) | Skip, not needed |
| Extension malloc crash | Intermittent | Deferred retry loop |
| npm/standalone symlink conflict | Handled | Auto-sanitization |
| code-server slow startup | Handled | Adaptive health check |
| coder.json wrong workspace path | Fixed | Corrected `/home/root` → `/root/home` |
| settings.json overwrite | Fixed | jq merge |
| DEPLOYER_DIR wrong path | Fixed | `../..` instead of `..` |
| TO_PROCESS unbound variable | Fixed | Initialize as `=()` |

---

## Environment Variables

All sensitive values in `~/.env` (sourced by scripts via `load_env`).
Source of truth: `.env.example` in repo.

| Variable | Used by | Required |
|----------|---------|----------|
| `GITHUB_PERSONAL_ACCESS_TOKEN` | gh, github-mcp, skill-swarm, settings.json | Yes |
| `GITHUB_USERNAME` | git credential store | Yes |
| `CS_PASSWORD` | csm config → code-server | Yes |
| `CS_PORT` | csm config (default: 8443) | No |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | git config, setup-credentials | Recommended |
| `GO_VERSION` | base-setup.sh (default: 1.24.2) | No |
| `NODE_TARGET_MAJOR` | setup-node.sh (default: 22) | No |

---

## File Locations Inside Proot

```
/root/.claude/                     Claude Code config
/root/.claude/agents/              Pipeline agents (5 .md files)
/root/.claude/settings.json        Plugins + MCP servers
/root/.gemini/                     Gemini CLI config + agents
/root/.gemini/settings.json        MCP servers
/root/.config/code-server/         code-server config + logs
/root/.config/code-server/watchdog.log  Watchdog persistent log
/root/.local/bin/csm               CSM binary
/root/.local/bin/github-mcp-server GitHub MCP binary
/root/.local/share/code-server/    code-server data
/root/.local/share/vscode-extensions/  Extensions
/root/.local/share/skill-swarm/    skill-swarm installation
/root/.env                         Environment variables
/root/home/Documents/              Workspace root (code-server opens here)
```
