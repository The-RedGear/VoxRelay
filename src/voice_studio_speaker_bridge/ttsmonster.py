from __future__ import annotations

import json
from urllib.parse import urlparse

from .http_util import get_bytes, get_json, post_json, request
from .media import to_wav
from .models import VoiceAlias
from .secrets import unprotect_windows_secret


class TtsMonsterClient:
    GCF = "https://us-central1-tts-monster.cloudfunctions.net"
    OFFICIAL = "https://api.console.tts.monster"
    WUTFACE = "https://wutface.tts.monster/"

    def __init__(
        self,
        api_token_encrypted: str = "",
        overlay_url: str = "",
        timeout: float = 120,
    ):
        self.timeout = timeout
        self.api_token = ""
        self.user_id = ""
        self.api_key = ""
        if api_token_encrypted:
            try:
                self.api_token = unprotect_windows_secret(api_token_encrypted)
            except (OSError, ValueError, AttributeError) as exc:
                raise ValueError("Saved TTS.Monster token could not be unlocked. Re-enter it on this Windows account.") from exc
        if overlay_url.strip():
            self._parse_overlay(overlay_url.strip())
        if not self.api_token and not (self.user_id and self.api_key):
            raise ValueError("TTS.Monster needs an overlay URL or API token under Services > Engines.")

    def _parse_overlay(self, value: str) -> None:
        trimmed = value.rstrip("/")
        try:
            uri = urlparse(trimmed)
            parts = [part for part in uri.path.split("/") if part]
            if len(parts) >= 2:
                self.user_id, self.api_key = parts[-2], parts[-1]
                return
        except ValueError:
            pass
        segs = [part for part in trimmed.split("/") if part]
        if len(segs) >= 2:
            self.user_id, self.api_key = segs[-2], segs[-1]

    @property
    def use_overlay(self) -> bool:
        return bool(self.user_id and self.api_key)

    def list_voices(self) -> list[dict]:
        return self._voices_overlay() if self.use_overlay else self._voices_official()

    def _voices_overlay(self) -> list[dict]:
        data = post_json(
            self.WUTFACE,
            {"userId": self.user_id, "apiKey": self.api_key},
            timeout=min(30, self.timeout),
        )
        message = data.get("message") or {}
        voices = []
        seen: set[str] = set()

        def add(name: str, suffix: str = "") -> None:
            key = name.casefold()
            if not name or key in seen:
                return
            seen.add(key)
            label = name[:1].upper() + name[1:] if name else name
            voices.append({
                "provider": "ttsmonster",
                "voice_id": name,
                "name": f"{label}{suffix}",
                "language": "en-US",
                "model": "ttsmonster",
            })

        for item in message.get("voices") or []:
            add(str(item))
        for item in message.get("customVoices") or []:
            name = str(item.get("name") if isinstance(item, dict) else item)
            add(name, " (Custom)")
        try:
            premium = get_json(f"{self.GCF}/getUltraPremiumVoices", timeout=min(20, self.timeout))
            for item in premium.get("ultraPremiumVoices") or []:
                add(str(item), " (Ultra Premium)")
        except Exception:
            pass
        return voices

    def _voices_official(self) -> list[dict]:
        _, payload, _ = request(
            "POST",
            f"{self.OFFICIAL}/voices",
            headers={"Authorization": self.api_token, "Content-Type": "application/json"},
            data=b"{}",
            timeout=min(30, self.timeout),
        )
        data = json.loads(payload.decode("utf-8"))
        voices = []

        def add_group(items, custom: bool) -> None:
            for voice in items or []:
                voice_id = str(voice.get("voice_id") or "")
                name = str(voice.get("name") or voice_id)
                if not voice_id:
                    continue
                meta = str(voice.get("metadata") or "").split("|")
                voices.append({
                    "provider": "ttsmonster",
                    "voice_id": voice_id,
                    "name": f"{name} (Custom)" if custom else name,
                    "language": meta[0] if meta and meta[0] else "en-US",
                    "model": "ttsmonster",
                })

        add_group(data.get("voices"), False)
        add_group(data.get("customVoices"), True)
        return voices

    def synthesize_wav(self, text: str, alias: VoiceAlias) -> bytes:
        if self.use_overlay:
            data = post_json(
                f"{self.GCF}/generateTTS",
                {
                    "data": {
                        "userId": self.user_id,
                        "key": self.api_key,
                        "ai": True,
                        "message": f"{alias.voice_id}: {text}",
                        "details": {"provider": "VoxRelay"},
                    }
                },
                timeout=self.timeout,
            )
            link = ((data.get("data") or {}).get("link")) if isinstance(data, dict) else None
            if not link:
                raise RuntimeError(f"TTS.Monster overlay returned no link: {json.dumps(data)[:300]}")
            return to_wav(get_bytes(str(link), timeout=self.timeout))

        data = post_json(
            f"{self.OFFICIAL}/generate",
            {"voice_id": alias.voice_id, "message": text, "return_usage": False},
            headers={"Authorization": self.api_token},
            timeout=self.timeout,
        )
        url = data.get("url")
        if not url:
            raise RuntimeError(f"TTS.Monster returned no url: {json.dumps(data)[:300]}")
        return to_wav(get_bytes(str(url), timeout=self.timeout))
