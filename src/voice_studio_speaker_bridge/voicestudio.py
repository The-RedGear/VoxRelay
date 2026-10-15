from __future__ import annotations

import json
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from .models import VoiceAlias


class VoiceStudioError(RuntimeError):
    pass


class VoiceStudioClient:
    def __init__(self, base_url: str, api_key: str = "local", timeout: float = 120.0):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key or "local"
        self.timeout = timeout

    def _request(self, path: str, method: str = "GET", body: dict | None = None) -> bytes:
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = Request(
            f"{self.base_url}{path}",
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json, audio/wav",
            },
        )
        try:
            with urlopen(request, timeout=self.timeout) as response:
                return response.read()
        except HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:1000]
            try:
                parsed = json.loads(detail)
                detail = parsed.get("detail") or parsed.get("error", {}).get("message") or detail
            except (ValueError, TypeError, AttributeError):
                pass
            raise VoiceStudioError(f"VoiceStudio returned HTTP {exc.code}: {detail}") from exc
        except (URLError, TimeoutError, OSError) as exc:
            reason = getattr(exc, "reason", exc)
            raise VoiceStudioError(f"Cannot reach VoiceStudio at {self.base_url}: {reason}") from exc

    def health(self) -> dict[str, Any]:
        return json.loads(self._request("/health"))

    def list_voices(self) -> list[dict[str, Any]]:
        payload = json.loads(self._request("/v1/audio/voices"))
        if isinstance(payload, list):
            return payload
        if isinstance(payload, dict):
            voices = payload.get("voices", [])
            return voices if isinstance(voices, list) else []
        return []

    def synthesize_wav(self, text: str, alias: VoiceAlias) -> bytes:
        body: dict[str, Any] = {
            "model": alias.model or "tts-1",
            "voice": alias.voice_id or "default",
            "input": text,
            "response_format": "wav",
            "speed": max(0.25, min(alias.speed, 4.0)),
        }
        if alias.language:
            body["language"] = alias.language
        if alias.instruct:
            body["instruct"] = alias.instruct
        result = self._request("/v1/audio/speech", method="POST", body=body)
        if len(result) < 12 or result[:4] != b"RIFF" or result[8:12] != b"WAVE":
            raise VoiceStudioError("VoiceStudio did not return a valid WAV file")
        return result
