# mimo tests

A [bats-core](https://github.com/bats-core/bats-core) suite covering every hook,
the `mimo` CLI, and the installer/uninstaller. All tests run under a throwaway
`$HOME` (`mktemp -d`) — the live mimo install that powers your own Claude Code
session is never touched.

## Running

```sh
bats tests/            # whole suite
bats tests/cli.bats    # one file
```

### Installing bats

```sh
# macOS
brew install bats-core
# Debian/Ubuntu
sudo apt-get install -y bats
```

If neither is available, clone bats into a temp dir and run its binary directly:

```sh
d=$(mktemp -d); git clone --depth 1 https://github.com/bats-core/bats-core "$d"
"$d/bin/bats" tests/
```

`jq` and `git` must be on `PATH` (both are used by fixtures and the hooks).

## Layout

| File                    | Covers                                                        |
|-------------------------|---------------------------------------------------------------|
| `helpers.bash`          | Sandbox `$HOME` guard, env resets, JSON/state fixture builders |
| `statusline.bats`       | Threshold flips, clamping, config override, state preservation |
| `memory-gate.bats`      | Stop-hook state machine + two give-up / cancellation regressions |
| `session-start.bats`    | State creation, auto-init matrix, stale cleanup, update check   |
| `session-lifecycle.bats`| track-changes, session-end, compact, user-prompt, subagent, precompact |
| `cli.bats`              | version/help/init/status/cleanup/sessions/doctor               |
| `install.bats`          | Local-mode install, idempotency, settings preservation, uninstall |

## Safety

`helpers.bash` captures the real home once, then `mimo_setup()` moves `$HOME` to a
fresh sandbox and **hard-exits** if that override didn't take effect or lands
inside the real home. It also `unset`s every `MIMO_*` env var the live session
exports, so a leaked value can't point a hook at the real `~/.claude`.

## Lint

Shell scripts are shellcheck-clean at default severity:

```sh
shellcheck hooks/*.sh mimo install.sh uninstall.sh tests/helpers.bash
```
