from __future__ import annotations

from .http_util import get_bytes, post_form
from .media import to_wav
from .models import VoiceAlias
from .secrets import unprotect_windows_secret


class AcapelaClient:
    BASE = "https://vaas.acapela-cloud.com"

    def __init__(
        self,
        account: str = "",
        password_encrypted: str = "",
        application_name: str = "YapLoq",
        timeout: float = 120,
    ):
        if not account or not password_encrypted:
            raise ValueError("Acapela needs an account and password under Services > Engines.")
        try:
            self.password = unprotect_windows_secret(password_encrypted)
        except (OSError, ValueError, AttributeError) as exc:
            raise ValueError("Saved Acapela password could not be unlocked. Re-enter it on this Windows account.") from exc
        self.account = account.strip()
        self.app_name = (application_name or "YapLoq").strip() or "YapLoq"
        self.timeout = timeout
        if not self.password:
            raise ValueError("Acapela password is empty")

    def list_voices(self) -> list[dict]:
        # Acapela cloud does not expose a public voice catalog in the same way;
        # aliases must use a voice id from your Acapela account (e.g. "ryan22k").
        return []

    def synthesize_wav(self, text: str, alias: VoiceAlias) -> bytes:
        speed = max(60, min(240, round(float(alias.speed) * 100)))
        data = post_form(
            f"{self.BASE}/Services/Synthesizer",
            {
                "req_loginID": self.account,
                "req_passwd": self.password,
                "req_vers": "2",
                "req_snd_id": self.app_name,
                "req_voice": alias.voice_id,
                "req_text": text,
                "req_spd": str(speed),
                "req_vct": "100",
                "req_vol": "100",
                "req_snd_type": "MP3",
            },
            timeout=self.timeout,
        )
        if not isinstance(data, dict):
            raise RuntimeError(f"Acapela returned unexpected response: {str(data)[:300]}")
        snd_url = data.get("snd_url")
        if not snd_url:
            raise RuntimeError(f"Acapela returned no snd_url: {data}")
        return to_wav(get_bytes(str(snd_url), timeout=self.timeout))
