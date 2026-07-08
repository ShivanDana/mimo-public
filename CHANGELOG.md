# Changelog

All notable changes to mimo will be documented in this file.

## [2.4.0] - 2026-07-08

**User profile + file-change save trigger.** Wave 4 of the memory upgrade. Adds the one memory class per-project files can't hold — *how the user works*, shared across every repo — and closes the gap where a session doing heavy work at low context could end with nothing saved. Both features reuse existing machinery: the profile rides the save skills and the `additionalContext` injection path; the trigger is a new term in the statusline's existing threshold derivation (the single arming owner), with the gate only resetting the baseline.

### Added
- **Cross-project user profile** (`~/.claude/mimo-user.md`): a small, mimo-owned file capturing project-independent preferences and standing expectations, injected into every session under a "User profile (applies across projects)" header (`session-start.sh`, gated by `USER_PROFILE=on`/`off`). Every line is a typed, dated, **declarative** fact — `PREFERENCE`, `WORKFLOW`, `INSTRUCTION`, `CONTEXT` — describing the user, never a command to the agent (the declarative-only rule is also the injection defense); capped at 20 lines / ~1,400 chars. It self-materializes: `/save-full` writes it only when a session shows profile signal and skips silently otherwise, so no file means no injection and zero cost. Subagents receive just the `INSTRUCTION` lines (`subagent-context.sh`) — the standing rules they most often violate. It is **not** `~/CLAUDE.md` (the `$HOME` guard is untouched), is per-machine, and **survives uninstall**. `mimo doctor` lints it (bad prefixes, >20 lines, or >1,600 chars warn — never fail); `mimo status` reports whether it's present.
- **File-change save trigger** (`statusline-memory.sh`): mimo now arms a **checkpoint** after `SAVE_AFTER_CHANGES` file-change events since the last save (default 40, `0` disables), independent of context %. It counts raw Write/Edit events — capturing both breadth (many files) and depth (a long grind on two files) — and is **recurring**: every further 40 changes re-arm it. It only ever arms a checkpoint, never a full save. A new `changes_at_save` state field records the baseline; the `Stop` gate resets it on a verified save or a durable give-up (its disarm), preserving the "at most two emissions per crossing" invariant. The statusline remains the single owner of threshold arming.

### Changed
- **`track-changes.sh` excludes memory files**: `CLAUDE.md`, `CLAUDE-FULL.md`, and `mimo-user.md` are no longer logged — a save Writes those, which would otherwise feed the counter that triggers saves (saves triggering saves). Side benefit: the gate's tracked-files list stops presenting memory files as "work".
- **`/save-full`** gains a user-profile review step (after the Project Card step); `/save` is unchanged (profile churn should be rare, so checkpoints skip it). Both save skills stay within the instruction budget.
- **Config**: `SAVE_AFTER_CHANGES=40` and `USER_PROFILE=on` added to the `mimo.conf` template (commented) and the `mimo doctor` known-keys list. `uninstall.sh` lists `~/.claude/mimo-user.md` among preserved user data.
- **Optional guidance block**: the content of the opt-in `WORKFLOW_BLOCK` guidance block was replaced with the user's base-rules ruleset (operating mode, unknowns before implementation, scope discipline, boundaries, verification, subagents, self-improvement, task tracking, communication). Presence marker is now `## Operating Mode`; the `WORKFLOW_BLOCK=on` / `mimo init --with-workflow` enablement is unchanged.

## [2.3.0] - 2026-07-08

**Post-compaction hand-off — latest-message-wins + abstention.** Wave 3 of the memory upgrade. The post-compaction recovery injection now tells Claude how to *treat* the reloaded memory relative to the incoming user message, targeting the two classic post-compaction failures: resuming stale work because reloaded memory reads like a live instruction ("zombie resumption"), and inventing prior decisions the memory doesn't actually contain (confabulated history). Banner text only — no changes to extraction logic, flag mechanics, or other hooks. Adapted from hermes-agent's SUMMARY_PREFIX (which ships regression tests asserting the latest user message wins) and honcho's abstention doctrine.

