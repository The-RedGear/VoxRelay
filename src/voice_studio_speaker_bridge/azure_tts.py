from __future__ import annotations

from xml.sax.saxutils import escape

from .http_util import get_json, post_bytes
from .media import to_wav
from .models import VoiceAlias
from .secrets import unprotect_windows_secret


class AzureTtsClient:
    """Azure Cognitive Services Speech REST (no SDK dependency)."""

    def __init__(self, subscription_key_encrypted: str = "", region: str = "eastus", timeout: float = 120):
        if not subscription_key_encrypted:
            raise ValueError("Azure Speech key is missing. Add it under Services > Engines.")
        try:
            self.key = unprotect_windows_secret(subscription_key_encrypted)
        except (OSError, ValueError, AttributeError) as exc:
            raise ValueError("Saved Azure key could not be unlocked. Re-enter it on this Windows account.") from exc
        if not self.key:
            raise ValueError("Azure Speech key is empty")
        self.region = (region or "eastus").strip()
        self.timeout = timeout
        self.base = f"https://{self.region}.tts.speech.microsoft.com"

    def _headers(self, *, content_type: str | None = None, accept: str | None = None) -> dict[str, str]:
        headers = {"Ocp-Apim-Subscription-Key": self.key}
        if content_type:
            headers["Content-Type"] = content_type
        if accept:
            headers["Accept"] = accept
        return headers

    def list_voices(self) -> list[dict]:
        data = get_json(
            f"{self.base}/cognitiveservices/voices/list",
            headers=self._headers(),
            timeout=min(30, self.timeout),
        )
        voices = []
        for voice in data if isinstance(data, list) else []:
            voice_id = str(voice.get("ShortName") or "")
            if not voice_id:
                continue
            locale = str(voice.get("Locale") or "")
            local_name = str(voice.get("LocalName") or voice_id)
            voices.append({
                "provider": "azure",
                "voice_id": voice_id,
                "name": f"{local_name} ({locale})" if locale else local_name,
                "language": locale,
                "model": "neural",
            })
        return voices

    def synthesize_wav(self, text: str, alias: VoiceAlias) -> bytes:
        parts = alias.voice_id.split("-")
        locale = f"{parts[0]}-{parts[1]}" if len(parts) >= 2 else (alias.language or "en-US")
        speed = max(0.5, min(2.0, float(alias.speed)))
        rate = f"{round((speed - 1.0) * 100):+d}%"
        spoken = text if alias.ssml else escape(text)
        if alias.ssml:
            ssml = text if text.lstrip().startswith("<") else (
                f"<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='{locale}'>"
                f"<voice name='{alias.voice_id}'>{spoken}</voice></speak>"
            )
        else:
            ssml = (
                f"<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='{locale}'>"
                f"<voice name='{alias.voice_id}'><prosody rate='{rate}'>{spoken}</prosody></voice></speak>"
            )
        headers = self._headers(content_type="application/ssml+xml")
        headers["X-Microsoft-OutputFormat"] = "riff-16khz-16bit-mono-pcm"
        audio = post_bytes(
            f"{self.base}/cognitiveservices/v1",
            ssml.encode("utf-8"),
            content_type="application/ssml+xml",
            headers=headers,
            timeout=self.timeout,
        )
        return to_wav(audio)
