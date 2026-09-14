# termux-linux-deployer

[![Shell](https://img.shields.io/badge/shell-Bash-4EAA25?logo=gnubash&logoColor=white)](#interactive-bash-profile)
[![Host](https://img.shields.io/badge/host-Termux-111111?logo=android&logoColor=white)](#architecture)
[![Guest](https://img.shields.io/badge/guest-Ubuntu%20PRoot-E95420?logo=ubuntu&logoColor=white)](#architecture)
[![tmux](https://img.shields.io/badge/persistence-tmux-1BB91F?logo=tmux&logoColor=white)](#tmux-persistence)
[![code--server](https://img.shields.io/badge/IDE-code--server-007ACC?logo=visualstudiocode&logoColor=white)](#code-server-manager-csm)
[![Agents](https://img.shields.io/badge/agents-Claude%20%C2%B7%20agy%20%C2%B7%20Codex-8A2BE2)](#interactive-bash-profile)

Automated deployment of a full development environment inside proot-distro Ubuntu on Termux (Android/arm64). Deploys **Claude Code**, **Antigravity CLI (agy)**, **Codex CLI**, **code-server**, **Go**, **UV/Python**, **Node.js**, MCP servers, and a 5-agent pipeline framework.

## Target Device

This project scales to hardware where a Linux server and code environments can run smoothly (e.g., high-end or mid-range Android tablets and phones). While initially modeled around premium specs, it is generic enough to work on any modern device with a capable multi-core processor and sufficient RAM (typically 8GB+ recommended for full IDE and agentic workloads).

### Termux Installation

**Important:** The version of Termux available on the Google Play Store is **deprecated** and severely limited by current Android policies. It is highly recommended to download and install Termux directly from **[F-Droid](https://f-droid.org/packages/com.termux/)** or the **[GitHub releases page](https://github.com/termux/termux-app/releases)** to ensure proper functionality and receive updates.

## Architecture

```mermaid
graph TB
    subgraph "Android Host"
        A["Termux App"]
    end

    subgraph "Termux Native"
        B["install-ubuntu.sh"]
        L["login-ubuntu.sh<br/>.env propagation"]
    end

    subgraph "Ubuntu proot - /root"
        subgraph "L0: Foundation"
            C["base-setup.sh<br/>apt + Go 1.24 + UV"]
        end

        subgraph "L1: Runtimes"
            D["Node.js v22 LTS"]
        end

        subgraph "L2: AI CLI Tools"
            G["Antigravity CLI<br/>agy (Go binary)"]
            H["Claude Code<br/>npm primary / standalone fallback"]
            CX["Codex CLI<br/>@openai/codex"]
        end

        subgraph "L3: IDE + Process Manager"
            I["csm Go binary<br/>watchdog + health + extensions"]
            J["code-server 4.x"]
        end

        subgraph "L4: Agent Pipeline"
            K["Global Claude / Gemini / Codex context<br/>Archon - Graphos - Ontos<br/>Pragma - Dokimos - Hermon"]
        end

        subgraph "L5: MCP Servers"
            M["sequential-thinking<br/>github-mcp-server<br/>skill-swarm"]
        end

        subgraph "L6: Session + Auth + Extensions"
            N["tmux (scroll + attach)<br/>gh CLI + git credentials<br/>profile-based extensions"]
        end
    end

    A --> B --> C
    A --> L
    C --> D --> G & H & CX
    C --> I -->|supervises| J
    G & H & CX --> K --> M
    H --> N
    I --> N
```

## Pipeline Flow

```mermaid
flowchart LR
    subgraph "Termux: install-ubuntu.sh"
        UB["proot-distro install"] --> BS["base-setup.sh<br/>Go + UV + apt"]
    end

    subgraph "Ubuntu proot: install-all.sh"
        direction LR
        ND["setup-node"] --> GM["setup-agy"]
        ND --> CL["setup-claude"]
        ND --> CX["setup-codex"]
        CSM["setup-csm"] --> TM["setup-tmux"]
        TM --> EX["setup-extensions"]
        CL --> PL["setup-pipeline"]
        CL --> MCP["setup-mcp"]
        MCP --> CR["setup-credentials"]
    end

    BS -.->|"foundation ready"| ND
    BS -.->|"Go available"| CSM

    style BS fill:#4a9eff
    style UB fill:#4a9eff
    style EX fill:#2ecc71
    style CL fill:#e74c3c
```

`base-setup.sh` runs inside `install-ubuntu.sh` (Termux side) as part of Ubuntu provisioning. `install-all.sh` assumes the foundation layer is already present.

## Quick Start

### 1. Clone and configure

**Prerequisites:** You must have Git installed, and both repositories (`termux-linux-deployer` and `pipeline-agentic`) must be cloned into the same parent directory so the installer can discover the agentic rules.

```bash
# In Termux
pkg update && pkg install git -y

# Create a workspace directory
mkdir -p ~/Documents/workspaces
cd ~/Documents/workspaces

# Clone both required repositories (pipeline-agentic must be public or you must be authenticated)
git clone https://github.com/ancrz/termux-linux-deployer.git
git clone https://github.com/ancrz/pipeline-agentic.git

# Configure the deployer
cd termux-linux-deployer
cp .env.example .env
nano .env   # Fill: GITHUB_PERSONAL_ACCESS_TOKEN, CS_PASSWORD, GIT_USER_NAME, GIT_USER_EMAIL
```

### 2. Bootstrap Ubuntu

```bash
bash scripts/termux/install-ubuntu.sh
```

### 3. Enter proot and run full setup

```bash
bash scripts/termux/login-ubuntu.sh

# Inside proot Ubuntu — single command installs everything:
bash /root/deployer/scripts/install-all.sh
```

### PRoot notes

`setup-agy.sh` detects PRoot and installs Antigravity CLI (`agy`) with Google's
official PRoot-compatible installer. It persists `/root/.local/bin` in
`~/.bashrc` and `~/.profile`, so `agy` is available automatically in new shells.
If the shell was already open while the installer ran, reload it once:

```bash
source ~/.bashrc
```

### 4. Start code-server

```bash
# csm already detaches code-server from the current shell.
csm start

# Keep the long-running supervisor in tmux.
csm watchdog --tmux

# Access via browser
# http://localhost:8443
```

### Daily Usage

```bash
# --- code-server ---
cs-start                     # starts the already-detached code-server and prints its URL
cs-stop                      # stop (works regardless of tmux)
cs-restart                   # stop + start
cs-watch                     # persistent watchdog in tmux
cs-attach                    # reconnect to csm-watchdog
cs-status                    # process state + health

# --- tmux session management ---
t-list                       # list sessions using the PRoot-safe socket
t-dev                        # create/reconnect a general development shell
t-agy                        # create/reconnect the agy session
t-claude                     # create/reconnect the Claude Code session
t-codex                      # create/reconnect the Codex session
t-attach csm-watchdog        # attach a named session
# Ctrl-a + d                                      # detach
# Ctrl-a + [                                      # scroll mode
```

> **Note:** PRoot requires a custom socket path (`~/.tmux-socket`), which all `t-*` commands use automatically. `csm start` is already detached; `cs-watch` is the persistent tmux workflow for the watchdog.

### Interactive Bash profile

`setup-shell.sh` installs a native Bash profile with a green/cyan boot splash,
no zsh dependency, and two complementary modes. On every new Ubuntu PRoot
login, the splash keeps the essential commands visible: persistent agent
sessions (`t-agy`, `t-claude`, `t-codex`), `t-dev`, code-server controls, and
the reconnect flow (`t-list`, `t-attach <session>`). Run `source ~/.bashrc`
once in an already-open shell, then use `stack` (or `menu`) for the launcher.
The profile never starts tmux, code-server, or an agent by itself.

**Preflight:** `base-setup.sh` installs `tmux` and the stable Ubuntu
`shellcheck` package; `setup-tmux.sh` validates its configuration; and
`setup-csm.sh`, `setup-agy.sh`, `setup-claude.sh`, and
`setup-codex.sh` provide the optional commands. Each shortcut checks its binary
and gives a clear message if its component was not installed.

| Command | Action |
|---------|--------|
| `ws` / `projects` | Go to `Documents` / `Documents/workspaces` |
| `stack` / `menu` | Open the interactive development menu |
| `stack-help` | Show normal, tmux, and persistence shortcuts |
| `agents` | Choose a pipeline role and engine interactively |
| `archon`, `ontos`, `pragma`, `dokimos`, `hermon` | Start that role with Claude Code |
| `agy-archon`, `agy-ontos`, `agy-pragma`, `agy-dokimos`, `agy-hermon` | Start that role with Antigravity CLI |
| `cs-status`, `cs-start`, `cs-stop`, `cs-restart`, `cs-url` | Manage code-server from a normal shell |
| `cs-watch` / `cs-attach` | Start or reconnect the persistent watchdog session |
| `t-dev`, `t-agy`, `t-claude`, `t-codex` | Create or reconnect persistent developer/agent sessions |
| `t-list`, `t-attach <session>` | Inspect or reconnect any managed tmux session |

### tmux persistence

```mermaid
flowchart LR
    L["Ubuntu PRoot login\nBash splash + command map"] --> N["Normal mode\ncs-start · agents · stack"]
    L --> T["tmux mode\nt-* uses ~/.tmux-socket"]
    N --> S["csm start\nalready detached"]
    T --> A["t-agy / t-claude / t-codex\nreconnect if session exists"]
    T --> D["t-dev\npersistent development shell"]
    N --> W["cs-watch\ntmux: csm-watchdog"]
    W -->|"monitors"| S
    S --> CS["code-server :8443"]
    CS --> B["browser"]
    T -->|"Ctrl-a d disconnect"| T

    style T fill:#2ecc71
    style W fill:#e67e22
    style CS fill:#4a9eff
```

## Code-Server Manager (csm)

Static Go binary (stdlib only, `CGO_ENABLED=0`) replacing the legacy bash management script.

```mermaid
stateDiagram-v2
    [*] --> Stopped
    Stopped --> Starting: csm start
    Starting --> HealthCheck: adaptive retry (5x3s)
    HealthCheck --> Running: healthy
    HealthCheck --> StartFailed: 5 checks failed
    Running --> Stopped: csm stop
    Running --> Stopped: SIGTERM/SIGKILL
    Running --> WatchdogMonitor: csm watchdog

    state WatchdogMonitor {
        [*] --> Healthy
        Healthy --> Unhealthy: health check fail
        Unhealthy --> Unhealthy: fail count < 3
        Unhealthy --> Restarting: 3 consecutive fails
        Restarting --> Backoff: 30s/60s/120s/300s
        Backoff --> Healthy: health restored
    }
```

### Commands

```bash
csm install                        # Install code-server
csm config                         # Generate config.yaml from .env
csm start                          # Start (already detached; tmux is not required)
csm stop                           # Graceful SIGTERM -> SIGKILL after 5s
csm restart                        # Stop + start (already detached)
csm status                         # Process state + health
csm health                         # HTTP /healthz check (exit 0/1)
csm logs [N]                       # Last N log lines (default 50)
csm logs rotate                    # Rotate logs if over 100MB (keeps 7 backups)
csm watchdog --tmux                # Supervisor in detached csm-watchdog tmux session
csm purge                          # Remove all data (interactive)
csm extensions install [profile]   # Profile-based install with retry
csm extensions list                # List installed extensions
csm extensions sync [profile]      # Sync: install missing, report extras
```

### Log Rotation

Logs auto-rotate on `csm start` and `csm watchdog`. Manual rotation via `csm logs rotate`.

| Setting | Value |
|---------|-------|
| Max file size | 100 MB |
| Max backups | 7 |
| Scheme | `.log` → `.log.1` → `.log.2` → ... → `.log.7` |
| Managed files | `code-server.log`, `watchdog.log` |

## Extension Install Pipeline

```mermaid
flowchart TD
    A["Load profile JSON"] --> B["Check installed"]
    B --> C{"All present?"}
    C -->|Yes| Z["Done"]
    C -->|No| D["Round 1: attempt all"]
    D --> E{"Failures?"}
    E -->|No| Z
    E -->|Yes| F["Classify: proot crash / network / generic"]
    F --> G["Queue to deferred"]
    G --> H{"Internet check"}
    H -->|Fail| I["Wait 10s, retry check"]
    I -->|Fail| J["Stop: network unavailable"]
    H -->|OK| K["Retry round (2-5)"]
    K --> L{"Progress?"}
    L -->|Yes| G
    L -->|No| M["Stop: no progress"]

    style F fill:#e74c3c
    style Z fill:#2ecc71
```

Error classification:
- **proot crash**: `double free`, `malloc`, `segfault`, signal 134/139
- **network**: `ECONNREFUSED`, `ETIMEDOUT`, `fetch failed`
- **generic**: unknown error

### Installing and syncing extensions

The extension pipeline can run while code-server is active; it does not stop the
server. Install the configured profile after `setup-csm.sh` has completed:

```bash
cd ~/Documents/workspaces/termux-linux-deployer
bash scripts/ubuntu/setup-extensions.sh
```

The operation is idempotent: it skips extensions that are already installed and
retries only deferred failures. To reconcile an existing installation with the
profile later, run:

```bash
csm extensions sync config/csm/profile-extensions.json
```

Reload the code-server browser tab after installation. If an extension still
does not activate, restart the service with `csm restart` and reload the tab.

## Claude Code Installation

```mermaid
flowchart TD
    A["Detect existing install"] --> B{"Both npm + standalone?"}
    B -->|Yes| C["Sanitize: remove standalone"]
    B -->|No| D{"Binary works?"}
    C --> D
    D -->|Yes| Z["Done - CLI auto-updates"]
    D -->|No| E["Strategy 1: npm latest"]
    E -->|OK + smoke test| Z
    E -->|Fail| F["Strategy 2: npm pinned 0.2.114"]
    F -->|OK + smoke test| Z
    F -->|Fail| G["Strategy 3: standalone installer"]
    G -->|OK + smoke test| Z
    G -->|Fail| H["FATAL: all strategies exhausted"]

    style C fill:#e74c3c
    style Z fill:#2ecc71
    style H fill:#c0392b
```

## Pipeline Agents (Topos Integrity Protocol)

```mermaid
flowchart LR
    subgraph Orchestrator
        direction TB
        O["CLAUDE.md / GEMINI.md / AGENTS.md"]
    end

    O -->|"new task"| AR["Archon<br/>Plan"]
    AR -->|"plan ready"| GR["Graphos<br/>Weave"]
    GR -->|"context ready"| ON["Ontos<br/>Audit"]
    ON -->|"APPROVED"| PR["Pragma<br/>Execute"]
    ON -->|"BLOCKED"| AR
    PR -->|"done"| DK["Dokimos<br/>Verify"]
    PR -->|"blocker"| ON
    DK -->|"VERIFIED"| HM["Hermon<br/>Commit"]
    DK -->|"LOGIC_ERROR"| PR
    DK -->|"PLAN_GAP"| AR

    style AR fill:#4a9eff
    style GR fill:#4a9eff
    style ON fill:#4a9eff
    style PR fill:#2ecc71
    style DK fill:#2ecc71
    style HM fill:#2ecc71
```

`pipeline-agentic`, a sibling canonical repository, is copied into a fresh
Ubuntu rootfs and then injected globally after `agy`, Claude, and Codex are
installed. No project-local agent configuration is created.

| CLI | Global pipeline location |
|-----|--------------------------|
| Claude Code | `~/.claude/CLAUDE.md`, `~/.claude/agents/*.md` |
| Antigravity CLI (`agy`) | `~/.gemini/GEMINI.md`, `~/.gemini/config/agents/<role>/agent.md` |
| Codex | `~/.codex/AGENTS.md`, `~/.codex/agentic-pipeline/roles/*.md` |

The installer requires `pipeline-agentic` beside this repository (or a valid
`PIPELINE_SOURCE_DIR`) and fails explicitly instead of falling back to stale
prompt copies. Antigravity workflow templates are maintained in the canonical
repository and added through its Customizations UI; its current documentation
does not define a stable filesystem discovery path.

## MCP Servers

| Server | Binary | Transport | Token |
|--------|--------|-----------|-------|
| sequential-thinking | npx (on-demand) | stdio | None |
| github-mcp-server | Go arm64 binary | stdio | `GITHUB_PERSONAL_ACCESS_TOKEN` |
| skill-swarm | Python venv | stdio | `GITHUB_PERSONAL_ACCESS_TOKEN` |

`setup-mcp.sh` installs Skill Swarm once in
`~/.local/share/skill-swarm/.venv` and registers that absolute interpreter
globally with Claude Code (user scope), agy, and Codex. It also installs the
controller skill canonically in `~/.agents/skills/skill-swarm` and reconciles
links for Claude and both supported agy skill directories. Re-running the setup
is idempotent; existing managed skills are preserved and missing links repaired.
Optional secrets are read at process startup through
`SKILL_SWARM_ENV_FILE` (default: `~/.env`).

## Project Structure

```
termux-linux-deployer/
├── scripts/
│   ├── termux/
│   │   ├── install-ubuntu.sh          proot-distro bootstrap
│   │   └── login-ubuntu.sh            env-aware proot login
│   ├── ubuntu/
│   │   ├── lib/common.sh              shared: colors, logging, validators
│   │   ├── base-setup.sh              system packages + Go + UV
│   │   ├── setup-node.sh              Node.js v22 LTS
│   │   ├── setup-agy.sh               Antigravity CLI (agy)
│   │   ├── setup-claude.sh            Claude Code (sanitized install)
│   │   ├── setup-codex.sh             Codex CLI
│   │   ├── setup-csm.sh              Go binary + code-server
│   │   ├── setup-pipeline.sh          agents + settings merge
│   │   ├── setup-mcp.sh              MCP servers
│   │   ├── setup-tmux.sh              tmux config (scroll + attach)
│   │   ├── setup-shell.sh             native Bash menu + aliases
│   │   ├── setup-credentials.sh       git + gh auth
│   ��   └── setup-extensions.sh        profile-based extensions
│   └── install-all.sh                 orchestrator
├── cmd/csm/                           Go source (code-server manager)
├── config/
│   ├── claude/                        Claude runtime settings
│   ├── agy/                           agy runtime settings and MCP template
│   ├── csm/                          profile-extensions.json
│   ├── shell/                         native Bash banner + menu + aliases
│   └── tmux/                          tmux.conf
├── .env.example                       environment template
└── README.md
```

## Resilience Features

| Feature | Mechanism |
|---------|-----------|
| Rust segfault | Graceful skip with a troubleshooting note |
| Extension malloc crash | Deferred retry loop (5 rounds, error classification) |
| npm/standalone conflict | Auto-detect + sanitize conflicting artifacts |
| code-server slow start | Adaptive health check (5 retries x 3s) |
| Settings overwrite | jq merge (preserves user MCPs) |
| CLI auto-updates | Respected; only reinstall if broken |
| Watchdog restarts | Persistent log + exponential backoff |
| Network failures | Internet pre-check before retry rounds |

## Environment Variables

See `.env.example` for the full list. Key variables:

| Variable | Used by | Required |
|----------|---------|----------|
| `GITHUB_PERSONAL_ACCESS_TOKEN` | gh, github-mcp, skill-swarm | Yes |
| `GITHUB_USERNAME` | git credential store | Yes |
| `CS_PASSWORD` | csm config | Yes |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | git config | Recommended |

## Idempotency

All scripts are idempotent. Re-running:
- Skips installed/current packages
- Upgrades if newer version available
- Preserves existing configuration (merge, not overwrite)
- Extension install only processes missing extensions

## License

This project is released under the [MIT License](LICENSE). You may use, copy,
modify, distribute, sublicense, and improve it, provided that the copyright
and license notice are retained. It is provided without warranty.
