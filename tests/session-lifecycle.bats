#!/usr/bin/env bats
# Lifecycle hooks: track-changes, session-end, session-start-compact,
# user-prompt-context, subagent-context, precompact-save.

load helpers

setup() {
    mimo_setup
    TRACK="$HOOKS_SRC/track-changes.sh"
    SEND="$HOOKS_SRC/session-end-backup.sh"
    COMPACT="$HOOKS_SRC/session-start-compact.sh"
    UPROMPT="$HOOKS_SRC/user-prompt-context.sh"
    SUBAGENT="$HOOKS_SRC/subagent-context.sh"
    PRECOMPACT="$HOOKS_SRC/precompact-save.sh"
}
teardown() { mimo_teardown; }

# ── track-changes.sh ─────────────────────────────────────────────────────────

@test "track-changes: creates the log dir and appends a Write file_path" {
    rm -rf "$STATE_DIR"   # simulate PostToolUse firing before SessionStart
    run bash "$TRACK" <<<'{"session_id":"s1","tool_input":{"file_path":"/tmp/a.py"}}'
    [ "$status" -eq 0 ]
    grep -q "/tmp/a.py" "$STATE_DIR/s1-changes.log"
}

@test "track-changes: records a NotebookEdit notebook_path" {
    run bash "$TRACK" <<<'{"session_id":"s1","tool_input":{"notebook_path":"/tmp/nb.ipynb"}}'
    [ "$status" -eq 0 ]
    grep -q "/tmp/nb.ipynb" "$STATE_DIR/s1-changes.log"
}

@test "track-changes: honors MIMO_CHANGES_LOG override" {
    export MIMO_CHANGES_LOG="$STATE_DIR/custom.log"
    run bash "$TRACK" <<<'{"session_id":"s1","tool_input":{"file_path":"/tmp/b.py"}}'
    grep -q "/tmp/b.py" "$STATE_DIR/custom.log"
}

@test "track-changes: no session_id and no log override exits 0 silently" {
    run bash "$TRACK" <<<'{"tool_input":{"file_path":"/tmp/c.py"}}'
    [ "$status" -eq 0 ]
}

@test "track-changes: empty file path exits 0 without writing" {
    run bash "$TRACK" <<<'{"session_id":"s1","tool_input":{}}'
    [ "$status" -eq 0 ]
    [ ! -f "$STATE_DIR/s1-changes.log" ]
}

# ── session-end-backup.sh ────────────────────────────────────────────────────

