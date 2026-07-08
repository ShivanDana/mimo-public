#!/usr/bin/env bats
# statusline-memory.sh — context detector + threshold state writer.

load helpers

setup()    { mimo_setup; SL="$HOOKS_SRC/statusline-memory.sh"; export MIMO_STATE_FILE="$STATE_DIR/sess-1.json"; }
teardown() { mimo_teardown; }

@test "statusline: normal render shows percent, bar, model and cost" {
    run bash "$SL" <<<"$(statusline_json 30 MyModel sess-1 0.42)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"30%"* ]]
    [[ "$output" == *"MyModel"* ]]
    [[ "$output" == *"0.42"* ]]
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]
}

@test "statusline: below checkpoint threshold stays clean" {
    run bash "$SL" <<<"$(statusline_json 49)"
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]
}

@test "statusline: flips to checkpoint_needed at configured 50%" {
    run bash "$SL" <<<"$(statusline_json 50)"
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "checkpoint_needed" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.percentage')" = "50" ]
}

@test "statusline: flips to fullsave_needed at configured 80%" {
    run bash "$SL" <<<"$(statusline_json 80)"
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "fullsave_needed" ]
}

@test "statusline: missing context_window defaults percentage to 0" {
    run bash "$SL" <<<'{"model":{"display_name":"M"},"session_id":"sess-1"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"0%"* ]]
    [ "$(state_field "$MIMO_STATE_FILE" '.percentage')" = "0" ]
}

@test "statusline: non-numeric percentage falls back to 0" {
    run bash "$SL" <<<'{"context_window":{"used_percentage":"abc"},"session_id":"sess-1"}'
    [ "$status" -eq 0 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.percentage')" = "0" ]
}

@test "statusline: preserves gate-owned fields across a render" {
    seed_state "$MIMO_STATE_FILE" save_requested_at=12345 save_attempts=1 pending_save_kind=fullsave
    run bash "$SL" <<<"$(statusline_json 55)"
    [ "$(state_field "$MIMO_STATE_FILE" '.save_requested_at')" = "12345" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.save_attempts')" = "1" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.pending_save_kind')" = "fullsave" ]
}

@test "statusline: done flag suppresses re-arming a crossed threshold" {
    seed_state "$MIMO_STATE_FILE" checkpoint_done=true
    run bash "$SL" <<<"$(statusline_json 55)"
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]
}

@test "statusline: fullsave_done suppresses fullsave re-arm" {
    # Both done: at 85% neither crossing should re-arm (checkpoint was already done).
    seed_state "$MIMO_STATE_FILE" checkpoint_done=true fullsave_done=true
    run bash "$SL" <<<"$(statusline_json 85)"
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]
}

@test "statusline: MIMO_CONF override lowers checkpoint threshold" {
    export MIMO_CONF="$HOME/.claude/mimo.conf"
    printf 'CHECKPOINT_THRESHOLD=30\n' > "$MIMO_CONF"
    run bash "$SL" <<<"$(statusline_json 35)"
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "checkpoint_needed" ]
}

@test "statusline: bar clamps at 100 for percentages over 100" {
    run bash "$SL" <<<"$(statusline_json 150)"
    [ "$status" -eq 0 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.percentage')" = "100" ]
    [[ "$output" == *"100%"* ]]
}

@test "statusline: bar renders at 0 percent without error" {
    run bash "$SL" <<<"$(statusline_json 0)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0%"* ]]
}

@test "statusline: creates a complete state file when none exists" {
    [ ! -f "$MIMO_STATE_FILE" ]
    run bash "$SL" <<<"$(statusline_json 10)"
    [ -f "$MIMO_STATE_FILE" ]
    # All gate + statusline fields present.
    for k in session_id percentage threshold checkpoint_done fullsave_done save_requested_at save_attempts pending_save_kind; do
        run jq -e "has(\"$k\")" "$MIMO_STATE_FILE"
        [ "$status" -eq 0 ]
    done
}
