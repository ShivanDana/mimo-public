#!/usr/bin/env bats
# session-start.sh — state creation, auto-init matrix, stale cleanup, updates.

load helpers

setup() {
    mimo_setup
    SS="$HOOKS_SRC/session-start.sh"
    export MIMO_TEMPLATES_DIR="$MIMO_REPO_ROOT/templates"
}
teardown() { mimo_teardown; }

# Run session-start; capture additionalContext into $ctx.
run_ss() {
    run bash "$SS" <<<"$(hook_json "${1:-sess-1}" "${2:-$PROJECT_DIR}")"
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null || echo "")"
}

@test "session-start: creates a complete state file for a new session" {
    run_ss sess-new "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    [ -f "$STATE_DIR/sess-new.json" ]
    for k in session_id percentage threshold checkpoint_done fullsave_done save_requested_at save_attempts pending_save_kind; do
        run jq -e "has(\"$k\")" "$STATE_DIR/sess-new.json"
        [ "$status" -eq 0 ]
    done
}

@test "session-start: resume is idempotent and preserves existing flags" {
    seed_state "$STATE_DIR/sess-1.json" checkpoint_done=true percentage=42
    run_ss sess-1 "$PROJECT_DIR"
    [ "$(state_field "$STATE_DIR/sess-1.json" '.checkpoint_done')" = "true" ]
    [ "$(state_field "$STATE_DIR/sess-1.json" '.percentage')" = "42" ]
}

@test "session-start: exports env vars via CLAUDE_ENV_FILE" {
    export CLAUDE_ENV_FILE="$TEST_HOME/envfile"
    run_ss sess-1 "$PROJECT_DIR"
    [ -f "$CLAUDE_ENV_FILE" ]
    grep -q 'MIMO_SESSION_ID="sess-1"' "$CLAUDE_ENV_FILE"
    grep -q "MIMO_STATE_FILE=" "$CLAUDE_ENV_FILE"
    grep -q "MIMO_CHANGES_LOG=" "$CLAUDE_ENV_FILE"
    grep -q "MIMO_CWD=" "$CLAUDE_ENV_FILE"
}

@test "session-start: banner interpolates configured thresholds" {
    export MIMO_CONF="$HOME/.claude/mimo.conf"
    printf 'CHECKPOINT_THRESHOLD=40\nFULLSAVE_THRESHOLD=70\n' > "$MIMO_CONF"
    run_ss sess-1 "$PROJECT_DIR"
    [[ "$ctx" == *"Checkpoints at 40% context, full save at 70%"* ]]
}

# ── Auto-init matrix ─────────────────────────────────────────────────────────

@test "auto-init git-only: initializes inside a git repo" {
    ( cd "$PROJECT_DIR" && git init -q )
    run_ss sess-1 "$PROJECT_DIR"
    [ -f "$PROJECT_DIR/CLAUDE.md" ]
    [ -f "$PROJECT_DIR/CLAUDE-FULL.md" ]
    grep -q "Memory — Current State" "$PROJECT_DIR/CLAUDE.md"
    [[ "$ctx" == *"Auto-initialized"* ]]
}

@test "auto-init git-only: skips a non-git directory with a hint" {
    run_ss sess-1 "$PROJECT_DIR"
    [ ! -f "$PROJECT_DIR/CLAUDE.md" ]
    [[ "$ctx" == *"auto-init skipped"* ]]
    [[ "$ctx" == *"not a git repo"* ]]
}

@test "auto-init: never writes into \$HOME even inside a git tree" {
    ( cd "$HOME" && git init -q )
    run_ss sess-1 "$HOME"
    [ ! -f "$HOME/CLAUDE.md" ]
}

@test "auto-init always: initializes a non-git directory" {
    export MIMO_CONF="$HOME/.claude/mimo.conf"
    printf 'AUTO_INIT=always\n' > "$MIMO_CONF"
    run_ss sess-1 "$PROJECT_DIR"
    [ -f "$PROJECT_DIR/CLAUDE.md" ]
}

@test "auto-init never: skips even a git repo" {
    export MIMO_CONF="$HOME/.claude/mimo.conf"
    printf 'AUTO_INIT=never\n' > "$MIMO_CONF"
    ( cd "$PROJECT_DIR" && git init -q )
    run_ss sess-1 "$PROJECT_DIR"
    [ ! -f "$PROJECT_DIR/CLAUDE.md" ]
}

