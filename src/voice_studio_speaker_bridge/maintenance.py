"""Portable maintenance files; diagnostics deliberately exclude speech and secrets."""
from __future__ import annotations

import json
import platform
from datetime import datetime, timezone
from pathlib import Path
import shutil
import re
import uuid
from urllib.request import Request, urlopen
from urllib.error import HTTPError
import zipfile

from .settings import Settings
from . import __version__

PRESET_KEYS = ("aliases", "pronunciations", "hidden_pronunciations", "routing_rules",
               "user_voice_rules", "role_voice_rules", "replacements")
PROFILE_KEYS = PRESET_KEYS + ("output_device", "preview_output_device", "stream_volume", "preview_volume",
    "max_characters", "max_queue", "max_message_age", "duplicate_window", "per_user_queue_limit",
    "per_user_cooldown", "global_cooldown", "blocked_words", "user_blocklist", "user_allowlist",
    "strip_links", "block_links", "strip_emojis", "ignore_command_messages", "ignore_mention_messages",
    "strip_non_ascii", "block_ascii_art", "normalize_audio", "fade_audio")


class Maintenance:
    def __init__(self, settings: Settings):
        self.settings = settings

    def _folder(self, name: str) -> Path:
        folder = self.settings.path.parent / name
        folder.mkdir(parents=True, exist_ok=True)
        return folder

    def backup(self) -> str:
        self.settings.reload_if_changed()
        self.settings.save()
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
        destination = self._folder("backups") / f"VoxRelay-{stamp}.json"
        shutil.copy2(self.settings.path, destination)
        return str(destination)

    def restore(self, filename: str) -> None:
        # Only restore files previously created in the app's backup directory.
        if Path(filename).name != filename:
            raise ValueError("Choose a backup from the backup list")
        source = self._folder("backups") / filename
        candidate = Settings(source)
        if not source.is_file() or not candidate._loaded_mtime_ns:
            raise ValueError("This backup could not be read")
        self.backup()
        temp = self.settings.path.with_suffix(".restore.tmp")
        temp.write_text(source.read_text(encoding="utf-8-sig"), encoding="utf-8")
        temp.replace(self.settings.path)
        self.settings.load()

    def backups(self) -> list[str]:
        return sorted((path.name for path in self._folder("backups").glob("VoxRelay-*.json")), reverse=True)

    def profiles(self) -> list[str]:
        return sorted((path.stem.removeprefix("profile-") for path in self._folder("profiles").glob("profile-*.json")), key=str.casefold)

    def _profile_path(self, name: str) -> Path:
        name = name.strip()
        if not re.fullmatch(r"[\w .-]{1,64}", name) or name.endswith("."):
            raise ValueError("Use 1–64 letters, numbers, spaces, hyphens or underscores for the profile name")
        return self._folder("profiles") / f"profile-{name}.json"

    def save_profile(self, name: str) -> str:
        self.settings.reload_if_changed()
        self.settings.save()
        data = json.loads(self.settings.path.read_text(encoding="utf-8-sig"))
        destination = self._profile_path(name)
        temporary = destination.with_suffix(".tmp")
        temporary.write_text(json.dumps({key: data.get(key) for key in PROFILE_KEYS}, indent=2), encoding="utf-8")
        temporary.replace(destination)
        return str(destination)

    def load_profile(self, name: str) -> None:
        source = self._profile_path(name)
        values = json.loads(source.read_text(encoding="utf-8"))
        if not isinstance(values, dict):
            raise ValueError("This profile could not be read")
        self.settings.reload_if_changed()
        self.settings.save()
        current = json.loads(self.settings.path.read_text(encoding="utf-8"))
        current.update({key: value for key, value in values.items() if key in PROFILE_KEYS})
        temp = self.settings.path.with_name(f"profile-check-{uuid.uuid4().hex}.json")
        try:
            temp.write_text(json.dumps(current, indent=2), encoding="utf-8")
            candidate = Settings(temp)
            if not candidate._loaded_mtime_ns:
                raise ValueError("This profile contains invalid settings")
            self.backup()
            temp.replace(self.settings.path)
            self.settings.load()
        finally:
            temp.unlink(missing_ok=True)

    def reset(self, confirmation: str) -> str:
        if confirmation != "RESET":
            raise ValueError("Reset must be confirmed in Settings")
        backup = self.backup()
        defaults = Settings(self.settings.path.with_name(f"defaults-{uuid.uuid4().hex}.json"))
        defaults.path = self.settings.path
        defaults.save()
        self.settings.load()
        return backup

    @staticmethod
    def check_updates() -> dict:
        request = Request("https://api.github.com/repos/The-RedGear/VoxRelay/releases/latest",
                          headers={"Accept": "application/vnd.github+json", "User-Agent": "VoxRelay/"+__version__})
        try:
            with urlopen(request, timeout=5) as response:
                data = json.loads(response.read(100000))
        except HTTPError as exc:
            if exc.code == 404:
                return {"checked": False, "message": "No public release is available yet. Private releases can be accessed on GitHub."}
            raise ValueError("Could not check for updates. Try again later.") from exc
        tag = str(data.get("tag_name", ""))
        match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", tag)
        if not match:
            return {"checked": False, "message": "No stable release is available yet."}
        available = tuple(map(int, match.groups())) > tuple(map(int, __version__.split(".")))
        return {"checked": True, "available": available, "version": tag,
                "message": f"VoxRelay {tag} is available on GitHub." if available else "You have the latest stable version."}

    def diagnostics(self, state: dict, events: list[dict]) -> str:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
        destination = self._folder("exports") / f"VoxRelay-diagnostics-{stamp}.zip"
        safe = {
            "app": "VoxRelay", "version": __version__, "python": platform.python_version(),
            "system": platform.system(), "release": platform.release(),
            "queueLength": state.get("queueLength", 0), "paused": state.get("paused", False),
            "pollyEnabled": self.settings.polly_enabled,
            "aliasCount": len(self.settings.aliases), "recoveryNotice": self.settings.recovery_notice,
            "events": [{"time": item["time"], "source": item["source"], "event": item["event"]}
                       for item in events],
        }
        with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("diagnostics.json", json.dumps(safe, indent=2))
        return str(destination)

    def export_presets(self) -> str:
        self.settings.reload_if_changed()
        data = json.loads(self.settings.path.read_text(encoding="utf-8-sig"))
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
        destination = self._folder("exports") / f"VoxRelay-presets-{stamp}.json"
        # Presets exclude provider credentials and local/network configuration.
        payload = {"format": "VoxRelay-presets", "version": 1,
                   "settings": {key: data.get(key) for key in PRESET_KEYS}}
        destination.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        return str(destination)

    def export_streamerbot(self, alias: str) -> str:
        from .streamerbot_export import export_actions
        self.settings.reload_if_changed()
        if alias not in self.settings.aliases:
            raise ValueError("Choose an existing voice alias")
        destination = self._folder("exports") / "VoxRelay-actions.sb"
        destination.write_text(export_actions(self.settings.udp_port, alias), encoding="utf-8")
        return str(destination)

    @staticmethod
    def preview_speakerbot(data: dict) -> dict:
        """Read alias metadata only. Never read Speaker.bot's credential databases."""
        if not isinstance(data.get("aliases"), list):
            raise ValueError("Choose Speaker.bot's data/voicealiases.dat file")
        aliases, skipped = {}, []
        for entry in data["aliases"]:
            name = str(entry.get("name", "")).strip()
            voices = entry.get("voices") or []
            if not name or not voices:
                continue
            voice = voices[0]
            match = re.fullmatch(r"Amazon Polly - .+ - (.+) \((standard|neural|long-form|generative)\)", str(voice.get("name", "")))
            if not match:
                skipped.append({"name": name, "reason": "This voice engine is not installed in VoxRelay."})
                continue
            aliases[name] = {"provider": "polly", "voice_id": match[1], "model": match[2],
                             "volume": max(0, min(2, float(voice.get("volume", 1)))), "speed": 1,
                             "group": "Imported"}
        return {"format": "VoxRelay-presets", "version": 1, "settings": {"aliases": aliases},
                "skipped": skipped,
                "note": "Audio devices and engine-specific rate/pitch need review. Multi-voice aliases import their first supported voice only. AWS credentials are configured separately."}

    def import_presets(self, payload: dict) -> dict:
        if payload.get("format") != "VoxRelay-presets" or payload.get("version") != 1:
            raise ValueError("Choose a VoxRelay preset file")
        values = payload.get("settings")
        if not isinstance(values, dict):
            raise ValueError("Preset settings must be an object")
        for key, value in values.items():
            if key not in PRESET_KEYS:
                raise ValueError(f"Unsupported preset field: {key}")
            expected = list if key in {"hidden_pronunciations", "routing_rules"} else dict
            if value is not None and not isinstance(value, expected):
                raise ValueError(f"Invalid preset field: {key}")
        # Validate alias values before saving anything.
        from .models import VoiceAlias
        aliases = {}
        for name, value in (values.get("aliases") or {}).items():
            if not isinstance(name, str) or not name.strip() or not isinstance(value, dict):
                raise ValueError("Every alias needs a name and voice settings")
            aliases[name] = VoiceAlias.from_dict(name, value)
        self.backup()
        for key, value in values.items():
            if key == "aliases":
                self.settings.aliases.update(aliases)
            elif key in {"routing_rules", "hidden_pronunciations"}:
                setattr(self.settings, key, value or [])
            else:
                getattr(self.settings, key).update(value or {})
        self.settings.save()
        return {"aliasesImported": len(aliases)}
