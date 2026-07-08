#!/usr/bin/env bash
# mimo v__VERSION__ — Stop hook memory gate
# Blocks Claude from stopping when a memory save is needed, and only records a
# save as DONE after VERIFYING it happened (CLAUDE.md mtime advanced past the
# moment the save was requested). A crashed/skipped save is retried once, then
# dropped — never silently recorded as done.
# Exit 0 = allow stop, Exit 2 = block stop (stderr → Claude as instructions).
# shellcheck disable=SC2016  # '$var' inside jq filters is jq syntax, not shell
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

# Portable mtime (BSD stat -f %m / GNU stat -c %Y), 0 on failure.
file_mtime() {
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# Emit the body of an installed skill (everything after the YAML frontmatter),
# dropping a leading blank/`[MIMO …` banner line so the gate's own urgency header
# is the only banner. Falls back to a compact built-in (anchor convention) when
# the skill is missing so the gate never blocks with empty instructions.
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
            "1. Read CLAUDE.md. Then run: grep -n '^## S' CLAUDE-FULL.md | tail -3  (find the last session number) and tail -30 CLAUDE-FULL.md (see the latest entry). Do NOT read the whole archive." \
            "2. Update CLAUDE.md \"Memory — Current State\" (date, focus, blockers) and \"Memory — Recent Sessions\"" \
            "3. Append a new session under a \"## S<N> — YYYY-MM-DD — <slug>\" heading in CLAUDE-FULL.md (N = last + 1, S1 if none); reference it from CLAUDE.md as [CLAUDE-FULL.md §S<N>]" \
            "4. Reconcile: edit or supersede existing entries (mark a reversed line [superseded YYYY-MM-DD → §S<N>]) instead of appending duplicates." \
            "Then say \"$2\" and IMMEDIATELY resume the task you were on."
    fi
}

# ── a. LOOP BREAKER ──────────────────────────────────────────────────────────
# If stop_hook_active is true, Claude is already continuing from a previous stop
# hook block. Allow it to stop now.
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# ── b. No state file → nothing to do ─────────────────────────────────────────
if [ ! -f "$STATE_FILE" ]; then
    exit 0
fi

THRESHOLD=$(jq -r '.threshold // "clean"' "$STATE_FILE" 2>/dev/null || echo "clean")
PCT=$(jq -r '.percentage // 0' "$STATE_FILE" 2>/dev/null || echo "0")
SAVE_REQUESTED_AT=$(jq -r '.save_requested_at // 0' "$STATE_FILE" 2>/dev/null || echo "0")
SAVE_ATTEMPTS=$(jq -r '.save_attempts // 0' "$STATE_FILE" 2>/dev/null || echo "0")
PENDING_KIND=$(jq -r '.pending_save_kind // ""' "$STATE_FILE" 2>/dev/null || echo "")

# Sanitize the integer fields (a corrupt state file must not crash `[ -gt ]`).
case "$SAVE_REQUESTED_AT" in ''|*[!0-9]*) SAVE_REQUESTED_AT=0 ;; esac
case "$SAVE_ATTEMPTS"     in ''|*[!0-9]*) SAVE_ATTEMPTS=0 ;; esac

# ── c. Clean and nothing pending → allow stop ────────────────────────────────
if [ "$THRESHOLD" = "clean" ] && [ "$SAVE_REQUESTED_AT" -eq 0 ]; then
    exit 0
fi

# ── d. Resolve CWD and require a CLAUDE.md to save into ───────────────────────
CWD="${MIMO_CWD:-}"
if [ -z "$CWD" ]; then
    CWD=$(echo "$INPUT" | jq -r '.cwd // "."')
fi
if [ ! -f "$CWD/CLAUDE.md" ]; then
    # Nothing to save into (e.g. auto-init was skipped). Reset and allow stop.
    write_state '.threshold = "clean" | .save_requested_at = 0 | .save_attempts = 0 | .pending_save_kind = ""' "$STATE_FILE"
    exit 0
fi

# ── e. VERIFICATION PATH ─────────────────────────────────────────────────────
# A save is verified by CLAUDE.md's mtime advancing to/after the request time.
# The legacy phrase-grep on the last assistant message is a secondary signal
# (belt and suspenders) and also covers a save that happened before any request
# (e.g. a manual /save immediately before the threshold Stop).
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""')

SAVED=false
if [ "$SAVE_REQUESTED_AT" -gt 0 ]; then
    MTIME=$(file_mtime "$CWD/CLAUDE.md")
    case "$MTIME" in ''|*[!0-9]*) MTIME=0 ;; esac
    if [ "$MTIME" -ge "$SAVE_REQUESTED_AT" ]; then
        SAVED=true
    fi
fi
if echo "$LAST_MSG" | grep -qiE '(checkpoint saved|memory saved)'; then
    SAVED=true
fi

