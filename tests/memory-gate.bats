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
    [[ "$output" == *"Save a quick checkpoint"* ]]
}

# The emitted protocol (real skill files) carries the v2.1 reconcile rules: the
# 4-way classification (DUPLICATE) and the supersession marker convention.
@test "gate: emitted protocol carries the reconcile classification and supersession marker" {
    seed_state "$MIMO_STATE_FILE" threshold=checkpoint_needed percentage=55
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DUPLICATE"* ]]
    [[ "$output" == *"superseded"* ]]
}

# Anchor steps survive the rewrite; the pre-v2 "line references" wording does not.
@test "gate: emitted protocol keeps anchor steps and drops line-reference wording" {
    seed_state "$MIMO_STATE_FILE" threshold=checkpoint_needed percentage=55
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [[ "$output" == *"grep -n '^## S'"* ]]
    [[ "$output" == *"§S<N>"* ]]
    [[ "$output" != *"line references"* ]]
}

# The full-save protocol adds the merit-based cap and the superseded-line sweep.
@test "gate: fullsave protocol carries merit consolidation and the superseded sweep" {
    seed_state "$MIMO_STATE_FILE" threshold=fullsave_needed percentage=85
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [[ "$output" == *"most valuable"* ]]
    [[ "$output" == *"invalidate-then-archive"* ]]
}

# v2.2 (Wave 2): the emitted protocol carries the Topics index line, the P9
# Current State schema, and — for full save — the Project Card re-emit step.
@test "gate: fullsave emission carries Topics, Current State schema, and Project Card" {
    seed_state "$MIMO_STATE_FILE" threshold=fullsave_needed percentage=85
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Topics:"* ]]
    [[ "$output" == *"Next actionable (verbatim)"* ]]
    [[ "$output" == *"Memory — Project Card"* ]]
    [[ "$output" == *"STACK"* ]]
}

@test "gate: checkpoint emission carries the Topics line and Current State schema" {
    seed_state "$MIMO_STATE_FILE" threshold=checkpoint_needed percentage=55
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Topics:"* ]]
    [[ "$output" == *"Next actionable (verbatim)"* ]]
    # Checkpoint defers the card to /save-full but names it so.
    [[ "$output" == *"Project Card"* ]]
}

# Budget: each SKILL.md stays well within the instruction budget (65-line target,
# 80-line ceiling) so the protocol never balloons the gate emission.
@test "gate: skill files stay within the line budget" {
    local n
    for f in save save-full; do
        n=$(awk 'END{print NR}' "$MIMO_SKILLS_DIR/$f/SKILL.md")
        [ "$n" -le 80 ]
    done
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

# REGRESSION (C1): a huge changes.log must not SIGPIPE-kill the gate. The
# sort|head -50 pipeline blocks past the ~64KB pipe buffer (>~1300 unique
# paths); without `|| true` sort dies with SIGPIPE (141) under pipefail and the
# whole hook aborts (exit 141) — silently dropping the save prompt. Assert the
# gate still blocks (exit 2), emits the header, and truncates to exactly 50.
@test "gate: 3000-path changes log still blocks (exit 2, not 141) and truncates to 50" {
    export MIMO_CHANGES_LOG="$STATE_DIR/sess-1-changes.log"
    awk 'BEGIN{for(i=1;i<=3000;i++)printf "/proj/f%05d.py\n",i}' > "$MIMO_CHANGES_LOG"
    seed_state "$MIMO_STATE_FILE" threshold=checkpoint_needed percentage=55
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CHECKPOINT REQUIRED"* ]]
    [[ "$output" == *"Files changed this session"* ]]
    # Truncation: exactly 50 tracked paths in the emitted list.
    local n
    n=$(printf '%s\n' "$output" | grep -c '^/proj/f[0-9]*\.py$')
    [ "$n" -eq 50 ]
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
