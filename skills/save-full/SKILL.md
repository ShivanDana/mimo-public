---
name: save-full
description: "Perform a full mimo memory save — comprehensive session log to CLAUDE.md and CLAUDE-FULL.md"
---

[MIMO — MANUAL FULL SAVE]

Perform a complete memory save. Memory is reconciled, not appended — update and supersede existing entries instead of stacking duplicates.

1. Read CLAUDE.md. Then run `grep -n '^## S' CLAUDE-FULL.md | tail -3` for the last session number, and `tail -30 CLAUDE-FULL.md` for the latest entry. Do NOT read the whole archive.
2. Append a DETAILED session log to CLAUDE-FULL.md under a new anchor, and reference it from CLAUDE.md as `[CLAUDE-FULL.md §S<N>]` (legacy [L##-L##] refs stay as-is):
   - Heading `## S<N> — YYYY-MM-DD — <short-slug>`, N = last session number + 1 (S1 if none).
   - Full work context, ALL files changed (verbatim paths) with what and why, decisions with reasoning, current state, next steps. Transient facts — commit SHAs, PR numbers, "phase N done", file counts — live HERE, never in the index.
3. Update "Memory — Current State": today's date, current focus, live blockers only.
4. Reconcile "Memory — Recent Sessions" and "Memory — Key Decisions" against what you just logged. Classify each candidate fact against the existing entries:
   - DUPLICATE — already recorded at equal specificity → do not re-add.
   - MORE-SPECIFIC UPDATE — same topic, adds or changes detail → edit that line in place.
   - CONTRADICTION/REVERSAL — mark the old line `[superseded YYYY-MM-DD → §S<N>]`, add the new one, and write the change as one arc: "Originally X (date); changed to Y (date) because Z".
   - NEW — add.
   Never treat facts differing in numbers, dates, or key qualifiers as duplicates. Never leave two contradictory "current" facts coexisting. In the §S<N> log, note in one clause which entry you updated and why (or that none matched).
5. Durability gate — "Memory — Key Decisions" admits only facts that will still matter in a month; if a fact is stale in a week it belongs in the §S<N> log, not the index. Convert transient observations to durable form ("Acme is in Room 105", not "currently in Room 105"). If nothing durable happened, write "(no durable learnings)" and stop — never manufacture decisions.
6. Sweep every line already marked `[superseded …]` out of CLAUDE.md into its referenced §S<N> entry — invalidate-then-archive, never silently delete.
7. Cap: "Memory — Recent Sessions" max 7 (drop oldest); "Memory — Key Decisions" max 10. Over 10, do NOT drop the oldest — merge overlapping entries and evict superseded and lowest-value ones (keep non-obvious decisions and reversals over routine confirmations), then add. The 10 you keep are the 10 most valuable, not the 10 most recent.

Write rules (every index line):
- One standalone subject-verb-object sentence naming its entities — verbatim file paths, function names, flags. No pronouns ("it", "the fix").
- Declarative dated past-tense facts, never imperatives: "Project uses pytest with xdist" ✓ — "Run tests with pytest -n 4" ✗ (imperatives get re-read as directives and cause redone work). Completed work reads as done: "Shipped X on <date>", never "ship X".
- Never generalize away concrete detail. Banned filler verbs — mentioned/discussed/looked into/described; state the fact itself. Mark unverified hunches `[inferred]`.
- Edit surgically: leave every still-accurate line byte-for-byte identical — no rewording, reordering, or restyling.
- Never write API keys, tokens, passwords, or connection strings into memory — replace with [REDACTED].
- Keep the whole Memory block in CLAUDE.md under ~60 lines — the archive grows, the index stays lean.

After saving, say "memory saved" then IMMEDIATELY resume the task you were working on before this interruption. Pick up exactly where you left off — do not wait for the user to re-ask. If context is very full, suggest /compact but still resume working.
