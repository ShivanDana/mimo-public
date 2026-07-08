#!/usr/bin/env bash
# mimo v__VERSION__ — SubagentStart hook: inject memory context into subagents
# Provides subagents with session state and current focus from CLAUDE.md
set -euo pipefail

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

# If no useful info, exit silently
if [ -z "$MEMORY_STATE" ] && [ -z "$PROJECT_CARD" ] && [ -z "$CTX_PCT" ]; then
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

jq -n --arg ctx "$(echo -e "$MSG")" \
    '{hookSpecificOutput: {hookEventName: "SubagentStart", additionalContext: $ctx}}'
