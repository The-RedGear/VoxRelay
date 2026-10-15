from __future__ import annotations

import io
import wave
from xml.sax.saxutils import escape

from .models import VoiceAlias
from .secrets import unprotect_windows_secret


class PollyClient:
    """Small Amazon Polly adapter using AWS's normal credential chain."""

    def __init__(self, region: str = "us-east-1", profile: str = "", access_key_encrypted: str = "", secret_key_encrypted: str = ""):
        try:
            import boto3
        except ImportError as exc:
            raise RuntimeError("Amazon Polly support is not installed") from exc
        kwargs = {"region_name": region or "us-east-1"}
        if access_key_encrypted and secret_key_encrypted:
            kwargs["aws_access_key_id"] = unprotect_windows_secret(access_key_encrypted)
            kwargs["aws_secret_access_key"] = unprotect_windows_secret(secret_key_encrypted)
        elif profile:
            kwargs["profile_name"] = profile
        self.client = boto3.Session(**kwargs).client("polly")

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
            "TextType": "text",
        }
        if speed != 1.0:
            request["Text"] = f'<speak><prosody rate="{round(speed * 100)}%">{escape(text)}</prosody></speak>'
            request["TextType"] = "ssml"
        if alias.language:
            request["LanguageCode"] = alias.language
        response = self.client.synthesize_speech(**request)
        stream = response.get("AudioStream")
        if stream is None:
            raise RuntimeError("Amazon Polly returned no audio")
        pcm = stream.read()
        output = io.BytesIO()
        with wave.open(output, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            wav.writeframes(pcm)
        return output.getvalue()
