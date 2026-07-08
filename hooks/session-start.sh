#!/usr/bin/env bash
# mimo v__VERSION__ — SessionStart hook (startup/resume)
# Resets state for new session, auto-inits project, injects memory context into Claude
# shellcheck disable=SC2016  # '$var' inside jq filters is jq syntax, not shell
# shellcheck disable=SC2012  # ls -t for newest backup is fine; names are timestamped
set -euo pipefail

STATE_DIR="$HOME/.claude/memory-state"
BACKUP_DIR="$HOME/.claude/backups"

mkdir -p "$STATE_DIR" "$BACKUP_DIR"

# ─── Config (defaults, then user overrides) ──────────────────────────────────
AUTO_INIT=git-only
WORKFLOW_BLOCK=off
STALE_MINUTES=120
CHECKPOINT_THRESHOLD=50
FULLSAVE_THRESHOLD=80
USER_PROFILE=on
MIMO_CONF="${MIMO_CONF:-$HOME/.claude/mimo.conf}"
# shellcheck disable=SC1090
[ -f "$MIMO_CONF" ] && . "$MIMO_CONF"
TEMPLATES_DIR="${MIMO_TEMPLATES_DIR:-$HOME/.claude/mimo-templates}"
# Cross-project user profile (P12). Env override for tests; never $HOME/CLAUDE.md.
MIMO_USER_PROFILE_FILE="${MIMO_USER_PROFILE_FILE:-$HOME/.claude/mimo-user.md}"

# Read stdin JSON
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' | tr -cd 'a-zA-Z0-9-')
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')

# Per-session state file (isolates concurrent sessions)
if [ -z "$SESSION_ID" ]; then SESSION_ID="fallback-$$-$(date +%s)"; fi
STATE_FILE="$STATE_DIR/${SESSION_ID}.json"

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

# Create state for new session (idempotent — preserves existing state on resume).
# Includes the gate-owned verification fields so a fresh file is complete.
if [ ! -f "$STATE_FILE" ]; then
    write_state -n --arg sid "$SESSION_ID" \
        '{session_id: $sid, percentage: 0, threshold: "clean", checkpoint_done: false, fullsave_done: false, save_requested_at: 0, save_attempts: 0, pending_save_kind: "", changes_at_save: 0}'
fi

# Export env vars for other hooks via CLAUDE_ENV_FILE
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    {
        echo "export MIMO_SESSION_ID=\"$SESSION_ID\""
        echo "export MIMO_STATE_FILE=\"$STATE_FILE\""
        echo "export MIMO_CHANGES_LOG=\"$STATE_DIR/${SESSION_ID}-changes.log\""
        echo "export MIMO_CWD=\"$CWD\""
    } >> "$CLAUDE_ENV_FILE"
fi

