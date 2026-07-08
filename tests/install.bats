#!/usr/bin/env bats
# install.sh / uninstall.sh — local-mode sandbox install, idempotency,
# settings preservation, uninstall.

load helpers

setup() {
    mimo_setup
    INSTALL="$MIMO_REPO_ROOT/install.sh"
    UNINSTALL="$MIMO_REPO_ROOT/uninstall.sh"
    HOOKS_DIR="$HOME/.claude/hooks"
    SETTINGS="$HOME/.claude/settings.json"
    CLI="$HOME/.local/bin/mimo"
    VERSION="$(cat "$MIMO_REPO_ROOT/VERSION")"
    # $HOME/.claude already created by mimo_setup (installer preflight requires it).
}
teardown() { mimo_teardown; }

@test "install: local-mode install is complete" {
    run bash "$INSTALL"
    [ "$status" -eq 0 ]
    # 9 hook scripts, all executable.
    [ "$(find "$HOOKS_DIR" -name '*.sh' | wc -l | tr -d ' ')" -eq 9 ]
    for h in "$HOOKS_DIR"/*.sh; do [ -x "$h" ]; done
    # settings.json valid, statusLine + hooks registered.
    jq empty "$SETTINGS"
    [ -n "$(jq -r '.statusLine.command' "$SETTINGS" | grep statusline-memory.sh)" ]
    [ "$(jq '[.hooks[][]?.hooks[]?] | length' "$SETTINGS")" -ge 8 ]
    # CLI + uninstaller + skills + templates + config + version file.
    [ -x "$CLI" ]
    [ -x "$HOME/.local/bin/mimo-uninstall" ]
    [ -f "$HOME/.claude/skills/save/SKILL.md" ]
    [ -f "$HOME/.claude/mimo-templates/claude-md-memory-sections.md" ]
    [ -f "$HOME/.claude/mimo.conf" ]
    [ "$(cat "$HOME/.claude/memory-state/mimo-installed-version")" = "$VERSION" ]
}

@test "install: no __VERSION__ literals survive in installed hooks or CLI" {
    run bash "$INSTALL"
    [ "$status" -eq 0 ]
    ! grep -rq '__VERSION__' "$HOOKS_DIR"
    ! grep -q '__VERSION__' "$CLI"
    # Version was stamped into the hook headers.
    grep -q "mimo v${VERSION}" "$HOOKS_DIR/memory-gate.sh"
}

@test "install: is idempotent (second run keeps a single set of hooks)" {
    run bash "$INSTALL"; [ "$status" -eq 0 ]
    run bash "$INSTALL"; [ "$status" -eq 0 ]
    jq empty "$SETTINGS"
    [ "$(find "$HOOKS_DIR" -name '*.sh' | wc -l | tr -d ' ')" -eq 9 ]
    # Exactly one Stop entry pointing at memory-gate (no duplicate merge).
    [ "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command | contains("memory-gate.sh"))] | length' "$SETTINGS")" -eq 1 ]
}

@test "install: preserves the user's own settings" {
    jq -n '{
        model: "opus",
        hooks: {
            PreToolUse: [{matcher:"Bash", hooks:[{type:"command", command:"echo user-pretool"}]}],
            Stop: [{hooks:[{type:"command", command:"echo user-stop"}]}]
        }
    }' > "$SETTINGS"
    run bash "$INSTALL"
    [ "$status" -eq 0 ]
    # User's unrelated settings + hooks survive.
    [ "$(jq -r '.model' "$SETTINGS")" = "opus" ]
    jq -e '.hooks.PreToolUse[0].hooks[0].command == "echo user-pretool"' "$SETTINGS"
    # User's non-mimo Stop hook coexists with mimo's.
    jq -e '[.hooks.Stop[]?.hooks[]?.command] | any(. == "echo user-stop")' "$SETTINGS"
    jq -e '[.hooks.Stop[]?.hooks[]?.command] | any(contains("memory-gate.sh"))' "$SETTINGS"
}

@test "uninstall: removes hooks + statusLine, preserves data and user settings" {
    jq -n '{model:"opus", hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:"echo keep-me"}]}]}}' > "$SETTINGS"
    run bash "$INSTALL"; [ "$status" -eq 0 ]
    # Seed user data that must survive.
    printf 'CHECKPOINT_THRESHOLD=42\n' >> "$HOME/.claude/mimo.conf"
    printf '{}\n' > "$HOME/.claude/backups/keep.jsonl"

    run bash "$UNINSTALL"
    [ "$status" -eq 0 ]
    # Hooks gone, templates gone, CLI gone.
    [ "$(find "$HOOKS_DIR" -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]
    [ ! -d "$HOME/.claude/mimo-templates" ]
    [ ! -f "$CLI" ]
    # settings.json cleaned of mimo, user hook + model preserved.
    jq empty "$SETTINGS"
    [ "$(jq -r '.statusLine.command // "gone"' "$SETTINGS")" = "gone" ]
    jq -e '.hooks.PreToolUse[0].hooks[0].command == "echo keep-me"' "$SETTINGS"
    [ "$(jq -r '.model' "$SETTINGS")" = "opus" ]
    # User data preserved.
    grep -q "CHECKPOINT_THRESHOLD=42" "$HOME/.claude/mimo.conf"
    [ -f "$HOME/.claude/backups/keep.jsonl" ]
}

@test "e2e: doctor passes after a clean install" {
    run bash "$INSTALL"; [ "$status" -eq 0 ]
    # Put ~/.local/bin on PATH so even the PATH check is clean.
    PATH="$HOME/.local/bin:$PATH" run bash "$CLI" doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"all checks passed"* ]]
}
