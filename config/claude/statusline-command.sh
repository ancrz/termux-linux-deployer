#!/bin/sh
input=$(cat)

# --- 1. Model + context (color by usage level) ---
model=$(echo "$input" | jq -r '.model.display_name // "Unknown Model"')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

if [ -n "$used" ]; then
  used_int=${used%%.*}
  if [ "$used_int" -ge 80 ]; then
    model_part=$(printf '\033[0;36m%s\033[0m  \033[0;31mCtx: %s%%\033[0m' "$model" "$used")
  elif [ "$used_int" -ge 60 ]; then
    model_part=$(printf '\033[0;36m%s\033[0m  \033[0;33mCtx: %s%%\033[0m' "$model" "$used")
  else
    model_part=$(printf '\033[0;36m%s\033[0m  \033[0;32mCtx: %s%%\033[0m' "$model" "$used")
  fi
else
  model_part=$(printf '\033[0;36m%s\033[0m' "$model")
fi

# --- 2. Git repo + branch + stats ---
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
if [ -z "$cwd" ]; then
  cwd=$(pwd)
fi

git_part=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  git_repo=$(basename "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)")

  if [ -n "$git_branch" ] && [ -n "$git_repo" ]; then
    # Commits ahead/behind remote
    upstream=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref "@{u}" 2>/dev/null)
    push_pull=""
    if [ -n "$upstream" ]; then
      ahead=$(git -C "$cwd" --no-optional-locks rev-list --count "@{u}..HEAD" 2>/dev/null)
      behind=$(git -C "$cwd" --no-optional-locks rev-list --count "HEAD..@{u}" 2>/dev/null)
      parts=""
      if [ -n "$ahead" ] && [ "$ahead" -gt 0 ]; then
        parts=$(printf '\033[0;32m↑%s\033[0m' "$ahead")
      fi
      if [ -n "$behind" ] && [ "$behind" -gt 0 ]; then
        if [ -n "$parts" ]; then
          parts=$(printf '%s \033[0;31m↓%s\033[0m' "$parts" "$behind")
        else
          parts=$(printf '\033[0;31m↓%s\033[0m' "$behind")
        fi
      fi
      push_pull="$parts"
    fi

    # Dirty files count (staged + unstaged + untracked)
    dirty_count=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    dirty=""
    if [ "$dirty_count" -gt 0 ]; then
      dirty=$(printf ' \033[0;33m~%s\033[0m' "$dirty_count")
    fi

    # Assemble git part
    git_part=$(printf '\033[0;35m%s\033[0m \033[0;37m(\033[0;32m%s\033[0;37m)\033[0m' "$git_repo" "$git_branch")
    if [ -n "$push_pull" ]; then
      git_part="${git_part} ${push_pull}"
    fi
    git_part="${git_part}${dirty}"
  fi
fi

# --- Assemble ---
output="$model_part"
if [ -n "$git_part" ]; then
  output="$output  $git_part"
fi

printf '%s' "$output"
