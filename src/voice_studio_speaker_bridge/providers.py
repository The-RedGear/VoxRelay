"""Provider registration shared by voice discovery and speech generation."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Protocol
import os

from .models import VoiceAlias
from .settings import Settings
from .polly import PollyClient
from .voicestudio import VoiceStudioClient
from .windows_voices import WindowsVoiceClient


class SpeechProvider(Protocol):
    def list_voices(self) -> list[dict]: ...
    def synthesize_wav(self, text: str, alias: VoiceAlias) -> bytes: ...


@dataclass(frozen=True)
class Provider:
    key: str
    name: str
    factory: Callable[[Settings], SpeechProvider]
    enabled: Callable[[Settings], bool]
    capabilities: tuple[str, ...]


class ProviderRegistry:
    def __init__(self):
        self.providers: dict[str, Provider] = {}

    def register(self, provider: Provider) -> None:
        if provider.key in self.providers:
            raise ValueError(f"Provider is already registered: {provider.key}")
        self.providers[provider.key] = provider

    def client(self, key: str, settings: Settings) -> SpeechProvider:
        provider = self.providers.get(key)
        if provider is None:
            raise ValueError(f"Unknown audio engine: {key}. Choose an installed engine for this alias.")
        if not provider.enabled(settings):
            raise ValueError(f"{provider.name} is disabled. Enable it in Services first.")
        return provider.factory(settings)

    def voices(self, settings: Settings) -> tuple[list[dict], list[str]]:
        voices, errors = [], []
        for provider in self.providers.values():
            if not provider.enabled(settings):
                continue
            try:
                client = self.client(provider.key, settings)
                if isinstance(client, VoiceStudioClient):
                    client.timeout = min(client.timeout, 5)
                for original in client.list_voices():
                    voice = dict(original)
                    identifier = str(voice.get("voice_id") or voice.get("id") or voice.get("name") or "default")
                    voice.update(provider=provider.key, voice_id=identifier,
                                 name=str(voice.get("name") or voice.get("display_name") or identifier))
                    voice.setdefault("model", "tts-1")
                    voice.setdefault("language", "")
                    voices.append(voice)
            except Exception as exc:
                errors.append(f"{provider.name}: {exc}")
        voices.sort(key=lambda voice: (voice["provider"], voice["name"].casefold(), voice["language"]))
        return voices, errors


registry = ProviderRegistry()
registry.register(Provider("voicestudio", "VoiceStudio",
    lambda settings: VoiceStudioClient(settings.voice_studio_url, settings.api_key, settings.request_timeout),
    lambda settings: True, ("speed", "style", "language")))
registry.register(Provider("polly", "Amazon Polly",
    lambda settings: PollyClient(settings.polly_region, settings.polly_profile,
        settings.polly_access_key_encrypted, settings.polly_secret_key_encrypted, settings.polly_session_token_encrypted, settings.request_timeout),
    lambda settings: settings.polly_enabled, ("speed", "language", "ssml")))
registry.register(Provider("windows", "Windows voices",
    lambda settings: WindowsVoiceClient(settings.request_timeout),
    lambda settings: os.name == "nt" and settings.windows_voices_enabled, ("speed", "language", "ssml")))
