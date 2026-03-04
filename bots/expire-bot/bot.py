#!/usr/bin/env python3
"""Matrix Expire Bot — auto-delete old messages from rooms."""

import asyncio
import fnmatch
import hashlib
import io
import json
import logging
import os
import re
import signal
import sys
import time
import uuid

import aiosqlite
import yaml
from nio import (
    AsyncClient,
    AsyncClientConfig,
    InviteMemberEvent,
    LoginResponse,
    MatrixRoom,
    MegolmEvent,
    RoomMessage,
    RoomMessageText,
    RoomMemberEvent,
    RoomMessagesError,
    RoomRedactError,
    PowerLevelsEvent,
    UploadResponse,
)

logger = logging.getLogger("expire-bot")


# ─── Rate limiter ────────────────────────────────────────────────────────────

class RateLimiter:
    """Token-bucket rate limiter with exponential backoff on 429."""

    def __init__(self, max_per_minute: int = 20):
        self.max_per_minute = max_per_minute
        self._tokens: list[float] = []
        self._cooldown_until: float = 0.0
        self._backoff: float = 1.0  # Start at 1s, doubles on each 429
        self._max_backoff: float = 60.0

    @property
    def in_cooldown(self) -> bool:
        return time.time() < self._cooldown_until

    def set_cooldown(self):
        """Pause all operations with exponential backoff."""
        until = time.time() + self._backoff
        if until > self._cooldown_until:
            self._cooldown_until = until
            logger.warning(f"Rate limiter: backoff {self._backoff:.0f}s")
        self._backoff = min(self._backoff * 2, self._max_backoff)

    def reset_backoff(self):
        """Reset backoff after a successful request."""
        self._backoff = 1.0

    async def acquire(self) -> bool:
        """Wait until allowed to make a request. Returns False if shutdown."""
        # Wait out global cooldown
        now = time.time()
        if now < self._cooldown_until:
            wait = self._cooldown_until - now
            logger.info(f"Rate limiter: waiting {wait:.0f}s (cooldown)")
            await asyncio.sleep(wait)

        # Token bucket — max N requests per 60s window
        now = time.time()
        self._tokens = [t for t in self._tokens if now - t < 60]
        if len(self._tokens) >= self.max_per_minute:
            wait = 60 - (now - self._tokens[0]) + 0.5
            logger.debug(f"Rate limiter: waiting {wait:.1f}s (bucket full)")
            await asyncio.sleep(wait)

        self._tokens.append(time.time())
        return True

    def reset(self):
        self._tokens.clear()
        self._cooldown_until = 0.0


# ─── Duration parsing ────────────────────────────────────────────────────────

DURATION_UNIT_RE = re.compile(r"(\d+)\s*(mo|month|min|m|hr|h|d|day|w|week|y|year)s?", re.I)

DURATION_MULTIPLIERS = {
    "m": 60, "min": 60,
    "h": 3600, "hr": 3600,
    "d": 86400, "day": 86400,
    "w": 604800, "week": 604800,
    "mo": 2592000, "month": 2592000,
    "y": 31536000, "year": 31536000,
}

# State events — never redacted
STATE_EVENTS = frozenset({
    "m.room.member", "m.room.power_levels", "m.room.create",
    "m.room.join_rules", "m.room.history_visibility",
    "m.room.name", "m.room.topic", "m.room.avatar",
    "m.room.canonical_alias", "m.room.guest_access",
    "m.room.encryption", "m.room.server_acl",
    "m.room.tombstone", "m.room.pinned_events",
    "m.room.third_party_invite", "m.space.child", "m.space.parent",
    "m.room.retention",
})


def parse_duration(text: str) -> int | None:
    """Parse duration into seconds. Supports:
    - Simple: '1h', '7d', '30m', '1y'
    - Combined: '1d12h', '2h30m', '10h15m', '1y 6mo'
    Returns None if invalid.
    """
    text = text.strip()
    matches = DURATION_UNIT_RE.findall(text)
    if not matches:
        return None
    total = 0
    for value_str, unit in matches:
        mult = DURATION_MULTIPLIERS.get(unit.lower(), 0)
        if not mult:
            return None
        total += int(value_str) * mult
    return total if total > 0 else None


def format_duration(seconds: int) -> str:
    """Format seconds into '7d 3h', '10h 15m', etc."""
    parts = []
    for unit, divisor in [("y", 31536000), ("mo", 2592000), ("w", 604800),
                          ("d", 86400), ("h", 3600), ("m", 60)]:
        if seconds >= divisor:
            count = seconds // divisor
            seconds %= divisor
            parts.append(f"{count}{unit}")
    return " ".join(parts) if parts else "0m"


# ─── Help text ────────────────────────────────────────────────────────────────

HELP_TEMPLATE = """**Expire Bot** — auto-delete old messages

**Commands:**
• `{p} set <duration>` — set retention (e.g. `1h`, `7d`, `30d`)
• `{p} off` / `{p} unset` — disable retention for this room
• `{p} status` / `{p} show` — current setting
• `{p} clean` — force cleanup now
• `{p} help` — this message

**Durations:** `30m`, `1h`, `6h`, `1d`, `7d`, `30d`, `1y`, `10h 15m`, `1d 12h`

**What gets deleted:** all content — text, images, audio, video, files, stickers, voice messages, encrypted messages.
State events (room name, topic, members) are preserved.

**Permissions:**
• Bot needs **moderator** power level (50+) to redact messages
• Bot management is restricted to authorized admins
• If bot lacks permissions, it will notify you

_Cleanup runs automatically every few minutes._"""


# ─── Database ─────────────────────────────────────────────────────────────────

