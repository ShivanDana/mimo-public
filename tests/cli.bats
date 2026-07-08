#!/usr/bin/env bats
# mimo CLI — version/help/init/status/cleanup/sessions/doctor.

load helpers

setup() {
    mimo_setup
    MIMO="$MIMO_REPO_ROOT/mimo"
    export MIMO_TEMPLATES_DIR="$MIMO_REPO_ROOT/templates"
    SETTINGS="$HOME/.claude/settings.json"
}
teardown() { mimo_teardown; }

# Run mimo from inside a given directory.
mimo_in() {
    local dir="$1"; shift
    run bash -c "cd '$dir' && bash '$MIMO' $*"
}

@test "cli: version prints the VERSION-file value (dev fallback)" {
    run bash "$MIMO" version
    [ "$status" -eq 0 ]
    [ "$output" = "mimo v$(cat "$MIMO_REPO_ROOT/VERSION")" ]
}

@test "cli: help lists the core commands" {
    run bash "$MIMO" help
    [ "$status" -eq 0 ]
    for c in init status doctor sessions cleanup update version uninstall; do
        [[ "$output" == *"$c"* ]]
    done
}

@test "cli: unknown command exits 1 and prints help" {
    run bash "$MIMO" frobnicate
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown command"* ]]
}

@test "cli: init fresh creates CLAUDE.md and CLAUDE-FULL.md" {
    mimo_in "$PROJECT_DIR" init
    [ "$status" -eq 0 ]
    [ -f "$PROJECT_DIR/CLAUDE.md" ]
    [ -f "$PROJECT_DIR/CLAUDE-FULL.md" ]
    grep -q "Memory — Current State" "$PROJECT_DIR/CLAUDE.md"
}

@test "cli: init --with-workflow includes the workflow block" {
    mimo_in "$PROJECT_DIR" init --with-workflow
    grep -q "## Workflow Orchestration" "$PROJECT_DIR/CLAUDE.md"
}

@test "cli: init appends memory sections to an existing CLAUDE.md" {
    printf '# Mine\n\nkeep this\n' > "$PROJECT_DIR/CLAUDE.md"
    mimo_in "$PROJECT_DIR" init
    head -1 "$PROJECT_DIR/CLAUDE.md" | grep -q "# Mine"
    grep -q "Memory — Current State" "$PROJECT_DIR/CLAUDE.md"
}

@test "cli: init refuses \$HOME without --force-home" {
    mimo_in "$HOME" init
    [ "$status" -eq 1 ]
    [[ "$output" == *"home directory"* ]]
    [ ! -f "$HOME/CLAUDE.md" ]
}

@test "cli: init --force-home overrides the \$HOME refusal" {
    mimo_in "$HOME" init --force-home
    [ "$status" -eq 0 ]
    [ -f "$HOME/CLAUDE.md" ]
}

@test "cli: status runs and shows the standard sections" {
    mimo_in "$PROJECT_DIR" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Hook scripts:"* ]]
    [[ "$output" == *"Config:"* ]]
    [[ "$output" == *"Active sessions:"* ]]
}

@test "cli: status marks a stale session and lists an active one" {
    seed_state "$STATE_DIR/active.json" percentage=20 threshold=clean
    seed_state "$STATE_DIR/stale.json" percentage=90
    touch -t 202001010000 "$STATE_DIR/stale.json"
    mimo_in "$PROJECT_DIR" status
    [[ "$output" == *"stale"* ]]
}

@test "cli: status shows config overrides from mimo.conf" {
    export MIMO_CONF="$HOME/.claude/mimo.conf"
    printf 'CHECKPOINT_THRESHOLD=30\n' > "$MIMO_CONF"
    mimo_in "$PROJECT_DIR" status
    [[ "$output" == *"CHECKPOINT_THRESHOLD=30"* ]]
}

@test "cli: cleanup removes a stale triple, orphan companion, and old temp" {
    seed_state "$STATE_DIR/stale.json"
    touch "$STATE_DIR/stale-changes.log" "$STATE_DIR/stale-postcompact.flag"
    touch -t 202001010000 "$STATE_DIR/stale.json" "$STATE_DIR/stale-changes.log" "$STATE_DIR/stale-postcompact.flag"
    touch "$STATE_DIR/ghost-changes.log"       # orphan companion, no json
    touch -t 202001010000 "$STATE_DIR/x.tmp"   # old temp
    mimo_in "$PROJECT_DIR" cleanup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed 1 stale session"* ]]
    [ ! -f "$STATE_DIR/stale.json" ]
    [ ! -f "$STATE_DIR/ghost-changes.log" ]
    [ ! -f "$STATE_DIR/x.tmp" ]
}

@test "cli: sessions lists anchors from CLAUDE-FULL.md" {
    printf '# A\n\n## S1 — 2026-01-01 — first\n## S2 — 2026-02-02 — second\n' > "$PROJECT_DIR/CLAUDE-FULL.md"
    mimo_in "$PROJECT_DIR" sessions
    [ "$status" -eq 0 ]
    [[ "$output" == *"S1"* ]]
    [[ "$output" == *"S2"* ]]
    [[ "$output" == *"second"* ]]
}

@test "cli: sessions is friendly when there is no CLAUDE-FULL.md" {
    mimo_in "$PROJECT_DIR" sessions
    [ "$status" -eq 0 ]
    [[ "$output" == *"No CLAUDE-FULL.md"* ]]
}

@test "cli: doctor fails (exit 1) when nothing is installed" {
    mimo_in "$PROJECT_DIR" doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"settings.json not found"* ]]
}

@test "cli: doctor flags a statusLine that is not mimo" {
    # Hand-built settings with mimo hooks but a foreign statusLine.
    jq -n '{statusLine:{command:"echo hi"}, hooks:{Stop:[{hooks:[{type:"command",command:"bash ~/.claude/hooks/memory-gate.sh"}]}]}}' > "$SETTINGS"
    mimo_in "$PROJECT_DIR" doctor
    [[ "$output" == *"statusLine does NOT point at statusline-memory.sh"* ]]
}
