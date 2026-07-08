#!/usr/bin/env bats
# Wave 4 — P13 file-change save trigger (statusline arms, gate resets baseline)
# and P12 cross-project user profile (inject / lint / preserve).

load helpers

setup() {
    mimo_setup
    SL="$HOOKS_SRC/statusline-memory.sh"
    GATE="$HOOKS_SRC/memory-gate.sh"
    TRACK="$HOOKS_SRC/track-changes.sh"
    SS="$HOOKS_SRC/session-start.sh"
    SUBAGENT="$HOOKS_SRC/subagent-context.sh"
    MIMO="$MIMO_REPO_ROOT/mimo"
    export MIMO_STATE_FILE="$STATE_DIR/sess-1.json"
    export MIMO_CHANGES_LOG="$STATE_DIR/sess-1-changes.log"
    export MIMO_CWD="$PROJECT_DIR"
    export MIMO_SKILLS_DIR="$MIMO_REPO_ROOT/skills"
    export MIMO_TEMPLATES_DIR="$MIMO_REPO_ROOT/templates"
    export MIMO_USER_PROFILE_FILE="$HOME/.claude/mimo-user.md"
    printf '# CLAUDE.md\n' > "$PROJECT_DIR/CLAUDE.md"
}
teardown() { mimo_teardown; }

# Write a changes log with N distinct paths.
seed_changes_log() {
    awk -v n="$1" 'BEGIN{for(i=1;i<=n;i++)printf "/proj/f%05d.py\n",i}' > "$MIMO_CHANGES_LOG"
}

# ══ P13 — file-change save trigger ═══════════════════════════════════════════

# THE interleaving test: statusline arms off the changes count at LOW context,
# the gate blocks + verifies, the gate resets the baseline, the next render is
# clean. Proves the statusline is the single arming owner and the gate only
# resets the baseline.
@test "p13: 45-change log at 20% arms checkpoint, verified save resets baseline, render clean" {
    seed_changes_log 45
    seed_state "$MIMO_STATE_FILE" percentage=20 changes_at_save=0

    # Render at 20% (well below the 50% checkpoint line): file trigger arms it.
    run bash "$SL" <<<"$(statusline_json 20)"
    [ "$status" -eq 0 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "checkpoint_needed" ]

    # Gate blocks (exit 2) and records the request.
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.pending_save_kind')" = "checkpoint" ]

    # The save happens: CLAUDE.md mtime advances past the request.
    touch "$PROJECT_DIR/CLAUDE.md"
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 0 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.checkpoint_done')" = "true" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]
    # Baseline advanced to the current log count (45).
    [ "$(state_field "$MIMO_STATE_FILE" '.changes_at_save')" = "45" ]

    # Next render at the same log size: 45 - 45 = 0 < 40 -> stays clean.
    run bash "$SL" <<<"$(statusline_json 20)"
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]
}

# Give-up variant (THE invariant): two unverified attempts -> give-up resets the
# baseline, so a render at the same log size does NOT re-arm. A crossing emits at
# most 2 requests, exactly like a % crossing bounded by its done flag.
@test "p13: give-up resets the baseline so the same log never re-arms" {
    seed_changes_log 45
    # CLAUDE.md is OLD so verification never succeeds.
    touch -t 202001010000 "$PROJECT_DIR/CLAUDE.md"
    seed_state "$MIMO_STATE_FILE" percentage=20 changes_at_save=0 threshold=checkpoint_needed

    # Emission 1 + 2 both block.
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.save_attempts')" = "2" ]

    # Give-up: allow stop, reset the baseline to the current count (45).
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 0 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]
    [ "$(state_field "$MIMO_STATE_FILE" '.changes_at_save')" = "45" ]

    # A render at the SAME log size must NOT re-arm (0 < 40) — the invariant.
    run bash "$SL" <<<"$(statusline_json 20)"
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]

    # And the gate still allows stop (no perpetual nag).
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 0 ]
}