# Clean up orphan files from dead sessions using the StatusLine heartbeat.
# The .json state file is the heartbeat: an active session rewrites it every few
# seconds, so a stale mtime (no heartbeat in 2h) means the session crashed or was
# force-quit — safe to delete by its own mtime. Companion files (-changes.log,
# -postcompact.flag) are NOT keyed on their own mtime: a live, long-idle session
# whose last edit was hours ago has an old changes.log but a fresh json, and its
# tracked-files list must survive. So companions are deleted pairwise — only when
# their session's json is already gone. Also reap orphaned jq temp files (crashed
# mid-write) that the *.json glob never matched.
find "$STATE_DIR" -name "*.json" -mmin +"$STALE_MINUTES" -delete 2>/dev/null || true
for f in "$STATE_DIR"/*-changes.log "$STATE_DIR"/*-postcompact.flag; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
        *-changes.log)      sid=${base%-changes.log} ;;
        *-postcompact.flag) sid=${base%-postcompact.flag} ;;
        *)                  continue ;;
    esac
    [ -f "$STATE_DIR/${sid}.json" ] || rm -f "$f"
done
find "$STATE_DIR" -name "*.tmp" -mmin +60 -delete 2>/dev/null || true

# ─── Auto-update check (at most once per 24h, never blocks) ──────────────────
UPDATE_CHECK_FILE="$STATE_DIR/mimo-update-check"
INSTALLED_VERSION_FILE="$STATE_DIR/mimo-installed-version"
INSTALLED_VERSION=$(cat "$INSTALLED_VERSION_FILE" 2>/dev/null || echo "")
UPDATE_MSG=""

if [ -n "$INSTALLED_VERSION" ]; then
    SHOULD_CHECK=false
    if [ ! -f "$UPDATE_CHECK_FILE" ]; then
        SHOULD_CHECK=true
    else
        # Check if file is older than 24h (86400 seconds)
        LAST_CHECK=$(stat -f %m "$UPDATE_CHECK_FILE" 2>/dev/null || stat -c %Y "$UPDATE_CHECK_FILE" 2>/dev/null || echo "0")
        NOW=$(date +%s)
        if [ $(( NOW - LAST_CHECK )) -gt 86400 ]; then
            SHOULD_CHECK=true
        fi
    fi

    if [ "$SHOULD_CHECK" = "true" ]; then
        # Background fetch — never blocks session start
        (
            REMOTE=$(curl -fsSL --max-time 3 \
                "https://raw.githubusercontent.com/ShivanDana/mimo/main/VERSION" 2>/dev/null | tr -d '[:space:]')
            [ -n "$REMOTE" ] && echo "$REMOTE" > "$UPDATE_CHECK_FILE"
        ) &
    fi

    # Read cached remote version from PREVIOUS successful check
    REMOTE_VERSION=$(cat "$UPDATE_CHECK_FILE" 2>/dev/null || echo "")
    if [ -n "$REMOTE_VERSION" ] && [ "$REMOTE_VERSION" != "$INSTALLED_VERSION" ]; then
        UPDATE_MSG="Update available: mimo v${INSTALLED_VERSION} → v${REMOTE_VERSION}. Run: mimo update"
    fi
fi

# ─── Auto-init: create CLAUDE.md and CLAUDE-FULL.md if missing ───────────────
# Emit the memory sections — from the installed template, with a built-in
# fallback (hooks must never hard-fail if templates are missing).
emit_memory_sections() {
    if [ -f "$TEMPLATES_DIR/claude-md-memory-sections.md" ]; then
        cat "$TEMPLATES_DIR/claude-md-memory-sections.md"
    else
        cat << 'MEMORY_SECTIONS'
## Memory — Current State
<!-- Updated by mimo checkpoint/save hooks. On load act only on "Next actionable"; Carried-over is stale reference unless the user re-asks. -->
Last session: (not yet set)
Focus: (not yet set)
Next actionable (verbatim): None
Blockers: None
Carried-over (STALE — do not auto-resume): None

## Memory — Project Card
<!-- Durable only — if it plausibly changes this quarter, it doesn't belong. Max ~30 lines. -->
<!-- Every line: - PREFIX: fact.  Allowed: STACK, CONVENTION, ENTRYPOINT, TOOL-RULE, FAILURE-LESSON, RELATIONSHIP, INSTRUCTION -->

## Memory — Recent Sessions
<!-- Rolling list, max 7 entries. Oldest dropped. -->
<!-- Each entry references a CLAUDE-FULL.md anchor like [CLAUDE-FULL.md §S12] -->

## Memory — Key Decisions
<!-- Durable decisions only; one dated line + anchor [CLAUDE-FULL.md §S12]. Reconcile before adding: -->
<!-- edit in place, or mark a reversed line [superseded YYYY-MM-DD → §S12]. Max 10, merit-consolidated (not oldest-dropped). -->
MEMORY_SECTIONS
    fi
}

# Decide whether to auto-init. The $HOME guard is absolute (a CLAUDE.md there
# loads into every session = cross-project contamination), then AUTO_INIT gates.
AUTO_INIT_MSG=""
DO_AUTOINIT=false
SKIP_REASON=""
if [ "$CWD" = "$HOME" ]; then
    SKIP_REASON="\$HOME directory"
elif [ "$AUTO_INIT" = "never" ]; then
    SKIP_REASON="AUTO_INIT=never"
elif [ "$AUTO_INIT" = "always" ]; then
    DO_AUTOINIT=true
else
    # git-only (default): auto-init only inside a git working tree (covers
    # worktrees + subdirs). Any unrecognized value falls back to this safe mode.
    if git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        DO_AUTOINIT=true
    else
        SKIP_REASON="not a git repo"
    fi
fi

if [ "$DO_AUTOINIT" = "true" ]; then
    MEMORY_MARKER="Memory — Current State"

    if [ ! -f "$CWD/CLAUDE.md" ]; then
        # Fresh file: title + description, optional workflow block, memory sections.
        {
            echo "# CLAUDE.md"
            echo ""
            echo "This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository."
            echo ""
            if [ "$WORKFLOW_BLOCK" = "on" ]; then
                if [ -f "$TEMPLATES_DIR/claude-md-workflow.md" ]; then
                    cat "$TEMPLATES_DIR/claude-md-workflow.md"
                    echo ""
                fi
            fi
            emit_memory_sections
        } > "$CWD/CLAUDE.md"
        AUTO_INIT_MSG="Auto-initialized CLAUDE.md for this project."

    elif ! grep -q "$MEMORY_MARKER" "$CWD/CLAUDE.md" 2>/dev/null; then
        # Existing CLAUDE.md without memory sections. Never prepend: appending
        # keeps the file's opening bytes intact (no duplicate # CLAUDE.md title,
        # no disruption of the user's own top content). When WORKFLOW_BLOCK=on
        # and the block is missing, append it at the END too.
        if [ "$WORKFLOW_BLOCK" = "on" ] \
           && ! grep -q "## Workflow Orchestration" "$CWD/CLAUDE.md" 2>/dev/null \
           && [ -f "$TEMPLATES_DIR/claude-md-workflow.md" ]; then
            {
                echo ""
                cat "$TEMPLATES_DIR/claude-md-workflow.md"
            } >> "$CWD/CLAUDE.md"
        fi
        {
            echo ""
            emit_memory_sections
        } >> "$CWD/CLAUDE.md"
        AUTO_INIT_MSG="Auto-initialized memory sections in existing CLAUDE.md."
    fi

    # CLAUDE-FULL.md
    if [ ! -f "$CWD/CLAUDE-FULL.md" ]; then
        if [ -f "$TEMPLATES_DIR/CLAUDE-FULL.md" ]; then
            cat "$TEMPLATES_DIR/CLAUDE-FULL.md" > "$CWD/CLAUDE-FULL.md"
        else
            cat > "$CWD/CLAUDE-FULL.md" << 'ARCHIVE'
# Deep Memory Archive

<!-- Detailed session logs for long-term context preservation. -->
<!-- Each session is a heading: ## S<N> — YYYY-MM-DD — <short-slug>  (e.g. ## S12 — 2026-03-08 — anchor refs). -->
<!-- CLAUDE.md references entries by anchor, e.g. [CLAUDE-FULL.md §S12]. Locate one with: grep -n '^## S' CLAUDE-FULL.md -->
ARCHIVE
        fi
        if [ -z "$AUTO_INIT_MSG" ]; then
            AUTO_INIT_MSG="Auto-initialized CLAUDE-FULL.md for this project."
        else
            AUTO_INIT_MSG="${AUTO_INIT_MSG} Created CLAUDE-FULL.md."
        fi
    fi
elif [ ! -f "$CWD/CLAUDE.md" ]; then
    # Auto-init skipped and no memory here yet — point the user at manual init.
    AUTO_INIT_MSG="mimo: auto-init skipped (${SKIP_REASON}). Run \`mimo init\` to set up memory here."
fi

# ─── Build context message ───────────────────────────────────────────────────
MSG="[MIMO ACTIVE] Memory hooks enabled. Checkpoints at ${CHECKPOINT_THRESHOLD}% context, full save at ${FULLSAVE_THRESHOLD}%."

if [ -n "$AUTO_INIT_MSG" ]; then
    MSG="${MSG}\n${AUTO_INIT_MSG}"
fi

# Memory conflict read rule (P5): the always-loaded index may hold superseded
# lines; tell Claude how to resolve a disagreement without re-reading the archive.
MSG="${MSG}\nMemory conflict rule: when two entries disagree, the later date wins; a line marked [superseded] is history, not current guidance. If dates cannot resolve a conflict, surface both."

# Current State read rule (P9): the schema separates the live task from parked
# threads — act on one, treat the other as reference until the user re-asks.
MSG="${MSG}\nCurrent State read rule: on load act only on \"Next actionable\"; Carried-over items are stale reference unless the user re-asks."

# Check for deep memory archive. Reference sessions by anchor (## S<N>), not
# line ranges — surface the latest session number so recall is a single grep.
if [ -f "$CWD/CLAUDE-FULL.md" ]; then
    LINES=$(wc -l < "$CWD/CLAUDE-FULL.md" | tr -d ' ')
    # `|| true`: a no-match grep returns 1, which would abort under set -e +
    # pipefail — every freshly auto-initialized archive has no `## S` anchors yet.
    LATEST_ANCHOR=$(grep -E '^## S[0-9]' "$CWD/CLAUDE-FULL.md" 2>/dev/null | tail -1 | sed -E 's/^## (S[0-9]+).*/\1/' || true)
    if [ -n "$LATEST_ANCHOR" ]; then
        MSG="${MSG}\nDeep memory archive: CLAUDE-FULL.md (${LINES} lines, latest: ${LATEST_ANCHOR}). Locate sessions with grep '^## S'."
    else
        MSG="${MSG}\nDeep memory archive: CLAUDE-FULL.md (${LINES} lines). Locate sessions with grep '^## S'."
    fi