class Database:
    def __init__(self, path: str):
        self.path = path
        self.db: aiosqlite.Connection | None = None

    async def connect(self):
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        self.db = await aiosqlite.connect(self.path)
        await self.db.execute("""
            CREATE TABLE IF NOT EXISTS room_retention (
                room_id TEXT PRIMARY KEY,
                retention_seconds INTEGER NOT NULL,
                set_by TEXT NOT NULL,
                set_at INTEGER NOT NULL
            )
        """)
        await self.db.execute("""
            CREATE TABLE IF NOT EXISTS cleanup_stats (
                room_id TEXT NOT NULL,
                cleaned_at INTEGER NOT NULL,
                count INTEGER NOT NULL
            )
        """)
        await self.db.execute("""
            CREATE TABLE IF NOT EXISTS greeted_rooms (
                room_id TEXT PRIMARY KEY,
                greeted_at INTEGER NOT NULL
            )
        """)
        await self.db.execute("""
            CREATE TABLE IF NOT EXISTS room_scan_state (
                room_id TEXT PRIMARY KEY,
                from_token TEXT,
                last_cleaned_at INTEGER NOT NULL DEFAULT 0,
                fully_cleaned INTEGER NOT NULL DEFAULT 0
            )
        """)
        await self.db.execute("""
            CREATE TABLE IF NOT EXISTS tracked_events (
                event_id TEXT PRIMARY KEY,
                room_id TEXT NOT NULL,
                timestamp_ms INTEGER NOT NULL
            )
        """)
        await self.db.execute(
            "CREATE INDEX IF NOT EXISTS idx_tracked_room_ts "
            "ON tracked_events (room_id, timestamp_ms)"
        )
        await self.db.commit()

    async def ensure_connected(self):
        """Reconnect if the DB connection was lost."""
        try:
            await self.db.execute("SELECT 1")
        except (ValueError, Exception):
            logger.warning("DB connection lost, reconnecting...")
            self.db = await aiosqlite.connect(self.path)

    async def close(self):
        if self.db:
            await self.db.close()

    async def set_retention(self, room_id: str, seconds: int, set_by: str):
        await self.db.execute(
            "INSERT OR REPLACE INTO room_retention (room_id, retention_seconds, set_by, set_at) "
            "VALUES (?, ?, ?, ?)",
            (room_id, seconds, set_by, int(time.time())),
        )
        await self.db.commit()

    async def remove_retention(self, room_id: str):
        await self.db.execute("DELETE FROM room_retention WHERE room_id = ?", (room_id,))
        await self.db.commit()

    async def remove_room_data(self, room_id: str):
        """Remove all data for a room."""
        await self.db.execute("DELETE FROM room_retention WHERE room_id = ?", (room_id,))
        await self.db.execute("DELETE FROM room_scan_state WHERE room_id = ?", (room_id,))
        await self.db.execute("DELETE FROM cleanup_stats WHERE room_id = ?", (room_id,))
        await self.db.execute("DELETE FROM greeted_rooms WHERE room_id = ?", (room_id,))
        await self.db.execute("DELETE FROM tracked_events WHERE room_id = ?", (room_id,))
        await self.db.commit()

    async def get_retention(self, room_id: str) -> tuple[int, str, int] | None:
        """Returns (retention_seconds, set_by, set_at) or None."""
        async with self.db.execute(
            "SELECT retention_seconds, set_by, set_at FROM room_retention WHERE room_id = ?",
            (room_id,),
        ) as cur:
            return await cur.fetchone()

    async def get_all_rooms(self) -> list[tuple[str, int]]:
        async with self.db.execute("SELECT room_id, retention_seconds FROM room_retention") as cur:
            return await cur.fetchall()

    async def log_cleanup(self, room_id: str, count: int):
        await self.db.execute(
            "INSERT INTO cleanup_stats (room_id, cleaned_at, count) VALUES (?, ?, ?)",
            (room_id, int(time.time()), count),
        )
        # Keep only last 1000 entries
        await self.db.execute(
            "DELETE FROM cleanup_stats WHERE rowid NOT IN "
            "(SELECT rowid FROM cleanup_stats ORDER BY cleaned_at DESC LIMIT 1000)",
        )
        await self.db.commit()

    async def get_total_cleaned(self, room_id: str) -> int:
        async with self.db.execute(
            "SELECT COALESCE(SUM(count), 0) FROM cleanup_stats WHERE room_id = ?",
            (room_id,),
        ) as cur:
            row = await cur.fetchone()
            return row[0] if row else 0

    async def is_greeted(self, room_id: str) -> bool:
        async with self.db.execute(
            "SELECT 1 FROM greeted_rooms WHERE room_id = ?", (room_id,),
        ) as cur:
            return await cur.fetchone() is not None

    async def mark_greeted(self, room_id: str):
        await self.db.execute(
            "INSERT OR REPLACE INTO greeted_rooms (room_id, greeted_at) VALUES (?, ?)",
            (room_id, int(time.time())),
        )
        await self.db.commit()

    async def unmark_greeted(self, room_id: str):
        await self.db.execute("DELETE FROM greeted_rooms WHERE room_id = ?", (room_id,))
        await self.db.commit()

    async def clear_scan_state(self, room_id: str):
        await self.db.execute("DELETE FROM room_scan_state WHERE room_id = ?", (room_id,))
        await self.db.commit()

    # ── Tracked events ──────────────────────────────────────────────

    async def track_event(self, event_id: str, room_id: str, timestamp_ms: int):
        await self.db.execute(
            "INSERT OR IGNORE INTO tracked_events (event_id, room_id, timestamp_ms) "
            "VALUES (?, ?, ?)",
            (event_id, room_id, timestamp_ms),
        )
        await self.db.commit()

    async def track_events_batch(self, events: list[tuple[str, str, int]]):
        """Batch insert: [(event_id, room_id, timestamp_ms), ...]"""
        await self.db.executemany(
            "INSERT OR IGNORE INTO tracked_events (event_id, room_id, timestamp_ms) "
            "VALUES (?, ?, ?)",
            events,
        )
        await self.db.commit()

    async def get_expired_events(self, room_id: str, cutoff_ms: int,
                                  limit: int = 50) -> list[str]:
        """Return event_ids older than cutoff_ms."""
        async with self.db.execute(
            "SELECT event_id FROM tracked_events "
            "WHERE room_id = ? AND timestamp_ms < ? LIMIT ?",
            (room_id, int(cutoff_ms), limit),
        ) as cur:
            return [row[0] for row in await cur.fetchall()]

    async def remove_tracked_events(self, event_ids: list[str]):
        """Batch remove tracked events."""
        if not event_ids:
            return
        await self.db.executemany(
            "DELETE FROM tracked_events WHERE event_id = ?",
            [(eid,) for eid in event_ids],
        )
        await self.db.commit()

    async def clear_tracked_events(self, room_id: str):
        """Remove all tracked events for a room."""
        await self.db.execute("DELETE FROM tracked_events WHERE room_id = ?", (room_id,))
        await self.db.commit()

    async def get_scan_state(self, room_id: str) -> tuple[str | None, int, bool]:
        """Returns (from_token, last_cleaned_at, fully_cleaned)."""
        async with self.db.execute(
            "SELECT from_token, last_cleaned_at, fully_cleaned FROM room_scan_state WHERE room_id = ?",
            (room_id,),
        ) as cur:
            row = await cur.fetchone()
            if row:
                return row[0], row[1], bool(row[2])
            return None, 0, False

    async def save_scan_state(self, room_id: str, from_token: str | None,
                               fully_cleaned: bool):
        await self.db.execute(
            "INSERT OR REPLACE INTO room_scan_state "
            "(room_id, from_token, last_cleaned_at, fully_cleaned) VALUES (?, ?, ?, ?)",
            (room_id, from_token, int(time.time()), int(fully_cleaned)),
        )
        await self.db.commit()


# ─── Bot ──────────────────────────────────────────────────────────────────────

