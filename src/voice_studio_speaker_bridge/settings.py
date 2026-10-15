from __future__ import annotations

import json
import logging
import os
import shutil
from pathlib import Path
from threading import RLock

from .models import VoiceAlias


APP_DIR_NAME = "VoxRelay"
LEGACY_APP_DIR_NAME = "VoiceStudioSpeakerBridge"


def default_config_dir() -> Path:
    portable = os.environ.get("VOXRELAY_DATA_DIR", "").strip()
    if portable:
        target = Path(portable).expanduser().resolve()
        legacy = Path(os.environ.get("LOCALAPPDATA", Path.home() / ".config")) / APP_DIR_NAME
        if not (target / "settings.json").exists() and (legacy / "settings.json").exists():
            target.mkdir(parents=True, exist_ok=True)
            for name in ("settings.json", "history.json"):
                source = legacy / name
                if source.exists():
                    shutil.copy2(source, target / name)
        return target
    base = Path(os.environ.get("LOCALAPPDATA", Path.home() / ".config"))
    target = base / APP_DIR_NAME
    legacy = base / LEGACY_APP_DIR_NAME
    if not (target / "settings.json").exists() and (legacy / "settings.json").exists():
        target.mkdir(parents=True, exist_ok=True)
        shutil.copy2(legacy / "settings.json", target / "settings.json")
    return target


