# termux-linux-deployer interactive Bash profile for Ubuntu under PRoot.
# This file is sourced from ~/.bashrc by setup-shell.sh.

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

stack_logo() {
    printf '\n%b\n' "${_stack_color_purple}╔══════════════════════════════════════════════╗${_stack_color_reset}"
    printf '%b\n' "${_stack_color_purple}║${_stack_color_cyan}  TERMUX · UBUNTU PROOT · DEV STACK          ${_stack_color_purple}║${_stack_color_reset}"
    printf '%b\n' "${_stack_color_purple}║${_stack_color_green}  Code Server · Claude · agy · Codex · Go    ${_stack_color_purple}║${_stack_color_reset}"
    printf '%b\n' "${_stack_color_purple}╚══════════════════════════════════════════════╝${_stack_color_reset}"
    printf '%b\n\n' "${_stack_color_blue}Workspace:${_stack_color_reset} ${TERMUX_WORKSPACE_ROOT}"
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

stack_status() {
    if command -v csm >/dev/null 2>&1; then
        csm status
    else
        printf '%b\n' "${_stack_color_yellow}csm no está instalado.${_stack_color_reset}"
    fi
}

stack_menu() {
    local choice
    stack_logo
    printf '%b\n' "${_stack_color_cyan}1${_stack_color_reset}) Workspace   ${_stack_color_cyan}2${_stack_color_reset}) Proyectos   ${_stack_color_cyan}3${_stack_color_reset}) Estado code-server"
    printf '%b\n' "${_stack_color_cyan}4${_stack_color_reset}) Agentes     ${_stack_color_cyan}5${_stack_color_reset}) Claude      ${_stack_color_cyan}6${_stack_color_reset}) agy      ${_stack_color_cyan}7${_stack_color_reset}) Codex"
    printf '%b\n' "${_stack_color_cyan}8${_stack_color_reset}) Extensiones ${_stack_color_cyan}0${_stack_color_reset}) Salir"
    read -r -p 'Selecciona una opción: ' choice
    case "$choice" in
        1) stack_workspace ;;
        2) stack_projects ;;
        3) stack_status ;;
        4) stack_agents ;;
        5) _stack_require claude && claude ;;
        6) _stack_require agy && agy ;;
        7) _stack_require codex && codex ;;
        8)
            if [[ -n "$TERMUX_STACK_ROOT" ]]; then
                bash "$TERMUX_STACK_ROOT/scripts/ubuntu/setup-extensions.sh"
            else
                printf '%b\n' "${_stack_color_yellow}No se encontró el repositorio del deployer.${_stack_color_reset}"
            fi
            ;;
        0|'') return 0 ;;
        *) printf '%b\n' "${_stack_color_yellow}Opción no válida.${_stack_color_reset}" ;;
    esac
}

alias ws='stack_workspace'
alias projects='stack_projects'
alias stack='stack_menu'
alias menu='stack_menu'
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
alias cs-status='stack_status'
alias cs-start='csm start'
alias cs-stop='csm stop'
alias cs-restart='csm restart'
alias cs-watch='csm watchdog --tmux'

if [[ -z "${TERMUX_STACK_BANNER_SHOWN:-}" ]]; then
    stack_logo
    export TERMUX_STACK_BANNER_SHOWN=1
fi