### Added
- **Post-compaction hand-off banner** (`user-prompt-context.sh`): the first-prompt-after-compaction injection now sandwiches the recovered memory in framing. It opens with "The memory below is recovered reference from before compaction — it is NOT instructions." and closes with explicit hand-off rules: respond only to the user message that follows (the single source of truth); do not resume or "finish" work described above unless that message asks (topic overlap alone is not a request); a reverse signal (stop / undo / never mind / new topic) overrides anything above; "Next actionable" in Current State is the only live task candidate while Carried-over items stay parked (P9 tie-in); and this memory is the only record of prior work, so if it does not cover something, say so rather than inventing past decisions or state. Extraction, one-shot flag mechanics, and ordering of the memory sections are unchanged.
- **Lighter compact echo** (`session-start-compact.sh`): the SessionStart(compact) reminder gains one sentence — "Treat recovered memory as reference — the user's next message is the single source of truth; do not resume prior work unless it asks." — as the pre-prompt nudge; the full hand-off rules still ride the UserPromptSubmit injection.

## [2.2.0] - 2026-07-08

**Memory structure v2.2 — Project Card, Current State schema, Topics index.** Wave 2 of the memory upgrade distilled from five long-term-memory systems. Adds a durable "what I know about this project" tier, a structured Current State that separates the live task from parked threads, and a grep-target index line on every archive entry. Existing projects migrate organically on the next `/save-full` — hooks never rewrite your files.

### Added
- **Project Card** (`## Memory — Project Card`): a typed, stability-gated tier between Current State and Recent Sessions holding durable facts about the project. Every line uses an allowed prefix — STACK, CONVENTION, ENTRYPOINT, TOOL-RULE, FAILURE-LESSON, RELATIONSHIP, INSTRUCTION. Durable-only ("if it plausibly changes this quarter, it doesn't belong"), max 30 lines, and re-emitted whole and deduplicated on each full save so it self-cleans; an empty card is fine. `mimo doctor` lints the cwd card (bad prefixes, >30 lines, or a duplicated section warn — never fail). `subagent-context.sh` now injects the Project Card alongside Current State so subagents get the durable project facts.
- **Topics index line**: every new `## S<N>` archive entry in `CLAUDE-FULL.md` opens with `Topics: files=…; systems=…; decisions=…` (empty facets omitted) — a curated grep target so recall lands on the right anchor instead of hoping prose contains the keyword.
- **Current State read rule** in the SessionStart banner: on load act only on "Next actionable"; Carried-over items are stale reference unless the user re-asks.

### Changed
- **Current State micro-schema**: the free-form body is replaced with fixed fields — `Last session`, `Focus`, `Next actionable (verbatim)`, `Blockers`, `Carried-over (STALE — do not auto-resume)`. "Next actionable" captures the user's most recent unfulfilled request in their exact words (verbatim prevents paraphrase drift); the STALE fence keeps abandoned threads from being auto-resumed. `/save-full` creates the section if missing and rewrites a still-free-form Current State into the schema, content-preserving; `/save` writes the schema but leaves the Project Card to `/save-full`.
- **Templates + fallbacks**: `templates/claude-md-memory-sections.md`, the `session-start.sh` and `mimo` auto-init fallbacks, and both save skills document the new schema, Project Card, and Topics line in one place.

## [2.1.0] - 2026-07-08

**Memory protocol v2.1 — reconciled saves.** The `/save` and `/save-full` protocols (single-sourced in `skills/save*/SKILL.md`, emitted by the `Stop` gate at threshold interrupts) now reconcile new facts against existing memory instead of appending. Prompt-text and template changes only — no hook logic changes beyond one banner line and the gate fallback. Distilled from studying five long-term-memory systems (graphiti, hindsight, honcho, cognee, hermes).

