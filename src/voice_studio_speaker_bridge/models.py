from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
import uuid
import math
from threading import Event
from time import monotonic


@dataclass(slots=True)
class VoiceAlias:
    name: str
    provider: str = "voicestudio"
    voice_id: str = "default"
    model: str = "tts-1"
    speed: float = 1.0
    language: str = ""
    instruct: str = ""
    volume: float = 1.0
    group: str = ""
    output_device: str = ""
    favorite: bool = False
    enabled: bool = True
    ssml: bool = False

    def __post_init__(self):
        folded = self.name.strip().casefold()
        if (
            not self.name.strip()
            or any(char in self.name for char in "\r\n")
            or folded.startswith(("group:", "playlist:"))
            or folded in {"random", "*"}
        ):
            raise ValueError("Use a single-line alias name that is not random/* and does not begin with group: or playlist:")
        if not math.isfinite(self.speed) or not 0.25 <= self.speed <= 4:
            raise ValueError("Voice speed must be between 0.25 and 4")
        if not math.isfinite(self.volume) or not 0 <= self.volume <= 2:
            raise ValueError("Voice volume must be between 0 and 2")

    @classmethod
    def from_dict(cls, name: str, value: dict) -> "VoiceAlias":
        return cls(
            name=name,
            provider=str(value.get("provider", "voicestudio")).casefold(),
            voice_id=str(value.get("voice_id", "default")),
            model=str(value.get("model", "tts-1")),
            speed=float(value.get("speed", 1.0)),
            language=str(value.get("language", "")),
            instruct=str(value.get("instruct", "")),
            volume=float(value.get("volume", 1.0)),
            group=str(value.get("group", "")),
            output_device=str(value.get("output_device", "")),
            favorite=bool(value.get("favorite", False)),
            enabled=bool(value.get("enabled", True)),
            ssml=bool(value.get("ssml", False)),
        )

    def to_dict(self) -> dict:
        return {
            "provider": self.provider,
            "voice_id": self.voice_id,
            "model": self.model,
            "speed": self.speed,
            "language": self.language,
            "instruct": self.instruct,
            "volume": self.volume,
            "group": self.group,
            "output_device": self.output_device,
            "favorite": self.favorite,
            "enabled": self.enabled,
            "ssml": self.ssml,
        }


@dataclass(slots=True)
class SpeechJob:
    text: str
    alias: VoiceAlias
    speech_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    timestamp: str = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    )
    pcm: bytes | None = None
    audio_bytes: bytes | None = None
    duration_ms: float = 0.0
    cancelled: bool = False
    source: str = "Manual"
    user: str = ""
    status: str = "Queued"
    error: str = ""
    audio_path: str = ""
    priority: int = 0
    enqueued_at: float = field(default_factory=monotonic)
    cancel_event: Event = field(default_factory=Event, repr=False)
    registered: bool = False
    replay_recording: bool = False