class ExpireBot:
    def __init__(self, config: dict):
        self.config = config
        self.homeserver = config["homeserver"]
        self.user_id = config["user_id"]
        self.password = config.get("password")
        self.access_token = config.get("access_token")

        self.cleanup_interval = config.get("cleanup_interval", 60)
        self.max_redacts = config.get("max_redacts_per_run", 50)
        self.max_scan = config.get("max_scan_per_room", 1000)
        self.sync_timeout = config.get("sync_timeout", 10000)
        self.rate_limiter = RateLimiter(max_per_minute=config.get("max_requests_per_minute", 60))
        self.max_retention = parse_duration(config.get("max_retention", "365d")) or 31536000
        self.min_power = config.get("min_power_level", 50)
        self.prefix = config.get("command_prefix", "!expire")
        self.cmd_read_limit = config.get("cmd_read_limit", 24)
        self.help_text = HELP_TEMPLATE.format(p=self.prefix)
        self.notify_cleanup = config.get("notify_cleanup", False)

        # Admin whitelist: None = everyone with power level, list = only these users
        admins_raw = config.get("admins", "all")
        if isinstance(admins_raw, list):
            self.admins: list[str] | None = [a.strip() for a in admins_raw if a.strip()]
            if self.admins:
                logger.info(f"Admin whitelist: {', '.join(self.admins)}")
            else:
                self.admins = None
        elif isinstance(admins_raw, str) and admins_raw.strip().lower() != "all":
            # Comma-separated string from env var
            self.admins = [a.strip() for a in admins_raw.split(",") if a.strip()]
            if self.admins:
                logger.info(f"Admin whitelist: {', '.join(self.admins)}")
            else:
                self.admins = None
        else:
            self.admins = None
        self.default_retention = parse_duration(str(config.get("default_retention", "7d"))) or 604800
        self.command_cooldown = config.get("command_cooldown", 5)

        self.store_path = config.get("store_path", "/data/store")
        os.makedirs(self.store_path, exist_ok=True)

        client_config = AsyncClientConfig(
            store_sync_tokens=True,
            encryption_enabled=True,
        )

        self.client = AsyncClient(
            self.homeserver,
            self.user_id,
            store_path=self.store_path,
            config=client_config,
        )

        self.db = Database(config.get("database", "/data/expire-bot.db"))
        self._clean_lock = asyncio.Lock()  # Only one clean/cleanup at a time
        self._first_sync = True
        self._fresh_login = False
        self._shutdown = False
        self._stopped = False
        self._bg_tasks: set[asyncio.Task] = set()
        self._cmd_cooldown: dict[str, float] = {}  # user_id → last command time
        # E2E health: track decrypt failures for auto-recovery
        self._decrypt_fail_sessions: set[str] = set()
        self._decrypt_fail_since: float = 0.0
        self._e2e_reset_threshold = 5  # unique failing sessions
        self._e2e_reset_window = 120  # seconds

    # ─── Session persistence (device_id for E2E) ──────────────────────────

    def _session_file(self) -> str:
        return os.path.join(self.store_path, "session.json")

    def _load_session(self) -> dict | None:
        path = self._session_file()
        if os.path.exists(path):
            try:
                with open(path) as f:
                    return json.load(f)
            except (json.JSONDecodeError, OSError):
                pass
        return None

    def _save_session(self, device_id: str, access_token: str | None = None):
        data = {"device_id": device_id}
        if access_token:
            data["access_token"] = access_token
        with open(self._session_file(), "w") as f:
            json.dump(data, f)
        logger.info(f"Session saved (device={device_id})")

    # ─── Start ─────────────────────────────────────────────────────────────

    async def start(self):
        """Start the bot."""
        await self.db.connect()

        # Graceful shutdown
        loop = asyncio.get_event_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, lambda: asyncio.create_task(self._signal_shutdown()))

        # Login / restore session
        if not await self._authenticate():
            return

        # Register callbacks
        self.client.add_event_callback(self._on_message, RoomMessageText)
        self.client.add_event_callback(self._track_event, RoomMessage)
        self.client.add_event_callback(self._track_megolm, MegolmEvent)
        self.client.add_event_callback(self._on_megolm, MegolmEvent)
        self.client.add_event_callback(self._on_invite, InviteMemberEvent)
        self.client.add_event_callback(self._on_member, RoomMemberEvent)
        self.client.add_event_callback(self._on_power_levels, PowerLevelsEvent)
        # Trust all devices after each sync (E2E)
        self.client.add_response_callback(self._on_sync)

        # Initial sync
        logger.info("Performing initial sync...")
        await asyncio.wait_for(
            self.client.sync(timeout=10000, full_state=True), timeout=60,
        )

        # E2E key management — upload our keys + query others
        if self.client.olm:
            if self.client.should_upload_keys:
                await asyncio.wait_for(self.client.keys_upload(), timeout=15)
                logger.info("Device keys uploaded to server")
            if self.client.should_query_keys:
                await asyncio.wait_for(self.client.keys_query(), timeout=15)
                logger.info("Queried device keys from server")

        self._trust_all_devices()
        self._first_sync = False

        # Set avatar if configured
        await self._set_avatar()

        # Mark all current rooms as greeted (don't spam on restart)
        for room_id in self.client.rooms:
            if not await self.db.is_greeted(room_id):
                await self.db.mark_greeted(room_id)

        # Establish Olm sessions only on fresh login (not on restart)
        if self._fresh_login:
            await self._init_encrypted_rooms()

        rooms_with_retention = await self.db.get_all_rooms()
        logger.info(
            f"Synced. In {len(self.client.rooms)} rooms. "
            f"{len(rooms_with_retention)} room(s) with active retention. "
            f"E2E: {'enabled' if self.client.olm else 'disabled'}. Starting loops."
        )

        # Run sync + cleanup in parallel
        # sync_forever handles E2E key management automatically
        await asyncio.gather(
            self.client.sync_forever(timeout=self.sync_timeout),
            self._cleanup_loop(),
        )

    async def _authenticate(self) -> bool:
        """Login or restore session. Returns True on success."""
        saved = self._load_session()

        # 1. Try to restore saved session (has device_id → E2E works)
        if saved and saved.get("device_id"):
            token = self.access_token or saved.get("access_token")
            if token:
                self.client.restore_login(
                    user_id=self.user_id,
                    device_id=saved["device_id"],
                    access_token=token,
                )
                resp = await asyncio.wait_for(self.client.whoami(), timeout=15)
                if hasattr(resp, "user_id"):
                    logger.info(
                        f"Session restored as {resp.user_id} "
                        f"(device={saved['device_id']})"
                    )
                    return True
                else:
                    logger.warning(f"Saved session expired: {resp}")

        # 2. Password login — creates device + Olm keys (best for E2E)
        if self.password:
            # Reuse saved device_id if available
            if saved and saved.get("device_id"):
                self.client.device_id = saved["device_id"]
            resp = await asyncio.wait_for(
                self.client.login(self.password, device_name="expire-bot"), timeout=15,
            )
            if isinstance(resp, LoginResponse):
                self._save_session(resp.device_id, resp.access_token)
                self._fresh_login = True
                logger.info(f"Logged in as {resp.user_id} (device={resp.device_id})")
                if not self.access_token:
                    logger.info(f"Access token: {resp.access_token}")
                    logger.info("Save as EXPIRE_BOT_TOKEN for future use")
                return True
            else:
                logger.error(f"Login failed: {resp}")
                return False

        # 3. Token-only without saved session — E2E won't work
        if self.access_token:
            self.client.access_token = self.access_token
            self.client.user_id = self.user_id
            resp = await asyncio.wait_for(self.client.whoami(), timeout=15)
            if hasattr(resp, "user_id"):
                logger.info(f"Authenticated as {resp.user_id} (token, no device)")
                logger.warning(
                    "E2E encryption DISABLED — no device_id. "
                    "For E2E support, set EXPIRE_BOT_PASSWORD for first-time device registration."
                )
                return True
            else:
                logger.error(f"Token auth failed: {resp}")
                return False

        logger.error("No access_token or password provided")
        return False

    async def _signal_shutdown(self):
        logger.info("Received shutdown signal, cleaning up...")
        self._shutdown = True
        # Cancel background tasks
        for task in self._bg_tasks:
            if not task.done():
                task.cancel()
        for task in self._bg_tasks:
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
        self._bg_tasks.clear()
        await self.stop()

    def _spawn_bg(self, coro):
        """Create a tracked background task (cleaned up on shutdown)."""
        task = asyncio.create_task(coro)
        self._bg_tasks.add(task)
        task.add_done_callback(self._bg_tasks.discard)

    async def stop(self):
        if self._stopped:
            return
        self._stopped = True
        await self.db.close()
        await self.client.close()

    # ─── Callbacks ────────────────────────────────────────────────────────

    async def _on_invite(self, room: MatrixRoom, event: InviteMemberEvent):
        """Auto-accept invites (only from admins if whitelist is set)."""
        if event.state_key != self.user_id:
            return
        if self.admins and not self._match_admin(event.sender):
            logger.warning(f"Ignored invite to {room.room_id} from {event.sender} (not in admin whitelist)")
            return
        logger.info(f"Invited to {room.room_id} by {event.sender}")
        try:
            result = await asyncio.wait_for(self.client.join(room.room_id), timeout=30)
            if hasattr(result, "room_id"):
                logger.info(f"Joined {room.room_id}")
            else:
                logger.error(f"Failed to join {room.room_id}: {result}")
        except asyncio.TimeoutError:
            logger.error(f"Join timed out for {room.room_id}")

    async def _on_member(self, room: MatrixRoom, event: RoomMemberEvent):
        """Send help when bot joins a room for the first time."""
        if self._first_sync:
            return
        if event.state_key != self.user_id:
            return
        if event.membership in ("leave", "ban"):
            # Kicked/banned — clean up all room data
            await self.db.remove_room_data(room.room_id)
            logger.info(f"Removed from {room.room_id}, cleared all data")
            return
        if event.membership != "join":
            return

        # Only send help on first join (not on restart)
        if await self.db.is_greeted(room.room_id):
            logger.debug(f"Already greeted {room.room_id}, skipping help")
            return

        # Set default retention for new rooms
        if not await self.db.get_retention(room.room_id):
            await self.db.set_retention(room.room_id, self.default_retention, self.user_id)
            logger.info(f"Default retention {format_duration(self.default_retention)} set for {room.room_id}")

        msg = self.help_text + f"\n\n**Default retention: {format_duration(self.default_retention)}.**"
        # _can_redact will fetch power_levels via API if not in cache (federation)
        if not await self._can_redact(room):
            msg += (
                "\n\n**Warning:** I don't have redact permissions in this room yet. "
                "Please set my power level to **50** (moderator) so I can work."
            )
        await self._send(room.room_id, msg)
        await self.db.mark_greeted(room.room_id)
        logger.info(f"Joined {room.display_name} ({room.room_id}), encrypted={room.encrypted}")

    async def _on_power_levels(self, room: MatrixRoom, event: PowerLevelsEvent):
        """Notify when bot gains or loses redact permissions."""
        if self._first_sync:
            return

        retention = await self.db.get_retention(room.room_id)
        can_redact = await self._can_redact(room)

        if retention and not can_redact:
            await self._send(
                room.room_id,
                "**Warning:** my power level was reduced. "
                "I can no longer redact messages. Retention is paused until permissions are restored.",
            )
        elif retention and can_redact:
            logger.info(f"Permissions restored in {room.room_id}")

    async def _on_megolm(self, room: MatrixRoom, event: MegolmEvent):
        """Handle encrypted messages we can't decrypt — request missing keys.
        If too many unique sessions fail in a short window, nuke E2E store and restart.
        """
        if self._first_sync:
            return
        logger.warning(
            f"Undecryptable event {event.event_id} in {room.display_name} "
            f"from {event.sender} (session {event.session_id})"
        )
        # Request missing room key from the sender's device
        try:
            if self.client.olm:
                await self.client.request_room_key(event)
                logger.info(f"Requested room key for session {event.session_id} in {room.room_id}")
        except Exception as e:
            logger.debug(f"Key request failed: {e}")

        # Track unique failing sessions for auto-recovery
        now = time.time()
        if not self._decrypt_fail_since:
            self._decrypt_fail_since = now
        # Reset window if too much time passed
        if now - self._decrypt_fail_since > self._e2e_reset_window:
            self._decrypt_fail_sessions.clear()
            self._decrypt_fail_since = now
        self._decrypt_fail_sessions.add(event.session_id)

        if len(self._decrypt_fail_sessions) >= self._e2e_reset_threshold:
            logger.error(
                f"E2E BROKEN: {len(self._decrypt_fail_sessions)} unique undecryptable sessions "
                f"in {int(now - self._decrypt_fail_since)}s — nuking E2E store and restarting"
            )
            await self._nuke_e2e_and_restart()

    async def _nuke_e2e_and_restart(self):
        """Delete E2E store and exit. Docker restart will re-login with fresh device."""
        import shutil
        # Reset scan state so history gets re-imported after restart
        try:
            await self.db.db.execute("UPDATE room_scan_state SET fully_cleaned = 0")
            await self.db.db.commit()
        except Exception:
            pass
        try:
            await self.db.close()
        except Exception:
            pass
        try:
            await self.client.close()
        except Exception:
            pass
        # Remove session file so next start does a fresh login
        session_file = self._session_file()
        if os.path.exists(session_file):
            os.remove(session_file)
            logger.info(f"Removed session file: {session_file}")
        # Nuke E2E crypto store
        store = self.store_path
        if os.path.isdir(store):
            for entry in os.listdir(store):
                path = os.path.join(store, entry)
                if os.path.isdir(path):
                    shutil.rmtree(path)
                else:
                    os.remove(path)
            logger.info(f"Wiped E2E store: {store}")
        logger.error("Exiting for auto-restart with fresh E2E session")
        sys.exit(1)

    # ─── Event tracking (maubot-style) ───────────────────────────────

    async def _track_event(self, room: MatrixRoom, event: RoomMessage):
        """Track incoming messages for rooms with retention."""
        if self._first_sync:
            return
        # Successful decrypt — reset E2E failure counters
        self._decrypt_fail_sessions.clear()
        self._decrypt_fail_since = 0.0
        try:
            await self.db.ensure_connected()
            retention = await self.db.get_retention(room.room_id)
            if not retention:
                return
            ts = getattr(event, "server_timestamp", 0)
            if ts and hasattr(event, "event_id"):
                await self.db.track_event(event.event_id, room.room_id, ts)
        except Exception as e:
            logger.error(f"DB error in _track_event: {e}")

    async def _track_megolm(self, room: MatrixRoom, event: MegolmEvent):
        """Track encrypted messages we can't decrypt (still need to be redacted)."""
        if self._first_sync:
            return
        try:
            await self.db.ensure_connected()
            retention = await self.db.get_retention(room.room_id)
            if not retention:
                return
            ts = getattr(event, "server_timestamp", 0)
            if ts and hasattr(event, "event_id"):
                await self.db.track_event(event.event_id, room.room_id, ts)
        except Exception as e:
            logger.error(f"DB error in _track_megolm: {e}")

    # ─── Commands ─────────────────────────────────────────────────────

    async def _on_message(self, room: MatrixRoom, event: RoomMessageText):
        """Handle commands."""
        if self._first_sync:
            return
        if event.sender == self.user_id:
            return

        body = event.body[:len(self.prefix) + self.cmd_read_limit].strip()
        if not body.startswith(self.prefix):
            return

        await self.db.ensure_connected()

        # Admin whitelist — block all commands from non-admins
        if self.admins and not self._match_admin(event.sender):
            await self._send(room.room_id, "You are not in the bot's admin whitelist.", event.event_id)
            return

        # Rate limit commands per user
        now = time.time()
        last = self._cmd_cooldown.get(event.sender, 0)
        if now - last < self.command_cooldown:
            return
        self._cmd_cooldown[event.sender] = now

        args = body[len(self.prefix):].strip().split()
        cmd = args[0].lower() if args else "help"

        reply_to = event.event_id

        if cmd == "help":
            await self._send(room.room_id, self.help_text, reply_to)
        elif cmd in ("status", "show"):
            await self._cmd_status(room, reply_to)
        elif cmd == "set":
            if len(args) < 2:
                await self._send(room.room_id, f"Usage: `{self.prefix} set <duration>` (e.g. `7d`, `1h`, `10h 15m`)", reply_to)
                return
            await self._cmd_set(room, event, " ".join(args[1:]), reply_to)
        elif cmd in ("off", "unset"):
            await self._cmd_off(room, event, reply_to)
        elif cmd == "clean":
            await self._cmd_clean(room, event, reply_to)
        elif parse_duration(cmd):
            await self._cmd_set(room, event, " ".join(args), reply_to)
        else:
            await self._send(room.room_id, f"Unknown command: `{cmd}`. Try `{self.prefix} help`", reply_to)

    # ─── Commands ─────────────────────────────────────────────────────────

    async def _cmd_status(self, room: MatrixRoom, reply_to: str | None = None):
        info = await self.db.get_retention(room.room_id)
        can_redact = await self._can_redact(room)

        if info:
            retention_s, set_by, set_at = info
            dur = format_duration(retention_s)
            status = f"**Retention:** {dur}\n"
            status += f"**Set by:** {set_by}\n"
            status += f"**Permissions:** {'OK' if can_redact else 'MISSING — need power level 50+'}"
        else:
            status = "No retention set for this room.\n"
            status += f"**Permissions:** {'OK' if can_redact else 'MISSING — need power level 50+'}\n"
            status += f"Use `{self.prefix} set <duration>` to enable."

        await self._send(room.room_id, status, reply_to)

    async def _cmd_set(self, room: MatrixRoom, event: RoomMessageText, duration_str: str, reply_to: str | None = None):
        if not await self._has_power(room, event.sender):
            reason = "Only whitelisted admins can configure the bot." if self.admins \
                else f"Only room moderators (power level {self.min_power}+) can configure the bot."
            await self._send(room.room_id, reason, reply_to)
            return

        seconds = parse_duration(duration_str)
        if not seconds or seconds < 60:
            await self._send(
                room.room_id,
                f"Can't parse `{duration_str}`. "
                "Examples: `1h`, `7d`, `30d`, `10h 15m`, `1d 12h`. Minimum: `1m`.",
                reply_to,
            )
            return

        if seconds > self.max_retention:
            await self._send(
                room.room_id,
                f"Maximum retention period is **{format_duration(self.max_retention)}**.",
                reply_to,
            )
            return

        if not await self._can_redact(room):
            await self._send(
                room.room_id,
                "I need **moderator** rights (power level 50+) to redact messages.\n"
                "Please promote me first, then try again.",
                reply_to,
            )
            return

        await self.db.set_retention(room.room_id, seconds, event.sender)
        # Trigger initial history import for this room
        await self.db.clear_scan_state(room.room_id)
        dur = format_duration(seconds)
        await self._send(
            room.room_id,
            f"Retention set to **{dur}**.",
            reply_to,
        )
        logger.info(f"Retention set: {room.room_id} → {dur} by {event.sender}")
        # Fire-and-forget: import + cleanup in background (don't block sync)
        self._spawn_bg(self._bg_set_cleanup(room.room_id, seconds))

    async def _bg_set_cleanup(self, room_id: str, retention_seconds: int):
        """Background task: import history + run initial cleanup after !expire set."""
        try:
            async with self._clean_lock:
                await self._import_history(room_id, retention_seconds)
                count = await self._redact_expired(room_id, retention_seconds)
                if count > 0:
                    await self.db.log_cleanup(room_id, count)
                    if self.notify_cleanup:
                        await self._send(room_id, f"Cleaned **{count}** message(s).")
        except Exception as e:
            logger.error(f"Background set cleanup failed for {room_id}: {e}")

    async def _cmd_off(self, room: MatrixRoom, event: RoomMessageText, reply_to: str | None = None):
        if not await self._has_power(room, event.sender):
            reason = "Only whitelisted admins can configure the bot." if self.admins \
                else f"Only room moderators (power level {self.min_power}+) can configure the bot."
            await self._send(room.room_id, reason, reply_to)
            return

        info = await self.db.get_retention(room.room_id)
        if not info:
            await self._send(room.room_id, "Retention is already disabled for this room.", reply_to)
            return

        await self.db.remove_retention(room.room_id)
        await self.db.clear_scan_state(room.room_id)
        await self.db.clear_tracked_events(room.room_id)
        await self._send(room.room_id, "Retention disabled. Messages will no longer be auto-deleted.", reply_to)
        logger.info(f"Retention disabled: {room.room_id} by {event.sender}")

    async def _cmd_clean(self, room: MatrixRoom, event: RoomMessageText, reply_to: str | None = None):
        if not await self._has_power(room, event.sender):
            reason = "Only whitelisted admins can run cleanup." if self.admins \
                else f"Only room moderators (power level {self.min_power}+) can run cleanup."
            await self._send(room.room_id, reason, reply_to)
            return

        if not await self._can_redact(room):
            await self._send(
                room.room_id,
                "I don't have redact permissions. Please set my power level to 50+.",
                reply_to,
            )
            return

        # Only one clean at a time (across all rooms)
        if self._clean_lock.locked():
            await self._send(room.room_id, "Cleanup is already running. Please wait.", reply_to)
            return

        await self._send(room.room_id, "Starting cleanup...", reply_to)
        # Fire-and-forget: full clean in background (don't block sync)
        self._spawn_bg(self._bg_clean(room.room_id))

    async def _bg_clean(self, room_id: str):
        """Background task: import ALL history + redact ALL messages (loops until done)."""
        try:
            async with self._clean_lock:
                total = 0
                failures = 0
                deadline = time.time() + 300  # 5 min max per run
                while not self._shutdown and time.time() < deadline:
                    # Redact whatever is already tracked
                    count = await self._redact_expired(room_id, 0)
                    total += count

                    if count > 0:
                        failures = 0
                        continue  # More might be available

                    # Nothing to redact — check if we've imported everything
                    _, _, fully_scanned = await self.db.get_scan_state(room_id)
                    if fully_scanned:
                        break  # All imported and redacted

                    # Import more history (unlimited scan for clean)
                    prev_count = total
                    await self._import_history(room_id, 0, max_scan=50_000)

                    # Detect stuck loop (import keeps failing)
                    if total == prev_count:
                        failures += 1
                        if failures >= 5:
                            logger.warning(f"bg_clean: no progress after {failures} rounds in {room_id}, stopping")
                            break
                        await asyncio.sleep(2)
                    else:
                        failures = 0

                if total > 0:
                    await self.db.log_cleanup(room_id, total)
                    await self._send(room_id, f"Done. Cleaned **{total}** message(s).")
                else:
                    await self._send(room_id, "Nothing to clean.")
        except Exception as e:
            logger.error(f"Background clean failed for {room_id}: {e}")
            try:
                await self._send(room_id, f"Cleanup error: {e}")
            except Exception:
                pass

    # ─── Cleanup loop ─────────────────────────────────────────────────────

    async def _cleanup_loop(self):
        while not self._shutdown:
            await asyncio.sleep(self.cleanup_interval)
            if self._shutdown:
                continue
            # Purge stale cooldown entries
            now = time.time()
            self._cmd_cooldown = {k: v for k, v in self._cmd_cooldown.items() if now - v < 3600}
            # Skip cycle if rate limited or clean command is running
            if self.rate_limiter.in_cooldown:
                logger.debug("Cleanup skipped: rate limiter cooldown")
                continue
            if self._clean_lock.locked():
                logger.debug("Cleanup skipped: manual clean running")
                continue
            async with self._clean_lock:
                try:
                    await self._run_cleanup()
                except Exception as e:
                    logger.error(f"Cleanup error: {e}")

    async def _run_cleanup(self):
        rooms = await self.db.get_all_rooms()
        if not rooms:
            return
        logger.debug(f"Cleanup cycle: {len(rooms)} room(s) to check")

        total = 0
        for room_id, retention in rooms:
            if self._shutdown or self.rate_limiter.in_cooldown:
                break
            if room_id not in self.client.rooms:
                continue

            room = self.client.rooms[room_id]
            if not await self._can_redact(room):
                continue

            # Phase 1: Initial history import (runs once per room)
            _, _, fully_scanned = await self.db.get_scan_state(room_id)
            if not fully_scanned:
                await self._import_history(room_id, retention)

            # Phase 2: Redact expired events from tracked_events (fast)
            try:
                count = await self._redact_expired(room_id, retention)
                if count > 0:
                    await self.db.log_cleanup(room_id, count)
                    if self.notify_cleanup:
                        await self._send(room_id, f"Cleaned **{count}** expired message(s).")
                total += count
                if total >= self.max_redacts:
                    logger.info(f"Redact limit reached ({self.max_redacts}), continuing next cycle")
                    break
            except Exception as e:
                logger.error(f"Error cleaning {room_id}: {e}")

        if total > 0:
            logger.info(f"Cleanup: {total} messages redacted across {len(rooms)} room(s)")

    async def _safe_redact(self, room_id: str, event_id: str) -> str:
        """Redact with rate limiting. Returns 'ok', 'skip' (bad event), or 'stop' (rate limited)."""
        await self.rate_limiter.acquire()
        try:
            result = await asyncio.wait_for(
                self.client.room_redact(
                    room_id, event_id,
                    reason="Message expired",
                    tx_id=uuid.uuid4().hex,
                ),
                timeout=15,
            )
        except asyncio.TimeoutError:
            self.rate_limiter.set_cooldown()
            return "stop"
        if isinstance(result, RoomRedactError):
            msg = str(result.message) if hasattr(result, "message") else str(result)
            status = str(getattr(result, "status_code", ""))
            # 429 rate limit → stop batch, retry next cycle
            if "429" in msg or "429" in status or "limit" in msg.lower():
                self.rate_limiter.set_cooldown()
                return "stop"
            # 403/404 → event is un-redactable or already gone, skip permanently
            if "403" in status or "404" in status or "forbidden" in msg.lower() or "not found" in msg.lower():
                logger.debug(f"Skipping un-redactable {event_id}: {msg}")
                return "skip"
            logger.warning(f"Redact failed {event_id} in {room_id}: {msg}")
            return "stop"
        # Successful redact — gradually reduce backoff
        if self.rate_limiter._backoff > 1.0:
            self.rate_limiter._backoff = max(1.0, self.rate_limiter._backoff / 2)
        return "ok"

    async def _import_history(self, room_id: str, retention_seconds: int,
                              max_scan: int | None = None):
        """One-time history scan: import existing events into tracked_events table."""
        saved_token, _, _ = await self.db.get_scan_state(room_id)
        from_token = saved_token or ""
        scan_limit = max_scan if max_scan is not None else self.max_scan
        scanned = 0
        imported = 0

        logger.info(f"Importing history for {room_id[:20]}...")

        while scanned < scan_limit and not self._shutdown:
            try:
                resp = await asyncio.wait_for(
                    self.client.room_messages(
                        room_id,
                        start=from_token or None,
                        limit=100,
                        direction="b",
                    ),
                    timeout=30,
                )
            except asyncio.TimeoutError:
                logger.warning(f"History import timeout for {room_id[:20]}, saving progress")
                await self.db.save_scan_state(room_id, from_token, False)
                return

            if isinstance(resp, RoomMessagesError):
                logger.error(f"History import failed for {room_id}: {resp.message}")
                await self.db.save_scan_state(room_id, from_token, False)
                return

            if not resp.chunk:
                break

            batch: list[tuple[str, str, int]] = []
            for ev in resp.chunk:
                scanned += 1
                ev_type = getattr(ev, "type", "") or getattr(ev, "source", {}).get("type", "")
                if ev_type in STATE_EVENTS:
                    continue
                content = getattr(ev, "source", {}).get("content", {})
                if not content:
                    continue
                batch.append((ev.event_id, room_id, ev.server_timestamp))

            if batch:
                await self.db.track_events_batch(batch)
                imported += len(batch)

            from_token = resp.end
            if not from_token or from_token == resp.start:
                break

            # Yield between pages to keep sync responsive
            await asyncio.sleep(0)

        fully_scanned = scanned < scan_limit  # True if we reached the end
        await self.db.save_scan_state(room_id, from_token, fully_scanned)
        logger.info(f"History import {room_id[:20]}: {imported} events, scan_complete={fully_scanned}")

    async def _redact_expired(self, room_id: str, retention_seconds: int,
                              limit: int | None = None) -> int:
        """Redact expired events from tracked_events table. Fast: no API scanning."""
        cutoff_ms = (time.time() - retention_seconds) * 1000
        batch_limit = limit or self.max_redacts
        expired = await self.db.get_expired_events(room_id, cutoff_ms, batch_limit)

        if not expired:
            return 0

        logger.debug(f"Redacting {len(expired)} expired events in {room_id[:20]}")
        redacted = 0
        done_ids: list[str] = []
        skip_ids: list[str] = []

        for event_id in expired:
            if self._shutdown or self.rate_limiter.in_cooldown:
                break

            result = await self._safe_redact(room_id, event_id)
            if result == "ok":
                done_ids.append(event_id)
                redacted += 1
            elif result == "skip":
                # 403/404 — event is gone or un-redactable, remove from tracking
                skip_ids.append(event_id)
            else:
                # "stop" — rate limit or transient error, retry next cycle
                break

            # Pace redactions: 500ms between each — ~2/sec, gentle on server
            await asyncio.sleep(0.5)

        # Remove processed events from tracking table
        if done_ids or skip_ids:
            await self.db.remove_tracked_events(done_ids + skip_ids)
            if skip_ids:
                logger.info(f"Skipped {len(skip_ids)} un-redactable events in {room_id[:20]}")

        return redacted

    # ─── E2E trust ─────────────────────────────────────────────────────────

    def _trust_all_devices(self):
        """Auto-verify all known devices so E2E works without manual verification."""
        if not self.client.olm:
            return
        for user_id in self.client.device_store.users:
            for device in self.client.device_store.active_user_devices(user_id):
                if user_id == self.user_id and device.id == self.client.device_id:
                    continue
                if not self.client.olm.is_device_verified(device):
                    self.client.verify_device(device)
                    logger.debug(f"Trusted device {device.id} of {user_id}")

    async def _on_sync(self, response):
        """Called after each sync — trust any new devices."""
        # Detect rate limiting from sync responses
        if hasattr(response, "transport_response"):
            status = getattr(response.transport_response, "status", 0)
            if status == 429:
                self.rate_limiter.set_cooldown()
        # Trust devices only when actual device key changes occurred
        changed = getattr(response, "changed_device_keys", None)
        if changed:
            try:
                if self.client.olm and self.client.should_query_keys:
                    await self.client.keys_query()
            except Exception:
                pass
            self._trust_all_devices()

    async def _init_encrypted_rooms(self):
        """Establish Olm sessions with encrypted rooms on startup."""
        if not self.client.olm:
            return
        count = 0
        for room_id, room in self.client.rooms.items():
            if not room.encrypted:
                continue
            if count >= 10:  # Limit to avoid rate limiting at startup
                break
            try:
                await self.rate_limiter.acquire()
                # Send empty Olm message to establish E2E session (no spam)
                await asyncio.wait_for(
                    self.client.share_group_session(room_id),
                    timeout=15,
                )
                logger.info(f"E2E session init: {room.display_name}")
                count += 1
            except Exception as e:
                logger.warning(f"E2E init failed for {room.display_name}: {e}")

    # ─── Avatar ──────────────────────────────────────────────────────────

    async def _set_avatar(self):
        """Set bot avatar from config or env var. Skips if file unchanged."""
        avatar_path = self.config.get("avatar") or os.environ.get("EXPIRE_BOT_AVATAR", "")
        if not avatar_path or not os.path.isfile(avatar_path):
            return

        try:
            with open(avatar_path, "rb") as f:
                data = f.read()

            # Check if avatar changed since last upload
            file_hash = hashlib.md5(data).hexdigest()
            hash_file = os.path.join(self.store_path, "avatar_hash")
            if os.path.exists(hash_file):
                with open(hash_file) as f:
                    if f.read().strip() == file_hash:
                        logger.debug("Avatar unchanged, skipping upload")
                        return

            ext = os.path.splitext(avatar_path)[1].lower()
            content_types = {
                ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                ".gif": "image/gif", ".webp": "image/webp", ".svg": "image/svg+xml",
            }
            content_type = content_types.get(ext, "image/png")

            resp, _ = await asyncio.wait_for(
                self.client.upload(
                    io.BytesIO(data),
                    content_type=content_type,
                    filename=os.path.basename(avatar_path),
                    filesize=len(data),
                ), timeout=30,
            )

            if isinstance(resp, UploadResponse):
                await asyncio.wait_for(self.client.set_avatar(resp.content_uri), timeout=15)
                with open(hash_file, "w") as f:
                    f.write(file_hash)
                logger.info(f"Avatar set from {avatar_path}")
            else:
                logger.warning(f"Failed to upload avatar: {resp}")
        except Exception as e:
            logger.error(f"Failed to set avatar: {e}")

    # ─── Helpers ──────────────────────────────────────────────────────────

    async def _send(self, room_id: str, message: str, reply_to: str | None = None) -> str | None:
        """Send a markdown message to a room. Returns event_id."""
        try:
            content = {
                "msgtype": "m.notice",
                "body": message,
                "format": "org.matrix.custom.html",
                "formatted_body": self._md_to_html(message),
            }
            if reply_to:
                content["m.relates_to"] = {
                    "m.in_reply_to": {"event_id": reply_to},
                }
            # Trust any new devices before sending (federated users etc.)
            self._trust_all_devices()
            resp = await asyncio.wait_for(
                self.client.room_send(room_id, "m.room.message", content),
                timeout=15,
            )
            if hasattr(resp, "event_id"):
                return resp.event_id
        except Exception as e:
            logger.error(f"Failed to send to {room_id}: {e}")
        return None

    async def _fetch_power_levels(self, room_id: str) -> dict | None:
        """Fetch power_levels via API when room state cache is empty (federation lag)."""
        try:
            resp = await asyncio.wait_for(
                self.client.room_get_state_event(room_id, "m.room.power_levels", ""),
                timeout=10,
            )
            if hasattr(resp, "content") and resp.content:
                logger.debug(f"Fetched power_levels via API for {room_id}")
                return resp.content
        except Exception as e:
            logger.debug(f"Could not fetch power_levels for {room_id}: {e}")
        return None

    async def _get_user_level(self, room: MatrixRoom, user_id: str) -> int:
        """Get user's power level, with API fallback for federated rooms."""
        pl = room.power_levels
        if pl is not None:
            return pl.get_user_level(user_id)
        content = await self._fetch_power_levels(room.room_id)
        if content is None:
            return 0
        return content.get("users", {}).get(user_id, content.get("users_default", 0))

    def _match_admin(self, user_id: str) -> bool:
        """Check if user_id matches admin whitelist (supports glob: @*:server)."""
        if not self.admins:
            return False
        return any(fnmatch.fnmatch(user_id, pattern) for pattern in self.admins)

    async def _has_power(self, room: MatrixRoom, user_id: str) -> bool:
        """Check if user is allowed to configure bot.
        With admin whitelist: only matching users. Without: power level check."""
        if self.admins:
            return self._match_admin(user_id)
        return await self._get_user_level(room, user_id) >= self.min_power

    async def _can_redact(self, room: MatrixRoom) -> bool:
        """Check if bot can redact messages in this room."""
        pl = room.power_levels
        if pl is not None:
            return pl.can_user_redact(self.user_id)
        content = await self._fetch_power_levels(room.room_id)
        if content is None:
            return False
        user_level = content.get("users", {}).get(self.user_id, content.get("users_default", 0))
        redact_level = content.get("redact", 50)
        return user_level >= redact_level

    @staticmethod
    def _md_to_html(text: str) -> str:
        """Minimal markdown → HTML."""
        html = text
        html = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", html)
        html = re.sub(r"_(.+?)_", r"<em>\1</em>", html)
        html = re.sub(r"`(.+?)`", r"<code>\1</code>", html)
        html = html.replace("\n", "<br>")
        return html


