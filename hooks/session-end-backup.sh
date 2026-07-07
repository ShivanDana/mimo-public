#!/usr/bin/env bash
# mimo v__VERSION__ — SessionEnd transcript backup
# Final safety net. Copies transcript on session exit. Runs async.
set -euo pipefail

BACKUP_DIR="$HOME/.claude/backups"
STATE_DIR="$HOME/.claude/memory-state"
BACKUP_RETENTION_DAYS=30
mkdir -p "$BACKUP_DIR"

# Read stdin JSON
INPUT=$(cat)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' | tr -cd 'a-zA-Z0-9-')

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Short session prefix keeps backup filenames identifiable
SID_SHORT="${SESSION_ID:0:8}"
[ -z "$SID_SHORT" ] && SID_SHORT="unknown"

# Copy transcript
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    cp "$TRANSCRIPT" "$BACKUP_DIR/${TIMESTAMP}-${SID_SHORT}-end.jsonl"
fi

# Prune backups older than the retention window
find "$BACKUP_DIR" -name "*.jsonl" -mtime +${BACKUP_RETENTION_DAYS} -delete 2>/dev/null || true
find "$BACKUP_DIR" -name "*-precompact-summary.md" -mtime +${BACKUP_RETENTION_DAYS} -delete 2>/dev/null || true

# Clean up this session's state file, changes log, and flag file
if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "none" ]; then
    rm -f "$STATE_DIR/${SESSION_ID}.json"
    rm -f "$STATE_DIR/${SESSION_ID}-changes.log"
    rm -f "$STATE_DIR/${SESSION_ID}-postcompact.flag"
fi
