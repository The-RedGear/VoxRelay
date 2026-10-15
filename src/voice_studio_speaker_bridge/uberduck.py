from __future__ import annotations

import json

from .http_util import get_bytes, get_json, post_json
from .media import to_wav
from .models import VoiceAlias
from .secrets import unprotect_windows_secret


class UberDuckClient:
    BASE = "https://api.uberduck.ai"

    def __init__(self, api_key_encrypted: str = "", timeout: float = 120):
        if not api_key_encrypted:
            raise ValueError("UberDuck API key is missing. Add it under Services > Engines.")
        try:
            self.api_key = unprotect_windows_secret(api_key_encrypted)
        except (OSError, ValueError, AttributeError) as exc:
            raise ValueError("Saved UberDuck key could not be unlocked. Re-enter it on this Windows account.") from exc
        if not self.api_key:
            raise ValueError("UberDuck API key is empty")
        self.timeout = timeout

    def _headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.api_key}"}

    def list_voices(self) -> list[dict]:
        data = get_json(f"{self.BASE}/v1/voices", headers=self._headers(), timeout=min(30, self.timeout))
        items = data if isinstance(data, list) else data.get("voices") or []
        voices = []
        for voice in items:
            voice_id = str(voice.get("uuid") or voice.get("name") or "")
            if not voice_id:
                continue
            voices.append({
                "provider": "uberduck",
                "voice_id": voice_id,
                "name": str(voice.get("display_name") or voice.get("name") or voice_id),
                "language": str(voice.get("language") or "en-US"),
                "model": "uberduck",
            })
        return voices

    def synthesize_wav(self, text: str, alias: VoiceAlias) -> bytes:
        data = post_json(
            f"{self.BASE}/v1/text-to-speech",
            {"text": text, "voice": alias.voice_id},
            headers=self._headers(),
            timeout=self.timeout,
        )
        audio_url = data.get("audio_url")
        if not audio_url:
            raise RuntimeError(f"UberDuck returned no audio_url: {json.dumps(data)[:300]}")
        return to_wav(get_bytes(str(audio_url), timeout=self.timeout))
