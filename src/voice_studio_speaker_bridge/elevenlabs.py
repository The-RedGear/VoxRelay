from __future__ import annotations

import json

from .http_util import get_json, post_bytes
from .media import to_wav
from .models import VoiceAlias
from .secrets import unprotect_windows_secret


class ElevenLabsClient:
    BASE = "https://api.elevenlabs.io"

    def __init__(self, api_key_encrypted: str = "", timeout: float = 120):
        if not api_key_encrypted:
            raise ValueError("ElevenLabs API key is missing. Add it under Services > Engines.")
        try:
            self.api_key = unprotect_windows_secret(api_key_encrypted)
        except (OSError, ValueError, AttributeError) as exc:
            raise ValueError("Saved ElevenLabs key could not be unlocked. Re-enter it on this Windows account.") from exc
        if not self.api_key:
            raise ValueError("ElevenLabs API key is empty")
        self.timeout = timeout

    def _headers(self, *, accept: str = "application/json") -> dict[str, str]:
        return {"xi-api-key": self.api_key, "Accept": accept}

    def list_voices(self) -> list[dict]:
        data = get_json(f"{self.BASE}/v1/voices", headers=self._headers(), timeout=min(30, self.timeout))
        voices = []
        for voice in data.get("voices") or []:
            voice_id = str(voice.get("voice_id") or "")
            if not voice_id:
                continue
            voices.append({
                "provider": "elevenlabs",
                "voice_id": voice_id,
                "name": str(voice.get("name") or voice_id),
                "language": "",
                "model": "eleven_multilingual_v2",
            })
        return voices

    def synthesize_wav(self, text: str, alias: VoiceAlias) -> bytes:
        body = {
            "text": text,
            "model_id": alias.model or "eleven_multilingual_v2",
            "voice_settings": {
                "stability": 0.5,
                "similarity_boost": 0.75,
                "style": 0.0,
            },
        }
        audio = post_bytes(
            f"{self.BASE}/v1/text-to-speech/{alias.voice_id}",
            json.dumps(body).encode("utf-8"),
            content_type="application/json",
            headers=self._headers(accept="audio/mpeg"),
            timeout=self.timeout,
        )
        return to_wav(audio)
