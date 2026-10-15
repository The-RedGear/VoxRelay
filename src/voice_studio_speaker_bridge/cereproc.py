from __future__ import annotations

import json
from threading import Lock
from urllib.parse import quote
from xml.sax.saxutils import escape

from .http_util import get_json, post_bytes, request
from .media import to_wav
from .models import VoiceAlias
from .secrets import unprotect_windows_secret


class CereProcClient:
    BASE = "https://api.cerevoice.com"

    def __init__(self, username: str = "", password_encrypted: str = "", timeout: float = 120):
        if not username or not password_encrypted:
            raise ValueError("CereProc needs a username and password under Services > Engines.")
        try:
            self.password = unprotect_windows_secret(password_encrypted)
        except (OSError, ValueError, AttributeError) as exc:
            raise ValueError("Saved CereProc password could not be unlocked. Re-enter it on this Windows account.") from exc
        self.username = username.strip()
        self.timeout = timeout
        self._token = ""
        self._lock = Lock()
        if not self.password:
            raise ValueError("CereProc password is empty")

    def _fetch_token(self) -> str:
        import base64

        credentials = base64.b64encode(f"{self.username}:{self.password}".encode("utf-8")).decode("ascii")
        _, payload, _ = request(
            "GET",
            f"{self.BASE}/v2/auth",
            headers={"Authorization": f"Basic {credentials}"},
            timeout=min(30, self.timeout),
        )
        data = json.loads(payload.decode("utf-8"))
        token = data.get("access_token")
        if not token:
            raise RuntimeError(f"CereProc auth returned no access_token: {data}")
        return str(token)

    def _token_value(self, *, force: bool = False) -> str:
        with self._lock:
            if force or not self._token:
                self._token = self._fetch_token()
            return self._token

    def _authed_headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self._token_value()}"}

    def list_voices(self) -> list[dict]:
        try:
            data = get_json(f"{self.BASE}/v2/voices", headers=self._authed_headers(), timeout=min(30, self.timeout))
        except Exception:
            data = get_json(
                f"{self.BASE}/v2/voices",
                headers={"Authorization": f"Bearer {self._token_value(force=True)}"},
                timeout=min(30, self.timeout),
            )
        items = data.get("voices") if isinstance(data, dict) else data
        voices = []
        for voice in items or []:
            name = str(voice.get("name") or "")
            if not name:
                continue
            lang = str(voice.get("language_iso") or "en")
            country = str(voice.get("country_iso") or "GB")
            voices.append({
                "provider": "cereproc",
                "voice_id": name,
                "name": name,
                "language": f"{lang}-{country}",
                "model": "cereproc",
            })
        return voices

    def synthesize_wav(self, text: str, alias: VoiceAlias) -> bytes:
        speed = max(0.5, min(2.0, float(alias.speed)))
        rate = f"{round(speed * 100)}%"
        spoken = text if alias.ssml else escape(text)
        if alias.ssml and text.lstrip().startswith("<"):
            ssml = text
        else:
            ssml = f'<speak xmlns="http://www.w3.org/2001/10/synthesis"><prosody rate="{rate}">{spoken}</prosody></speak>'
        url = f"{self.BASE}/v2/speak?voice={quote(alias.voice_id)}&audio_format=mp3"
        try:
            audio = post_bytes(
                url,
                ssml.encode("utf-8"),
                content_type="application/xml",
                headers=self._authed_headers(),
                timeout=self.timeout,
            )
        except Exception:
            audio = post_bytes(
                url,
                ssml.encode("utf-8"),
                content_type="application/xml",
                headers={"Authorization": f"Bearer {self._token_value(force=True)}"},
                timeout=self.timeout,
            )
        return to_wav(audio)
