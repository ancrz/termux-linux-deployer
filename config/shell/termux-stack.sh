# termux-linux-deployer interactive Bash profile for Ubuntu under PRoot.
# This file is sourced from ~/.bashrc by setup-shell.sh.
# shellcheck shell=bash

[[ $- == *i* ]] || return 0

export PATH="/usr/local/go/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

_stack_color_reset='\033[0m'
_stack_color_cyan='\033[1;36m'
_stack_color_blue='\033[1;34m'
_stack_color_green='\033[1;32m'
_stack_color_yellow='\033[1;33m'
_stack_color_purple='\033[1;35m'

_stack_find_root() {
    local candidate
    for candidate in \
        "$HOME/Documents/workspaces/termux-linux-deployer" \
        "$HOME/deployer"; do
        if [[ -d "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

export TERMUX_STACK_ROOT="${TERMUX_STACK_ROOT:-$(_stack_find_root 2>/dev/null || true)}"
if [[ "${WORKSPACE_DIR:-}" == "$HOME/home/Documents" ]]; then
    export TERMUX_WORKSPACE_ROOT="$HOME/Documents"
else
    export TERMUX_WORKSPACE_ROOT="${WORKSPACE_DIR:-$HOME/Documents}"
fi
export TERMUX_TMUX_SOCKET="${TERMUX_TMUX_SOCKET:-$HOME/.tmux-socket}"

stack_logo() {
    printf '\n%b\n' "${_stack_color_green}╔════════════════════════════════════════════════════╗${_stack_color_reset}"
    printf '%b\n' "${_stack_color_green}║${_stack_color_cyan}   TERMUX // UBUNTU PROOT // AGENTIC DEV BOOT       ${_stack_color_green}║${_stack_color_reset}"
    printf '%b\n' "${_stack_color_green}║${_stack_color_purple}   Claude · agy · Codex · code-server · tmux         ${_stack_color_green}║${_stack_color_reset}"
    printf '%b\n' "${_stack_color_green}╚════════════════════════════════════════════════════╝${_stack_color_reset}"
    printf '%b\n\n' "${_stack_color_blue}Workspace:${_stack_color_reset} ${TERMUX_WORKSPACE_ROOT}  ${_stack_color_blue}tmux:${_stack_color_reset} ${TERMUX_TMUX_SOCKET}"
}

stack_workspace() {
    mkdir -p "$TERMUX_WORKSPACE_ROOT/workspaces"
    cd "$TERMUX_WORKSPACE_ROOT" || return
}

stack_projects() {
    mkdir -p "$TERMUX_WORKSPACE_ROOT/workspaces"
    cd "$TERMUX_WORKSPACE_ROOT/workspaces" || return
}

_stack_require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf '%b\n' "${_stack_color_yellow}${1} no está instalado o no está en PATH.${_stack_color_reset}" >&2
        return 1
    fi
}

# tmux must use a socket under $HOME because PRoot may not support sockets in
# /tmp. All tmux helpers go through this wrapper to prevent split sessions.
stack_tmux() {
    _stack_require tmux || return
    tmux -S "$TERMUX_TMUX_SOCKET" "$@"
}

stack_tmux_list() {
    stack_tmux list-sessions
}

stack_tmux_attach() {
    local session="${1:-dev}"
    stack_tmux attach-session -t "$session"
}

_stack_tmux_run_or_attach() {
    local session="$1"
    local tmux_command
    shift

    if stack_tmux has-session -t "$session" 2>/dev/null; then
        printf '%b\n' "${_stack_color_cyan}Reconectando a tmux:${_stack_color_reset} $session"
        stack_tmux attach-session -t "$session"
        return
    fi

    printf '%b\n' "${_stack_color_green}Nueva sesión tmux:${_stack_color_reset} $session"
    printf -v tmux_command '%q ' "$@"
    stack_tmux new-session -s "$session" "${tmux_command% }"
}

stack_tmux_dev() {
    _stack_tmux_run_or_attach dev "${SHELL:-/bin/bash}"
}

_stack_tmux_agent() {
    local session="$1"
    local executable="$2"
    shift 2
    _stack_require "$executable" || return
    _stack_tmux_run_or_attach "$session" "$executable" "$@"
}

stack_tmux_agy() {
    _stack_tmux_agent agy agy "$@"
}

stack_tmux_claude() {
    _stack_tmux_agent claude claude "$@"
}

stack_tmux_codex() {
    _stack_tmux_agent codex codex "$@"
}

_stack_claude_agent() {
    _stack_require claude || return
    claude --agent "$1" "${@:2}"
}

_stack_agy_agent() {
    _stack_require agy || return
    agy --agent "$1" "${@:2}"
}

claude_archon()  { _stack_claude_agent Archon "$@"; }
claude_ontos()   { _stack_claude_agent Ontos "$@"; }
claude_pragma()  { _stack_claude_agent Pragma "$@"; }
claude_dokimos() { _stack_claude_agent Dokimos "$@"; }
claude_hermon()  { _stack_claude_agent Hermon "$@"; }

agy_archon()  { _stack_agy_agent archon "$@"; }
agy_ontos()   { _stack_agy_agent ontos "$@"; }
agy_pragma()  { _stack_agy_agent pragma "$@"; }
agy_dokimos() { _stack_agy_agent dokimos "$@"; }
agy_hermon()  { _stack_agy_agent hermon "$@"; }

stack_agents() {
    local role engine
    printf '%b\n' "${_stack_color_cyan}Pipeline: Archon → Ontos → Pragma → Dokimos → Hermon${_stack_color_reset}"
    printf '  1) Archon   2) Ontos   3) Pragma   4) Dokimos   5) Hermon\n'
    read -r -p 'Rol [1-5, Enter para cancelar]: ' role
    case "$role" in
        1) role=archon ;; 2) role=ontos ;; 3) role=pragma ;;
        4) role=dokimos ;; 5) role=hermon ;; *) return 0 ;;
    esac
    read -r -p 'Motor [c=Claude, a=agy, Enter para cancelar]: ' engine
    case "$engine" in
        c|C) "claude_${role}" ;;
        a|A) "agy_${role}" ;;
        *) return 0 ;;
    esac
}

