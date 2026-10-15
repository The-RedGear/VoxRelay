from __future__ import annotations

import base64
import io
import json
import wave

import pytest

from voice_studio_speaker_bridge.models import VoiceAlias
from voice_studio_speaker_bridge import (
    elevenlabs,
    azure_tts,
    google_tts,
    watson,
    uberduck,
    ttsmonster,
    acapela,
    cereproc,
    media,
    http_util,
)
from voice_studio_speaker_bridge.providers import registry
from voice_studio_speaker_bridge.settings import Settings


def _wav_bytes(frames: int = 160) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(b"\x00\x00" * frames)
    return output.getvalue()


def test_registry_has_speakerbot_engines():
    expected = {
        "voicestudio", "polly", "windows", "elevenlabs", "azure", "google",
        "watson", "uberduck", "ttsmonster", "acapela", "cereproc",
    }
    assert expected <= set(registry.providers)


def test_pcm_to_wav_roundtrip():
    wav = media.pcm_to_wav(b"\x00\x00" * 10, sample_rate=16000)
    assert wav[:4] == b"RIFF"
    assert media.to_wav(wav)[:4] == b"RIFF"


def test_elevenlabs_list_and_synth(monkeypatch):
    monkeypatch.setattr(elevenlabs, "unprotect_windows_secret", lambda value: "key")
    monkeypatch.setattr(elevenlabs, "get_json", lambda *a, **k: {"voices": [{"voice_id": "abc", "name": "Rachel"}]})
    monkeypatch.setattr(elevenlabs, "post_bytes", lambda *a, **k: _wav_bytes())
    client = elevenlabs.ElevenLabsClient("enc")
    assert client.list_voices()[0]["voice_id"] == "abc"
    audio = client.synthesize_wav(
        "hi",
        VoiceAlias("R", provider="elevenlabs", voice_id="abc", model="eleven_multilingual_v2"),
    )
    assert audio[:4] == b"RIFF"


def test_azure_builds_ssml(monkeypatch):
    monkeypatch.setattr(azure_tts, "unprotect_windows_secret", lambda value: "key")
    monkeypatch.setattr(
        azure_tts,
        "get_json",
        lambda *a, **k: [{"ShortName": "en-US-JennyNeural", "LocalName": "Jenny", "Locale": "en-US"}],
    )
    captured = {}

    def fake_post(url, data, **kwargs):
        captured["url"] = url
        captured["data"] = data.decode("utf-8")
        return _wav_bytes()

    monkeypatch.setattr(azure_tts, "post_bytes", fake_post)
    client = azure_tts.AzureTtsClient("enc", region="eastus")
    assert client.list_voices()[0]["voice_id"] == "en-US-JennyNeural"
    client.synthesize_wav("Hello", VoiceAlias("A", provider="azure", voice_id="en-US-JennyNeural", speed=1.0))
    assert "en-US-JennyNeural" in captured["data"]
    assert "Hello" in captured["data"]


def test_google_api_key_synth(monkeypatch):
    monkeypatch.setattr(google_tts, "unprotect_windows_secret", lambda value: "gkey")
    monkeypatch.setattr(
        google_tts,
        "get_json",
        lambda *a, **k: {"voices": [{"name": "en-US-Standard-B", "languageCodes": ["en-US"]}]},
    )
    pcm = b"\x00\x00" * 32
    monkeypatch.setattr(
        google_tts,
        "post_json",
        lambda *a, **k: {"audioContent": base64.b64encode(pcm).decode("ascii")},
    )
    client = google_tts.GoogleTtsClient(api_key_encrypted="enc")
    voice = client.list_voices()[0]
    assert voice["voice_id"].startswith("en-US-Standard-B|")
    audio = client.synthesize_wav("hi", VoiceAlias("G", provider="google", voice_id=voice["voice_id"]))
    assert audio[:4] == b"RIFF"


def test_watson_auth_header(monkeypatch):
    monkeypatch.setattr(watson, "unprotect_windows_secret", lambda value: "wkey")
    monkeypatch.setattr(
        watson,
        "get_json",
        lambda *a, **k: {"voices": [{"name": "en-US_AllisonV3Voice", "language": "en-US"}]},
    )
    monkeypatch.setattr(watson, "post_bytes", lambda *a, **k: _wav_bytes())
    client = watson.WatsonClient("enc", "https://api.us-south.text-to-speech.watson.cloud.ibm.com")
    assert client.list_voices()[0]["provider"] == "watson"
    assert client.synthesize_wav("hi", VoiceAlias("W", provider="watson", voice_id="en-US_AllisonV3Voice"))[:4] == b"RIFF"


