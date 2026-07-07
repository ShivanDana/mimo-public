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
- **Validated atomic state writes** (audit #1): every jq state-file rewrite (`statusline-memory.sh`, `memory-gate.sh`, `session-start.sh`) now goes through a `write_state` helper that writes to a temp file, verifies it is non-empty, and only then `mv`s it over the real state — a failed or empty jq leaves the previous state intact instead of clobbering it with garbage. The old fragile `.$$.tmp` pattern is gone.
- **track-changes.sh missing directory** (audit #2): `track-changes.sh` now `mkdir -p`s the state dir before appending, so a fast first edit (PostToolUse firing before SessionStart) no longer fails.
- **statusline numeric guard** (audit #3): `statusline-memory.sh` sanitizes the context percentage — a missing `.context_window` (jq emits `null`) or any non-numeric value now falls back to `0` instead of crashing `printf "%.0f"`.
- **Uninstall cleanup** (audit #5): `uninstall.sh` now removes the internal `mimo-installed-version` and `mimo-update-check` files.
- **Sanitized precompact session id**: `precompact-save.sh` now sanitizes `session_id` with `tr -cd 'a-zA-Z0-9-'` like the other hooks.

### Added
- **Smart stale-session detection**: the StatusLine hook is a heartbeat — an active session rewrites its state file every few seconds. `mimo status` now marks a session `stale (last seen Xh ago)` when its state file has no heartbeat in over 2 hours, instead of reporting every orphan as active.
- **`mimo cleanup` command**: removes stale session state triples (state + changes log + post-compact flag) with no heartbeat in 2h, reaps orphaned jq temp files older than 60 min, and prunes transcript backups older than 30 days — reporting a count per category.
- **Backup retention**: `session-end-backup.sh` prunes `~/.claude/backups/*.jsonl` and `*-precompact-summary.md` older than 30 days (`BACKUP_RETENTION_DAYS`) after each backup.
- **Identifiable backup filenames**: transcript backups now embed the first 8 chars of the session id — `${TIMESTAMP}-${SID}-end.jsonl` / `-precompact.jsonl` (falling back to `unknown`).
- **NotebookEdit change tracking**: the PostToolUse matcher is now `Write|Edit|NotebookEdit` and `track-changes.sh` reads `.tool_input.notebook_path` as well as `.file_path`.
- **`/pcompact` skill shipped with mimo**: the `pcompact` skill now lives in the repo (`skills/pcompact/`) and installs generically alongside `save`/`save-full`; `mimo status` lists it.

### Changed
- **Heartbeat-based orphan cleanup**: `session-start.sh` replaces the blunt 7-day `*.json` cleanup with a 2-hour heartbeat cleanup of state files, changes logs, and post-compact flags, plus a 60-minute cleanup of orphaned jq temp files (which the old `*.json` glob never matched).

## [1.5.0] - 2026-03-08

### Added
- **Auto-update notifications**: The `session-start.sh` hook checks GitHub for a newer version at most once every 24 hours. The check is throttled by the mtime of `~/.claude/memory-state/mimo-update-check` (a 24h TTL cache), and the actual version fetch runs as a backgrounded `curl` subshell so it never blocks session start. On the *next* session start after a successful fetch, the cached remote version is compared against the installed version and, if newer, an "Update available" line is injected via the SessionStart `additionalContext`. Nothing is installed automatically.
- **`mimo update` CLI command**: Checks the remote `VERSION`, and if it differs from the installed version, downloads and runs `install.sh` pinned to the target version tag (falling back to `main` if the tag does not exist yet). Idempotent — reports "Already up to date" when versions match.
- **Installed version tracking**: `install.sh` writes the installed version to `~/.claude/memory-state/mimo-installed-version`, which both the update-check hook and `mimo update` read to compare against the remote `VERSION`.

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
