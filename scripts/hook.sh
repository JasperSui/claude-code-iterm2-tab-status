#!/usr/bin/env bash
# claude-code-iterm2-tab-status unified hook
# Handles both Notification and UserPromptSubmit events.
#   Notification(idle_prompt)       → writes signal with type "idle"
#   Notification(permission_prompt) → writes signal with type "attention"
#   UserPromptSubmit                → writes signal with type "running"
set -euo pipefail

default_status_dir() {
  # Per-user directory so other local users cannot read signal files (which
  # carry cwd, pid, tty, and an optional sanitized prompt snippet).
  if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    printf '%s' "${XDG_RUNTIME_DIR}/claude-tab-status"
  else
    printf '%s' "${HOME}/.cache/claude-tab-status"
  fi
}

STATUS_DIR="${CLAUDE_ITERM2_TAB_STATUS_DIR:-$(default_status_dir)}"
mkdir -p "$STATUS_DIR"
# Enforce 0700 on the leaf even if it pre-existed with looser perms (e.g. created
# by a 0.1.x install in /tmp). Parent dirs keep whatever the user already had.
chmod 700 "$STATUS_DIR" 2>/dev/null || true

# Read all of stdin
INPUT="$(cat)"

# Pure-bash JSON field extraction (no jq dependency).
# Handles flat JSON with string values. Not a full parser.
extract() {
  local key="$1"
  echo "$INPUT" | sed -n "s/.*\"${key}\": *\"\\([^\"]*\\)\".*/\\1/p" | head -1
}

subtitle_activity_source() {
  local source="${CLAUDE_ITERM2_TAB_STATUS_SUBTITLE_ACTIVITY_SOURCE:-}"
  if [[ -z "$source" && -f "$HOME/.config/claude-tab-status/config.json" ]]; then
    source="$(
      sed -n 's/.*"subtitle_activity_source": *"\([^"]*\)".*/\1/p' \
        "$HOME/.config/claude-tab-status/config.json" | head -1
    )"
  fi
  printf '%s' "$source" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

activity_word() {
  local word="$1" index="$2" normalized first rest
  normalized="$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')"
  case "$normalized" in
    debugging) normalized="debug" ;;
    editing) normalized="edit" ;;
    fixing) normalized="fix" ;;
    implementing) normalized="implement" ;;
    planning) normalized="plan" ;;
    reviewing) normalized="review" ;;
    running) normalized="run" ;;
    testing) normalized="test" ;;
    updating) normalized="update" ;;
    writing) normalized="write" ;;
  esac
  case "$normalized" in
    api|pr|url)
      printf '%s' "$normalized" | tr '[:lower:]' '[:upper:]'
      return
      ;;
  esac
  if [[ "$index" == "0" ]]; then
    first="$(printf '%s' "$normalized" | cut -c1 | tr '[:lower:]' '[:upper:]')"
    rest="$(printf '%s' "$normalized" | cut -c2-)"
    printf '%s%s' "$first" "$rest"
    return
  fi
  printf '%s' "$normalized"
}