@test "workflow block: off by default (memory sections only)" {
    ( cd "$PROJECT_DIR" && git init -q )
    run_ss sess-1 "$PROJECT_DIR"
    [ -f "$PROJECT_DIR/CLAUDE.md" ]
    ! grep -q "## Workflow Orchestration" "$PROJECT_DIR/CLAUDE.md"
}

@test "workflow block: on via config includes the workflow block" {
    export MIMO_CONF="$HOME/.claude/mimo.conf"
    printf 'WORKFLOW_BLOCK=on\n' > "$MIMO_CONF"
    ( cd "$PROJECT_DIR" && git init -q )
    run_ss sess-1 "$PROJECT_DIR"
    grep -q "## Workflow Orchestration" "$PROJECT_DIR/CLAUDE.md"
}

@test "auto-init: appends memory sections to an existing CLAUDE.md without them" {
    ( cd "$PROJECT_DIR" && git init -q )
    printf '# My Project\n\nCustom top content.\n' > "$PROJECT_DIR/CLAUDE.md"
    run_ss sess-1 "$PROJECT_DIR"
    # Original opening bytes intact, memory sections appended.
    head -1 "$PROJECT_DIR/CLAUDE.md" | grep -q "# My Project"
    grep -q "Memory — Current State" "$PROJECT_DIR/CLAUDE.md"
}

# ── Stale cleanup (heartbeat) ────────────────────────────────────────────────

@test "stale cleanup: keeps fresh state, removes old triple and tmp orphans" {
    # Fresh session (mtime now) — must survive.
    seed_state "$STATE_DIR/fresh.json"
    # Old session triple (state + companions), backdated past the 120m window.
    seed_state "$STATE_DIR/old.json"
    touch "$STATE_DIR/old-changes.log" "$STATE_DIR/old-postcompact.flag"
    touch -t 202001010000 "$STATE_DIR/old.json" "$STATE_DIR/old-changes.log" "$STATE_DIR/old-postcompact.flag"
    # Orphaned jq temp file, backdated past the 60m window.
    touch -t 202001010000 "$STATE_DIR/stray.tmp"

    run_ss sess-1 "$PROJECT_DIR"
    [ -f "$STATE_DIR/fresh.json" ]
    [ ! -f "$STATE_DIR/old.json" ]
    [ ! -f "$STATE_DIR/old-changes.log" ]
    [ ! -f "$STATE_DIR/old-postcompact.flag" ]
    [ ! -f "$STATE_DIR/stray.tmp" ]
}

@test "stale cleanup: reaps a companion whose json is already gone" {
    # changes.log with no matching json — should be swept even if recent.
    touch "$STATE_DIR/ghost-changes.log"
    run_ss sess-1 "$PROJECT_DIR"
    [ ! -f "$STATE_DIR/ghost-changes.log" ]
}

# ── Update check (no network — cached file only) ─────────────────────────────

@test "update check: composes message from cached file, no network" {
    printf '1.0.0\n' > "$STATE_DIR/mimo-installed-version"
    printf '9.9.9\n' > "$STATE_DIR/mimo-update-check"   # fresh mtime => no curl
    run_ss sess-1 "$PROJECT_DIR"
    [[ "$ctx" == *"Update available"* ]]
    [[ "$ctx" == *"1.0.0"* ]]
    [[ "$ctx" == *"9.9.9"* ]]
}

@test "update check: silent when installed matches cached remote" {
    printf '2.0.0\n' > "$STATE_DIR/mimo-installed-version"
    printf '2.0.0\n' > "$STATE_DIR/mimo-update-check"
    run_ss sess-1 "$PROJECT_DIR"
    [[ "$ctx" != *"Update available"* ]]
}

@test "session-start: reports the deep archive with the latest anchor" {
    ( cd "$PROJECT_DIR" && git init -q )
    printf '# CLAUDE.md\n\nMemory — Current State\n' > "$PROJECT_DIR/CLAUDE.md"
    printf '# Archive\n\n## S3 — 2026-01-01 — first\n## S4 — 2026-02-02 — latest\n' > "$PROJECT_DIR/CLAUDE-FULL.md"
    run_ss sess-1 "$PROJECT_DIR"
    [[ "$ctx" == *"latest: S4"* ]]
}