if [ "$SAVED" = "true" ]; then
    # Determine what to mark done: the recorded pending kind wins; fall back to
    # the current threshold when a save landed with no outstanding request.
    KIND="$PENDING_KIND"
    if [ -z "$KIND" ]; then
        case "$THRESHOLD" in
            fullsave_needed) KIND="fullsave" ;;
            *)               KIND="checkpoint" ;;
        esac
    fi
    if [ "$KIND" = "fullsave" ]; then
        write_state '.checkpoint_done = true | .fullsave_done = true | .threshold = "clean" | .save_requested_at = 0 | .save_attempts = 0 | .pending_save_kind = ""' "$STATE_FILE"
    else
        write_state '.checkpoint_done = true | .threshold = "clean" | .save_requested_at = 0 | .save_attempts = 0 | .pending_save_kind = ""' "$STATE_FILE"
    fi
    exit 0
fi

# ── f. GIVE-UP GUARD ─────────────────────────────────────────────────────────
# Two emissions with no verified save: stop nagging. Reset to clean AND mark the
# pending kind's done flag(s) so the give-up is durable: statusline-memory.sh
# recomputes .threshold from (percentage, done flags) on every render, so unless
# we set the done flag it would just re-arm *_needed (pct is still over the line)
# and the gate would nag again — 2 nags, a pause, 2 more, forever. Setting done
# means "done trying — do not re-arm this crossing."
if [ "$SAVE_ATTEMPTS" -ge 2 ]; then
    # Resolve the kind we gave up on: the recorded pending kind wins; fall back
    # to the current threshold (fullsave_needed → fullsave) otherwise.
    GIVEUP_KIND="$PENDING_KIND"
    if [ -z "$GIVEUP_KIND" ]; then
        case "$THRESHOLD" in
            fullsave_needed) GIVEUP_KIND="fullsave" ;;
            *)               GIVEUP_KIND="checkpoint" ;;
        esac
    fi
    if [ "$GIVEUP_KIND" = "fullsave" ]; then
        write_state '.checkpoint_done = true | .fullsave_done = true | .threshold = "clean" | .save_requested_at = 0 | .save_attempts = 0 | .pending_save_kind = ""' "$STATE_FILE"
    else
        write_state '.checkpoint_done = true | .threshold = "clean" | .save_requested_at = 0 | .save_attempts = 0 | .pending_save_kind = ""' "$STATE_FILE"
    fi
    exit 0
fi

# ── g. REQUEST PATH ──────────────────────────────────────────────────────────
# Only *_needed thresholds request a save. Record the request (timestamp + kind,
# increment attempts) WITHOUT setting done flags — those are set only on verified
# success in the path above — then emit instructions and block the stop.
if [ "$THRESHOLD" = "checkpoint_needed" ] || [ "$THRESHOLD" = "fullsave_needed" ]; then
    if [ "$THRESHOLD" = "fullsave_needed" ]; then
        KIND="fullsave"; SKILL="save-full"; PHRASE="memory saved"; HEADER="FULL SAVE REQUIRED"
    else
        KIND="checkpoint"; SKILL="save"; PHRASE="checkpoint saved"; HEADER="CHECKPOINT REQUIRED"
    fi

    NOW=$(date +%s)
    NEW_ATTEMPTS=$(( SAVE_ATTEMPTS + 1 ))
    write_state \
        --argjson ts "$NOW" \
        --argjson at "$NEW_ATTEMPTS" \
        --arg kind "$KIND" \
        '.save_requested_at = $ts | .save_attempts = $at | .pending_save_kind = $kind' \
        "$STATE_FILE"

    # Build the tracked-files list: the per-session changes log merged with the
    # working tree's git status (uncommitted paths), deduped. git absent / not a
    # repo → silently log-only.
    CHANGES_LOG="${MIMO_CHANGES_LOG:-}"
    if [ -z "$CHANGES_LOG" ]; then
        SID=$(basename "$STATE_FILE" .json)
        CHANGES_LOG="$STATE_DIR/${SID}-changes.log"
    fi
    TRACKED_FILES=$(
        {
            if [ -f "$CHANGES_LOG" ]; then cat "$CHANGES_LOG"; fi
            git -C "$CWD" status --porcelain=v1 2>/dev/null | sed 's/^...//' || true
        } | sed '/^[[:space:]]*$/d' | sort -u | head -50 || true
    )

    {
        echo "[MIMO — $HEADER — context at ${PCT}%]"
        echo "This is an automatic threshold interrupt."
        echo ""
        emit_skill_body "$SKILL" "$PHRASE"
        if [ -n "$TRACKED_FILES" ]; then
            echo ""
            echo "Files changed this session (tracked + git status):"
            echo "$TRACKED_FILES"
        fi
    } >&2
    exit 2
fi

# Pending but unverifiable and not yet at the give-up cap (e.g. compaction
# dropped the percentage below the line, so statusline recomputed threshold=clean
# while a request was outstanding). A request whose crossing evaporated is
# cancelled — clear save_requested_at/save_attempts/pending_save_kind (leaving
# threshold and done flags untouched) so a LATER genuine crossing issues a fresh
# request and cannot be spuriously "verified" by an unrelated CLAUDE.md edit that
# happened to occur after this now-dead request.
if [ "$SAVE_REQUESTED_AT" -gt 0 ]; then
    write_state '.save_requested_at = 0 | .save_attempts = 0 | .pending_save_kind = ""' "$STATE_FILE"
fi
exit 0