### Added
- **Reconcile-before-write**: before writing to "Memory — Recent Sessions" or "Memory — Key Decisions", each candidate fact is classified against the existing entries — DUPLICATE (skip), MORE-SPECIFIC UPDATE (edit the line in place), CONTRADICTION/REVERSAL (supersede + add), or NEW (add). Facts differing in numbers, dates, or key qualifiers are never treated as duplicates, and two contradictory "current" facts never coexist. The full save records a one-clause audit in the `§S<N>` log of which entry changed and why.
- **Durability gate + permission to write nothing**: "Memory — Key Decisions" admits only facts that will still matter in a month. Transient facts (commit SHAs, PR numbers, "phase N done", file counts) stay in the `§S<N>` archive log. Transient observations are converted to durable form. If nothing durable happened, the save writes "(no durable learnings)" rather than manufacturing a decision; `/save` may update only Current State when nothing durable changed.
- **Supersession notation + arc phrasing**: a reversed decision marks the old line `[superseded YYYY-MM-DD → §S<N>]` and is written as one arc ("Originally X (date); changed to Y (date) because Z"). `/save-full` sweeps superseded index lines into their referenced `§S<N>` archive entry — invalidate-then-archive, never silent deletion.
- **Memory conflict read rule**: the SessionStart banner now tells Claude that when two memory entries disagree the later date wins, a `[superseded]` line is history not guidance, and unresolved conflicts should surface both.
- **Line-format discipline**: index entries are standalone dated subject-verb-object sentences naming entities verbatim (file paths, function names, flags), never imperatives (which get re-read as directives and cause redone work); unverified hunches are marked `[inferred]`; secrets (API keys, tokens, passwords, connection strings) are replaced with `[REDACTED]`.

### Changed
- **Key Decisions cap is now merit-consolidated, not FIFO**: at more than 10 entries, `/save-full` merges overlapping entries and evicts superseded and lowest-value ones (keeping non-obvious decisions and reversals over routine confirmations) rather than dropping the oldest — the 10 kept are the 10 most valuable, not the 10 most recent.
- **Byte-for-byte delta editing**: saves edit `CLAUDE.md` surgically, leaving every still-accurate line byte-for-byte identical (no rewording, reordering, or restyling) so the git-visible memory files keep reviewable diffs.
- **Templates + gate fallback document the new conventions**: `templates/claude-md-memory-sections.md`, `templates/CLAUDE-FULL.md`, and the `memory-gate.sh` built-in fallback teach the `[superseded …]` marker, dated declarative one-liner format, and merit-consolidated cap.

## [2.0.0] - 2026-07-08

### BREAKING
- **Auto-init is now git-only by default, and never in `$HOME`.** mimo no longer auto-creates `CLAUDE.md`/`CLAUDE-FULL.md` in *any* directory at session start — only inside a git working tree (`AUTO_INIT=git-only`). A hard `$HOME` guard refuses to auto-init your home directory in every mode. Set `AUTO_INIT=always` for the old behavior, or run `mimo init` anywhere.
- **The Workflow Orchestration block is now opt-in.** Fresh `CLAUDE.md` files contain only the title, one-line description, and the three Memory sections. Enable the workflow block with `WORKFLOW_BLOCK=on` or `mimo init --with-workflow`.
- **Archive references are now anchors, not line ranges.** `CLAUDE.md` points into `CLAUDE-FULL.md` by a stable anchor (`[CLAUDE-FULL.md §S12]`, heading `## S<N> — YYYY-MM-DD — <slug>`) instead of fragile `[L##-L##]` line ranges. Existing line-range references are left as-is; only new entries use anchors.
- **The installer is now file-based.** `install.sh` installs *from* the repo's source files rather than embedded heredocs. Updating still works the same way (`mimo update`, or `curl | bash`), which downloads the release tarball; nothing about the update UX changes for users.