def test_uberduck_downloads_audio_url(monkeypatch):
    monkeypatch.setattr(uberduck, "unprotect_windows_secret", lambda value: "ukey")
    monkeypatch.setattr(uberduck, "get_json", lambda *a, **k: [{"uuid": "v1", "display_name": "Voice"}])
    monkeypatch.setattr(uberduck, "post_json", lambda *a, **k: {"audio_url": "https://example/a.wav"})
    monkeypatch.setattr(uberduck, "get_bytes", lambda *a, **k: _wav_bytes())
    client = uberduck.UberDuckClient("enc")
    assert client.list_voices()[0]["voice_id"] == "v1"
    assert client.synthesize_wav("hi", VoiceAlias("U", provider="uberduck", voice_id="v1"))[:4] == b"RIFF"


def test_ttsmonster_overlay_parse_and_synth(monkeypatch):
    def fake_post(url, body, **k):
        if "wutface" in url:
            return {"message": {"voices": ["brian"], "customVoices": []}}
        return {"data": {"link": "https://example/out.wav"}}

    monkeypatch.setattr(ttsmonster, "post_json", fake_post)
    monkeypatch.setattr(ttsmonster, "get_json", lambda *a, **k: {"ultraPremiumVoices": []})
    monkeypatch.setattr(ttsmonster, "get_bytes", lambda *a, **k: _wav_bytes())
    client = ttsmonster.TtsMonsterClient(overlay_url="https://tts.monster/overlay/user123/key456")
    assert client.user_id == "user123"
    assert client.list_voices()[0]["voice_id"] == "brian"
    assert client.synthesize_wav("hi", VoiceAlias("T", provider="ttsmonster", voice_id="brian"))[:4] == b"RIFF"


def test_acapela_form_synth(monkeypatch):
    monkeypatch.setattr(acapela, "unprotect_windows_secret", lambda value: "pass")
    monkeypatch.setattr(acapela, "post_form", lambda *a, **k: {"snd_url": "https://example/a.mp3"})
    monkeypatch.setattr(acapela, "get_bytes", lambda *a, **k: _wav_bytes())
    client = acapela.AcapelaClient(account="acc", password_encrypted="enc")
    assert client.list_voices() == []
    assert client.synthesize_wav("hi", VoiceAlias("A", provider="acapela", voice_id="ryan22k"))[:4] == b"RIFF"


def test_cereproc_token_and_speak(monkeypatch):
    monkeypatch.setattr(cereproc, "unprotect_windows_secret", lambda value: "pass")
    calls = {"auth": 0}

    def fake_request(method, url, **kwargs):
        if url.endswith("/v2/auth"):
            calls["auth"] += 1
            return 200, json.dumps({"access_token": "tok"}).encode(), {}
        raise AssertionError(url)

    monkeypatch.setattr(cereproc, "request", fake_request)
    monkeypatch.setattr(
        cereproc,
        "get_json",
        lambda *a, **k: {"voices": [{"name": "William", "language_iso": "en", "country_iso": "GB"}]},
    )
    monkeypatch.setattr(cereproc, "post_bytes", lambda *a, **k: _wav_bytes())
    client = cereproc.CereProcClient(username="u", password_encrypted="enc")
    assert client.list_voices()[0]["voice_id"] == "William"
    assert client.synthesize_wav("hi", VoiceAlias("C", provider="cereproc", voice_id="William"))[:4] == b"RIFF"
    assert calls["auth"] >= 1


def test_settings_roundtrip_engine_fields(tmp_path):
    path = tmp_path / "settings.json"
    settings = Settings(path)
    settings.elevenlabs_enabled = True
    settings.elevenlabs_api_key_encrypted = "abc"
    settings.azure_enabled = True
    settings.azure_region = "westus2"
    settings.google_service_account_path = "C:/keys/sa.json"
    settings.watson_service_url = "https://example/watson"
    settings.ttsmonster_overlay_url = "https://tts.monster/u/k"
    settings.acapela_account = "acc"
    settings.cereproc_username = "user"
    settings.save()
    loaded = Settings(path)
    assert loaded.elevenlabs_enabled is True
    assert loaded.elevenlabs_api_key_encrypted == "abc"
    assert loaded.azure_region == "westus2"
    assert loaded.google_service_account_path.endswith("sa.json")
    assert loaded.watson_service_url.endswith("watson")
    assert loaded.ttsmonster_overlay_url.endswith("/u/k")
    assert loaded.acapela_account == "acc"
    assert loaded.cereproc_username == "user"


def test_http_error_includes_status(monkeypatch):
    def boom(*args, **kwargs):
        raise http_util.urllib.error.HTTPError(None, 401, "nope", hdrs=None, fp=io.BytesIO(b"nope"))

    monkeypatch.setattr(http_util.urllib.request, "urlopen", boom)
    with pytest.raises(http_util.HttpError) as exc:
        http_util.get_bytes("https://example.test")
    assert exc.value.status == 401
