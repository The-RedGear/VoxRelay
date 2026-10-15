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
from .elevenlabs import ElevenLabsClient
from .azure_tts import AzureTtsClient
from .google_tts import GoogleTtsClient
from .watson import WatsonClient
from .uberduck import UberDuckClient
from .ttsmonster import TtsMonsterClient
from .acapela import AcapelaClient
from .cereproc import CereProcClient


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
registry.register(Provider(
    "voicestudio", "VoiceStudio",
    lambda settings: VoiceStudioClient(settings.voice_studio_url, settings.api_key, settings.request_timeout),
    lambda settings: True,
    ("speed", "style", "language"),
))
registry.register(Provider(
    "polly", "Amazon Polly",
    lambda settings: PollyClient(
        settings.polly_region, settings.polly_profile,
        settings.polly_access_key_encrypted, settings.polly_secret_key_encrypted,
        settings.polly_session_token_encrypted, settings.request_timeout,
    ),
    lambda settings: settings.polly_enabled,
    ("speed", "language", "ssml"),
))
registry.register(Provider(
    "windows", "Windows voices",
    lambda settings: WindowsVoiceClient(settings.request_timeout),
    lambda settings: os.name == "nt" and settings.windows_voices_enabled,
    ("speed", "language", "ssml"),
))
registry.register(Provider(
    "elevenlabs", "ElevenLabs",
    lambda settings: ElevenLabsClient(settings.elevenlabs_api_key_encrypted, settings.request_timeout),
    lambda settings: settings.elevenlabs_enabled,
    ("speed", "language"),
))
registry.register(Provider(
    "azure", "Azure Speech",
    lambda settings: AzureTtsClient(
        settings.azure_subscription_key_encrypted, settings.azure_region, settings.request_timeout,
    ),
    lambda settings: settings.azure_enabled,
    ("speed", "language", "ssml"),
))
registry.register(Provider(
    "google", "Google Cloud TTS",
    lambda settings: GoogleTtsClient(
        settings.google_api_key_encrypted, settings.google_service_account_path, settings.request_timeout,
    ),
    lambda settings: settings.google_enabled,
    ("speed", "language"),
))
registry.register(Provider(
    "watson", "IBM Watson",
    lambda settings: WatsonClient(
        settings.watson_api_key_encrypted, settings.watson_service_url, settings.request_timeout,
    ),
    lambda settings: settings.watson_enabled,
    ("speed", "language"),
))
registry.register(Provider(
    "uberduck", "UberDuck",
    lambda settings: UberDuckClient(settings.uberduck_api_key_encrypted, settings.request_timeout),
    lambda settings: settings.uberduck_enabled,
    ("speed", "language"),
))
registry.register(Provider(
    "ttsmonster", "TTS.Monster",
    lambda settings: TtsMonsterClient(
        settings.ttsmonster_api_token_encrypted, settings.ttsmonster_overlay_url, settings.request_timeout,
    ),
    lambda settings: settings.ttsmonster_enabled,
    ("speed", "language"),
))
registry.register(Provider(
    "acapela", "Acapela",
    lambda settings: AcapelaClient(
        settings.acapela_account, settings.acapela_password_encrypted,
        settings.acapela_application_name, settings.request_timeout,
    ),
    lambda settings: settings.acapela_enabled,
    ("speed", "language"),
))
registry.register(Provider(
    "cereproc", "CereProc",
    lambda settings: CereProcClient(
        settings.cereproc_username, settings.cereproc_password_encrypted, settings.request_timeout,
    ),
    lambda settings: settings.cereproc_enabled,
    ("speed", "language", "ssml"),
))
