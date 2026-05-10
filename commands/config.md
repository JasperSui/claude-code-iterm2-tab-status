---
description: Configure iterm2-tab-status plugin settings (emoji prefixes, colors, display target, subtitle activity, badge, notifications)
---

Read the current config file at `~/.config/claude-tab-status/config.json` (create the directory if it doesn't exist). Merge with these defaults for any missing keys:

| # | Setting | Key | Default |
|---|---------|-----|---------|
| 1 | Running prefix | `prefix_running` | ⚡ |
| 2 | Idle prefix | `prefix_idle` | 💤 |
| 3 | Attention prefix | `prefix_attention` | 🔴 |
| 4 | Flash color R (0-255) | `color_r` | 255 |
| 5 | Flash color G (0-255) | `color_g` | 140 |
| 6 | Flash color B (0-255) | `color_b` | 0 |
| 7 | Flash interval (seconds) | `interval` | 0.6 |
| 8 | Badge enabled | `badge_enabled` | true |
| 9 | Badge text | `badge` | ⚠️ Needs input |
| 10 | macOS notifications | `notify` | false |
| 11 | Sound file path | `sound` | (empty) |
| 12 | Display target | `display_target` | title |
| 13 | Subtitle activity source | `subtitle_activity_source` | off |

Display all settings with their current effective values in a numbered table. Then ask the user which setting(s) they want to change. After they respond, update only the specified values and write the full config to `~/.config/claude-tab-status/config.json`. The adapter will hot-reload the changes within ~1 second.

Validation rules:
- `color_r`, `color_g`, `color_b`: integers 0-255
- `interval`: positive float
- `badge_enabled`, `notify`: boolean
- `display_target`: one of `title`, `subtitle`, or `both`
- `subtitle_activity_source`: one of `off` or `prompt`; `prompt` appends a compact sanitized snippet to the subtitle and is opt-in because prompt text may be sensitive
- `sound`: valid file path or empty string
