from __future__ import annotations

from typing import TYPE_CHECKING
import random
from dataclasses import replace

from .settings import Settings
from . import __version__


import json


def _parse_streamerbot_user(value) -> tuple[str, str]:
    """Normalize Streamer.bot %user% / %userName% into (display, login).

    Some Streamer.bot variable paths stringify a whole user object into JSON
    (badges, login, name, ...). That must never be used as the viewer key.
    """
    if value is None:
        return "", ""
    if isinstance(value, dict):
        display = str(
            value.get("name")
            or value.get("displayName")
            or value.get("display_name")
            or ""
        ).strip()
        login = str(
            value.get("login")
            or value.get("userName")
            or value.get("user_name")
            or value.get("userLogin")
            or ""
        ).strip()
        return display, login
    text = str(value).strip()
    if not text:
        return "", ""
    if text.startswith("%") and text.endswith("%") and len(text) > 2:
        return "", ""
    if text.startswith("{") and ('"login"' in text or '"badges"' in text or "'login'" in text):
        try:
            parsed = json.loads(text)
        except Exception:
            return "", ""
        if isinstance(parsed, dict):
            return _parse_streamerbot_user(parsed)
        return "", ""
    return text, text



if TYPE_CHECKING:
    from .engine import SpeechEngine


class SpeakerBotProtocol:
    EVENTS = {
        "application": ["startedspeaking", "stoppedspeaking"],
        "texttospeech": ["received", "generating", "textqueued", "queueadded", "engineprocessed", "playing", "finished", "cancelled", "deleted", "error"],
        "voicegate": ["profileactivated"],
    }

    def __init__(self, settings: Settings, engine: "SpeechEngine"):
        self.settings = settings
        self.engine = engine

    def execute(self, request: str, data: dict) -> dict:
        normalized = request.lower()
        if normalized == "speak":
            self.settings.reload_if_changed()
            text = str(data.get("message", "")).strip()
            alias_name = str(data.get("voice", "")).strip()
            display_a, login_a = _parse_streamerbot_user(data.get("user", data.get("displayName", "")))
            display_b, login_b = _parse_streamerbot_user(
                data.get("userName", data.get("userLogin", data.get("login", "")))
            )
            # Prefer real display/login pairs; never keep JSON blobs.
            user_display = display_a or display_b
            user_login = login_b or login_a
            if user_display and user_display == user_login and display_a and login_b and display_a != login_b:
                user_display, user_login = display_a, login_b
            user = user_display or user_login
            # Prefer login for allowlist/blocklist when both are known.
            moderation_user = user_login or user_display or user
            role = str(data.get("role", "")).strip().casefold()
            # Role may also arrive as part of a Streamer.bot user object.
            # Never reuse `text` here — that variable is the spoken message.
            if not role:
                for raw in (data.get("user"), data.get("userName")):
                    if isinstance(raw, dict) and raw.get("role") is not None:
                        role = str(raw.get("role")).strip().casefold()
                        break
                    raw_text = str(raw or "").strip()
                    if raw_text.startswith("{") and '"role"' in raw_text:
                        try:
                            parsed = json.loads(raw_text)
                            if isinstance(parsed, dict) and parsed.get("role") is not None:
                                role = str(parsed.get("role")).strip().casefold()
                                break
                        except Exception:
                            pass
            source = str(data.get("source", "Streamer.bot")).strip()
            priority = int(data.get("priority", 0))
            user_keys = {
                value.casefold()
                for value in (user_display, user_login, user)
                if value
            }
            routing_matched = False
            for rule in self.settings.routing_rules:
                if rule.get("enabled", True) is False:
                    continue
                field = str(rule.get("field", ""))
                rule_value = str(rule.get("value", "")).casefold()
                if field == "user":
                    matched = bool(rule_value) and rule_value in user_keys
                else:
                    actual = {"role": role, "source": source, "event": str(data.get("event", ""))}.get(field)
                    matched = actual is not None and actual.casefold() == rule_value
                if matched:
                    alias_name = str(rule.get("alias") or alias_name)
                    priority = int(rule.get("priority", priority))
                    routing_matched = True
                    break
            rule_alias = None
            for key in user_keys:
                rule_alias = self.settings.user_voice_rules.get(key)
                if rule_alias:
                    break
            if not rule_alias and role:
                rule_alias = self.settings.role_voice_rules.get(role)
            if rule_alias and not routing_matched:
                alias_name = rule_alias
            if alias_name.casefold().startswith("group:"):
                group = alias_name.split(":", 1)[1].strip().casefold()
                choices = [alias for alias in self.settings.aliases.values() if alias.group.casefold() == group]
                if not choices:
                    raise ValueError(f"Voice group not found or empty: {group}")
                alias = random.choice(choices)
                alias_name = alias.name
            else:
                alias = self.settings.get_alias(alias_name)
            if alias is None:
                raise ValueError(f"Voice alias not found: {alias_name}")
            overrides = {}
            if "speed" in data:
                overrides["speed"] = float(data["speed"])
            if "volume" in data:
                overrides["volume"] = float(data["volume"])
            if "ssml" in data:
                overrides["ssml"] = bool(data["ssml"])
            if str(data.get("instruct", "")).strip():
                overrides["instruct"] = str(data["instruct"]).strip()
            if overrides:
                alias = replace(alias, **overrides)
            if priority:
                job = self.engine.enqueue(text, alias, source=source, user=moderation_user, priority=priority)
            else:
                job = self.engine.enqueue(text, alias, source=source, user=moderation_user)
            return {
                "speechId": job.speech_id,
                "text": text,
                "voiceName": alias_name,
                "pitch": 0.0,
                "volume": alias.volume,
                "rate": alias.speed,
            }
        if normalized == "stop":
            self.engine.stop_current()
            return {}
        if normalized == "pause":
            self.engine.pause()
            return {}
        if normalized == "pauseaftercurrent":
            self.engine.pause_after_current()
            return {}
        if normalized == "clearall":
            self.engine.clear_all()
            return {}
        if normalized == "resume":
            self.engine.resume()
            return {}
        if normalized == "clear":
            self.engine.clear()
            return {}
        if normalized in {"enable", "on"}:
            self.engine.enable()
            return {}
        if normalized in {"disable", "off"}:
            self.engine.disable()
            return {}
        if normalized == "getinfo":
            return {
                "instanceId": "45402e66-303c-43a4-bb1c-4ba721bb0569",
                "name": "Speaker.bot",
                "version": "0.1.6",
                "os": "windows",
                "apiVersion": 2,
                "bridgeName": "VoxRelay",
                "bridgeVersion": __version__,
            }
        if normalized == "getevents":
            return {"events": self.EVENTS}
        if normalized == "getaliases":
            self.settings.reload_if_changed()
            return {
                "aliases": [
                    {"id": index, "name": name, "voiceCount": 1}
                    for index, name in enumerate(sorted(self.settings.aliases), 1)
                ]
            }
        if normalized == "getstate":
            return self.engine.state()
        if normalized == "loadprofile":
            from .maintenance import Maintenance
            name = str(data.get("profile", ""))
            Maintenance(self.settings).load_profile(name)
            return {"profile": name}
        if normalized == "gethistory":
            return {"history": self.engine.history_items()}
        if normalized == "clearhistory":
            self.engine.clear_history()
            return {}
        if normalized == "savehistoryaudio":
            return {"path": self.engine.save_history_audio(str(data.get("speechId", "")))}
        if normalized == "replayhistory":
            job = self.engine.replay_history(str(data.get("speechId", "")))
            return {"speechId": job.speech_id}
        if normalized == "removespeech":
            return {"removed": self.engine.remove(str(data.get("speechId", "")))}
        if normalized == "movespeech":
            direction = -1 if str(data.get("direction", "up")).lower() == "up" else 1
            return {"moved": self.engine.move(str(data.get("speechId", "")), direction)}
        if normalized == "reorderspeech":
            return {"moved": self.engine.move_before(str(data.get("speechId", "")), str(data.get("beforeId", "")))}
        if normalized == "commands":
            return {"commands": [
                "Speak", "Stop", "Pause", "PauseAfterCurrent", "Resume", "Clear", "ClearAll", "Enable", "Disable",
                "GetInfo", "GetEvents", "GetAliases", "GetState", "GetHistory", "ClearHistory", "SaveHistoryAudio", "ReplayHistory",
                "RemoveSpeech", "MoveSpeech", "ReorderSpeech", "LoadProfile", "Subscribe", "Unsubscribe", "Commands",
            ]}
        if normalized in {"events", "mode", "getvoicegateprofiles", "activatevoicegateprofile"}:
            return {}
        raise ValueError(f"Unsupported request: {request}")
