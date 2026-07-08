---
name: save
description: "Save a mimo checkpoint — snapshot current work to CLAUDE.md and CLAUDE-FULL.md"
---

[MIMO — MANUAL CHECKPOINT]

Save a quick checkpoint. Reconcile with existing memory — update entries in place, do not stack duplicates.

1. Read CLAUDE.md. Then run `grep -n '^## S' CLAUDE-FULL.md | tail -3` for the last session number, and `tail -30 CLAUDE-FULL.md` for the latest entry. Do NOT read the whole archive.
2. Update "Memory — Current State": today's date, current focus, live blockers only.
3. Append a brief session log to CLAUDE-FULL.md under a new anchor `## S<N> — YYYY-MM-DD — <short-slug>` (N = last session number + 1, S1 if none): work summary, key files changed (verbatim paths), state at checkpoint. Transient facts — SHAs, PR numbers, file counts — live here, not in the index. Reference the entry from CLAUDE.md as `[CLAUDE-FULL.md §S<N>]`.
4. Reconcile "Memory — Recent Sessions" against this session (max 7, drop oldest). Classify each candidate against the existing entries: DUPLICATE (equal specificity) → skip; MORE-SPECIFIC UPDATE (new detail, same topic) → edit that line in place; CONTRADICTION → mark the old line `[superseded YYYY-MM-DD → §S<N>]` and add the new one; NEW → add. Never dedupe across differing numbers, dates, or qualifiers; never leave two contradictory "current" facts.
5. If nothing durable changed since the last save, update only Current State and stop — do not manufacture entries. Leave "Memory — Key Decisions" reconciliation, the superseded-line sweep, and merit-based cap consolidation to /save-full.

Write rules (every index line): one standalone subject-verb-object sentence with verbatim paths/names/flags, no pronouns; declarative dated past-tense facts, never imperatives ("Project uses pytest with xdist" ✓ — "Run tests with pytest -n 4" ✗); completed work reads as done ("Shipped X on <date>"). Banned filler verbs: mentioned/discussed/looked into. Edit surgically — leave still-accurate lines byte-for-byte identical. Never write secrets (API keys, tokens, passwords, connection strings) — use [REDACTED]. Keep the whole Memory block under ~60 lines.

After saving, say "checkpoint saved" then IMMEDIATELY resume the task you were working on before this interruption. Pick up exactly where you left off — do not wait for the user to re-ask.