# Recurring: after the baseline reset, another K changes re-arm a fresh crossing.
@test "p13: trigger is recurring — a further 40 changes re-arm after a save" {
    seed_changes_log 40
    seed_state "$MIMO_STATE_FILE" percentage=20 changes_at_save=40 checkpoint_done=true
    # 40 - 40 = 0 -> clean even though checkpoint_done is already set.
    run bash "$SL" <<<"$(statusline_json 20)"
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]
    # Grow the log by 40 more -> 80 - 40 = 40 >= 40 -> re-arms (ignores checkpoint_done).
    seed_changes_log 80
    run bash "$SL" <<<"$(statusline_json 20)"
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "checkpoint_needed" ]
}

@test "p13: SAVE_AFTER_CHANGES=0 disables the trigger (500-line log never arms)" {
    export MIMO_CONF="$HOME/.claude/mimo.conf"
    printf 'SAVE_AFTER_CHANGES=0\n' > "$MIMO_CONF"
    seed_changes_log 500
    seed_state "$MIMO_STATE_FILE" percentage=20 changes_at_save=0
    run bash "$SL" <<<"$(statusline_json 20)"
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]
}

@test "p13: a zero-edit session (no changes log) never arms" {
    rm -f "$MIMO_CHANGES_LOG"
    seed_state "$MIMO_STATE_FILE" percentage=20 changes_at_save=0
    run bash "$SL" <<<"$(statusline_json 20)"
    [ "$status" -eq 0 ]
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]
}

# Priority: at fullsave context a big log arms fullsave_needed, NOT checkpoint.
@test "p13: fullsave priority — 85% with a big log arms fullsave, not checkpoint" {
    seed_changes_log 500
    seed_state "$MIMO_STATE_FILE" percentage=20 changes_at_save=0
    run bash "$SL" <<<"$(statusline_json 85)"
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "fullsave_needed" ]
}

@test "p13: a custom SAVE_AFTER_CHANGES threshold is honored" {
    export MIMO_CONF="$HOME/.claude/mimo.conf"
    printf 'SAVE_AFTER_CHANGES=10\n' > "$MIMO_CONF"
    seed_changes_log 10
    seed_state "$MIMO_STATE_FILE" percentage=5 changes_at_save=0
    run bash "$SL" <<<"$(statusline_json 5)"
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "checkpoint_needed" ]
}

@test "p13: statusline preserves changes_at_save across a render" {
    seed_state "$MIMO_STATE_FILE" percentage=20 changes_at_save=17
    run bash "$SL" <<<"$(statusline_json 20)"
    [ "$(state_field "$MIMO_STATE_FILE" '.changes_at_save')" = "17" ]
}

# Migration: a pre-Wave-4 state file lacks changes_at_save — readers default 0,
# and the first render establishes the field.
@test "p13: legacy state file without changes_at_save is handled (defaults 0)" {
    jq -n '{session_id:"sess-1", percentage:20, threshold:"clean", checkpoint_done:false, fullsave_done:false, save_requested_at:0, save_attempts:0, pending_save_kind:""}' > "$MIMO_STATE_FILE"
    seed_changes_log 5
    run bash "$SL" <<<"$(statusline_json 20)"
    [ "$status" -eq 0 ]
    # 5 - 0 = 5 < 40 -> clean, and the field now exists (defaulted by any writer).
    [ "$(state_field "$MIMO_STATE_FILE" '.threshold')" = "clean" ]
}

# ── track-changes memory-file exclusion ──────────────────────────────────────

@test "p13: track-changes skips CLAUDE.md, CLAUDE-FULL.md, mimo-user.md" {
    unset MIMO_CHANGES_LOG   # derive the log path from session_id
    for f in CLAUDE.md CLAUDE-FULL.md mimo-user.md; do
        run bash "$TRACK" <<<"{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"/proj/$f\"}}"
        [ "$status" -eq 0 ]
    done
    [ ! -f "$STATE_DIR/s1-changes.log" ]
}

