from __future__ import annotations

import io
import wave
from xml.sax.saxutils import escape

from .models import VoiceAlias
from .secrets import unprotect_windows_secret


class PollyClient:
    """Small Amazon Polly adapter using AWS's normal credential chain."""

    def __init__(self, region: str = "us-east-1", profile: str = "", access_key_encrypted: str = "", secret_key_encrypted: str = "", session_token_encrypted: str = "", timeout: float = 120):
        try:
            import boto3
        except ImportError as exc:
            raise RuntimeError("Amazon Polly support is not installed") from exc
        kwargs = {"region_name": region or "us-east-1"}
        if access_key_encrypted and secret_key_encrypted:
            try:
                kwargs["aws_access_key_id"] = unprotect_windows_secret(access_key_encrypted)
                kwargs["aws_secret_access_key"] = unprotect_windows_secret(secret_key_encrypted)
                if session_token_encrypted:
                    kwargs["aws_session_token"] = unprotect_windows_secret(session_token_encrypted)
            except (OSError, ValueError, AttributeError) as exc:
                raise ValueError("Saved AWS keys could not be unlocked. Re-enter them in Services > Amazon Polly on this Windows account.") from exc
        elif profile:
            kwargs["profile_name"] = profile
        from botocore.config import Config
        self.client = boto3.Session(**kwargs).client("polly", config=Config(
            connect_timeout=5, read_timeout=max(1, min(600, timeout)), retries={"total_max_attempts": 2}))

    def list_voices(self) -> list[dict]:
        voices: list[dict] = []
        paginator = self.client.get_paginator("describe_voices")
        for page in paginator.paginate():
            for voice in page.get("Voices", []):
                engines = list(voice.get("SupportedEngines") or ["standard"])
                preferred = "neural" if "neural" in engines else engines[0]
                voices.append({
                    "provider": "polly",
                    "voice_id": str(voice["Id"]),
                    "name": str(voice.get("Name") or voice["Id"]),
                    "language": str(voice.get("LanguageCode") or ""),
                    "language_name": str(voice.get("LanguageName") or ""),
                    "engines": engines,
                    "model": preferred,
                })
        return voices

    def synthesize_wav(self, text: str, alias: VoiceAlias) -> bytes:
        speed = max(0.5, min(2.0, float(alias.speed)))
        request = {
            "VoiceId": alias.voice_id,
            "Engine": alias.model or "standard",
            "OutputFormat": "pcm",
            "SampleRate": "16000",
            "Text": text,
            "TextType": "ssml" if alias.ssml else "text",
        }
        if speed != 1.0 and not alias.ssml:
            request["Text"] = f'<speak><prosody rate="{round(speed * 100)}%">{escape(text)}</prosody></speak>'
            request["TextType"] = "ssml"
        if alias.language:
            request["LanguageCode"] = alias.language
        response = self.client.synthesize_speech(**request)
        stream = response.get("AudioStream")
        if stream is None:
            raise RuntimeError("Amazon Polly returned no audio")
        try:
            pcm = stream.read()
        finally:
            if hasattr(stream, "close"):
                stream.close()
        output = io.BytesIO()
        with wave.open(output, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            wav.writeframes(pcm)
        return output.getvalue()