# ─── Main ─────────────────────────────────────────────────────────────────────

def load_config() -> dict:
    """Load config from env vars, falling back to YAML file."""
    homeserver = os.environ.get("EXPIRE_BOT_HOMESERVER", "")
    access_token = os.environ.get("EXPIRE_BOT_TOKEN", "")
    user_id = os.environ.get("EXPIRE_BOT_USER", "")

    if homeserver and user_id and (access_token or os.environ.get("EXPIRE_BOT_PASSWORD")):
        config = {
            "homeserver": homeserver,
            "user_id": user_id,
        }
        if access_token:
            config["access_token"] = access_token
    else:
        config_path = os.environ.get("EXPIRE_BOT_CONFIG", "/data/config.yaml")
        for p in [config_path, "config.yaml", "/etc/expire-bot/config.yaml"]:
            if os.path.exists(p):
                with open(p) as f:
                    config = yaml.safe_load(f)
                break
        else:
            print("Config not found. Either set env vars:")
            print("  EXPIRE_BOT_HOMESERVER=https://matrix.example.com")
            print("  EXPIRE_BOT_USER=@expire-bot:example.com")
            print("  EXPIRE_BOT_TOKEN=syt_...")
            print("Or place config.yaml in /data/")
            sys.exit(1)

    # Env vars override file config
    for env_key, cfg_key in [
        ("EXPIRE_BOT_HOMESERVER", "homeserver"),
        ("EXPIRE_BOT_TOKEN", "access_token"),
        ("EXPIRE_BOT_USER", "user_id"),
        ("EXPIRE_BOT_PASSWORD", "password"),
        ("EXPIRE_BOT_PREFIX", "command_prefix"),
        ("EXPIRE_BOT_LOG_LEVEL", "log_level"),
        ("EXPIRE_BOT_DB", "database"),
        ("EXPIRE_BOT_AVATAR", "avatar"),
        ("EXPIRE_BOT_DEFAULT_RETENTION", "default_retention"),
        ("EXPIRE_BOT_ADMINS", "admins"),
    ]:
        val = os.environ.get(env_key)
        if val:
            config[cfg_key] = val

    for env_key, cfg_key in [
        ("EXPIRE_BOT_INTERVAL", "cleanup_interval"),
        ("EXPIRE_BOT_MAX_REDACTS", "max_redacts_per_run"),
        ("EXPIRE_BOT_COMMAND_COOLDOWN", "command_cooldown"),
        ("EXPIRE_BOT_SYNC_TIMEOUT", "sync_timeout"),
        ("EXPIRE_BOT_MAX_REQUESTS_PER_MINUTE", "max_requests_per_minute"),
    ]:
        val = os.environ.get(env_key)
        if val:
            config[cfg_key] = int(val)

    # Boolean env vars
    val = os.environ.get("EXPIRE_BOT_NOTIFY_CLEANUP", "")
    if val.lower() in ("1", "true", "yes"):
        config["notify_cleanup"] = True

    return config


async def main():
    config = load_config()

    logging.basicConfig(
        level=getattr(logging, config.get("log_level", "INFO")),
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    # Suppress noisy nio internal warnings (malformed events from server etc.)
    class _NioFilter(logging.Filter):
        def filter(self, record):
            return not record.name.startswith("nio")
    for handler in logging.getLogger().handlers:
        handler.addFilter(_NioFilter())

    logger.info(f"Starting Expire Bot as {config['user_id']}")
    logger.info(f"Homeserver: {config['homeserver']}")
    logger.info(f"Auth: {'token' if config.get('access_token') else 'password'}")
    logger.info(f"Cleanup interval: {config.get('cleanup_interval', 300)}s")

    bot = ExpireBot(config)
    try:
        await bot.start()
    except (KeyboardInterrupt, SystemExit):
        logger.info("Shutting down...")
    finally:
        await bot.stop()  # idempotent — safe even if _signal_shutdown already called


if __name__ == "__main__":
    asyncio.run(main())
