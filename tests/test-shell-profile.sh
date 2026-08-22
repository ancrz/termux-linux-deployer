#!/bin/bash
# Smoke-test the interactive shell template without creating a real tmux server.
set -euo pipefail

PROFILE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="$PROFILE_DIR/config/shell/termux-stack.sh"
TEST_DIR="$(mktemp -d)"
TMUX_CAPTURE="$TEST_DIR/tmux-args"
TMUX_COUNT="$TEST_DIR/tmux-count"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

if [[ ! -f "$PROFILE" ]]; then
    printf 'profile missing: %s\n' "$PROFILE" >&2
    exit 1
fi

output="$(bash --noprofile --norc -ic 'source "$1"; alias t-agy; alias t-claude; alias t-codex; alias cs-start; declare -F stack_tmux stack_tmux_attach stack_code_watch stack_help' _ "$PROFILE" 2>&1)"

for expected in \
    "alias t-agy='stack_tmux_agy'" \
    "alias t-claude='stack_tmux_claude'" \
    "alias t-codex='stack_tmux_codex'" \
    "alias cs-start='stack_code_start'" \
    'stack_tmux' \
    'stack_tmux_attach' \
    'stack_code_watch' \
    'stack_help'; do
    if [[ "$output" != *"$expected"* ]]; then
        printf 'shell profile assertion failed: %s\n' "$expected" >&2
        exit 1
    fi
done

# shellcheck disable=SC2016 # The generated fake tmux must expand these at runtime.
printf '%s\n' '#!/bin/bash' \
    'if [[ "$3" == "has-session" ]]; then exit 1; fi' \
    'printf "%s\\n" "$#" > "$TMUX_COUNT"' \
    'printf "%s\\n" "$*" > "$TMUX_CAPTURE"' > "$TEST_DIR/tmux"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$TEST_DIR/agy"
chmod +x "$TEST_DIR/tmux" "$TEST_DIR/agy"

PATH="$TEST_DIR:$PATH" TMUX_CAPTURE="$TMUX_CAPTURE" TMUX_COUNT="$TMUX_COUNT" TERMUX_STACK_BANNER_SHOWN=1 \
    TERMUX_TMUX_SOCKET="$TEST_DIR/proot.socket" \
    bash --noprofile --norc -ic 'source "$1"; stack_tmux_agy --resume' _ "$PROFILE" >/dev/null 2>&1

expected_tmux="-S $TEST_DIR/proot.socket new-session -s agy agy --resume"
if [[ "$(<"$TMUX_CAPTURE")" != "$expected_tmux" ]]; then
    printf 'tmux socket or command mapping failed\n' >&2
    exit 1
fi
if [[ "$(<"$TMUX_COUNT")" != '6' ]]; then
    printf 'tmux command must be passed as one shell-safe argument\n' >&2
    exit 1
fi

printf 'shell profile: ok\n'