fi

# Cross-project user profile (P12): inject the whole file (it is capped ≤20
# lines) under a clear header so Claude reads it as declarative facts about the
# user. Absent file → no injection, zero cost. USER_PROFILE=off disables it (the
# file is never deleted by mimo). `head -c 2000 || true` bounds + SIGPIPE-guards.
if [ "$USER_PROFILE" = "on" ] && [ -f "$MIMO_USER_PROFILE_FILE" ]; then
    PROFILE_CONTENT=$(head -c 2000 "$MIMO_USER_PROFILE_FILE" 2>/dev/null || true)
    if [ -n "$PROFILE_CONTENT" ]; then
        MSG="${MSG}\nUser profile (applies across projects):\n${PROFILE_CONTENT}"
    fi
fi

# Include update notification if available
if [ -n "$UPDATE_MSG" ]; then
    MSG="${MSG}\n${UPDATE_MSG}"
fi

# Check for recent backups
BACKUP_COUNT=$(find "$BACKUP_DIR" -name "*.jsonl" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
if [ "$BACKUP_COUNT" -gt "0" ]; then
    LATEST_BACKUP=$(ls -1t "$BACKUP_DIR"/*.jsonl 2>/dev/null | head -1 || true)
    BACKUP_DATE=$(date -r "$LATEST_BACKUP" +%Y-%m-%d 2>/dev/null || echo "unknown")
    MSG="${MSG}\nTranscript backups: ${BACKUP_COUNT} saved (latest: ${BACKUP_DATE})"
fi

# Output as structured JSON — additionalContext is injected into Claude's context
jq -n --arg ctx "$(echo -e "$MSG")" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
