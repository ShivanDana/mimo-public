#!/usr/bin/env bash
# mimo v__VERSION__ — StatusLine context detector + ANSI progress bar
# Reads context usage from stdin JSON, writes threshold state, outputs colored bar
set -euo pipefail

STATE_DIR="$HOME/.claude/memory-state"

# ─── Config (defaults, then user overrides via ~/.claude/mimo.conf) ──────────
CHECKPOINT_THRESHOLD=50
FULLSAVE_THRESHOLD=80
BAR_WIDTH=20
MIMO_CONF="${MIMO_CONF:-$HOME/.claude/mimo.conf}"
# shellcheck disable=SC1090
[ -f "$MIMO_CONF" ] && . "$MIMO_CONF"

mkdir -p "$STATE_DIR"

# Read full stdin JSON
INPUT=$(cat)

# Extract fields
PERCENTAGE=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0')
MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "?"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' | tr -cd 'a-zA-Z0-9-')
COST=$(echo "$INPUT" | jq -r '.cost.total_cost_usd // 0')

# Per-session state file
STATE_FILE="${MIMO_STATE_FILE:-}"
if [ -z "$STATE_FILE" ]; then
    [ -z "$SESSION_ID" ] && SESSION_ID="fallback-$$-$(date +%s)"
    STATE_FILE="$STATE_DIR/${SESSION_ID}.json"
fi

# Atomically rewrite the state file from jq output. Never clobbers valid state
# with empty/corrupt output: the temp file is validated non-empty before mv, and
# the ".tmp" suffix lets orphan cleanup (find -name "*.tmp") reap a crashed write.
write_state() {
    local tmp="${STATE_FILE}.$$.${RANDOM}.tmp"
    if jq "$@" > "$tmp" && [ -s "$tmp" ]; then
        mv "$tmp" "$STATE_FILE"
    else
        rm -f "$tmp"
    fi
}

# Sanitize percentage — default to 0 if not a valid number (jq may emit "null"
# when .context_window is missing entirely).
if ! printf '%s' "$PERCENTAGE" | grep -qE '^[0-9]+\.?[0-9]*$'; then
    PERCENTAGE=0
fi

# Round percentage to integer
PCT_INT=$(printf "%.0f" "$PERCENTAGE")
if [ "$PCT_INT" -gt 100 ]; then PCT_INT=100; fi
if [ "$PCT_INT" -lt 0 ]; then PCT_INT=0; fi

# Create state file if it doesn't exist yet
if [ ! -f "$STATE_FILE" ]; then
    write_state -n --arg sid "$SESSION_ID" \
        '{session_id: $sid, percentage: 0, threshold: "clean", checkpoint_done: false, fullsave_done: false}'
fi

# Read current done flags
CHECKPOINT_DONE=$(jq -r '.checkpoint_done // false' "$STATE_FILE" 2>/dev/null || echo "false")
FULLSAVE_DONE=$(jq -r '.fullsave_done // false' "$STATE_FILE" 2>/dev/null || echo "false")

# Determine threshold
THRESHOLD="clean"
if [ "$PCT_INT" -ge "$FULLSAVE_THRESHOLD" ] && [ "$FULLSAVE_DONE" = "false" ]; then
    THRESHOLD="fullsave_needed"
elif [ "$PCT_INT" -ge "$CHECKPOINT_THRESHOLD" ] && [ "$CHECKPOINT_DONE" = "false" ]; then
    THRESHOLD="checkpoint_needed"
fi

# Update state file (validated atomic write — old state survives a failed jq)
write_state -n \
    --arg sid "$SESSION_ID" \
    --argjson pct "$PCT_INT" \
    --arg threshold "$THRESHOLD" \
    --argjson cp_done "$([ "$CHECKPOINT_DONE" = "true" ] && echo true || echo false)" \
    --argjson fs_done "$([ "$FULLSAVE_DONE" = "true" ] && echo true || echo false)" \
    '{session_id: $sid, percentage: $pct, threshold: $threshold, checkpoint_done: $cp_done, fullsave_done: $fs_done}'

# Build progress bar
FILLED=$(( PCT_INT * BAR_WIDTH / 100 ))
if [ "$FILLED" -gt "$BAR_WIDTH" ]; then FILLED=$BAR_WIDTH; fi
EMPTY=$(( BAR_WIDTH - FILLED ))

BAR_FILLED=$(printf '%*s' "$FILLED" '' | tr ' ' '█')
BAR_EMPTY=$(printf '%*s' "$EMPTY" '' | tr ' ' '░')
BAR="${BAR_FILLED}${BAR_EMPTY}"

# Choose ANSI color code
if [ "$PCT_INT" -ge "$FULLSAVE_THRESHOLD" ]; then
    CC="31"  # Red
elif [ "$PCT_INT" -ge "$CHECKPOINT_THRESHOLD" ]; then
    CC="33"  # Yellow
else
    CC="32"  # Green
fi

# Threshold indicator
INDICATOR=""
if [ "$THRESHOLD" = "fullsave_needed" ]; then
    INDICATOR=" \033[31m!\033[0m"
elif [ "$THRESHOLD" = "checkpoint_needed" ]; then
    INDICATOR=" \033[33m*\033[0m"
fi

# Output ANSI statusline
printf '\033[%sm%s %d%%\033[0m%b │ %s │ $%.2f' "$CC" "$BAR" "$PCT_INT" "$INDICATOR" "$MODEL" "$COST"
