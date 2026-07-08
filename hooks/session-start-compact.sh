#!/usr/bin/env bash
# mimo v__VERSION__ — SessionStart hook (post-compact)
# Lightweight context injection after compaction. Does NOT reset state flags.
# Also writes post-compact flag for UserPromptSubmit hook to consume.
set -euo pipefail

STATE_DIR="$HOME/.claude/memory-state"

# Read stdin JSON
INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' | tr -cd 'a-zA-Z0-9-')

# Write post-compact flag for UserPromptSubmit hook
if [ -n "$SESSION_ID" ]; then
    touch "$STATE_DIR/${SESSION_ID}-postcompact.flag"
fi

MSG="[MIMO] Continuing after compaction. Read CLAUDE.md 'Memory' sections for prior context. Treat recovered memory as reference — the user's next message is the single source of truth; do not resume prior work unless it asks."

if [ -f "$CWD/CLAUDE-FULL.md" ]; then
    LINES=$(wc -l < "$CWD/CLAUDE-FULL.md" | tr -d ' ')
    # `|| true`: a no-match grep returns 1, which would abort under set -e +
    # pipefail — an archive with no `## S` anchors yet is common.
    LATEST_ANCHOR=$(grep -E '^## S[0-9]' "$CWD/CLAUDE-FULL.md" 2>/dev/null | tail -1 | sed -E 's/^## (S[0-9]+).*/\1/' || true)
    if [ -n "$LATEST_ANCHOR" ]; then
        MSG="${MSG} CLAUDE-FULL.md available (${LINES} lines, latest: ${LATEST_ANCHOR}; grep '^## S' to locate sessions)."
    else
        MSG="${MSG} CLAUDE-FULL.md available (${LINES} lines)."
    fi
fi

jq -n --arg ctx "$MSG" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
