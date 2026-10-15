from __future__ import annotations

from typing import TYPE_CHECKING
import random
from dataclasses import replace

from .settings import Settings
from . import __version__

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
            user = str(data.get("user", data.get("userName", ""))).strip()
            role = str(data.get("role", "")).strip().casefold()
            source = str(data.get("source", "Streamer.bot")).strip()
            priority = int(data.get("priority", 0))
            routing_matched = False
            for rule in self.settings.routing_rules:
                if rule.get("enabled", True) is False:
                    continue
                field = str(rule.get("field", ""))
                actual = {"user": user, "role": role, "source": source, "event": str(data.get("event", ""))}.get(field)
                if actual is not None and actual.casefold() == str(rule.get("value", "")).casefold():
                    alias_name = str(rule.get("alias") or alias_name)
                    priority = int(rule.get("priority", priority))
                    routing_matched = True
                    break
            rule_alias = self.settings.user_voice_rules.get(user.casefold()) if user else None
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
                job = self.engine.enqueue(text, alias, source=source, user=user, priority=priority)
            else:
                job = self.engine.enqueue(text, alias, source=source, user=user)
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
