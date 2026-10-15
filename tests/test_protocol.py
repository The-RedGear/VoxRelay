import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

from voice_studio_speaker_bridge.models import SpeechJob
from voice_studio_speaker_bridge.protocol import SpeakerBotProtocol
from voice_studio_speaker_bridge.settings import Settings


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.settings = Settings(Path(self.temp.name) / "settings.json")
        self.engine = Mock()
        self.engine.enqueue.return_value = SpeechJob("hello", self.settings.aliases["EventVoice"])
        self.protocol = SpeakerBotProtocol(self.settings, self.engine)

    def tearDown(self):
        self.temp.cleanup()

    def test_speak_uses_alias(self):
        result = self.protocol.execute("Speak", {"message": "hello", "voice": "EventVoice"})
        self.assertEqual(result["text"], "hello")
        self.engine.enqueue.assert_called_once()

    def test_unknown_alias_fails(self):
        with self.assertRaisesRegex(ValueError, "Voice alias not found"):
            self.protocol.execute("Speak", {"message": "hello", "voice": "Missing"})

    def test_aliases_are_reported(self):
        result = self.protocol.execute("GetAliases", {})
        self.assertEqual(result["aliases"][0]["name"], "EventVoice")

    def test_alias_added_on_disk_is_available_without_restart(self):
        writer = Settings(self.settings.path)
        writer.aliases["New Voice"] = writer.aliases["EventVoice"]
        writer.aliases["New Voice"].name = "New Voice"
        writer.save()

        self.protocol.execute("Speak", {"message": "hello", "voice": "New Voice"})
        self.assertEqual(self.engine.enqueue.call_args.args[1].name, "New Voice")


if __name__ == "__main__":
    unittest.main()