stack_code_url() {
    printf '%b\n' "${_stack_color_cyan}code-server:${_stack_color_reset} http://127.0.0.1:8443"
}

stack_code_status() {
    _stack_require csm || return
    csm status
}

stack_code_start() {
    _stack_require csm || return
    csm start
    stack_code_url
}

stack_code_stop() {
    _stack_require csm || return
    csm stop
}

stack_code_restart() {
    _stack_require csm || return
    csm restart
    stack_code_url
}

stack_code_watch() {
    _stack_require csm || return
    _stack_require tmux || return
    csm watchdog --tmux
}

stack_code_attach() {
    stack_tmux_attach csm-watchdog
}

stack_help() {
    printf '%b\n' "${_stack_color_green}Normal:${_stack_color_reset} stack, ws, projects, agents, cs-start, cs-stop, cs-status"
    printf '%b\n' "${_stack_color_green}tmux:${_stack_color_reset} t-dev, t-agy, t-claude, t-codex, t-list, t-attach [sesión]"
    printf '%b\n' "${_stack_color_green}Persistencia:${_stack_color_reset} cs-watch crea csm-watchdog; cs-attach la reconecta"
}

stack_menu() {
    local choice
    stack_logo
    printf '%b\n' "${_stack_color_cyan}1${_stack_color_reset}) Workspace   ${_stack_color_cyan}2${_stack_color_reset}) Proyectos   ${_stack_color_cyan}3${_stack_color_reset}) code-server"
    printf '%b\n' "${_stack_color_cyan}4${_stack_color_reset}) Agentes     ${_stack_color_cyan}5${_stack_color_reset}) Claude      ${_stack_color_cyan}6${_stack_color_reset}) agy      ${_stack_color_cyan}7${_stack_color_reset}) Codex"
    printf '%b\n' "${_stack_color_cyan}8${_stack_color_reset}) t-dev       ${_stack_color_cyan}9${_stack_color_reset}) Ayuda       ${_stack_color_cyan}0${_stack_color_reset}) Salir"
    read -r -p 'Selecciona una opción: ' choice
    case "$choice" in
        1) stack_workspace ;;
        2) stack_projects ;;
        3) stack_code_status ;;
        4) stack_agents ;;
        5) _stack_require claude && claude ;;
        6) _stack_require agy && agy ;;
        7) _stack_require codex && codex ;;
        8) stack_tmux_dev ;;
        9) stack_help ;;
        0|'') return 0 ;;
        *) printf '%b\n' "${_stack_color_yellow}Opción no válida.${_stack_color_reset}" ;;
    esac
}

alias ws='stack_workspace'
alias projects='stack_projects'
alias stack='stack_menu'
alias menu='stack_menu'
alias stack-help='stack_help'
alias agents='stack_agents'
alias archon='claude_archon'
alias ontos='claude_ontos'
alias pragma='claude_pragma'
alias dokimos='claude_dokimos'
alias hermon='claude_hermon'
alias agy-archon='agy_archon'
alias agy-ontos='agy_ontos'
alias agy-pragma='agy_pragma'
alias agy-dokimos='agy_dokimos'
alias agy-hermon='agy_hermon'
alias cs-status='stack_code_status'
alias cs-start='stack_code_start'
alias cs-stop='stack_code_stop'
alias cs-restart='stack_code_restart'
alias cs-watch='stack_code_watch'
alias cs-attach='stack_code_attach'
alias cs-url='stack_code_url'
alias t='stack_tmux'
alias t-list='stack_tmux_list'
alias t-attach='stack_tmux_attach'
alias t-dev='stack_tmux_dev'
alias t-agy='stack_tmux_agy'
alias t-claude='stack_tmux_claude'
alias t-codex='stack_tmux_codex'

if [[ -z "${TERMUX_STACK_BANNER_SHOWN:-}" ]]; then
    stack_logo
    export TERMUX_STACK_BANNER_SHOWN=1
fi