@test "session-end: writes a backup with the session prefix and removes the triple" {
    local tr="$TEST_HOME/transcript.jsonl"
    printf '{"role":"user"}\n' > "$tr"
    seed_state "$STATE_DIR/abcd1234ef.json"
    touch "$STATE_DIR/abcd1234ef-changes.log" "$STATE_DIR/abcd1234ef-postcompact.flag"
    run bash "$SEND" <<<"{\"session_id\":\"abcd1234ef\",\"transcript_path\":\"$tr\"}"
    [ "$status" -eq 0 ]
    ls "$BACKUP_DIR"/*-abcd1234-end.jsonl >/dev/null 2>&1
    [ ! -f "$STATE_DIR/abcd1234ef.json" ]
    [ ! -f "$STATE_DIR/abcd1234ef-changes.log" ]
    [ ! -f "$STATE_DIR/abcd1234ef-postcompact.flag" ]
}

@test "session-end: prunes backups older than the retention window" {
    local tr="$TEST_HOME/transcript.jsonl"; printf '{}\n' > "$tr"
    printf 'old\n' > "$BACKUP_DIR/20200101-000000-old-end.jsonl"
    touch -t 202001010000 "$BACKUP_DIR/20200101-000000-old-end.jsonl"
    printf '# old summary\n' > "$BACKUP_DIR/20200101-000000-precompact-summary.md"
    touch -t 202001010000 "$BACKUP_DIR/20200101-000000-precompact-summary.md"
    run bash "$SEND" <<<"{\"session_id\":\"s1\",\"transcript_path\":\"$tr\"}"
    [ ! -f "$BACKUP_DIR/20200101-000000-old-end.jsonl" ]
    [ ! -f "$BACKUP_DIR/20200101-000000-precompact-summary.md" ]
}

@test "session-end: missing transcript still prunes and cleans up (no crash)" {
    run bash "$SEND" <<<'{"session_id":"s1","transcript_path":"/does/not/exist"}'
    [ "$status" -eq 0 ]
}

# ── session-start-compact.sh ─────────────────────────────────────────────────

@test "session-start-compact: writes the post-compact flag and a context message" {
    run bash "$COMPACT" <<<"$(hook_json s1 "$PROJECT_DIR")"
    [ "$status" -eq 0 ]
    [ -f "$STATE_DIR/s1-postcompact.flag" ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"after compaction"* ]]
}

@test "session-start-compact: surfaces the latest archive anchor" {
    printf '# A\n\n## S7 — 2026-01-01 — x\n' > "$PROJECT_DIR/CLAUDE-FULL.md"
    run bash "$COMPACT" <<<"$(hook_json s1 "$PROJECT_DIR")"
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"latest: S7"* ]]
}

@test "session-start-compact: no archive still emits valid JSON (no anchor abort)" {
    printf '# A\n\nNo anchors here.\n' > "$PROJECT_DIR/CLAUDE-FULL.md"
    run bash "$COMPACT" <<<"$(hook_json s1 "$PROJECT_DIR")"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
}

# ── user-prompt-context.sh ───────────────────────────────────────────────────

@test "user-prompt: no flag exits 0 with no output" {
    run bash "$UPROMPT" <<<"$(hook_json s1 "$PROJECT_DIR")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "user-prompt: one-shot consumes the flag; second run is silent" {
    printf '## Memory — Current State\nFocus: testing\nBlockers: None\n\n## Memory — Key Decisions\n- decided X\n' > "$PROJECT_DIR/CLAUDE.md"
    touch "$STATE_DIR/s1-postcompact.flag"
    run bash "$UPROMPT" <<<"$(hook_json s1 "$PROJECT_DIR")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Post-Compact Context Recovery"* ]]
    [ ! -f "$STATE_DIR/s1-postcompact.flag" ]
    # Second run: flag gone -> silent.
    run bash "$UPROMPT" <<<"$(hook_json s1 "$PROJECT_DIR")"
    [ -z "$output" ]
}

# REGRESSION (M1): Key Decisions extraction must stop at the next heading on BSD
# sed too. The old end-address `/^## \|^$/` used GNU-only `\|` alternation, which
# BSD sed treats literally — never matches, so the range ran to EOF and bled the
# following section into the injected context. Fixed to the portable `/^## /`.
@test "user-prompt: Key Decisions extraction stops at next heading (BSD-sed portable)" {
    printf '## Memory — Current State\nFocus: testing\n\n## Memory — Key Decisions\n- decided X\n\n## Other Section\nOTHERSECTIONBLEED\n' > "$PROJECT_DIR/CLAUDE.md"
    touch "$STATE_DIR/s1-postcompact.flag"
    run bash "$UPROMPT" <<<"$(hook_json s1 "$PROJECT_DIR")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"decided X"* ]]
    [[ "$output" != *"OTHERSECTIONBLEED"* ]]
}

# ── subagent-context.sh ──────────────────────────────────────────────────────

@test "subagent: injects Memory — Current State from CLAUDE.md" {
    printf '## Memory — Current State\nFocus: shipping v2\n\n## Next\n' > "$PROJECT_DIR/CLAUDE.md"
    export MIMO_STATE_FILE="$STATE_DIR/s1.json"
    seed_state "$MIMO_STATE_FILE" percentage=33
    run bash "$SUBAGENT" <<<"$(hook_json s1 "$PROJECT_DIR")"
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"Focus: shipping v2"* ]]
    [[ "$ctx" == *"33%"* ]]
}

@test "subagent: exits 0 silently when there is no info to inject" {
    export MIMO_STATE_FILE="$STATE_DIR/none.json"
    run bash "$SUBAGENT" <<<"$(hook_json s1 "$PROJECT_DIR")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# P8: subagents get the durable Project Card facts alongside Current State.
@test "subagent: injects Memory — Project Card when present" {
    printf '## Memory — Current State\nFocus: shipping v2\n\n## Memory — Project Card\n- STACK: bash 3.2, jq\n- TOOL-RULE: run tests with bats tests/\n\n## Memory — Recent Sessions\n' > "$PROJECT_DIR/CLAUDE.md"
    export MIMO_STATE_FILE="$STATE_DIR/s1.json"
    seed_state "$MIMO_STATE_FILE" percentage=33
    run bash "$SUBAGENT" <<<"$(hook_json s1 "$PROJECT_DIR")"
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"Memory — Project Card"* ]]
    [[ "$ctx" == *"STACK: bash 3.2, jq"* ]]
    [[ "$ctx" == *"TOOL-RULE: run tests with bats"* ]]
    [[ "$ctx" == *"Focus: shipping v2"* ]]
}

# No card present → Current State still injected, no empty Project Card block.
@test "subagent: works with Current State only (no Project Card section)" {
    printf '## Memory — Current State\nFocus: no card here\n\n## Next\n' > "$PROJECT_DIR/CLAUDE.md"
    export MIMO_STATE_FILE="$STATE_DIR/s1.json"
    seed_state "$MIMO_STATE_FILE" percentage=10
    run bash "$SUBAGENT" <<<"$(hook_json s1 "$PROJECT_DIR")"
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"Focus: no card here"* ]]
    [[ "$ctx" != *"Memory — Project Card"* ]]
}

# ── precompact-save.sh ───────────────────────────────────────────────────────

@test "precompact: backs up transcript, writes a summary, emits PreCompact JSON" {
    local tr="$TEST_HOME/t.jsonl"
    printf '{"role":"user","content":"hello there"}\n' > "$tr"
    run bash "$PRECOMPACT" <<<"{\"session_id\":\"abcd1234ef\",\"transcript_path\":\"$tr\",\"trigger\":\"auto\"}"
    [ "$status" -eq 0 ]
    ls "$BACKUP_DIR"/*-abcd1234-precompact.jsonl >/dev/null 2>&1
    ls "$BACKUP_DIR"/*-precompact-summary.md >/dev/null 2>&1
    [ "$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "PreCompact" ]
}

@test "precompact: emits valid JSON even with no transcript" {
    run bash "$PRECOMPACT" <<<'{"session_id":"s1","transcript_path":"","trigger":"manual"}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
}
