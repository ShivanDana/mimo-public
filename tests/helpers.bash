#!/usr/bin/env bash
# mimo test helpers — shared setup, sandbox HOME guard, fixture builders.
#
# SAFETY: every test runs under a throwaway $HOME created by mktemp. The guard in
# mimo_setup() REFUSES to run (hard exit) if HOME was not moved off the real home
# directory — a live mimo install powers the developer's own session and must
# never be touched by the suite.

# Resolve the repo root from this file's location (tests/ lives at repo root).
# shellcheck disable=SC2034
MIMO_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_SRC="$MIMO_REPO_ROOT/hooks"

# Capture the real home ONCE, before any test overrides it. Exported so it
# survives across the per-test subshells bats spawns.
export MIMO_REAL_HOME="${MIMO_REAL_HOME:-$HOME}"

mimo_setup() {
    # Fresh sandbox HOME per test. Canonicalize so the path matches `pwd` in
    # subshells (TMPDIR may end in a slash → a double slash mktemp keeps but pwd
    # normalizes away; a real /Users/<name> home never has that).
    TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/mimo-test.XXXXXX")"
    TEST_HOME="$(cd "$TEST_HOME" && pwd)"
    export HOME="$TEST_HOME"

    # ── MANDATORY SAFETY GUARD ────────────────────────────────────────────────
    # Refuse to proceed unless HOME is a sandbox distinct from the real home.
    if [ -z "${HOME:-}" ] || [ "$HOME" = "$MIMO_REAL_HOME" ] || [ "$HOME" != "$TEST_HOME" ]; then
        echo "FATAL: sandbox HOME not established (HOME='$HOME', real='$MIMO_REAL_HOME'). Refusing to run." >&2
        exit 1
    fi
    case "$HOME" in
        "$MIMO_REAL_HOME"|"$MIMO_REAL_HOME"/*)
            echo "FATAL: sandbox HOME is inside the real home. Refusing to run." >&2
            exit 1 ;;
    esac

    # The live session exports some of these — a leaked value would point a hook
    # at the real install. Clear them all; tests set what they need explicitly.
    unset MIMO_STATE_FILE MIMO_CHANGES_LOG MIMO_SESSION_ID MIMO_CWD MIMO_CONF \
          MIMO_SKILLS_DIR MIMO_TEMPLATES_DIR MIMO_USER_PROFILE_FILE CLAUDE_ENV_FILE

    mkdir -p "$HOME/.claude"
    STATE_DIR="$HOME/.claude/memory-state"
    BACKUP_DIR="$HOME/.claude/backups"
    SKILLS_DIR="$HOME/.claude/skills"
    TEMPLATES_DIR="$HOME/.claude/mimo-templates"
    mkdir -p "$STATE_DIR" "$BACKUP_DIR"

    # A project directory to save into (separate from HOME so the $HOME guard in
    # the hooks is not tripped by accident).
    PROJECT_DIR="$TEST_HOME/project"
    mkdir -p "$PROJECT_DIR"
}

mimo_teardown() {
    # Only ever remove a path we created via mktemp under the temp dir.
    if [ -n "${TEST_HOME:-}" ]; then
        case "$TEST_HOME" in
            */mimo-test.*) rm -rf "$TEST_HOME" ;;
        esac
    fi
}

# ── Fixture builders (hook stdin JSON) ───────────────────────────────────────

# statusline stdin: pct [model] [session_id] [cost]
statusline_json() {
    jq -n \
        --argjson pct "${1:-0}" \
        --arg model "${2:-TestModel}" \
        --arg sid "${3:-sess-1}" \
        --argjson cost "${4:-0}" \
        '{context_window: {used_percentage: $pct}, model: {display_name: $model}, session_id: $sid, cost: {total_cost_usd: $cost}}'
}

# gate/session stdin: session_id [cwd] [stop_hook_active] [last_assistant_message]
hook_json() {
    jq -n \
        --arg sid "${1:-sess-1}" \
        --arg cwd "${2:-}" \
        --argjson sha "${3:-false}" \
        --arg msg "${4:-}" \
        '{session_id: $sid, cwd: $cwd, stop_hook_active: $sha, last_assistant_message: $msg}'
}

# Write a state JSON file. $1=path, remaining key=value pairs merged via jq.
seed_state() {
    local path="$1"; shift
    local base='{session_id:"sess-1", percentage:0, threshold:"clean", checkpoint_done:false, fullsave_done:false, save_requested_at:0, save_attempts:0, pending_save_kind:"", changes_at_save:0}'
    local filter="$base"
    local args=()
    while [ "$#" -gt 0 ]; do
        local key="${1%%=*}" val="${1#*=}"
        case "$val" in
            true|false|-[0-9]*|[0-9]*)
                args+=(--argjson "$key" "$val") ;;
            *)
                args+=(--arg "$key" "$val") ;;
        esac
        filter="$filter | .$key = \$$key"
        shift
    done
    jq -n "${args[@]}" "$filter" > "$path"
}

# Read a field from a state file: state_field <path> <jq-key>
state_field() {
    jq -r "$2" "$1"
}

# Portable mtime.
mtime_of() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}