activity_snippet() {
  local text="$1" cleaned word normalized candidate next
  local -a words
  if printf '%s' "$text" | grep -Eiq \
    '\b(password|passwd|passphrase|secret|token|api[-_ ]?key|private[-_ ]?key|credential|bearer|cookie)\b[[:space:]]*[:=]?'; then
    return
  fi

  cleaned="$(
    printf '%s' "$text" |
      tr '\r\n\t' '   ' |
      sed -E \
        -e 's#https?://[^[:space:]]+|www\.[^[:space:]]+# link #g' \
        -e 's#[^[:space:]]+@[^[:space:]]+\.[^[:space:]]+# email #g' \
        -e 's#(^|[[:space:]])(~|/)[^[:space:]]+# file #g' \
        -e 's/[Pp]ull[[:space:]]+[Rr]equest/ PR /g' \
        -e 's/[^[:alnum:]#]+/ /g'
  )"
  read -r -a words <<< "$cleaned"
  local snippet="" count=0
  for word in "${words[@]}"; do
    normalized="$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')"
    case "$normalized" in
      a|an|and|about|can|for|in|me|my|of|on|our|please|the|this|to|with|you)
        continue
        ;;
    esac
    candidate="$(activity_word "$word" "$count")"
    next="$candidate"
    if [[ -n "$snippet" ]]; then
      next="$snippet $candidate"
    fi
    if (( count >= 2 || ${#next} > 18 )); then
      break
    fi
    snippet="$next"
    count=$((count + 1))
  done
  printf '%s' "$snippet"
}

# Extract fields
SESSION_ID="$(extract "session_id")"
if [[ -z "$SESSION_ID" ]]; then
  echo "hook.sh: no session_id found, skipping" >&2
  exit 0
fi

HOOK_EVENT="$(extract "hook_event_name")"

# Determine signal type based on event
if [[ "$HOOK_EVENT" == "UserPromptSubmit" ]]; then
  SIGNAL_TYPE="running"
  MESSAGE=""
  if [[ "$(subtitle_activity_source)" == "prompt" ]]; then
    ACTIVITY="$(activity_snippet "$(extract "prompt")")"
  else
    ACTIVITY=""
  fi
else
  # Notification event — map notification_type to signal type
  NOTIF_TYPE="$(extract "notification_type")"
  case "$NOTIF_TYPE" in
    permission_prompt) SIGNAL_TYPE="attention" ;;
    *)                 SIGNAL_TYPE="idle" ;;
  esac
  MESSAGE="$(extract "message")"
  ACTIVITY=""
fi

CWD="$(extract "cwd")"
PROJECT="$(basename "${CWD:-unknown}")"

# Find TTY and a stable PID by walking up the process tree.
# The stable PID is the process that owns the TTY (typically the login shell
# spawned by iTerm2), which stays alive for the tab's lifetime.
# Using $$ (the hook process PID) would cause the adapter's stale-signal
# cleanup to remove signals after 10s because the hook exits immediately.
# Called directly (not in a subshell) so TTY and PID are set in this shell.
TTY=""
PID="$$"
_find_tty_info() {
  local pid="$$"
  local depth=0
  while (( pid > 1 && depth < 15 )); do
    local tty_val
    tty_val="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')" || true
    if [[ -n "$tty_val" && "$tty_val" != "??" && "$tty_val" != "-" ]]; then
      TTY="/dev/$tty_val"
      PID="$pid"
      # Keep walking — we want the highest ancestor with the TTY (login shell)
    fi
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" || break
    depth=$((depth + 1))
  done
}
_find_tty_info
TS="$(date +%s)"

# Escape double quotes in values to produce valid JSON
escape_json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

S_SID="$(escape_json "$SESSION_ID")"
S_TYPE="$(escape_json "$SIGNAL_TYPE")"
S_MSG="$(escape_json "$MESSAGE")"
S_PROJ="$(escape_json "$PROJECT")"
S_CWD="$(escape_json "$CWD")"
S_TTY="$(escape_json "$TTY")"
S_ACTIVITY="$(escape_json "$ACTIVITY")"

ACTIVITY_FIELD=""
if [[ -n "$S_ACTIVITY" ]]; then
  printf -v ACTIVITY_FIELD ',\n  "activity": "%s"' "$S_ACTIVITY"
fi

# Write signal file
cat > "${STATUS_DIR}/${SESSION_ID}.json" <<SIGNAL
{
  "session_id": "${S_SID}",
  "type": "${S_TYPE}",
  "message": "${S_MSG}",
  "project": "${S_PROJ}",
  "cwd": "${S_CWD}",
  "tty": "${S_TTY}",
  "pid": "${PID}",
  "ts": "${TS}"${ACTIVITY_FIELD}
}
SIGNAL
