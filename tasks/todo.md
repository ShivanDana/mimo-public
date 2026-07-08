# tasks/todo.md — v2.0.0 release

## Status: COMPLETE

The v2 overhaul shipped across five tasks on `feat/v2-overhaul`. Task 5 (this one)
added the test suite, lint hardening, CI, and release polish.

## Task 5 checklist

- [x] `tests/` bats-core suite (`helpers.bash` + 6 component files), 83 tests
- [x] Sandbox-`$HOME` guard in `helpers.bash` (hard-refuses to run against real home)
- [x] Mandatory regression guards: give-up durability (statusline-interleaved) + stale-request cancellation
- [x] shellcheck clean at **default severity** on all shipped scripts + `tests/helpers.bash`
- [x] `.github/workflows/ci.yml` — shellcheck / bats matrix (Ubuntu + macOS) / sandbox e2e
- [x] `tests/README.md` — how to run + safety notes
- [x] Polish: SessionStart banner interpolates configured thresholds; `.gitignore` += `.DS_Store`, `.superpowers/`
- [x] `VERSION` → `2.0.0`
- [x] `CHANGELOG.md` — `## [2.0.0] - 2026-07-08` with BREAKING / Added / Changed / Fixed
- [x] `README.md` — CI badge, file-locations rows (`mimo.conf`, `mimo-templates/`, backup format), "why not native memory" + stale-sessions FAQ, Development section (repo layout, single-source rule, tests, shellcheck, releasing)

## Review

### What changed
Two commits: (1) tests + shellcheck hardening + CI + the two bug fixes the tests
exposed; (2) the v2.0.0 release docs (VERSION, CHANGELOG, README, this file).

### Bugs found by the tests
1. **SessionStart aborted on an anchor-less archive** (`session-start.sh`,
   `session-start-compact.sh`). Under `set -euo pipefail` the `LATEST_ANCHOR`
   grep pipeline returned non-zero when `CLAUDE-FULL.md` had no `## S` anchors —
   killing the hook before it emitted any context. Every freshly auto-initialized
   project hit this. Fixed with `|| true` on both pipelines. This is the reason
   the fix is bundled with the tests that found it (per repo bug policy).

### Lint approach
Fixed all warning-level findings (SC1090 dynamic-source directive, SC2088
tilde-in-quotes reworded to `$HOME`, SC2129 grouped redirect). Documented
file-level disables for intentional info-level patterns: SC2059 (color codes in
printf formats), SC2016 (`$var` inside jq filters is jq syntax), SC2015
(`cmd && ok || { err; exit; }` chains abort on any failure by design), SC2012
(timestamped backup names make `ls -t` safe).

### Verification
- `bats tests/` — 83 tests, 0 failures, ~13s.
- `shellcheck hooks/*.sh mimo install.sh uninstall.sh tests/helpers.bash` — exit 0.
- Sandbox e2e (install → assert 9 hooks + valid settings + stamped versions →
  `mimo doctor` exit 0 → uninstall → settings cleaned) — passes locally, mirrors
  the CI `e2e` job.

### Not done (intentional)
- Git tag `v2.0.0` is **not** created here — the human tags on merge (installer +
  updater prefer the tag, fall back to `main`). See README "Releasing".
