# Changelog

All notable changes to mimo will be documented in this file.

## [Unreleased]

### Changed
- **File-based installer — single source of truth**: `install.sh` no longer embeds copies of the hooks, skills, `mimo` CLI, and uninstaller as heredocs (was ~1,530 lines, now ~310). It installs *from* the repo's source files, so each file exists exactly once. Two modes: **local** (running from a clone installs the local `hooks/`, `skills/`, `mimo`, and `uninstall.sh` with no network) and **remote** (`curl | bash` downloads the release tarball, falling back from the version tag to `main`).
- **Version stamping via `__VERSION__` placeholders**: source hooks and the `mimo` CLI carry a `__VERSION__` placeholder that the installer replaces with the release version. Run from a dev clone, the CLI falls back to the local `VERSION` file, then to `dev`.
- **Pinned self-update**: `mimo update` now runs the installer pinned to the target version (`.../v${VERSION}/install.sh`), falling back to `main` if the tag does not exist yet.
- **Generic skill install/uninstall**: the installer copies every `skills/*/` directory (no hardcoded names), so new skills need no installer changes.

### Fixed
- **Installer error checking** (audit #6): every `cp`, `chmod +x`, and version-stamp `sed` now aborts with a clear message on failure instead of continuing silently.
- **Portable in-place edits**: version stamping uses a temp-file rewrite instead of `sed -i''`, which left `*.sh-e` backup files on BSD/macOS sed.

## [1.5.0] - 2026-03-08

### Added
- **Auto-update notifications**: Session start checks for new versions once per 24 hours (background fetch, never blocks). Notifies via additionalContext when an update is available
- **`mimo update` CLI command**: Check for and install the latest version with a single command. Re-runs install.sh from GitHub
- **Installed version tracking**: `~/.claude/memory-state/mimo-installed-version` records the installed version for fast update checks

## [1.4.0] - 2026-03-08

### Fixed
- **Source hook files now use per-session state**: All source hooks (`memory-gate.sh`, `session-start.sh`, `statusline-memory.sh`, `session-end-backup.sh`) previously used a single `state.json` while installed versions used `${SESSION_ID}.json`. Source files now match installed behavior.

### Added
- **CLAUDE_ENV_FILE integration**: `session-start.sh` now exports `MIMO_SESSION_ID`, `MIMO_STATE_FILE`, `MIMO_CHANGES_LOG`, and `MIMO_CWD` via `CLAUDE_ENV_FILE`, eliminating session_id extraction boilerplate across hooks
- **SubagentStart hook** (`subagent-context.sh`): Injects "Memory — Current State" and context % into subagent context so subagents are aware of session state
- **UserPromptSubmit hook** (`user-prompt-context.sh`): On the first prompt after compaction, injects memory state and key decisions as additional context. One-shot via flag file — zero overhead on normal prompts
- **PostToolUse hook** (`track-changes.sh`): Tracks file changes (Write/Edit) in a per-session changes log. Runs async — never blocks Claude
- **Tracked files in save instructions**: Memory gate now includes list of files modified this session in checkpoint/full save instructions
- **Custom compact instructions**: PreCompact hook now outputs instructions to preserve task focus, decisions, and modified files during compaction
- **Post-compact flag**: `session-start-compact.sh` writes a flag file consumed by UserPromptSubmit hook for context recovery

### Changed
- PreCompact hook changed from async to sync (transcript backup is fast, and sync is needed for additionalContext output)
- `session-end-backup.sh` now cleans up changes log and post-compact flag files alongside session state
- `mimo status` checks 9 hooks (was 6)
- Uninstaller removes 3 new hook scripts

## [1.3.0] - 2026-02-25

### Fixed
- **Save interruption now resumes work**: After a checkpoint (50%) or full save (80%) interruption, Claude now immediately picks up the interrupted task instead of stopping and waiting for user input
- **Concurrent session isolation**: Each Claude Code session now gets its own state file (`~/.claude/memory-state/<session-id>.json`), fixing race conditions when running multiple projects simultaneously
  - Sessions no longer overwrite each other's context thresholds
  - Ending one session no longer deletes other sessions' state
  - Stop hook no longer blocks wrong sessions from stopping

### Changed
- `mimo status` now shows all active sessions with per-session context percentages
- State file cleanup uses 7-day threshold for crash orphans (safe for long-running sessions)
- Session state creation is idempotent on resume (preserves checkpoint/save flags)
- Session IDs are sanitized for safe filesystem use

## [1.2.0] - 2026-02-25

### Added
- **Manual save commands**: `/save` (checkpoint) and `/save-full` (comprehensive save) as Claude Code slash commands
- Skills installed to `~/.claude/skills/save/` and `~/.claude/skills/save-full/`
- `mimo status` now checks skill installation
- `mimo help` now lists available slash commands

## [1.1.0] - 2026-02-25

### Changed
- **One-command install**: `session-start.sh` now auto-initializes `CLAUDE.md` and `CLAUDE-FULL.md` on first session start — no need to run `mimo init` separately
- Auto-generated `CLAUDE.md` includes workflow guidance (plan mode, subagents, verification, etc.) at the top and memory sections at the bottom
- Existing `CLAUDE.md` files are preserved: workflow block prepended at top, memory sections appended at bottom (idempotent)
- `mimo init` is now an optional re-initialization/reset command
- Updated install completion message and CLI help text

### Added
- `templates/claude-md-workflow.md` — reference template for the workflow guidance block

## [1.0.0] - 2026-02-24

### Added
- Hook-based memory system with 6 hooks:
  - `statusline-memory.sh` — ANSI progress bar with context % and threshold indicators
  - `memory-gate.sh` — Stop hook that blocks exit when memory save is needed
  - `precompact-save.sh` — Backs up transcript before compaction
  - `session-start.sh` — Resets state and injects memory context on startup/resume
  - `session-start-compact.sh` — Lightweight context injection after compaction
  - `session-end-backup.sh` — Final transcript backup on session exit
- Two-tier memory architecture:
  - `CLAUDE.md` — compact index (auto-loaded by Claude Code)
  - `CLAUDE-FULL.md` — deep archive with detailed session logs
- Automatic checkpoints at 50% context usage
- Full memory save at 80% context usage
- `mimo` CLI with `init`, `status`, `version`, `uninstall` commands
- One-line installer with safe `settings.json` merging
- Idempotent install/uninstall (safe to run repeatedly)
- Coexistence with user's existing Claude Code hooks
