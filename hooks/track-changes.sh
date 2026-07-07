#!/usr/bin/env bash
# mimo v__VERSION__ — PostToolUse hook: track file changes
# After every successful Write or Edit, append file path to per-session changes log
# Runs async — never blocks Claude
set -euo pipefail

# Read stdin JSON
INPUT=$(cat)

# Get changes log path from env or derive from session_id
CHANGES_LOG="${MIMO_CHANGES_LOG:-}"
if [ -z "$CHANGES_LOG" ]; then
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' | tr -cd 'a-zA-Z0-9-')
    [ -z "$SESSION_ID" ] && exit 0
    CHANGES_LOG="$HOME/.claude/memory-state/${SESSION_ID}-changes.log"
fi

# Extract path from tool_input (Write/Edit use file_path, NotebookEdit uses notebook_path)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // ""')
[ -z "$FILE_PATH" ] && exit 0

# Ensure the state dir exists — PostToolUse can fire before SessionStart on a fast first edit
mkdir -p "$(dirname "$CHANGES_LOG")"

# Append to changes log (one path per line, deduped at read time)
echo "$FILE_PATH" >> "$CHANGES_LOG"