class Settings:
    def __init__(self, path: Path | None = None):
        self.path = path or default_config_dir() / "settings.json"
        self.lock = RLock()
        self._loaded_mtime_ns = 0
        self.voice_studio_url = "http://127.0.0.1:3900"
        self.api_key = "local"
        self.request_timeout = 120.0
        self.polly_enabled = False
        self.windows_voices_enabled = True
        self.polly_region = "us-east-1"
        self.polly_profile = ""
        self.polly_access_key_encrypted = ""
        self.polly_secret_key_encrypted = ""
        self.polly_session_token_encrypted = ""
        self.ws_address = "127.0.0.1"
        # Use a separate port so the bridge can coexist with Speaker.bot.
        self.ws_port = 7581
        # A separate, simple endpoint for Streamer.bot actions. This keeps the
        # native Speaker.bot integration free to remain on its usual port.
        self.http_address = "127.0.0.1"
        self.http_port = 7582
        # Streamer.bot's UDP Broadcast sub-action sends a broadcast packet.
        # Windows only delivers that packet to a listener bound to all adapters.
        self.udp_address = "0.0.0.0"
        # Dedicated port; Speaker.bot commonly owns 6669.
        self.udp_port = 6670
        self.enable_udp = True
        self.streamerbot_actions_enabled = False
        self.streamerbot_http_url = "http://127.0.0.1:7474"
        self.streamerbot_queued_action = ""
        self.streamerbot_queue_added_action = ""
        self.streamerbot_playing_action = ""
        self.streamerbot_finished_action = ""
        self.streamerbot_received_action = ""
        self.streamerbot_generating_action = ""
        self.streamerbot_generated_action = ""
        self.streamerbot_error_action = ""
        self.streamerbot_cancelled_action = ""
        self.streamerbot_playback_delay = 0.0
        self.streamerbot_finished_delay = 0.0
        self.output_device = ""
        self.preview_output_device = ""
        self.voice_save_folder = ""
        self.max_characters = 500
        self.max_queue = 25
        self.per_user_cooldown = 0.0
        self.global_cooldown = 0.0
        self.block_links = False
        self.strip_links = False
        self.block_excess_caps = False
        self.collapse_repeated_characters = True
        self.ignore_command_messages = False
        self.ignore_mention_messages = False
        self.strip_non_ascii = False
        self.strip_emojis = False
        self.block_ascii_art = False
        self.blocked_words: list[str] = []
        self.user_blocklist: list[str] = []
        self.user_allowlist: list[str] = []
        self.replacements: dict[str, str] = {}
        self.pronunciations: dict[str, str] = {}
        self.hidden_pronunciations: list[str] = []
        self.user_voice_rules: dict[str, str] = {}
        self.role_voice_rules: dict[str, str] = {}
        self.history_limit = 200
        self.minimize_to_tray = False
        self.max_message_age = 0.0
        self.duplicate_window = 0.0
        self.per_user_queue_limit = 0
        self.persist_queue = False
        self.normalize_audio = False
        self.fade_audio = False
        self.stream_volume = 1.0
        self.preview_volume = 1.0
        self.routing_rules: list[dict] = []
        self.setup_completed = False
        self.check_updates_on_startup = False
        self.obs_ducking_enabled = False
        self.obs_url = "ws://127.0.0.1:4455"
        self.obs_input = ""
        self.obs_password_encrypted = ""
        self.obs_duck_volume = 0.25
        self.recovery_notice = ""
        self.aliases: dict[str, VoiceAlias] = {
            "EventVoice": VoiceAlias(name="EventVoice")
        }
        self.load()

    def load(self) -> None:
        if not self.path.exists():
            return
        previous_state = self.__dict__.copy()
        try:
            # Windows PowerShell 5 writes UTF-8 JSON with a BOM.
            try:
                data = json.loads(self.path.read_text(encoding="utf-8-sig"))
                if not isinstance(data, dict):
                    raise ValueError("Settings must be an object")
            except (ValueError, UnicodeError):
                backup = self.path.with_suffix(".json.bak")
                data = json.loads(backup.read_text(encoding="utf-8-sig"))
                if not isinstance(data, dict):
                    raise ValueError("Backup must be an object")
                self.recovery_notice = "Settings were recovered from the last backup. Save to repair the settings file."
                logging.warning(self.recovery_notice)
            self.voice_studio_url = str(data.get("voice_studio_url", self.voice_studio_url)).rstrip("/")
            self.api_key = str(data.get("api_key", self.api_key))
            self.request_timeout = max(1, min(600, float(data.get("request_timeout", self.request_timeout))))
            self.polly_enabled = bool(data.get("polly_enabled", self.polly_enabled))
            self.windows_voices_enabled = bool(data.get("windows_voices_enabled", True))
            self.polly_region = str(data.get("polly_region", self.polly_region)).strip() or "us-east-1"
            self.polly_profile = str(data.get("polly_profile", self.polly_profile)).strip()
            self.polly_access_key_encrypted = str(data.get("polly_access_key_encrypted", self.polly_access_key_encrypted)).strip()
            self.polly_secret_key_encrypted = str(data.get("polly_secret_key_encrypted", self.polly_secret_key_encrypted)).strip()
            self.polly_session_token_encrypted = str(data.get("polly_session_token_encrypted", "")).strip()
            self.ws_address = str(data.get("ws_address", self.ws_address))
            ws_port = int(data.get("ws_port", self.ws_port))
            self.ws_port = ws_port if 1 <= ws_port <= 65535 else self.ws_port
            self.http_address = str(data.get("http_address", self.http_address))
            http_port = int(data.get("http_port", self.http_port))
            self.http_port = http_port if 1 <= http_port <= 65535 else self.http_port
            self.udp_address = str(data.get("udp_address", self.udp_address))
            udp_port = int(data.get("udp_port", self.udp_port))
            self.udp_port = udp_port if 1 <= udp_port <= 65535 else self.udp_port
            self.enable_udp = bool(data.get("enable_udp", self.enable_udp))
            self.streamerbot_actions_enabled = bool(data.get("streamerbot_actions_enabled", self.streamerbot_actions_enabled))
            self.streamerbot_http_url = str(data.get("streamerbot_http_url", self.streamerbot_http_url)).rstrip("/")
            self.streamerbot_queued_action = str(data.get("streamerbot_queued_action", self.streamerbot_queued_action))
            self.streamerbot_queue_added_action = str(data.get("streamerbot_queue_added_action", self.streamerbot_queue_added_action))
            self.streamerbot_playing_action = str(data.get("streamerbot_playing_action", self.streamerbot_playing_action))
            self.streamerbot_finished_action = str(data.get("streamerbot_finished_action", self.streamerbot_finished_action))
            for state in ("received", "generating", "generated", "error", "cancelled"):
                key = f"streamerbot_{state}_action"
                setattr(self, key, str(data.get(key, "")))
            self.streamerbot_playback_delay = max(0.0, min(10.0, float(data.get("streamerbot_playback_delay", self.streamerbot_playback_delay))))
            self.streamerbot_finished_delay = max(0.0, min(10.0, float(data.get("streamerbot_finished_delay", self.streamerbot_finished_delay))))
            self.output_device = str(data.get("output_device", self.output_device))
            self.preview_output_device = str(data.get("preview_output_device", self.preview_output_device))
            self.voice_save_folder = str(data.get("voice_save_folder", self.voice_save_folder))
            self.max_characters = max(1, min(100000, int(data.get("max_characters", self.max_characters))))
            self.max_queue = max(1, min(10000, int(data.get("max_queue", self.max_queue))))
            self.per_user_cooldown = max(0, float(data.get("per_user_cooldown", self.per_user_cooldown)))
            self.global_cooldown = max(0, float(data.get("global_cooldown", self.global_cooldown)))
            self.block_links = bool(data.get("block_links", self.block_links))
            self.strip_links = bool(data.get("strip_links", self.strip_links))
            self.block_excess_caps = bool(data.get("block_excess_caps", self.block_excess_caps))
            self.collapse_repeated_characters = bool(data.get("collapse_repeated_characters", self.collapse_repeated_characters))
            self.ignore_command_messages = bool(data.get("ignore_command_messages", self.ignore_command_messages))
            self.ignore_mention_messages = bool(data.get("ignore_mention_messages", self.ignore_mention_messages))
            self.strip_non_ascii = bool(data.get("strip_non_ascii", self.strip_non_ascii))
            self.strip_emojis = bool(data.get("strip_emojis", self.strip_emojis))
            self.block_ascii_art = bool(data.get("block_ascii_art", self.block_ascii_art))
            # PowerShell serializes an empty pipeline as JSON null. Treat null
            # collections as empty so one blank Rules field cannot invalidate
            # the rest of the settings file (especially saved voice aliases).
            self.blocked_words = [str(value) for value in (data.get("blocked_words") or [])]
            self.user_blocklist = [str(value) for value in (data.get("user_blocklist") or [])]
            self.user_allowlist = [str(value) for value in (data.get("user_allowlist") or [])]
            self.replacements = {str(key): str(value) for key, value in (data.get("replacements") or {}).items()}
            self.pronunciations = {str(key): str(value) for key, value in (data.get("pronunciations") or {}).items()}
            self.hidden_pronunciations = [str(value) for value in (data.get("hidden_pronunciations") or [])]
            self.user_voice_rules = {str(key).casefold(): str(value) for key, value in (data.get("user_voice_rules") or {}).items()}
            self.role_voice_rules = {str(key).casefold(): str(value) for key, value in (data.get("role_voice_rules") or {}).items()}
            self.history_limit = max(1, min(100000, int(data.get("history_limit", self.history_limit))))
            self.minimize_to_tray = bool(data.get("minimize_to_tray", self.minimize_to_tray))
            for key, upper in (("max_message_age", 86400), ("duplicate_window", 3600),
                               ("per_user_queue_limit", 1000), ("stream_volume", 2), ("preview_volume", 2)):
                value = max(0, min(upper, float(data.get(key, getattr(self, key)))))
                setattr(self, key, int(value) if key == "per_user_queue_limit" else value)
            for key in ("persist_queue", "normalize_audio", "fade_audio", "setup_completed", "check_updates_on_startup"):
                setattr(self, key, bool(data.get(key, getattr(self, key))))
            self.routing_rules = [rule for rule in (data.get("routing_rules") or []) if isinstance(rule, dict)]
            self.obs_ducking_enabled = bool(data.get("obs_ducking_enabled", False))
            self.obs_url = str(data.get("obs_url", self.obs_url))
            self.obs_input = str(data.get("obs_input", ""))
            self.obs_password_encrypted = str(data.get("obs_password_encrypted", ""))
            self.obs_duck_volume = max(0, min(1, float(data.get("obs_duck_volume", 0.25))))
            aliases = data.get("aliases", {})
            if isinstance(aliases, dict):
                self.aliases = {
                    name: VoiceAlias.from_dict(name, value)
                    for name, value in aliases.items()
                }
            self._loaded_mtime_ns = self.path.stat().st_mtime_ns
        except (OSError, ValueError, TypeError, AttributeError, json.JSONDecodeError):
            self.__dict__.clear()
            self.__dict__.update(previous_state)
            logging.exception("Could not load settings from %s", self.path)

    def reload_if_changed(self) -> bool:
        """Reload settings written by the WPF front end without restarting."""
        try:
            modified = self.path.stat().st_mtime_ns
        except OSError:
            return False
        if modified == self._loaded_mtime_ns:
            return False
        with self.lock:
            # Recheck after taking the lock in case another request reloaded it.
            try:
                modified = self.path.stat().st_mtime_ns
            except OSError:
                return False
            if modified == self._loaded_mtime_ns:
                return False
            self.load()
            return self._loaded_mtime_ns == modified

    def save(self) -> None:
        with self.lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            payload = {
                "voice_studio_url": self.voice_studio_url.rstrip("/"),
                "api_key": self.api_key,
                "request_timeout": self.request_timeout,
                "polly_enabled": self.polly_enabled,
                "windows_voices_enabled": self.windows_voices_enabled,
                "polly_region": self.polly_region,
                "polly_profile": self.polly_profile,
                "polly_access_key_encrypted": self.polly_access_key_encrypted,
                "polly_secret_key_encrypted": self.polly_secret_key_encrypted,
                "polly_session_token_encrypted": self.polly_session_token_encrypted,
                "ws_address": self.ws_address,
                "ws_port": self.ws_port,
                "http_address": self.http_address,
                "http_port": self.http_port,
                "udp_address": self.udp_address,
                "udp_port": self.udp_port,
                "enable_udp": self.enable_udp,
                "streamerbot_actions_enabled": self.streamerbot_actions_enabled,
                "streamerbot_http_url": self.streamerbot_http_url.rstrip("/"),
                "streamerbot_queued_action": self.streamerbot_queued_action,
                "streamerbot_queue_added_action": self.streamerbot_queue_added_action,
                "streamerbot_playing_action": self.streamerbot_playing_action,
                "streamerbot_finished_action": self.streamerbot_finished_action,
                "streamerbot_playback_delay": self.streamerbot_playback_delay,
                "streamerbot_finished_delay": self.streamerbot_finished_delay,
                "output_device": self.output_device,
                "preview_output_device": self.preview_output_device,
                "voice_save_folder": self.voice_save_folder,
                "max_characters": self.max_characters,
                "max_queue": self.max_queue,
                "per_user_cooldown": self.per_user_cooldown,
                "global_cooldown": self.global_cooldown,
                "block_links": self.block_links,
                "strip_links": self.strip_links,
                "block_excess_caps": self.block_excess_caps,
                "collapse_repeated_characters": self.collapse_repeated_characters,
                "ignore_command_messages": self.ignore_command_messages,
                "ignore_mention_messages": self.ignore_mention_messages,
                "strip_non_ascii": self.strip_non_ascii,
                "strip_emojis": self.strip_emojis,
                "block_ascii_art": self.block_ascii_art,
                "blocked_words": self.blocked_words,
                "user_blocklist": self.user_blocklist,
                "user_allowlist": self.user_allowlist,
                "replacements": self.replacements,
                "pronunciations": self.pronunciations,
                "hidden_pronunciations": self.hidden_pronunciations,
                "user_voice_rules": self.user_voice_rules,
                "role_voice_rules": self.role_voice_rules,
                "history_limit": self.history_limit,
                "minimize_to_tray": self.minimize_to_tray,
                "aliases": {name: alias.to_dict() for name, alias in self.aliases.items()},
            }
            for key in ("max_message_age", "duplicate_window", "per_user_queue_limit", "persist_queue",
                        "normalize_audio", "fade_audio", "stream_volume", "preview_volume", "routing_rules", "setup_completed",
                        "obs_ducking_enabled", "obs_url", "obs_input", "obs_password_encrypted", "obs_duck_volume", "check_updates_on_startup"):
                payload[key] = getattr(self, key)
            for state in ("received", "generating", "generated", "error", "cancelled"):
                key = f"streamerbot_{state}_action"
                payload[key] = getattr(self, key)
            temp = self.path.with_suffix(".tmp")
            temp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
            if self.path.exists():
                try:
                    previous = json.loads(self.path.read_text(encoding="utf-8-sig"))
                    if isinstance(previous, dict):
                        shutil.copy2(self.path, self.path.with_suffix(".json.bak"))
                except (OSError, ValueError):
                    pass  # Never replace the good backup with a broken file.
            temp.replace(self.path)
            self._loaded_mtime_ns = self.path.stat().st_mtime_ns

    def get_alias(self, name: str) -> VoiceAlias | None:
        self.reload_if_changed()
        with self.lock:
            return self.aliases.get(name)
