"""claude-code-iterm2-tab-status — iTerm2 adapter.

Polls the per-user signal directory (default
``${XDG_RUNTIME_DIR:-$HOME/.cache}/claude-tab-status``) for signal files written
by Claude Code hooks. Shows tab status (running/idle/attention) for each Claude
Code session.

Three states:
  Running (⚡)   — Claude is processing. Prefix only, no flash.
  Idle (💤)      — Claude finished. Prefix only, no flash.
  Attention (🔴) — Claude needs permission. Flash + badge + notification.

Configuration:
  Settings are resolved in priority order (highest wins):
    1. Environment variable (e.g. CLAUDE_ITERM2_TAB_STATUS_COLOR_R=255)
    2. Config file at ~/.config/claude-tab-status/config.json
    3. Built-in defaults

  Use the /iterm2-tab-status:config slash command for interactive configuration.
  The config file is hot-reloaded — changes take effect within ~1 second.

Environment variables (all optional):
  CLAUDE_ITERM2_TAB_STATUS_DIR              Signal directory
                                              (default: $XDG_RUNTIME_DIR/claude-tab-status,
                                               or ~/.cache/claude-tab-status)
  CLAUDE_ITERM2_TAB_STATUS_COLOR_R          Flash color red 0-255 (default: 255)
  CLAUDE_ITERM2_TAB_STATUS_COLOR_G          Flash color green 0-255 (default: 140)
  CLAUDE_ITERM2_TAB_STATUS_COLOR_B          Flash color blue 0-255 (default: 0)
  CLAUDE_ITERM2_TAB_STATUS_INTERVAL         Flash interval seconds (default: 0.6)
  CLAUDE_ITERM2_TAB_STATUS_PREFIX_RUNNING   Running prefix (default: "⚡ ")
  CLAUDE_ITERM2_TAB_STATUS_PREFIX_IDLE      Idle prefix (default: "💤 ")
  CLAUDE_ITERM2_TAB_STATUS_PREFIX_ATTENTION Attention prefix (default: "🔴 ")
  CLAUDE_ITERM2_TAB_STATUS_DISPLAY_TARGET   Display target title/subtitle/both (default: title)
  CLAUDE_ITERM2_TAB_STATUS_SUBTITLE_ACTIVITY_SOURCE
                                                Subtitle activity off/prompt (default: off)
  CLAUDE_ITERM2_TAB_STATUS_BADGE            Badge text (default: "⚠️ Needs input")
  CLAUDE_ITERM2_TAB_STATUS_BADGE_ENABLED    Enable/disable badge true/false (default: true)
  CLAUDE_ITERM2_TAB_STATUS_NOTIFY           macOS notification true/false (default: false)
  CLAUDE_ITERM2_TAB_STATUS_SOUND            Sound file path (default: "")
  CLAUDE_ITERM2_TAB_STATUS_LOG              Log level (default: WARNING)
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import subprocess
import time
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Awaitable, Callable, Optional

# --- Configuration ---

CONFIG_PATH = os.path.expanduser("~/.config/claude-tab-status/config.json")


def _default_signal_dir() -> str:
    """Per-user signal directory.

    Defaults to ``$XDG_RUNTIME_DIR/claude-tab-status`` when set (typically tmpfs and
    already mode 0700), otherwise ``~/.cache/claude-tab-status``. We avoid ``/tmp``
    so signal files are not readable by other local users on shared hosts.
    """
    base = os.environ.get("XDG_RUNTIME_DIR") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "claude-tab-status")


_DEFAULTS: dict[str, object] = {
    "dir": _default_signal_dir(),
    "prefix_running": "⚡ ",
    "prefix_idle": "💤 ",
    "prefix_attention": "🔴 ",
    "color_r": 255,
    "color_g": 140,
    "color_b": 0,
    "interval": 0.6,
    "badge_enabled": True,
    "badge": "⚠️ Needs input",
    "notify": False,
    "sound": "",
    "display_target": "title",
    "subtitle_activity_source": "off",
}

_ENV_MAP: dict[str, tuple[str, type]] = {
    "dir": ("DIR", str),
    "prefix_running": ("PREFIX_RUNNING", str),
    "prefix_idle": ("PREFIX_IDLE", str),
    "prefix_attention": ("PREFIX_ATTENTION", str),
    "color_r": ("COLOR_R", int),
    "color_g": ("COLOR_G", int),
    "color_b": ("COLOR_B", int),
    "interval": ("INTERVAL", float),
    "badge_enabled": ("BADGE_ENABLED", lambda v: v.lower() == "true"),
    "badge": ("BADGE", str),
    "notify": ("NOTIFY", lambda v: v.lower() == "true"),
    "sound": ("SOUND", str),
    "display_target": ("DISPLAY_TARGET", str),
    "subtitle_activity_source": ("SUBTITLE_ACTIVITY_SOURCE", str),
}

_DISPLAY_TARGETS = {"title", "subtitle", "both"}
_SUBTITLE_ACTIVITY_SOURCES = {"off", "prompt"}


def _normalize_display_target(value: object) -> str:
    """Return a supported display target, defaulting to title."""
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in _DISPLAY_TARGETS:
            return normalized
    return "title"


def _normalize_subtitle_activity_source(value: object) -> str:
    """Return a supported subtitle activity source, defaulting to off."""
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in _SUBTITLE_ACTIVITY_SOURCES:
            return normalized
    return "off"


def load_config(config_path: str | None = None) -> dict[str, object]:
    """Load config: defaults ← config.json ← env vars."""
    cfg = dict(_DEFAULTS)

    path = config_path or CONFIG_PATH
    try:
        with open(path) as f:
            file_cfg = json.load(f)
        if isinstance(file_cfg, dict):
            for k in _DEFAULTS:
                if k in file_cfg:
                    cfg[k] = file_cfg[k]
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass

    for key, (suffix, converter) in _ENV_MAP.items():
        env_val = os.environ.get(f"CLAUDE_ITERM2_TAB_STATUS_{suffix}")
        if env_val is not None:
            try:
                cfg[key] = converter(env_val)
            except (ValueError, TypeError):
                pass

    cfg["display_target"] = _normalize_display_target(cfg.get("display_target"))
    cfg["subtitle_activity_source"] = _normalize_subtitle_activity_source(
        cfg.get("subtitle_activity_source")
    )

    return cfg


CONFIG = load_config()

LOG_LEVEL = os.environ.get("CLAUDE_ITERM2_TAB_STATUS_LOG", "WARNING").upper()

_config_mtime: float = 0.0


def _rebuild_prefixes() -> None:
    """Rebuild prefix lookups from CONFIG. Called after config reload."""
    global _STATE_PREFIXES, ALL_PREFIXES
    _STATE_PREFIXES = {
        TabState.RUNNING: CONFIG["prefix_running"],
        TabState.IDLE: CONFIG["prefix_idle"],
        TabState.ATTENTION: CONFIG["prefix_attention"],
    }
    ALL_PREFIXES = [CONFIG["prefix_running"], CONFIG["prefix_idle"], CONFIG["prefix_attention"]]


# Auto-contrast: fallback colors when configured color is too close to tab color
_FALLBACK_COLORS = [(0, 136, 255), (255, 255, 255)]  # Blue, then White
_COLOR_DISTANCE_THRESHOLD = 120

# Stale PID grace period (seconds)
_PID_STALE_GRACE = 10

logging.basicConfig(level=getattr(logging, LOG_LEVEL, logging.WARNING))
log = logging.getLogger("claude_tab_status")


# --- TabState ---


class TabState(str, Enum):
    RUNNING = "running"
    IDLE = "idle"
    ATTENTION = "attention"


_STATE_PREFIXES: dict[TabState, str] = {}
ALL_PREFIXES: list[str] = []
_rebuild_prefixes()


def reload_config(config_path: str | None = None) -> None:
    """Reload CONFIG from disk and rebuild derived state."""
    global CONFIG, _config_mtime
    CONFIG = load_config(config_path)
    _rebuild_prefixes()
    try:
        _config_mtime = os.path.getmtime(config_path or CONFIG_PATH)
    except OSError:
        _config_mtime = 0.0


def _check_config_reload() -> None:
    """Check config file mtime; reload if changed."""
    global _config_mtime
    try:
        mtime = os.path.getmtime(CONFIG_PATH)
    except OSError:
        return
    if mtime != _config_mtime:
        log.info("Config file changed, reloading")
        reload_config()


def resolve_state(raw_type: str) -> TabState:
    """Resolve a signal type string to a TabState."""
    try:
        return TabState(raw_type)
    except ValueError:
        return TabState.IDLE  # unknown → safe default


# --- Signal I/O ---


def read_signals(signal_dir: str) -> dict[str, dict]:
    """Read all *.json signal files from the directory. Returns {session_id: data}."""
    signals: dict[str, dict] = {}
    d = Path(signal_dir)
    if not d.is_dir():
        return signals
    for f in d.glob("*.json"):
        try:
            data = json.loads(f.read_text())
            sid = data.get("session_id")
            if sid:
                signals[sid] = data
        except (json.JSONDecodeError, OSError) as e:
            log.debug("Skipping malformed signal %s: %s", f, e)
    return signals


def remove_signal(signal_dir: str, session_id: str) -> None:
    """Remove a signal file. No error if it doesn't exist."""
    p = Path(signal_dir) / f"{session_id}.json"
    try:
        p.unlink()
    except FileNotFoundError:
        pass


