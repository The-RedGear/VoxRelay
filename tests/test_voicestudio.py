import io
import json
import unittest
from unittest.mock import patch

from voice_studio_speaker_bridge.models import VoiceAlias
from voice_studio_speaker_bridge.voicestudio import VoiceStudioClient, VoiceStudioError


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


class VoiceStudioClientTests(unittest.TestCase):
    def test_list_voices_accepts_wrapped_response(self):
        body = json.dumps({"voices": [{"voice_id": "abc", "name": "Test"}]}).encode()
        with patch("voice_studio_speaker_bridge.voicestudio.urlopen", return_value=FakeResponse(body)):
            voices = VoiceStudioClient("http://127.0.0.1:3900").list_voices()
        self.assertEqual(voices[0]["voice_id"], "abc")

    def test_synthesis_requests_wav(self):
        wav = b"RIFF" + b"\x00" * 4 + b"WAVE" + b"data"
        with patch("voice_studio_speaker_bridge.voicestudio.urlopen", return_value=FakeResponse(wav)) as mocked:
            result = VoiceStudioClient("http://127.0.0.1:3900").synthesize_wav(
                "hello", VoiceAlias(name="Test", voice_id="profile-1")
            )
        self.assertEqual(result, wav)
        request = mocked.call_args.args[0]
        payload = json.loads(request.data)
        self.assertEqual(payload["response_format"], "wav")
        self.assertEqual(payload["voice"], "profile-1")

    def test_invalid_audio_is_rejected(self):
        with patch("voice_studio_speaker_bridge.voicestudio.urlopen", return_value=FakeResponse(b"not audio")):
            with self.assertRaises(VoiceStudioError):
                VoiceStudioClient("http://127.0.0.1:3900").synthesize_wav(
                    "hello", VoiceAlias(name="Test")
                )


if __name__ == "__main__":
    unittest.main()
