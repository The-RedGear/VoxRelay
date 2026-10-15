from __future__ import annotations

import io
import sys
import types
import wave

from voice_studio_speaker_bridge.models import VoiceAlias
from voice_studio_speaker_bridge.polly import PollyClient


class FakeStream:
    def read(self):
        return b"\x00\x00" * 160


class FakePaginator:
    def paginate(self):
        yield {"Voices": [{
            "Id": "Brian", "Name": "Brian", "LanguageCode": "en-GB",
            "LanguageName": "British English", "SupportedEngines": ["standard", "neural"],
        }]}


class FakeClient:
    def __init__(self):
        self.request = None

    def get_paginator(self, name):
        assert name == "describe_voices"
        return FakePaginator()

    def synthesize_speech(self, **request):
        self.request = request
        return {"AudioStream": FakeStream()}


def make_client(monkeypatch):
    fake_client = FakeClient()

    class Session:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

        def client(self, name, **kwargs):
            assert name == "polly"
            return fake_client

    monkeypatch.setitem(sys.modules, "boto3", types.SimpleNamespace(Session=Session))
    return PollyClient("us-west-2", "streaming"), fake_client


def test_old_aliases_default_to_voicestudio():
    alias = VoiceAlias.from_dict("Legacy", {"voice_id": "old"})
    assert alias.provider == "voicestudio"
    assert alias.to_dict()["provider"] == "voicestudio"


def test_lists_polly_voices(monkeypatch):
    client, _ = make_client(monkeypatch)
    voice = client.list_voices()[0]
    assert voice["voice_id"] == "Brian"
    assert voice["provider"] == "polly"
    assert voice["model"] == "neural"


def test_wraps_polly_pcm_as_wav(monkeypatch):
    client, fake = make_client(monkeypatch)
    alias = VoiceAlias("Brian", provider="polly", voice_id="Brian", model="neural", speed=1.2)
    payload = client.synthesize_wav("Fish & chips", alias)
    assert payload[:4] == b"RIFF"
    assert fake.request["TextType"] == "ssml"
    assert "Fish &amp; chips" in fake.request["Text"]
    with wave.open(io.BytesIO(payload), "rb") as wav:
        assert wav.getnchannels() == 1
        assert wav.getframerate() == 16000
