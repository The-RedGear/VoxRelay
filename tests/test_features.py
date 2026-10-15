import tempfile
import unittest
import json
from pathlib import Path
from unittest.mock import Mock, patch

from voice_studio_speaker_bridge.engine import SpeechEngine
from voice_studio_speaker_bridge.events import EventBus
from voice_studio_speaker_bridge.models import SpeechJob, VoiceAlias
from voice_studio_speaker_bridge.protocol import SpeakerBotProtocol
from voice_studio_speaker_bridge.settings import Settings


class FeatureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.settings = Settings(Path(self.temp.name) / "settings.json")

    def tearDown(self):
        self.temp.cleanup()

    def test_pronunciation_and_repeated_characters_are_applied(self):
        self.settings.pronunciations = {"RG": "Red Gear"}
        engine = SpeechEngine(self.settings, EventBus())
        job = engine.enqueue("RG is coooooool", self.settings.aliases["EventVoice"])
        self.assertEqual(job.text, "Red Gear is coool")

    def test_hidden_pronunciation_setting_survives_save(self):
        self.settings.pronunciations = {"private word": "clean pronunciation"}
        self.settings.hidden_pronunciations = ["private word"]
        self.settings.voice_save_folder = str(Path(self.temp.name) / "exports")
        self.settings.save()
        loaded = Settings(self.settings.path)
        self.assertEqual(loaded.pronunciations["private word"], "clean pronunciation")
        self.assertEqual(loaded.hidden_pronunciations, ["private word"])
        self.assertEqual(loaded.voice_save_folder, str(Path(self.temp.name) / "exports"))

    def test_comma_separated_pronunciations_choose_randomly_per_match(self):
        self.settings.pronunciations = {"RG": "Red Gear, R G"}
        engine = SpeechEngine(self.settings, EventBus())
        with patch("voice_studio_speaker_bridge.engine.random.choice", side_effect=["Red Gear", "R G"]):
            job = engine.enqueue("RG and RG", self.settings.aliases["EventVoice"])
        self.assertEqual(job.text, "Red Gear and R G")

    def test_pronunciation_does_not_replace_inside_larger_words(self):
        self.settings.pronunciations = {"ASS": "censored"}
        engine = SpeechEngine(self.settings, EventBus())
        job = engine.enqueue("grass class ass assignment ass-hole", self.settings.aliases["EventVoice"])
        self.assertEqual(job.text, "grass class censored assignment censored-hole")

    def test_history_audio_can_be_exported_to_configured_folder(self):
        cache = Path(self.temp.name) / "cached.wav"
        cache.write_bytes(b"RIFFtest")
        self.settings.voice_save_folder = str(Path(self.temp.name) / "exports")
        engine = SpeechEngine(self.settings, EventBus())
        engine.history = [{
            "id": "12345678-1234-1234-1234-123456789012",
            "timestamp": "2026-10-13T12:34:56Z",
            "alias": "Test Voice",
            "audioPath": str(cache),
        }]
        exported = Path(engine.save_history_audio("12345678-1234-1234-1234-123456789012"))
        self.assertTrue(exported.is_file())
        self.assertEqual(exported.read_bytes(), b"RIFFtest")

    def test_cache_filename_uses_alias_and_timestamp(self):
        engine = SpeechEngine(self.settings, EventBus())
        alias = VoiceAlias(name="Sgt Johnson!", voice_id="johnson")
        job = SpeechJob("hello", alias, timestamp="2026-10-14T15:42:03.456Z")
        path = engine._cache_file_path(job)
        self.assertRegex(path.name, r"^Sgt_Johnson_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}-456\.wav$")

    def test_audio_cache_keeps_only_newest_thirty_files(self):
        cache = Path(self.temp.name) / "audio_cache"
        cache.mkdir()
        for index in range(35):
            path = cache / f"voice_{index:02}.wav"
            path.write_bytes(b"wav")
            path.touch()
            import os
            os.utime(path, (index + 1, index + 1))
        SpeechEngine(self.settings, EventBus())
        remaining = sorted(path.name for path in cache.glob("*.wav"))
        self.assertEqual(len(remaining), 30)
        self.assertNotIn("voice_00.wav", remaining)
        self.assertIn("voice_34.wav", remaining)

    def test_invalid_zero_ports_fall_back_to_dedicated_defaults(self):
        path = Path(self.temp.name) / "invalid-ports.json"
        path.write_text(json.dumps({"http_port": 0, "ws_port": 0, "udp_port": 0}), encoding="utf-8")
        settings = Settings(path)
        self.assertEqual(settings.http_port, 7582)
        self.assertEqual(settings.ws_port, 7581)
        self.assertEqual(settings.udp_port, 6670)

    def test_null_rule_collections_do_not_discard_saved_aliases(self):
        path = Path(self.temp.name) / "null-rules.json"
        path.write_text(json.dumps({
            "blocked_words": None,
            "user_blocklist": None,
            "user_allowlist": None,
            "replacements": None,
            "pronunciations": None,
            "hidden_pronunciations": None,
            "user_voice_rules": None,
            "role_voice_rules": None,
            "aliases": {"Wallace": {"voice_id": "wallace"}},
        }), encoding="utf-8")
        settings = Settings(path)
        self.assertIn("Wallace", settings.aliases)
        self.assertEqual(settings.blocked_words, [])
        self.assertEqual(settings.replacements, {})

    def test_command_and_mention_tokens_can_be_removed_anywhere(self):
        engine = SpeechEngine(self.settings, EventBus())
        self.settings.ignore_command_messages = True
        command = engine.enqueue("before !command keep reading this", self.settings.aliases["EventVoice"])
        self.assertEqual(command.text, "before keep reading this")
        self.settings.ignore_mention_messages = True
        mention = engine.enqueue("thered20Coin @VwSExecutioner spun the wheel", self.settings.aliases["EventVoice"])
        self.assertEqual(mention.text, "thered20Coin spun the wheel")

    def test_prefix_characters_inside_words_are_not_removed(self):
        self.settings.ignore_command_messages = True
        self.settings.ignore_mention_messages = True
        engine = SpeechEngine(self.settings, EventBus())
        job = engine.enqueue("email@example.com wow!great", self.settings.aliases["EventVoice"])
        self.assertEqual(job.text, "email@example.com wow!great")

    def test_non_ascii_characters_can_be_removed(self):
        self.settings.strip_non_ascii = True
        engine = SpeechEngine(self.settings, EventBus())
        job = engine.enqueue("hello ╬ world 😀", self.settings.aliases["EventVoice"])
        self.assertEqual(job.text, "hello world 😀")

    def test_emojis_can_be_removed_independently(self):
        self.settings.strip_emojis = True
        engine = SpeechEngine(self.settings, EventBus())
        job = engine.enqueue("hello ╬ world 😀", self.settings.aliases["EventVoice"])
        self.assertEqual(job.text, "hello ╬ world")

    def test_symbol_heavy_ascii_art_can_be_blocked(self):
        self.settings.block_ascii_art = True
        engine = SpeechEngine(self.settings, EventBus())
        with self.assertRaisesRegex(ValueError, "ASCII art"):
            engine.enqueue("/\\/\\/\\/\\/\\", self.settings.aliases["EventVoice"])

    def test_links_can_be_removed_while_the_rest_is_spoken(self):
        self.settings.strip_links = True
        engine = SpeechEngine(self.settings, EventBus())
        job = engine.enqueue(
            "check https://example.com/page and www.example.org now",
            self.settings.aliases["EventVoice"],
        )
        self.assertEqual(job.text, "check and now")

    def test_blocked_phrase_rejects_speech(self):
        self.settings.blocked_words = ["spoiler"]
        engine = SpeechEngine(self.settings, EventBus())
        with self.assertRaisesRegex(ValueError, "blocked word"):
            engine.enqueue("This has a spoiler", self.settings.aliases["EventVoice"])

    def test_group_selects_an_alias(self):
        self.settings.aliases = {
            "One": VoiceAlias(name="One", group="Halo"),
            "Two": VoiceAlias(name="Two", group="Halo"),
        }
        engine = Mock()
        engine.enqueue.return_value = SpeechJob("hello", self.settings.aliases["One"])
        protocol = SpeakerBotProtocol(self.settings, engine)
        protocol.execute("Speak", {"message": "hello", "voice": "group:Halo"})
        self.assertIn(engine.enqueue.call_args.args[1].name, {"One", "Two"})

    def test_playground_overrides_do_not_modify_saved_alias(self):
        engine = Mock()
        engine.enqueue.return_value = SpeechJob("hello", self.settings.aliases["EventVoice"])
        protocol = SpeakerBotProtocol(self.settings, engine)
        protocol.execute("Speak", {"message": "hello", "voice": "EventVoice", "speed": 1.7})
        self.assertEqual(engine.enqueue.call_args.args[1].speed, 1.7)
        self.assertEqual(self.settings.aliases["EventVoice"].speed, 1.0)


if __name__ == "__main__":
    unittest.main()
