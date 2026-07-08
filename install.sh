#!/usr/bin/env bash
# mimo installer — hook-based memory system for Claude Code
# Local mode:  git clone https://github.com/ShivanDana/mimo && bash mimo/install.sh
# Remote mode: curl -fsSL https://raw.githubusercontent.com/ShivanDana/mimo/main/install.sh | bash
#
# The installer copies mimo's source files (hooks/, skills/, mimo, uninstall.sh)
# into ~/.claude and ~/.local/bin. The repo files are the single source of truth;
# nothing is embedded here except the settings.json hook registration (config).
# shellcheck disable=SC2059  # color codes in printf formats are intentional
# shellcheck disable=SC2015  # `cmd && ok || { error; exit; }` chains abort on ANY failure by design
set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${GREEN}[mimo]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[mimo]${NC} %s\n" "$1"; }
error() { printf "${RED}[mimo]${NC} %s\n" "$1" >&2; }
step()  { printf "${BOLD}[%s/7]${NC} %s\n" "$1" "$2"; }

REPO_RAW="https://raw.githubusercontent.com/ShivanDana/mimo"
REPO_ARCHIVE="https://github.com/ShivanDana/mimo/archive/refs"

# ─── Locate source files: local clone or remote tarball ─────────────────────────
# When run from a clone, $BASH_SOURCE points at this script; when piped via
# curl | bash it is unset and $0 is "bash", so fall back and rely on the
# hooks/ + VERSION existence check to distinguish the two modes.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")

