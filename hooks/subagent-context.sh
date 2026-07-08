#!/usr/bin/env bash
# mimo v__VERSION__ — SubagentStart hook: inject memory context into subagents
# Provides subagents with session state and current focus from CLAUDE.md
set -euo pipefail

# ─── Config (defaults, then user overrides) ──────────────────────────────────
USER_PROFILE=on
MIMO_CONF="${MIMO_CONF:-$HOME/.claude/mimo.conf}"
# shellcheck disable=SC1090
[ -f "$MIMO_CONF" ] && . "$MIMO_CONF"

# Read stdin JSON
INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')

# Get state file path from env or extract from input
STATE_FILE="${MIMO_STATE_FILE:-}"
if [ -z "$STATE_FILE" ]; then
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' | tr -cd 'a-zA-Z0-9-')
    [ -z "$SESSION_ID" ] && exit 0
    STATE_FILE="$HOME/.claude/memory-state/${SESSION_ID}.json"
fi

# Extract "Memory — Current State" and "Memory — Project Card" from CLAUDE.md.
# `|| true` on each pipeline: `head` closing early can SIGPIPE the sed producer,
# which would abort the hook under `set -euo pipefail`.
MEMORY_STATE=""
PROJECT_CARD=""
if [ -f "$CWD/CLAUDE.md" ]; then
    MEMORY_STATE=$(sed -n '/^## Memory — Current State/,/^## /{/^## Memory — Current State/d;/^## /d;p;}' "$CWD/CLAUDE.md" | head -10 || true)
    PROJECT_CARD=$(sed -n '/^## Memory — Project Card/,/^## /{/^## Memory — Project Card/d;/^## /d;p;}' "$CWD/CLAUDE.md" | head -30 || true)
fi

# Read context % from state file
CTX_PCT=""
if [ -f "$STATE_FILE" ]; then
    CTX_PCT=$(jq -r '.percentage // ""' "$STATE_FILE" 2>/dev/null || echo "")
fi

# User-profile INSTRUCTION lines (P12): standing rules like "never auto-push" are
# exactly what subagents violate today — inject those; prose preferences about
# output style are noise for a subagent, so PREFERENCE/WORKFLOW/CONTEXT are left
# out here. Gated by USER_PROFILE (default on): USER_PROFILE=off in mimo.conf
# silences injection here too, matching session-start — off means off everywhere.
# `|| true` guards a SIGPIPE from head closing the grep early.
PROFILE_FILE="${MIMO_USER_PROFILE_FILE:-$HOME/.claude/mimo-user.md}"
PROFILE_INSTRUCTIONS=""
if [ "$USER_PROFILE" = "on" ] && [ -f "$PROFILE_FILE" ]; then
    PROFILE_INSTRUCTIONS=$(grep '^- INSTRUCTION:' "$PROFILE_FILE" 2>/dev/null | head -5 || true)
fi

# If no useful info, exit silently
if [ -z "$MEMORY_STATE" ] && [ -z "$PROJECT_CARD" ] && [ -z "$CTX_PCT" ] && [ -z "$PROFILE_INSTRUCTIONS" ]; then
    exit 0
fi

# Build context message
MSG="[MIMO — Subagent Context]"
if [ -n "$CTX_PCT" ]; then
    MSG="${MSG}\nParent session context usage: ${CTX_PCT}%"
fi
if [ -n "$MEMORY_STATE" ]; then
    MSG="${MSG}\nMemory — Current State:\n${MEMORY_STATE}"
fi
if [ -n "$PROJECT_CARD" ]; then
    MSG="${MSG}\nMemory — Project Card:\n${PROJECT_CARD}"
fi
if [ -n "$PROFILE_INSTRUCTIONS" ]; then
    MSG="${MSG}\nUser instructions (standing rules):\n${PROFILE_INSTRUCTIONS}"
fi

jq -n --arg ctx "$(echo -e "$MSG")" \
    '{hookSpecificOutput: {hookEventName: "SubagentStart", additionalContext: $ctx}}'