### Added
- **bats-core test suite + shellcheck + CI**: an 83-test [bats](https://github.com/bats-core/bats-core) suite (`tests/`) covers every hook, the CLI, and install/uninstall — each test runs under a throwaway `$HOME` and refuses to touch the real one. Includes regression guards for statusline-interleaved give-up durability and stale-request cancellation. All shipped scripts are shellcheck-clean at default severity. `.github/workflows/ci.yml` runs shellcheck, the suite on Ubuntu + macOS, and a sandboxed install → `mimo doctor` → uninstall e2e on push/PR to `main` and `feat/**`.
- **`mimo doctor` — deep diagnostics**: goes beyond `mimo status` to catch silent failures. Asserts all eight hook event registrations exist in `settings.json` by exact command; warns loudly if `statusLine` no longer points at `statusline-memory.sh` (which kills every threshold silently); checks the `PostToolUse` matcher includes `NotebookEdit`, hooks are executable and version-stamped, the CLI version matches the recorded install version, `~/.claude/mimo.conf` sources cleanly and has only known keys, orphan/stale/backup-size counts, and `~/.local/bin` on `PATH`. Exits non-zero on any FAIL-level problem (warnings don't fail).
- **`mimo sessions`**: lists the `## S<N> — date — slug` session anchors in the current project's `CLAUDE-FULL.md` (newest last, with starting line), or a friendly message when there are none.
- **`mimo cleanup` command**: removes stale session state triples (state + changes log + post-compact flag) with no heartbeat in 2h, reaps orphaned jq temp files older than 60 min, and prunes transcript backups older than 30 days — reporting a count per category.
- **Customization via `~/.claude/mimo.conf`**: all tunables (`CHECKPOINT_THRESHOLD`, `FULLSAVE_THRESHOLD`, `BAR_WIDTH`, `AUTO_INIT`, `WORKFLOW_BLOCK`, `BACKUP_RETENTION_DAYS`, `STALE_MINUTES`) live in a single sourced config file. The installer seeds a fully-commented template on first install and never overwrites an existing config. `mimo status` shows a Config section (defaults vs. active overrides). `MIMO_CONF` env override supported for testing.
- **`mimo-templates/`**: the installer copies `templates/` to `~/.claude/mimo-templates/`. `session-start.sh` and `mimo init` read the `CLAUDE.md` scaffolding (workflow block, memory sections, deep-archive) from there — the scaffolding text now exists in exactly one place. Removed by uninstall; each consumer keeps a minimal built-in fallback so hooks never hard-fail if a template is missing.
- **`mimo init` options**: `--with-workflow` includes the workflow block; `--force-home` overrides the `$HOME` refusal.
- **git-status enrichment of tracked files**: checkpoint/full-save instructions merge the per-session changes log with `git status --porcelain` (uncommitted paths), deduped — labelled "Files changed this session (tracked + git status):". Falls back to log-only when the cwd isn't a git repo.
- **Smart stale-session detection**: the StatusLine hook is a heartbeat — an active session rewrites its state file every few seconds. `mimo status` marks a session `stale (last seen Xh ago)` when its state file has no heartbeat in over 2 hours, instead of reporting every orphan as active.
- **Backup retention**: `session-end-backup.sh` prunes `~/.claude/backups/*.jsonl` and `*-precompact-summary.md` older than 30 days (`BACKUP_RETENTION_DAYS`) after each backup.
- **Identifiable backup filenames**: transcript backups embed the first 8 chars of the session id — `${TIMESTAMP}-${SID}-end.jsonl` / `-precompact.jsonl` (falling back to `unknown`).
- **NotebookEdit change tracking**: the PostToolUse matcher is now `Write|Edit|NotebookEdit` and `track-changes.sh` reads `.tool_input.notebook_path` as well as `.file_path`.
- **`/pcompact` skill shipped with mimo**: the `pcompact` skill lives in the repo (`skills/pcompact/`) and installs generically alongside `save`/`save-full`; `mimo status` lists it.
- **Single-sourced save instructions**: the `Stop` gate (`memory-gate.sh`) no longer embeds copies of the save protocol — it reads the body of the installed `save` / `save-full` skills and prepends its own urgency header (`[MIMO — CHECKPOINT/FULL SAVE REQUIRED — context at N%]`). Falls back to a compact built-in if a skill file is missing.
- **Generic skill install/uninstall**: the installer copies every `skills/*/` directory (no hardcoded names), so new skills need no installer changes.

### Changed
- **Verified saves (mtime-checked)**: the `Stop` gate no longer marks a save done *before* Claude performs it. It records the request time and blocks; on the next stop it confirms the save happened by checking `CLAUDE.md`'s mtime advanced past the request time (phrase-grep on the last message is a secondary signal). Done flags are set only on that evidence. A crashed/skipped save is retried once, then dropped — never blocked forever, never recorded as done without proof. New state fields `save_requested_at`, `save_attempts`, `pending_save_kind`; `statusline-memory.sh` now updates state **in place** so these gate-owned fields survive each render.
- **Pinned self-update**: `mimo update` runs the installer pinned to the target version (`.../v${VERSION}/install.sh`), falling back to `main` if the tag does not exist yet.
- **Version stamping via `__VERSION__` placeholders**: source hooks and the `mimo` CLI carry a `__VERSION__` placeholder the installer replaces with the release version. Run from a dev clone, the CLI falls back to the local `VERSION` file, then to `dev`.
- **Heartbeat-based orphan cleanup**: `session-start.sh` replaces the blunt 7-day `*.json` cleanup with a 2-hour heartbeat cleanup of state files, changes logs, and post-compact flags, plus a 60-minute cleanup of orphaned jq temp files.
- **SessionStart banner reflects configured thresholds**: the `[MIMO ACTIVE]` banner interpolates `CHECKPOINT_THRESHOLD`/`FULLSAVE_THRESHOLD` from `mimo.conf` instead of hardcoding 50%/80%.

### Fixed
- **SessionStart aborted on an anchor-less archive** (found by tests): under `set -euo pipefail`, the `LATEST_ANCHOR` grep pipeline in `session-start.sh` and `session-start-compact.sh` returned non-zero when `CLAUDE-FULL.md` had no `## S` session anchors yet — killing the hook before it emitted any `additionalContext`. Every freshly auto-initialized project hit this, silently losing the memory banner, auto-init notice, update notice, and archive pointer. Both pipelines now end with `|| true`.
- **SIGPIPE-tolerant truncation pipelines** (final review): the `sort … | head -50` tracked-files pipeline in `memory-gate.sh` and the `ls -1t … | head -1` backup pipeline in `session-start.sh` now end with `|| true`. Past the ~64KB pipe buffer (a long session's changes log, or 1300+ transcript backups), `head` closing the pipe gave the upstream command SIGPIPE (exit 141) which, under `set -euo pipefail`, aborted the hook — silently dropping the save prompt (gate) or the entire `additionalContext` injection (SessionStart). Also: `precompact-save.sh` no longer prints a spurious "(could not parse transcript)" line when a transcript has more than 50 user messages (SIGPIPE from `head` was misread as a parse failure).
- **BSD-sed portability**: the Key Decisions extraction in `user-prompt-context.sh` dropped the GNU-only `\|` alternation end-address (treated literally by BSD/macOS sed, so the range ran to EOF and bled the following section into the post-compact context) for the portable `/^## /` next-heading form. The tracked-files list in `memory-gate.sh` now strips the fixed 3-char `git status --porcelain` prefix instead of `awk '{print $NF}'`, so paths containing spaces survive intact.
- **Installer error checking**: every `cp`, `chmod +x`, and version-stamp `sed` aborts with a clear message on failure instead of continuing silently.
- **Portable in-place edits**: version stamping uses a temp-file rewrite instead of `sed -i''`, which left `*.sh-e` backup files on BSD/macOS sed.
- **Validated atomic state writes**: every jq state-file rewrite (`statusline-memory.sh`, `memory-gate.sh`, `session-start.sh`) goes through a `write_state` helper that writes to a temp file, verifies it is non-empty, then `mv`s — a failed or empty jq leaves the previous state intact.
- **track-changes.sh missing directory**: `track-changes.sh` `mkdir -p`s the state dir before appending, so a fast first edit (PostToolUse before SessionStart) no longer fails.
- **statusline numeric guard**: `statusline-memory.sh` sanitizes the context percentage — a missing `.context_window` (jq `null`) or any non-numeric value falls back to `0` instead of crashing `printf "%.0f"`.
- **Uninstall cleanup**: `uninstall.sh` removes the internal `mimo-installed-version` and `mimo-update-check` files.
- **Sanitized precompact session id**: `precompact-save.sh` sanitizes `session_id` with `tr -cd 'a-zA-Z0-9-'` like the other hooks.
- **Duplicate-title bug**: existing `CLAUDE.md` files now get *only* the memory sections appended — mimo never prepends the workflow block, which also fixes the duplicate `# CLAUDE.md` title from older versions.

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