SRC_DIR=""
if [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/hooks" ] && [ -f "$SCRIPT_DIR/VERSION" ]; then
    # ── Local mode: install from the clone, no network access ──
    SRC_DIR="$SCRIPT_DIR"
    MIMO_VERSION=$(tr -d '[:space:]' < "$SRC_DIR/VERSION")
    if [ -z "$MIMO_VERSION" ]; then
        error "Local VERSION file is empty."
        exit 1
    fi
    info "Local install from $SRC_DIR (v${MIMO_VERSION})"
else
    # ── Remote mode: fetch VERSION, download + extract the release tarball ──
    info "Fetching mimo from GitHub..."
    MIMO_VERSION=$(curl -fsSL "$REPO_RAW/main/VERSION" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$MIMO_VERSION" ]; then
        error "Could not fetch version. Check your network connection."
        exit 1
    fi

    TMP_SRC=$(mktemp -d)
    trap 'rm -rf "$TMP_SRC"' EXIT
    TARBALL="$TMP_SRC/mimo.tar.gz"

    # Prefer the version tag; fall back to main if the tag does not exist yet.
    if ! curl -fsSL "$REPO_ARCHIVE/tags/v${MIMO_VERSION}.tar.gz" -o "$TARBALL" 2>/dev/null; then
        curl -fsSL "$REPO_ARCHIVE/heads/main.tar.gz" -o "$TARBALL" 2>/dev/null \
            || { error "Could not download mimo source."; exit 1; }
    fi

    tar -xzf "$TARBALL" -C "$TMP_SRC" || { error "Could not extract mimo source."; exit 1; }

    # The tarball unpacks to a single top-level dir (mimo-<version> or mimo-main).
    SRC_DIR=$(find "$TMP_SRC" -maxdepth 1 -mindepth 1 -type d | head -1 || true)
    if [ -z "$SRC_DIR" ] || [ ! -d "$SRC_DIR/hooks" ]; then
        error "Downloaded source is missing hooks/."
        exit 1
    fi
    info "Downloaded mimo v${MIMO_VERSION}"
fi

# ─── Install target paths ──────────────────────────────────────────────────────
HOOKS_DIR="$HOME/.claude/hooks"
STATE_DIR="$HOME/.claude/memory-state"
BACKUP_DIR="$HOME/.claude/backups"
SETTINGS_FILE="$HOME/.claude/settings.json"
SKILLS_DIR="$HOME/.claude/skills"
TEMPLATES_DIR="$HOME/.claude/mimo-templates"
MIMO_CONF="$HOME/.claude/mimo.conf"
CLI_DIR="$HOME/.local/bin"

# ─── Step 1: Preflight checks ────────────────────────────────────────────────
step 1 "Preflight checks"

if ! command -v jq &>/dev/null; then
    error "jq is required but not installed."
    echo ""
    echo "Install jq:"
    echo "  macOS:  brew install jq"
    echo "  Ubuntu: sudo apt-get install jq"
    echo "  Other:  https://jqlang.github.io/jq/download/"
    exit 1
fi

BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
if [ "$BASH_MAJOR" -lt 3 ]; then
    error "bash 3.2+ required (found ${BASH_VERSION:-unknown})"
    exit 1
fi

if [ ! -d "$HOME/.claude" ]; then
    error "\$HOME/.claude/ not found. Install Claude Code first: https://docs.anthropic.com/en/docs/claude-code"
    exit 1
fi

info "jq $(jq --version 2>&1 | tr -d 'jq-'), bash ${BASH_VERSION}, ~/.claude/ exists"

# ─── Step 2: Install hook scripts ────────────────────────────────────────────
step 2 "Installing hook scripts"

mkdir -p "$HOOKS_DIR" "$STATE_DIR" "$BACKUP_DIR"

HOOK_COUNT=0
for src in "$SRC_DIR"/hooks/*.sh; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    dest="$HOOKS_DIR/$name"
    cp "$src" "$dest" || { error "Failed to copy hook $name."; exit 1; }
    # Stamp version via temp file (portable across GNU and BSD/macOS sed).
    sed "s/__VERSION__/${MIMO_VERSION}/g" "$dest" > "${dest}.tmp" \
        && mv "${dest}.tmp" "$dest" \
        || { error "Failed to stamp version into $name."; rm -f "${dest}.tmp"; exit 1; }
    chmod +x "$dest" || { error "Failed to make $name executable."; exit 1; }
    HOOK_COUNT=$((HOOK_COUNT + 1))
done

info "Installed $HOOK_COUNT hooks to $HOOKS_DIR"

# ─── Step 3: Install skills (slash commands) ────────────────────────────────
step 3 "Installing skills (slash commands)"

mkdir -p "$SKILLS_DIR"

SKILL_LIST=""
for skdir in "$SRC_DIR"/skills/*/; do
    [ -d "$skdir" ] || continue
    skname=$(basename "$skdir")
    mkdir -p "$SKILLS_DIR/$skname"
    cp -R "$skdir." "$SKILLS_DIR/$skname/" || { error "Failed to copy skill /$skname."; exit 1; }
    SKILL_LIST="$SKILL_LIST /$skname"
done

info "Installed skills:$SKILL_LIST"

# ─── Step 4: Install templates + config ──────────────────────────────────────
step 4 "Installing templates + config"

# Templates are mimo-managed (session-start.sh and `mimo init` read CLAUDE.md
# scaffolding from here). Always refresh — updates should ship new template text.
if [ -d "$SRC_DIR/templates" ]; then
    mkdir -p "$TEMPLATES_DIR"
    TPL_COUNT=0
    for tpl in "$SRC_DIR"/templates/*; do
        [ -f "$tpl" ] || continue
        tname=$(basename "$tpl")
        # mimo.conf is the user config seed, not a runtime template — skip it here.
        [ "$tname" = "mimo.conf" ] && continue
        cp "$tpl" "$TEMPLATES_DIR/$tname" || { error "Failed to copy template $tname."; exit 1; }
        TPL_COUNT=$((TPL_COUNT + 1))
    done
    info "Installed $TPL_COUNT templates to $TEMPLATES_DIR"
else
    warn "No templates/ in source — hooks will use built-in fallbacks"
fi

# User config: seed from the template ONLY when absent — never clobber a
# user-edited config. The file is fully commented (all defaults), so a fresh
# install changes no behavior until the user uncomments a key.
if [ ! -f "$MIMO_CONF" ]; then
    if [ -f "$SRC_DIR/templates/mimo.conf" ]; then
        cp "$SRC_DIR/templates/mimo.conf" "$MIMO_CONF" \
            || { error "Failed to create $MIMO_CONF."; exit 1; }
        info "Created config template at $MIMO_CONF"
    else
        warn "templates/mimo.conf missing — skipping config seed"
    fi
else
    info "Config exists at $MIMO_CONF (preserved)"
fi

# ─── Step 5: Merge settings.json ─────────────────────────────────────────────
step 5 "Configuring settings.json"

# Define mimo's hook configuration as JSON
MIMO_HOOKS=$(cat <<'MJSON'
{
  "SessionStart": [
    {
      "matcher": "startup|resume",
      "hooks": [
        {"type": "command", "command": "bash ~/.claude/hooks/session-start.sh", "timeout": 10}
      ]
    },
    {
      "matcher": "compact",
      "hooks": [
        {"type": "command", "command": "bash ~/.claude/hooks/session-start-compact.sh", "timeout": 10}
      ]
    }
  ],
  "Stop": [
    {
      "hooks": [
        {"type": "command", "command": "bash ~/.claude/hooks/memory-gate.sh", "timeout": 10}
      ]
    }
  ],
  "PreCompact": [
    {
      "hooks": [
        {"type": "command", "command": "bash ~/.claude/hooks/precompact-save.sh", "timeout": 30}
      ]
    }
  ],
  "SessionEnd": [
    {
      "hooks": [
        {"type": "command", "command": "bash ~/.claude/hooks/session-end-backup.sh", "async": true, "timeout": 30}
      ]
    }
  ],
  "SubagentStart": [
    {
      "hooks": [
        {"type": "command", "command": "bash ~/.claude/hooks/subagent-context.sh", "timeout": 5}
      ]
    }
  ],
  "UserPromptSubmit": [
    {
      "hooks": [
        {"type": "command", "command": "bash ~/.claude/hooks/user-prompt-context.sh", "timeout": 5}
      ]
    }
  ],
  "PostToolUse": [
    {
      "matcher": "Write|Edit|NotebookEdit",
      "hooks": [
        {"type": "command", "command": "bash ~/.claude/hooks/track-changes.sh", "async": true, "timeout": 5}
      ]
    }
  ]
}
MJSON
)

MIMO_STATUSLINE='{"type": "command", "command": "bash ~/.claude/hooks/statusline-memory.sh"}'

if [ ! -f "$SETTINGS_FILE" ]; then
    # Fresh install — create settings with only mimo entries
    echo "$MIMO_HOOKS" | jq --argjson sl "$MIMO_STATUSLINE" \
        '{statusLine: $sl, hooks: .}' > "$SETTINGS_FILE"
    info "Created $SETTINGS_FILE"
else
    # Backup existing settings
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.mimo-backup"
    info "Backed up settings to settings.json.mimo-backup"

    # Check for non-mimo statusLine
    EXISTING_SL=$(jq -r '.statusLine.command // ""' "$SETTINGS_FILE" 2>/dev/null || echo "")
    if [ -n "$EXISTING_SL" ] && ! echo "$EXISTING_SL" | grep -q '/.claude/hooks/'; then
        warn "Replacing existing statusLine: $EXISTING_SL (backup preserved)"
    fi

    # Merge: remove old mimo hooks, append new ones, set statusLine
    jq --argjson mimo "$MIMO_HOOKS" --argjson sl "$MIMO_STATUSLINE" '
        # Filter out mimo hook groups from an array
        def remove_mimo: [.[]? | select((.hooks // []) | any(.command // "" | contains("/.claude/hooks/")) | not)];

        # Ensure .hooks exists
        .hooks //= {} |

        # For each event type: remove old mimo hooks, append new ones
        .hooks.SessionStart = ((.hooks.SessionStart // []) | remove_mimo) + $mimo.SessionStart |
        .hooks.Stop = ((.hooks.Stop // []) | remove_mimo) + $mimo.Stop |
        .hooks.PreCompact = ((.hooks.PreCompact // []) | remove_mimo) + $mimo.PreCompact |
        .hooks.SessionEnd = ((.hooks.SessionEnd // []) | remove_mimo) + $mimo.SessionEnd |
        .hooks.SubagentStart = ((.hooks.SubagentStart // []) | remove_mimo) + $mimo.SubagentStart |
        .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) | remove_mimo) + $mimo.UserPromptSubmit |
        .hooks.PostToolUse = ((.hooks.PostToolUse // []) | remove_mimo) + $mimo.PostToolUse |

        # Set statusLine
        .statusLine = $sl
    ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"

    # Validate output is valid JSON before replacing
    if jq empty "${SETTINGS_FILE}.tmp" 2>/dev/null; then
        mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
        info "Merged hooks into existing settings (user settings preserved)"
    else
        error "Merge produced invalid JSON. Restoring backup."
        mv "${SETTINGS_FILE}.mimo-backup" "$SETTINGS_FILE"
        rm -f "${SETTINGS_FILE}.tmp"
        exit 1
    fi
fi

# ─── Step 6: Install mimo CLI + uninstaller ──────────────────────────────────
step 6 "Installing mimo CLI"

mkdir -p "$CLI_DIR"

cp "$SRC_DIR/mimo" "$CLI_DIR/mimo" || { error "Failed to copy mimo CLI."; exit 1; }
# Stamp version via temp file (portable across GNU and BSD/macOS sed).
sed "s/__VERSION__/${MIMO_VERSION}/g" "$CLI_DIR/mimo" > "$CLI_DIR/mimo.tmp" \
    && mv "$CLI_DIR/mimo.tmp" "$CLI_DIR/mimo" \
    || { error "Failed to stamp version into mimo CLI."; rm -f "$CLI_DIR/mimo.tmp"; exit 1; }
chmod +x "$CLI_DIR/mimo" || { error "Failed to make mimo CLI executable."; exit 1; }

cp "$SRC_DIR/uninstall.sh" "$CLI_DIR/mimo-uninstall" \
    || { error "Failed to copy uninstaller."; exit 1; }
chmod +x "$CLI_DIR/mimo-uninstall" \
    || { error "Failed to make uninstaller executable."; exit 1; }

info "Installed mimo CLI to $CLI_DIR/mimo"

# Check if ~/.local/bin is in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -q "$HOME/.local/bin"; then
    echo ""
    warn "\$HOME/.local/bin is not in your PATH. Add it:"
    echo ""
    echo "  # Add to your ~/.zshrc or ~/.bashrc:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

# ─── Step 7: Done ────────────────────────────────────────────────────────────
step 7 "Installation complete"

# Record installed version for update checks
mkdir -p "$STATE_DIR"
echo "$MIMO_VERSION" > "$STATE_DIR/mimo-installed-version" \
    || { error "Failed to record installed version."; exit 1; }

echo ""
printf "${BOLD}${GREEN}mimo v${MIMO_VERSION} installed successfully!${NC}\n"
echo ""
echo "Next steps:"
echo "  1. cd into your project directory"
echo "  2. Start a Claude Code session — mimo auto-initializes your project"
echo ""
echo "Commands:"
echo "  mimo status     — check installation health"
echo "  mimo init       — re-initialize memory files in current project"
echo "  mimo update     — check for and install the latest version"
echo "  mimo uninstall  — remove mimo"
echo ""
echo "Slash commands (inside Claude Code):"
echo "  /save           — quick checkpoint"
echo "  /save-full      — full memory save"
echo "  /pcompact       — generate context-preserving /compact instructions"
echo ""