# --- PID Liveness ---


def _is_pid_alive(pid: int) -> bool:
    """Check if a PID is still running. Returns False if dead."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # process exists but we can't signal it


# --- Snapshot ---


@dataclass
class Snapshot:
    """Captured state of an iTerm2 session before modification."""

    tab_color: Optional[dict[str, int]]  # {"red": int, "green": int, "blue": int} or None
    use_tab_color: bool
    name: str
    badge_text: str
    allow_title_setting: bool


async def capture_snapshot(session: object) -> Snapshot:
    """Capture current session state for later restoration."""
    profile = await session.async_get_profile()  # type: ignore[union-attr]
    tc = profile.tab_color
    # NOTE: iTerm2 Color values are already 0-255. Do NOT multiply by 255.
    return Snapshot(
        tab_color={
            "red": int(tc.red),
            "green": int(tc.green),
            "blue": int(tc.blue),
        }
        if tc
        else None,
        use_tab_color=bool(profile.use_tab_color),
        name=await session.async_get_variable("name") or "",  # type: ignore[union-attr]
        badge_text=profile.badge_text or "",
        allow_title_setting=bool(getattr(profile, "allow_title_setting", True)),
    )


async def restore_snapshot(session: object, snapshot: Snapshot) -> None:
    """Restore session to its pre-modification state."""
    import iterm2

    change = iterm2.LocalWriteOnlyProfile()
    change.set_use_tab_color(snapshot.use_tab_color)
    if snapshot.tab_color is not None:
        change.set_tab_color(
            iterm2.Color(
                snapshot.tab_color["red"],
                snapshot.tab_color["green"],
                snapshot.tab_color["blue"],
            )
        )
    change.set_badge_text(snapshot.badge_text)
    await session.async_set_profile_properties(change)  # type: ignore[union-attr]
    await session.async_set_name(snapshot.name)  # type: ignore[union-attr]


# --- Session Matching ---


async def match_session(sessions: list[object], tty: str, pid: str) -> Optional[object]:
    """Find the iTerm2 session that owns the given TTY or PID.

    Primary: match by TTY via session.tty variable.
    Fallback: match by PID ancestry via _is_ancestor.
    """
    # Primary: match by TTY
    for s in sessions:
        s_tty = await s.async_get_variable("tty")  # type: ignore[union-attr]
        if s_tty and s_tty == tty:
            return s
    # Fallback: match by PID ancestry
    if pid:
        for s in sessions:
            s_pid = await s.async_get_variable("jobPid")  # type: ignore[union-attr]
            if s_pid and _is_ancestor(int(s_pid), int(pid)):
                return s
    return None


# --- PID Ancestry ---


def _get_ppid(pid: int) -> int:
    """Get parent PID. Returns 0 on failure."""
    try:
        out = subprocess.check_output(
            ["ps", "-o", "ppid=", "-p", str(pid)],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        return int(out.strip())
    except (subprocess.CalledProcessError, ValueError):
        return 0


def _is_ancestor(ancestor: int, descendant: int) -> bool:
    """Check if ancestor PID is an ancestor of descendant PID. Max depth 15."""
    if ancestor == descendant:
        return True
    current = descendant
    for _ in range(15):
        parent = _get_ppid(current)
        if parent == ancestor:
            return True
        if parent <= 1:
            return False
        current = parent
    return False


# --- Focus Tracking ---


class FocusTracker:
    """Tracks which iTerm2 session is currently focused."""

    def __init__(self) -> None:
        self.focused_session_id: Optional[str] = None

    def set_focused(self, session_id: str) -> None:
        self.focused_session_id = session_id

    def is_focused(self, session_id: str) -> bool:
        return self.focused_session_id == session_id


# --- Flasher ---


class Flasher:
    """Tracks which sessions are currently flashing."""

    def __init__(self) -> None:
        self._flashing: set[str] = set()

    def start(self, session_id: str) -> None:
        self._flashing.add(session_id)

    def stop(self, session_id: str) -> None:
        self._flashing.discard(session_id)

    def is_flashing(self, session_id: str) -> bool:
        return session_id in self._flashing

    def all_flashing(self) -> set[str]:
        return set(self._flashing)


# --- Title Prefix Helpers ---


def strip_all_prefixes(name: str) -> str:
    """Remove all known state prefixes from a name."""
    for prefix in ALL_PREFIXES:
        if name.startswith(prefix):
            return name[len(prefix) :]
    return name


def set_state_prefix(name: str, prefix: str) -> str:
    """Set a state prefix, replacing any existing one."""
    return prefix + strip_all_prefixes(name)


_SUBTITLE_VARIABLE = "user.claudeStatus"
_ACTIVITY_MAX_CHARS = 18
_ACTIVITY_MAX_WORDS = 2
_ACTIVITY_STOP_WORDS = {
    "a",
    "an",
    "and",
    "about",
    "can",
    "for",
    "in",
    "me",
    "my",
    "of",
    "on",
    "our",
    "please",
    "the",
    "this",
    "to",
    "with",
    "you",
}
_ACTIVITY_VERBS = {
    "debugging": "debug",
    "editing": "edit",
    "fixing": "fix",
    "implementing": "implement",
    "planning": "plan",
    "reviewing": "review",
    "running": "run",
    "testing": "test",
    "updating": "update",
    "writing": "write",
}
_ACTIVITY_ACRONYMS = {"api", "pr", "url"}
_SENSITIVE_ACTIVITY_RE = re.compile(
    r"(?i)\b(password|passwd|passphrase|secret|token|api[-_ ]?key|private[-_ ]?key|"
    r"credential|bearer|cookie)\b\s*[:=]?"
)


def _should_update_title(display_target: object | None = None) -> bool:
    """Return whether the current target should update the tab title."""
    target = _normalize_display_target(display_target or CONFIG.get("display_target"))
    return target in {"title", "both"}


def _should_update_subtitle(display_target: object | None = None) -> bool:
    """Return whether the current target should update the subtitle variable."""
    target = _normalize_display_target(display_target or CONFIG.get("display_target"))
    return target in {"subtitle", "both"}


def _activity_word(word: str, index: int) -> str:
    """Format one sanitized activity word for compact display."""
    normalized = _ACTIVITY_VERBS.get(word.lower(), word.lower())
    if normalized in _ACTIVITY_ACRONYMS:
        return normalized.upper()
    if index == 0:
        return normalized.capitalize()
    return normalized


def _activity_snippet(text: object) -> str:
    """Convert opt-in prompt text into a compact, privacy-conscious snippet."""
    if not isinstance(text, str):
        return ""
    if _SENSITIVE_ACTIVITY_RE.search(text):
        return ""

    cleaned = re.sub(r"https?://\S+|www\.\S+", " link ", text)
    cleaned = re.sub(r"\b\S+@\S+\.\S+\b", " email ", cleaned)
    cleaned = re.sub(r"(?:~|/)[^\s]+", " file ", cleaned)
    cleaned = re.sub(r"(?i)\bpull\s+request\b", " PR ", cleaned)
    cleaned = re.sub(r"[\r\n\t]+", " ", cleaned)
    cleaned = re.sub(r"[^A-Za-z0-9#]+", " ", cleaned)

    words = [word for word in cleaned.split() if word.lower() not in _ACTIVITY_STOP_WORDS]
    if not words:
        return ""

    formatted_words: list[str] = []
    for word in words:
        candidate = _activity_word(word, len(formatted_words))
        candidate_words = formatted_words + [candidate]
        candidate_text = " ".join(candidate_words)
        if len(candidate_words) > _ACTIVITY_MAX_WORDS or len(candidate_text) > _ACTIVITY_MAX_CHARS:
            break
        formatted_words.append(candidate)

    return " ".join(formatted_words)


def _subtitle_status_text(prefix: str, signal: dict | None = None) -> str:
    """Convert a title prefix into compact subtitle text."""
    status = prefix.strip()
    if _normalize_subtitle_activity_source(CONFIG.get("subtitle_activity_source")) != "prompt":
        return status

    activity = (signal or {}).get("activity", "")
    snippet = _activity_snippet(activity)
    if not snippet:
        return status
    return f"{status} {snippet}" if status else snippet


def _signal_display_signature(signal: dict) -> tuple[object, object]:
    """Return fields that affect visible status display."""
    return (signal.get("type"), signal.get("activity", ""))


async def _set_subtitle_status(session: object, status_text: str) -> None:
    """Set the fixed iTerm2 user variable used by profile subtitles."""
    try:
        await session.async_set_variable(_SUBTITLE_VARIABLE, status_text)  # type: ignore[union-attr]
    except Exception:
        log.debug("session.async_set_variable failed for subtitle status")


async def _clear_subtitle_status(session: object) -> None:
    """Clear the fixed iTerm2 user variable used by profile subtitles."""
    await _set_subtitle_status(session, "")


async def _apply_status_display(
    info: dict,
    prefix: str,
    signal: dict,
    set_title: Callable[[dict, str], Awaitable[None]],
) -> None:
    """Apply status to the configured display target."""
    if _should_update_title():
        await set_title(info, prefix)
    if _should_update_subtitle():
        await _set_subtitle_status(info["session"], _subtitle_status_text(prefix, signal))


async def _clear_status_display(info: dict) -> None:
    """Clear status display state that may outlive a signal file."""
    await _clear_subtitle_status(info["session"])


async def _handle_display_target_change(
    active: dict[str, dict],
    old_target: str,
    new_target: str,
    set_title: Callable[[dict, str], Awaitable[None]],
) -> None:
    """Reconcile active sessions when ``display_target`` changes via hot-reload.

    Without this, switching from ``title`` to ``subtitle`` mid-session leaves the
    title prefix stuck on the tab; switching the other way leaves a stale subtitle
    variable in place.
    """
    old_title = old_target in {"title", "both"}
    new_title = new_target in {"title", "both"}
    old_subtitle = old_target in {"subtitle", "both"}
    new_subtitle = new_target in {"subtitle", "both"}

    for info in list(active.values()):
        if old_title and not new_title:
            tab = info.get("tab")
            try:
                if tab:
                    displayed = await tab.async_get_variable("title") or info["snapshot"].name
                    await tab.async_set_title(strip_all_prefixes(displayed))
                else:
                    clean = strip_all_prefixes(info["snapshot"].name)
                    await info["session"].async_set_name(clean)  # type: ignore[union-attr]
            except Exception:
                log.debug("Failed to clear title prefix on display_target change")

        if old_subtitle and not new_subtitle:
            await _clear_subtitle_status(info["session"])

        # If a channel was added, re-apply the current state immediately so the
        # user sees feedback without waiting for the next signal change.
        added_title = new_title and not old_title
        added_subtitle = new_subtitle and not old_subtitle
        if added_title or added_subtitle:
            state = info.get("state")
            if state is not None:
                prefix = _STATE_PREFIXES[state]
                await _apply_status_display(info, prefix, {}, set_title)


def add_title_prefix(name: str, prefix: str) -> str:
    """Add prefix to name if not already present."""
    if name.startswith(prefix):
        return name
    return prefix + name


def remove_title_prefix(name: str, prefix: str) -> str:
    """Remove prefix from name if present."""
    if name.startswith(prefix):
        return name[len(prefix) :]
    return name


# --- macOS Notifications ---


def send_notification(title: str, message: str) -> None:
    """Send a macOS notification via osascript."""
    safe_title = title.replace("\\", "\\\\").replace('"', '\\"')
    safe_message = message.replace("\\", "\\\\").replace('"', '\\"')
    script = f'display notification "{safe_message}" with title "{safe_title}"'
    try:
        subprocess.run(
            ["osascript", "-e", script],
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except FileNotFoundError:
        pass


def play_sound(path: str) -> None:
    """Play a sound file via afplay."""
    if path and os.path.isfile(path):
        try:
            subprocess.Popen(  # noqa: S603
                ["afplay", path],
                stderr=subprocess.DEVNULL,
            )
        except FileNotFoundError:
            pass


# --- iTerm2 Main Loop ---
# This section only runs inside the iTerm2 Python environment.
# It is NOT covered by unit tests — see tests/test_adapter.py for mocked tests.


def _pick_flash_color(
    orig_r: int,
    orig_g: int,
    orig_b: int,
) -> tuple[int, int, int]:
    """Pick a flash color that contrasts with the original tab color.

    Tries the user-configured color first, then blue, then white.
    Falls back to color inversion as a last resort.
    """
    user_color = (CONFIG["color_r"], CONFIG["color_g"], CONFIG["color_b"])
    candidates = [user_color] + list(_FALLBACK_COLORS)
    for r, g, b in candidates:
        dist = ((r - orig_r) ** 2 + (g - orig_g) ** 2 + (b - orig_b) ** 2) ** 0.5
        if dist > _COLOR_DISTANCE_THRESHOLD:
            return (r, g, b)
    return (255 - orig_r, 255 - orig_g, 255 - orig_b)


async def _flash_loop(
    session: object, snapshot: Snapshot, session_id: str, flasher: Flasher
) -> None:
    """Alternate tab color between flash color and original."""
    import iterm2

    orig_r = snapshot.tab_color["red"] if snapshot.tab_color else 0
    orig_g = snapshot.tab_color["green"] if snapshot.tab_color else 0
    orig_b = snapshot.tab_color["blue"] if snapshot.tab_color else 0
    flash_r, flash_g, flash_b = _pick_flash_color(orig_r, orig_g, orig_b)

    flash_on = False
    while flasher.is_flashing(session_id):
        change = iterm2.LocalWriteOnlyProfile()
        change.set_use_tab_color(True)
        if flash_on:
            change.set_tab_color(iterm2.Color(orig_r, orig_g, orig_b))
        else:
            change.set_tab_color(iterm2.Color(flash_r, flash_g, flash_b))
        await session.async_set_profile_properties(change)  # type: ignore[union-attr]
        flash_on = not flash_on
        await asyncio.sleep(CONFIG["interval"])


async def main(connection: object) -> None:
    """Main entry point for iTerm2 Python API."""
    import iterm2

    app = await iterm2.async_get_app(connection)
    focus_tracker = FocusTracker()
    flasher = Flasher()
    # Maps claude session_id -> session state info
    active: dict[str, dict] = {}

    def get_all_sessions() -> list[object]:
        sessions: list[object] = []
        for w in app.terminal_windows:
            for tab in w.tabs:
                for s in tab.sessions:
                    sessions.append(s)
        return sessions

    def find_tab_for_session(session: object) -> object | None:
        for w in app.terminal_windows:
            for tab in w.tabs:
                if session in tab.sessions:
                    return tab
        return None

    async def _set_tab_title(info: dict, prefix: str) -> None:
        """Set tab title with given prefix."""
        tab = info.get("tab")
        if tab:
            try:
                displayed = await tab.async_get_variable("title") or info["snapshot"].name
                clean = strip_all_prefixes(displayed)
                await tab.async_set_title(set_state_prefix(clean, prefix))
            except Exception:
                log.debug("tab.async_set_title failed, falling back to session name")
                tab = None
                info["tab"] = None
        if not tab:
            clean = strip_all_prefixes(info["snapshot"].name)
            await info["session"].async_set_name(  # type: ignore[union-attr]
                set_state_prefix(clean, prefix)
            )

    async def _enter_state(claude_sid: str, state: TabState, signal: dict) -> None:
        """Apply visual treatment for entering a state."""
        info = active[claude_sid]
        info["state"] = state
        prefix = _STATE_PREFIXES[state]

        await _apply_status_display(info, prefix, signal, _set_tab_title)

        # ATTENTION only: badge, flash, notification
        if state == TabState.ATTENTION:
            if CONFIG["badge_enabled"]:
                badge_change = iterm2.LocalWriteOnlyProfile()
                badge_change.set_badge_text(CONFIG["badge"])
                await info["session"].async_set_profile_properties(badge_change)  # type: ignore[union-attr]

            flasher.start(claude_sid)
            task = asyncio.create_task(
                _flash_loop(info["session"], info["snapshot"], claude_sid, flasher)
            )
            info["flash_task"] = task

            project = signal.get("project", "")
            msg = signal.get("message", "Needs attention")
            if CONFIG["notify"]:
                send_notification(f"Claude Code — {project}", msg)
            if CONFIG["sound"]:
                play_sound(CONFIG["sound"])

    async def _leave_state(claude_sid: str) -> None:
        """Cleanup when leaving a state. Only attention needs cleanup."""
        info = active.get(claude_sid)
        if not info:
            return
        state = info.get("state")
        if state == TabState.ATTENTION:
            flasher.stop(claude_sid)
            task = info.get("flash_task")
            if task:
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass
                info["flash_task"] = None
            # Restore tab color + badge
            await restore_snapshot(info["session"], info["snapshot"])

    async def apply_state(claude_sid: str, signal: dict) -> None:
        """Entry point for processing a signal. Handles new sessions and state transitions."""
        state = resolve_state(signal.get("type", "idle"))

        if claude_sid not in active:
            # New session — find iTerm2 session, capture snapshot
            sessions = get_all_sessions()
            iterm_session = await match_session(
                sessions, signal.get("tty", ""), signal.get("pid", "")
            )
            if not iterm_session:
                log.warning("No iTerm2 session found for signal %s", claude_sid)
                return

            snapshot = await capture_snapshot(iterm_session)
            tab = find_tab_for_session(iterm_session)
            orig_tab_title = ""
            if tab:
                try:
                    orig_tab_title = await tab.async_get_variable("titleOverrideFormat") or ""
                except Exception:
                    tab = None

            active[claude_sid] = {
                "session": iterm_session,
                "snapshot": snapshot,
                "tab": tab,
                "orig_tab_title": orig_tab_title,
                "state": None,
                "flash_task": None,
            }
            await _enter_state(claude_sid, state, signal)
            log.info("Session %s → %s", claude_sid, state.value)
        else:
            # Existing session — transition if state changed
            current_state = active[claude_sid].get("state")
            if current_state != state:
                await _leave_state(claude_sid)
                await _enter_state(claude_sid, state, signal)
                log.info(
                    "Session %s: %s → %s",
                    claude_sid,
                    current_state.value if current_state else "?",
                    state.value,
                )
            else:
                await _enter_state(claude_sid, state, signal)

    async def clear_session(claude_sid: str) -> None:
        """Fully remove a session: leave state + restore original title + cleanup."""
        if claude_sid not in active:
            return
        await _leave_state(claude_sid)
        info = active.pop(claude_sid)
        await _clear_status_display(info)
        # Restore original tab title
        tab = info.get("tab")
        if tab:
            try:
                orig = info.get("orig_tab_title", "")
                if orig:
                    await tab.async_set_title(orig)
                else:
                    await tab.async_set_title("")  # Clear override → back to default
            except Exception:
                pass
        # If state was not attention, we also need to restore snapshot
        # (attention already restored in _leave_state)
        if info.get("state") != TabState.ATTENTION:
            await restore_snapshot(info["session"], info["snapshot"])
        log.info("Cleared session %s", claude_sid)

    # Signal watcher: polls signal directory every 1 second
    async def signal_watcher() -> None:
        prev_signals: dict[str, dict] = {}
        last_display_target = CONFIG["display_target"]
        while True:
            _check_config_reload()
            current_display_target = CONFIG["display_target"]
            if current_display_target != last_display_target:
                await _handle_display_target_change(
                    active, last_display_target, current_display_target, _set_tab_title
                )
                last_display_target = current_display_target
            try:
                signals = read_signals(CONFIG["dir"])
                current_sids = set(signals.keys())
                prev_sids = set(prev_signals.keys())

                # New or changed signals → apply_state
                for sid in current_sids:
                    prev = prev_signals.get(sid)
                    curr = signals[sid]
                    if prev is None or _signal_display_signature(prev) != _signal_display_signature(
                        curr
                    ):
                        await apply_state(sid, curr)

                # Removed signals → clear session
                for sid in prev_sids - current_sids:
                    await clear_session(sid)

                # Focus check: only dismiss "attention" state on focus
                for sid, info in list(active.items()):
                    if info.get("state") != TabState.ATTENTION:
                        continue
                    iterm_sid = info["session"].session_id
                    if focus_tracker.is_focused(iterm_sid):
                        await clear_session(sid)
                        remove_signal(CONFIG["dir"], sid)

                # PID liveness: clean stale signals
                now = time.time()
                for sid, sig in list(signals.items()):
                    try:
                        pid = int(sig.get("pid", "0"))
                        ts = int(sig.get("ts", "0"))
                    except (ValueError, TypeError):
                        continue
                    if pid > 0 and (now - ts) > _PID_STALE_GRACE and not _is_pid_alive(pid):
                        log.info("Stale signal %s (PID %d dead), cleaning up", sid, pid)
                        await clear_session(sid)
                        remove_signal(CONFIG["dir"], sid)

                prev_signals = signals
            except Exception:
                log.exception("Error in signal watcher")
            await asyncio.sleep(1)

    # Focus monitor: event-driven via iTerm2 FocusMonitor
    async def focus_monitor() -> None:
        async with iterm2.FocusMonitor(connection) as monitor:
            while True:
                update = await monitor.async_get_next_update()
                if update.active_session_changed:
                    session_id = update.active_session_changed.session_id
                    if session_id:
                        focus_tracker.set_focused(session_id)

    # Run both concurrently
    await asyncio.gather(signal_watcher(), focus_monitor())


# Entry point for iTerm2
try:
    import iterm2

    iterm2.run_forever(main)
except ImportError:
    # Not running inside iTerm2 — module is importable for testing
    pass
