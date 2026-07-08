#!/usr/bin/env bats
# memory-gate.sh — Stop hook state machine (request → verify → done / give-up).

load helpers

setup() {
    mimo_setup
    GATE="$HOOKS_SRC/memory-gate.sh"
    export MIMO_STATE_FILE="$STATE_DIR/sess-1.json"
    export MIMO_CWD="$PROJECT_DIR"
    export MIMO_SKILLS_DIR="$MIMO_REPO_ROOT/skills"
    printf '# CLAUDE.md\n' > "$PROJECT_DIR/CLAUDE.md"
}
teardown() { mimo_teardown; }

# ── Early exits ──────────────────────────────────────────────────────────────

@test "gate: stop_hook_active true always allows stop" {
    seed_state "$MIMO_STATE_FILE" threshold=fullsave_needed percentage=90
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD" true)"
    [ "$status" -eq 0 ]
}

@test "gate: no state file allows stop" {
    rm -f "$MIMO_STATE_FILE"
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 0 ]
}

@test "gate: clean threshold with no request allows stop" {
    seed_state "$MIMO_STATE_FILE" threshold=clean
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 0 ]
}

@test "gate: missing CLAUDE.md resets request and allows stop" {
    rm -f "$PROJECT_DIR/CLAUDE.md"
    seed_state "$MIMO_STATE_FILE" threshold=checkpoint_needed percentage=55
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 0 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.save_requested_at')" = "0" ]
}

# ── Request path ─────────────────────────────────────────────────────────────

@test "gate: checkpoint_needed blocks stop and records the request" {
    seed_state "$MIMO_STATE_FILE" threshold=checkpoint_needed percentage=55
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.save_attempts')" = "1" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.pending_save_kind')" = "checkpoint" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.save_requested_at')" -gt 0 ]
    [[ "$output" == *"CHECKPOINT REQUIRED"* ]]
    [[ "$output" == *"context at 55%"* ]]
}

@test "gate: fullsave_needed blocks stop with a full-save header" {
    seed_state "$MIMO_STATE_FILE" threshold=fullsave_needed percentage=85
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.pending_save_kind')" = "fullsave" ]
    [[ "$output" == *"FULL SAVE REQUIRED"* ]]
}

@test "gate: request path emits the installed skill body" {
    seed_state "$MIMO_STATE_FILE" threshold=checkpoint_needed percentage=55
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Save a checkpoint of your current work"* ]]
}

@test "gate: falls back to built-in instructions when skill file missing" {
    export MIMO_SKILLS_DIR="$TEST_HOME/empty-skills"
    mkdir -p "$MIMO_SKILLS_DIR"
    seed_state "$MIMO_STATE_FILE" threshold=checkpoint_needed percentage=55
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Save your work now to preserve context:"* ]]
    [[ "$output" == *"grep -n '^## S'"* ]]
}

@test "gate: tracked-files list merges changes log with git status" {
    ( cd "$PROJECT_DIR" && git init -q && git config user.email t@t.t && git config user.name t )
    printf 'uncommitted content\n' > "$PROJECT_DIR/newfile.txt"
    export MIMO_CHANGES_LOG="$STATE_DIR/sess-1-changes.log"
    printf '%s/logged.py\n' "$PROJECT_DIR" > "$MIMO_CHANGES_LOG"
    seed_state "$MIMO_STATE_FILE" threshold=checkpoint_needed percentage=55
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Files changed this session"* ]]
    [[ "$output" == *"newfile.txt"* ]]
    [[ "$output" == *"logged.py"* ]]
}

# ── Verification path ────────────────────────────────────────────────────────

@test "gate: verified checkpoint (mtime advanced) marks done and clears request" {
    local req=$(( $(date +%s) - 100 ))
    seed_state "$MIMO_STATE_FILE" threshold=checkpoint_needed percentage=55 \
        save_requested_at="$req" save_attempts=1 pending_save_kind=checkpoint
    touch "$PROJECT_DIR/CLAUDE.md"   # mtime = now, after the request
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 0 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.checkpoint_done')" = "true" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.save_requested_at')" = "0" ]
}

