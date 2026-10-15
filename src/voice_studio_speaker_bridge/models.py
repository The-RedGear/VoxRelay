from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
import uuid


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
    duration_ms: float = 0.0
    cancelled: bool = False
    source: str = "Manual"
    user: str = ""
    status: str = "Queued"
    error: str = ""
    audio_path: str = ""
