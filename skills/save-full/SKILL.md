---
name: save-full
description: "Perform a full mimo memory save — comprehensive session log to CLAUDE.md and CLAUDE-FULL.md"
---

[MIMO — MANUAL FULL SAVE]

Perform a complete memory save to preserve full session context.

1. Read CLAUDE.md. Then run `grep -n '^## S' CLAUDE-FULL.md | tail -3` to find the last session number, and `tail -30 CLAUDE-FULL.md` to see the latest entry. Do NOT read the whole archive.
2. Update CLAUDE.md "Memory — Current State" section:
   - Today's date
   - Current task/focus and progress
   - Any blockers, open issues, or important context
3. Update CLAUDE.md "Memory — Recent Sessions" with a comprehensive entry for this session (keep max 7, drop oldest).
4. Update CLAUDE.md "Memory — Key Decisions" with any decisions made this session (max 10 — when adding beyond 10, move the oldest decision into its corresponding CLAUDE-FULL.md session entry).
5. Append a DETAILED session log to CLAUDE-FULL.md under a new anchor heading:
   - Heading format: `## S<N> — YYYY-MM-DD — <short-slug>` where N = last session number + 1 (S1 if none).
   - Full context of work, ALL files changed with descriptions, all decisions made with reasoning, current state and suggested next steps.
6. Reference the new entry from CLAUDE.md as `[CLAUDE-FULL.md §S<N>]`. If you see legacy [L##-L##] references, leave them; use § anchors for new entries.

Keep the whole Memory block in CLAUDE.md under ~60 lines — the archive grows, the index stays lean.

After saving, say "memory saved" then IMMEDIATELY resume the task you were working on before this interruption. Pick up exactly where you left off — do not wait for the user to re-ask. If context is very full, suggest /compact but still resume working.
