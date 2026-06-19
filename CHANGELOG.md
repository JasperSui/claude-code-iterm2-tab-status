# Changelog

## Unreleased

### Fixed
- **Tabs stuck on a stale status** (e.g. still flashing 🔴 attention after you've already responded). Signals were only reclaimed when their PID died, but `hook.sh` records the long-lived login-shell PID, so a signal left behind by a session that has moved on persisted for the life of the terminal tab — and PID reuse could leak orphans indefinitely.

### Added
- `signal_max_age` config (int seconds, default `1800`): expire any signal not refreshed within this window regardless of PID liveness; set `<= 0` to disable. Every hook event rewrites a signal's timestamp, so active sessions are never affected. New env var `CLAUDE_ITERM2_TAB_STATUS_SIGNAL_MAX_AGE`; hot-reloadable.

## 0.3.0 — 2026-05-31

### Added
- `flash_enabled` config (bool, default `true`): set to `false` to keep the 🔴 attention prefix and badge but stop the tab color from animating. New env var `CLAUDE_ITERM2_TAB_STATUS_FLASH_ENABLED`; hot-reloadable at runtime. (#9, thanks @bginbey)

### Changed
- Subtitle activity snippets now preserve Unicode letters (e.g. CJK) instead of stripping them. (#4)

### Security
- **Validate `session_id`** before using it in signal-file paths: values that aren't plain `[A-Za-z0-9_-]` tokens are rejected, closing a path-traversal vector (e.g. a crafted `session_id` containing `../`). Real session IDs are UUIDs, so nothing legitimate is rejected. (#8)
- **Removed the legacy `/tmp/claude-tab-status` fallback** from bootstrap. Nothing has read that path since v0.2.0 moved signals to the private per-user dir, so this drops a leftover world-readable path. (#8)

## 0.2.0 — 2026-05-10

### Added
- `display_target` config: render status to the tab title, the iTerm2 subtitle, or both. Subtitle mode writes the iTerm2 user variable `user.claudeStatus`; reference it from your iTerm2 profile's Subtitle field as `\(user.claudeStatus)`. (#2, thanks @davidalee)
- `subtitle_activity_source` config: optionally append a short sanitized snippet of the user's prompt (e.g. `⚡ Run tests`) to the subtitle. Default is `off`; `prompt` is opt-in because the snippet is derived from prompt text. (#2)
- New env vars `CLAUDE_ITERM2_TAB_STATUS_DISPLAY_TARGET` and `CLAUDE_ITERM2_TAB_STATUS_SUBTITLE_ACTIVITY_SOURCE`.

### Changed
- **Default signal directory** moved from `/tmp/claude-tab-status` to `${XDG_RUNTIME_DIR:-$HOME/.cache}/claude-tab-status` and created with mode `0700`, so signal files (which carry `cwd`, `pid`, `tty`, and the optional sanitized prompt snippet) are not readable by other local users on shared hosts. Set `CLAUDE_ITERM2_TAB_STATUS_DIR=/tmp/claude-tab-status` to restore the old path.
- Hot-reloading `display_target` now reconciles active sessions: dropping `title` clears the prefix, dropping `subtitle` clears the user variable, and adding either channel re-applies the current state immediately. Previously the dropped channel was left stuck.

### Notes
- README example previously listed `signal_dir`/`flash_interval`/`badge_text`/`log_level` keys that the runtime never read; the example now matches the actual keys (`dir`/`interval`/`badge`). Existing valid `config.json` files do not need to change.
- After upgrading, restart the iTerm2 adapter (close and reopen iTerm2, or relaunch the Python script) so it polls the new default signal directory.

## 0.1.0 — 2026-03-06

Initial open-source release as a Claude Code plugin.

- Three tab states: Running (⚡), Idle (💤), Attention (🔴)
- Unified hook script handles `UserPromptSubmit`, `Notification`, and `Stop` events
- TTY-based session matching with PID ancestry fallback
- Original tab color/title/badge save and restore
- Auto-contrast flash color selection
- PID liveness check cleans stale signals from dead sessions
- Per-state configurable prefixes and environment variable configuration (`CLAUDE_ITERM2_TAB_STATUS_*`)
- Auto-bootstrap: creates iTerm2 Python runtime on first session start
- `/setup` and `/uninstall` slash commands
- macOS notification and sound support (optional)
- Shell and Python unit tests