@test "gate: verified fullsave sets both done flags" {
    local req=$(( $(date +%s) - 100 ))
    seed_state "$MIMO_STATE_FILE" threshold=fullsave_needed percentage=85 \
        save_requested_at="$req" save_attempts=1 pending_save_kind=fullsave
    touch "$PROJECT_DIR/CLAUDE.md"
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 0 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.checkpoint_done')" = "true" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.fullsave_done')" = "true" ]
}

@test "gate: legacy phrase-grep accepts a save even with an old mtime" {
    local req=$(( $(date +%s) - 100 ))
    seed_state "$MIMO_STATE_FILE" threshold=checkpoint_needed percentage=55 \
        save_requested_at="$req" save_attempts=1 pending_save_kind=checkpoint
    touch -t 202001010000 "$PROJECT_DIR/CLAUDE.md"   # OLD — mtime does NOT verify
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD" false "all done — checkpoint saved")"
    [ "$status" -eq 0 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.checkpoint_done')" = "true" ]
}

# ── REGRESSION (a): statusline-interleaved give-up durability ────────────────
# 85% fullsave: two blocking emissions, then a give-up. A statusline render at
# 86% must NOT re-arm the crossing — the give-up set fullsave_done, so threshold
# stays clean and the gate never nags again.

@test "gate: give-up durability survives a statusline render at 86%" {
    SL="$HOOKS_SRC/statusline-memory.sh"
    # CLAUDE.md is OLD so verification NEVER succeeds — the save genuinely never happens.
    touch -t 202001010000 "$PROJECT_DIR/CLAUDE.md"
    seed_state "$MIMO_STATE_FILE" threshold=fullsave_needed percentage=85 fullsave_done=false

    # Emission 1 (attempts 0 -> 1), blocks.
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.save_attempts')" = "1" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.save_requested_at')" -gt 0 ]

    # Emission 2 (attempts 1 -> 2), blocks.
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.save_attempts')" = "2" ]

    # Give-up (attempts >= 2): allow stop, mark fullsave_done, go clean.
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 0 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.fullsave_done')" = "true" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.save_requested_at')" = "0" ]

    # Statusline render at 86% must NOT re-arm — done flag holds.
    run bash "$SL" <<<"$(statusline_json 86)"
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.fullsave_done')" = "true" ]

    # And a subsequent gate call still allows stop (no perpetual nag).
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 0 ]
}

# ── REGRESSION (b): stale-request cancellation ───────────────────────────────
# A recent request whose crossing evaporated (threshold fell back to clean) is
# cancelled — not spuriously "verified" by an unrelated old CLAUDE.md — and a
# later genuine crossing issues a fresh request.

@test "gate: stale request is cancelled, later crossing issues a fresh one" {
    SL="$HOOKS_SRC/statusline-memory.sh"
    touch -t 202001010000 "$PROJECT_DIR/CLAUDE.md"   # old, predates the request
    local req; req=$(date +%s)                        # REALISTIC recent request time
    seed_state "$MIMO_STATE_FILE" threshold=clean percentage=45 \
        save_requested_at="$req" save_attempts=1 pending_save_kind=checkpoint checkpoint_done=false

    # Crossing evaporated: gate cancels the dead request, does NOT mark done.
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 0 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.save_requested_at')" = "0" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.save_attempts')" = "0" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.pending_save_kind')" = "" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.checkpoint_done')" = "false" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]

    # A genuine later crossing (statusline at 55%) re-arms checkpoint...
    run bash "$SL" <<<"$(statusline_json 55)"
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "checkpoint_needed" ]

    # ...and the gate issues a fresh request (blocks, attempts back to 1).
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.save_attempts')" = "1" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.save_requested_at')" -gt 0 ]
}
