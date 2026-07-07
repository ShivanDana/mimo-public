#!/usr/bin/env bash
# mimo v__VERSION__ — Stop hook memory gate
# Blocks Claude from stopping when a memory save is needed
# Exit 0 = allow stop, Exit 2 = block stop (stderr → Claude as instructions)
set -euo pipefail

STATE_DIR="$HOME/.claude/memory-state"
SKILLS_DIR="${MIMO_SKILLS_DIR:-$HOME/.claude/skills}"

# Read stdin JSON
INPUT=$(cat)

# Extract session_id for per-session state isolation
STATE_FILE="${MIMO_STATE_FILE:-}"
if [ -z "$STATE_FILE" ]; then
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' | tr -cd 'a-zA-Z0-9-')
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

# LOOP BREAKER: If stop_hook_active is true, Claude is already continuing
# from a previous stop hook block. Allow it to stop now.
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# If no state file, nothing to do
if [ ! -f "$STATE_FILE" ]; then
    exit 0
fi

THRESHOLD=$(jq -r '.threshold // "clean"' "$STATE_FILE" 2>/dev/null || echo "clean")
PCT=$(jq -r '.percentage // 0' "$STATE_FILE" 2>/dev/null || echo "0")

# If no save needed, allow stop
if [ "$THRESHOLD" = "clean" ]; then
    exit 0
fi

# Emit the body of an installed skill (everything after the YAML frontmatter),
# dropping a leading blank/`[MIMO …` banner line so the gate's own urgency header
# is the only banner. Falls back to a compact built-in when the skill is missing
# so the gate never blocks with empty instructions.
emit_skill_body() {
    # $1 = skill name (save | save-full); $2 = "checkpoint saved" | "memory saved"
    local skill_file="$SKILLS_DIR/$1/SKILL.md"
    if [ -f "$skill_file" ] && [ -s "$skill_file" ]; then
        awk '
            NR==1 && /^---[[:space:]]*$/ { infm=1; next }
            infm && /^---[[:space:]]*$/ { infm=0; started=1; next }
            infm { next }
            started {
                if (!content) {
                    if ($0 ~ /^[[:space:]]*$/) next     # skip leading blanks
                    if ($0 ~ /^\[MIMO/)        next     # skip the manual banner
                    content=1
                }
                print
            }
        ' "$skill_file"
    else
        printf '%s\n' \
            "Save your work now to preserve context:" \
            "1. Read CLAUDE.md and CLAUDE-FULL.md in the project root" \
            "2. Update CLAUDE.md \"Memory — Current State\" (date, focus, blockers) and \"Memory — Recent Sessions\"" \
            "3. Append a session log to CLAUDE-FULL.md and update the [L##-L##] line refs" \
            "Then say \"$2\" and IMMEDIATELY resume the task you were on."
    fi
}

# IDEMPOTENCY: Check if Claude already performed a save in this response
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""')
if echo "$LAST_MSG" | grep -qiE '(checkpoint saved|memory saved)'; then
    # Claude already saved — mark done and allow stop
    if [ "$THRESHOLD" = "fullsave_needed" ]; then
        write_state '.fullsave_done = true | .checkpoint_done = true | .threshold = "clean"' "$STATE_FILE"
    elif [ "$THRESHOLD" = "checkpoint_needed" ]; then
        write_state '.checkpoint_done = true | .threshold = "clean"' "$STATE_FILE"
    fi
    exit 0
fi

# Build tracked files list for save instructions
CHANGES_LOG="${MIMO_CHANGES_LOG:-}"
if [ -z "$CHANGES_LOG" ]; then
    SID=$(basename "$STATE_FILE" .json)
    CHANGES_LOG="$STATE_DIR/${SID}-changes.log"
fi
TRACKED_FILES=""
if [ -f "$CHANGES_LOG" ]; then
    TRACKED_FILES=$(sort -u "$CHANGES_LOG" 2>/dev/null | head -50)
fi

# FULL SAVE (80%+)
if [ "$THRESHOLD" = "fullsave_needed" ]; then
    # Mark as done before blocking (prevents re-trigger after Claude saves)
    write_state '.fullsave_done = true | .checkpoint_done = true | .threshold = "clean"' "$STATE_FILE"

    {
        echo "[MIMO — FULL SAVE REQUIRED — context at ${PCT}%]"
        echo "This is an automatic threshold interrupt."
        echo ""
        emit_skill_body "save-full" "memory saved"
        if [ -n "$TRACKED_FILES" ]; then
            echo ""
            echo "Files modified this session (tracked by mimo):"
            echo "$TRACKED_FILES"
        fi
    } >&2
    exit 2
fi

# CHECKPOINT (50%+)
if [ "$THRESHOLD" = "checkpoint_needed" ]; then
    # Mark as done before blocking
    write_state '.checkpoint_done = true | .threshold = "clean"' "$STATE_FILE"

    {
        echo "[MIMO — CHECKPOINT REQUIRED — context at ${PCT}%]"
        echo "This is an automatic threshold interrupt."
        echo ""
        emit_skill_body "save" "checkpoint saved"
        if [ -n "$TRACKED_FILES" ]; then
            echo ""
            echo "Files modified this session (tracked by mimo):"
            echo "$TRACKED_FILES"
        fi
    } >&2
    exit 2
fi

exit 0
