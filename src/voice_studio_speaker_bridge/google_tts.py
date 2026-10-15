from __future__ import annotations

import json
from pathlib import Path

from .http_util import get_json, post_json
from .media import pcm_to_wav
from .models import VoiceAlias
from .secrets import unprotect_windows_secret


class GoogleTtsClient:
    """Google Cloud Text-to-Speech REST via API key or service-account JSON path."""

    BASE = "https://texttospeech.googleapis.com/v1"

    def __init__(
        self,
        api_key_encrypted: str = "",
        service_account_path: str = "",
        timeout: float = 120,
    ):
        self.timeout = timeout
        self.api_key = ""
        self._token = ""
        if api_key_encrypted:
            try:
                self.api_key = unprotect_windows_secret(api_key_encrypted)
            except (OSError, ValueError, AttributeError) as exc:
                raise ValueError("Saved Google API key could not be unlocked. Re-enter it on this Windows account.") from exc
        path = (service_account_path or "").strip()
        if path:
            self._token = self._token_from_service_account(Path(path))
        if not self.api_key and not self._token:
            raise ValueError("Google TTS needs an API key or a service-account JSON path under Services > Engines.")

    @staticmethod
    def _token_from_service_account(path: Path) -> str:
        if not path.is_file():
            raise ValueError(f"Google service-account file not found: {path}")
        try:
            from google.auth.transport.requests import Request
            from google.oauth2 import service_account
        except ImportError as exc:
            raise RuntimeError(
                "Google service accounts need the optional google-auth package. "
                "Install it with: pip install google-auth  — or use an API key instead."
            ) from exc
        credentials = service_account.Credentials.from_service_account_file(
            str(path),
            scopes=["https://www.googleapis.com/auth/cloud-platform"],
        )
        credentials.refresh(Request())
        if not credentials.token:
            raise ValueError("Google service account did not return an access token")
        return credentials.token

    def _url(self, path: str) -> str:
        url = f"{self.BASE}{path}"
        if self.api_key:
            sep = "&" if "?" in url else "?"
            return f"{url}{sep}key={self.api_key}"
        return url

    def _headers(self) -> dict[str, str]:
        if self._token:
            return {"Authorization": f"Bearer {self._token}"}
        return {}

    def list_voices(self) -> list[dict]:
        data = get_json(self._url("/voices"), headers=self._headers(), timeout=min(30, self.timeout))
        voices = []
        for voice in data.get("voices") or []:
            name = str(voice.get("name") or "")
            if not name:
                continue
            languages = voice.get("languageCodes") or ["en-US"]
            language = str(languages[0] if languages else "en-US")
            voices.append({
                "provider": "google",
                "voice_id": f"{name}|{language}",
                "name": name,
                "language": language,
                "model": "neural2" if "Neural2" in name else "standard",
            })
        return voices

    def synthesize_wav(self, text: str, alias: VoiceAlias) -> bytes:
        parts = alias.voice_id.split("|", 1)
        voice_name = parts[0]
        language = parts[1] if len(parts) > 1 else (alias.language or "en-US")
        speed = max(0.25, min(4.0, float(alias.speed)))
        body = {
            "input": {"text": text},
            "voice": {"languageCode": language, "name": voice_name},
            "audioConfig": {
                "audioEncoding": "LINEAR16",
                "sampleRateHertz": 16000,
                "speakingRate": speed,
            },
        }
        data = post_json(self._url("/text:synthesize"), body, headers=self._headers(), timeout=self.timeout)
        import base64

        audio_b64 = data.get("audioContent")
        if not audio_b64:
            raise RuntimeError(f"Google TTS returned no audio: {json.dumps(data)[:300]}")
        return pcm_to_wav(base64.b64decode(audio_b64), sample_rate=16000)
