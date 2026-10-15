from __future__ import annotations

import json
from urllib.parse import quote

from .http_util import basic_auth_header, get_json, post_bytes
from .media import to_wav
from .models import VoiceAlias
from .secrets import unprotect_windows_secret


class WatsonClient:
    def __init__(self, api_key_encrypted: str = "", service_url: str = "", timeout: float = 120):
        if not api_key_encrypted or not service_url:
            raise ValueError("IBM Watson needs an API key and service URL under Services > Engines.")
        try:
            self.api_key = unprotect_windows_secret(api_key_encrypted)
        except (OSError, ValueError, AttributeError) as exc:
            raise ValueError("Saved Watson key could not be unlocked. Re-enter it on this Windows account.") from exc
        self.service_url = service_url.rstrip("/")
        self.timeout = timeout
        if not self.api_key:
            raise ValueError("IBM Watson API key is empty")

    def _auth(self) -> dict[str, str]:
        return {"Authorization": basic_auth_header("apikey", self.api_key)}

    def list_voices(self) -> list[dict]:
        data = get_json(f"{self.service_url}/v1/voices", headers=self._auth(), timeout=min(30, self.timeout))
        voices = []
        for voice in data.get("voices") or []:
            name = str(voice.get("name") or "")
            if not name:
                continue
            voices.append({
                "provider": "watson",
                "voice_id": name,
                "name": name,
                "language": str(voice.get("language") or ""),
                "model": "watson",
            })
        return voices

    def synthesize_wav(self, text: str, alias: VoiceAlias) -> bytes:
        url = f"{self.service_url}/v1/synthesize?voice={quote(alias.voice_id)}"
        headers = {**self._auth(), "Accept": "audio/mp3"}
        audio = post_bytes(
            url,
            json.dumps({"text": text}).encode("utf-8"),
            content_type="application/json",
            headers=headers,
            timeout=self.timeout,
        )
        return to_wav(audio)