@test "p13: track-changes still logs a normal source file" {
    unset MIMO_CHANGES_LOG   # derive the log path from session_id
    run bash "$TRACK" <<<'{"session_id":"s1","tool_input":{"file_path":"/proj/app.py"}}'
    [ "$status" -eq 0 ]
    grep -q "/proj/app.py" "$STATE_DIR/s1-changes.log"
}

# ══ P12 — cross-project user profile ═════════════════════════════════════════

PROFILE='# mimo user profile
<!-- Who the user is across ALL projects. -->
- PREFERENCE: (2026-07-08) prefers concise answers; tables only for enumerable facts
- INSTRUCTION: (2026-07-08) never push or tag without an explicit ask'

@test "p12: session-start injects an existing profile under its header" {
    printf '%s\n' "$PROFILE" > "$MIMO_USER_PROFILE_FILE"
    run bash "$SS" <<<"$(hook_json sess-1 "$PROJECT_DIR")"
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"User profile (applies across projects):"* ]]
    [[ "$ctx" == *"prefers concise answers"* ]]
    [[ "$ctx" == *"never push or tag"* ]]
}

@test "p12: session-start stays silent when no profile exists" {
    run bash "$SS" <<<"$(hook_json sess-1 "$PROJECT_DIR")"
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" != *"User profile"* ]]
}

@test "p12: USER_PROFILE=off suppresses injection even when the file exists" {
    printf '%s\n' "$PROFILE" > "$MIMO_USER_PROFILE_FILE"
    export MIMO_CONF="$HOME/.claude/mimo.conf"
    printf 'USER_PROFILE=off\n' > "$MIMO_CONF"
    run bash "$SS" <<<"$(hook_json sess-1 "$PROJECT_DIR")"
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" != *"User profile"* ]]
}

@test "p12: subagent injects INSTRUCTION lines only (not PREFERENCE)" {
    printf '%s\n' "$PROFILE" > "$MIMO_USER_PROFILE_FILE"
    export MIMO_STATE_FILE="$STATE_DIR/s1.json"
    seed_state "$MIMO_STATE_FILE" percentage=33
    run bash "$SUBAGENT" <<<"$(hook_json s1 "$PROJECT_DIR")"
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"User instructions (standing rules):"* ]]
    [[ "$ctx" == *"never push or tag"* ]]
    [[ "$ctx" != *"prefers concise answers"* ]]
}

@test "p12: subagent injects the profile even with no CLAUDE.md memory" {
    printf '%s\n' "$PROFILE" > "$MIMO_USER_PROFILE_FILE"
    rm -f "$PROJECT_DIR/CLAUDE.md"
    export MIMO_STATE_FILE="$STATE_DIR/none.json"   # no state -> no ctx pct
    run bash "$SUBAGENT" <<<"$(hook_json s1 "$PROJECT_DIR")"
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"never push or tag"* ]]
}

@test "p12: subagent USER_PROFILE=off silences injection but keeps other sections" {
    printf '%s\n' "$PROFILE" > "$MIMO_USER_PROFILE_FILE"
    export MIMO_CONF="$HOME/.claude/mimo.conf"
    printf 'USER_PROFILE=off\n' > "$MIMO_CONF"
    export MIMO_STATE_FILE="$STATE_DIR/s1.json"
    seed_state "$MIMO_STATE_FILE" percentage=33
    run bash "$SUBAGENT" <<<"$(hook_json s1 "$PROJECT_DIR")"
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" != *"User instructions"* ]]
    [[ "$ctx" != *"never push or tag"* ]]
    # Other sections still emit normally.
    [[ "$ctx" == *"[MIMO — Subagent Context]"* ]]
    [[ "$ctx" == *"Parent session context usage: 33%"* ]]
}

