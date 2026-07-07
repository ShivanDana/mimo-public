---
name: save
description: "Save a mimo checkpoint — snapshot current work to CLAUDE.md and CLAUDE-FULL.md"
---

[MIMO — MANUAL CHECKPOINT]

Save a checkpoint of your current work to preserve context:

1. Read CLAUDE.md. Then run `grep -n '^## S' CLAUDE-FULL.md | tail -3` to find the last session number, and `tail -30 CLAUDE-FULL.md` to see the latest entry. Do NOT read the whole archive.
2. Update CLAUDE.md "Memory — Current State" section:
   - Today's date
   - What you're currently working on
   - Any blockers or key context to preserve
3. Update "Memory — Recent Sessions" — add/update this session entry (max 7, drop oldest).
4. Append a brief session log to CLAUDE-FULL.md under a new anchor heading:
   - Heading format: `## S<N> — YYYY-MM-DD — <short-slug>` where N = last session number + 1 (S1 if none).
   - Work summary, key files changed, state at checkpoint.
5. Reference the new entry from CLAUDE.md as `[CLAUDE-FULL.md §S<N>]`.

Budget: keep "Memory — Recent Sessions" to max 7 entries and "Memory — Key Decisions" to max 10 — when adding beyond 10, move the oldest decision into its corresponding CLAUDE-FULL.md session entry. Keep the whole Memory block under ~60 lines.

After saving, say "checkpoint saved" then IMMEDIATELY resume the task you were working on before this interruption. Pick up exactly where you left off — do not wait for the user to re-ask.