@test "p12: save-full skill carries the user-profile step" {
    grep -q "user-profile" "$MIMO_SKILLS_DIR/save-full/SKILL.md"
    grep -q "mimo-user.md" "$MIMO_SKILLS_DIR/save-full/SKILL.md"
    grep -q "skip silently" "$MIMO_SKILLS_DIR/save-full/SKILL.md"
}

@test "p12: checkpoint skill has NO profile step" {
    ! grep -q "mimo-user.md" "$MIMO_SKILLS_DIR/save/SKILL.md"
}

# The gate emission (real skill body) carries the profile step at a threshold.
@test "p12: gate fullsave emission contains the profile step" {
    seed_state "$MIMO_STATE_FILE" threshold=fullsave_needed percentage=85
    run bash "$GATE" <<<"$(hook_json sess-1 "$MIMO_CWD")"
    [ "$status" -eq 2 ]
    [[ "$output" == *"user-profile"* ]]
    [[ "$output" == *"mimo-user.md"* ]]
}

# ── doctor profile lint ──────────────────────────────────────────────────────

mimo_in() { local dir="$1"; shift; run bash -c "cd '$dir' && bash '$MIMO' $*"; }

@test "p12: doctor accepts a clean profile" {
    printf '%s\n' "$PROFILE" > "$MIMO_USER_PROFILE_FILE"
    mimo_in "$PROJECT_DIR" doctor
    [[ "$output" == *"profile prefixes valid"* ]]
    [[ "$output" != *"lack an allowed PREFIX"* ]]
}

@test "p12: doctor warns on a bad-prefix profile line (no added failure)" {
    printf '# mimo user profile\n- PREFERENCE: (2026-07-08) ok\n- always be concise\n' > "$MIMO_USER_PROFILE_FILE"
    mimo_in "$PROJECT_DIR" doctor
    [[ "$output" == *"lack an allowed PREFIX"* ]]
    # Warning only — the (uninstalled) baseline still fails on settings, but the
    # profile warning must not itself add to the count. Assert it is a [warn].
    [[ "$output" == *"profile line(s) lack"* ]]
}

@test "p12: doctor warns on a >20-line profile" {
    {
        printf '# mimo user profile\n'
        for i in $(seq 1 21); do printf -- '- PREFERENCE: (2026-07-08) fact %d\n' "$i"; done
    } > "$MIMO_USER_PROFILE_FILE"
    mimo_in "$PROJECT_DIR" doctor
    [[ "$output" == *">20 — trim"* ]]
}

@test "p12: doctor is silent about the profile when none exists" {
    mimo_in "$PROJECT_DIR" doctor
    [[ "$output" != *"User profile ("* ]]
}

# ── status + uninstall preservation ──────────────────────────────────────────

@test "p12: status reports a present profile with a line count" {
    printf '%s\n' "$PROFILE" > "$MIMO_USER_PROFILE_FILE"
    mimo_in "$PROJECT_DIR" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"User profile:"* ]]
    [[ "$output" == *"present (4 lines)"* ]]
}

@test "p12: status reports an absent profile" {
    mimo_in "$PROJECT_DIR" status
    [[ "$output" == *"absent"* ]]
}

@test "p12: uninstall preserves a seeded profile file" {
    export INSTALL="$MIMO_REPO_ROOT/install.sh"
    export UNINSTALL="$MIMO_REPO_ROOT/uninstall.sh"
    run bash "$INSTALL"
    [ "$status" -eq 0 ]
    printf '%s\n' "$PROFILE" > "$HOME/.claude/mimo-user.md"
    run bash "$UNINSTALL"
    [ "$status" -eq 0 ]
    [ -f "$HOME/.claude/mimo-user.md" ]
    grep -q "never push or tag" "$HOME/.claude/mimo-user.md"
    [[ "$output" == *"mimo-user.md"* ]]
}
