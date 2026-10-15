import json
import tempfile
import unittest
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event, Thread
from unittest.mock import Mock

from voice_studio_speaker_bridge.audio import AudioPlayer
from voice_studio_speaker_bridge.engine import SpeechEngine
from voice_studio_speaker_bridge.events import EventBus
from voice_studio_speaker_bridge.maintenance import Maintenance
from voice_studio_speaker_bridge.models import VoiceAlias
from voice_studio_speaker_bridge.settings import Settings
from voice_studio_speaker_bridge.streamerbot import StreamerBotActions


class ReliabilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.settings = Settings(Path(self.temp.name) / "settings.json")
        self.events = EventBus()
        self.engine = SpeechEngine(self.settings, self.events)
        self.alias = self.settings.aliases["EventVoice"]

    def test_concurrent_admission_never_exceeds_limit(self):
        self.settings.max_queue = 5
        def send(index):
            try:
                return self.engine.enqueue(str(index), self.alias)
            except ValueError:
                return None
        with ThreadPoolExecutor(max_workers=12) as pool:
            accepted = list(pool.map(send, range(50)))
        self.assertEqual(sum(item is not None for item in accepted), 5)

    def test_priority_preserves_order_within_same_priority(self):
        first = self.engine.enqueue("first", self.alias)
        important = self.engine.enqueue("important", self.alias, priority=10)
        second = self.engine.enqueue("second", self.alias)
        self.assertEqual([job["id"] for job in self.engine.state()["queue"]],
                         [important.speech_id, first.speech_id, second.speech_id])

    def test_duplicate_rejection_does_not_block_other_users(self):
        self.settings.duplicate_window = 30
        self.engine.enqueue("hello", self.alias, user="one")
        with self.assertRaisesRegex(ValueError, "already"):
            self.engine.enqueue("HELLO", self.alias, user="one")
        self.engine.enqueue("hello", self.alias, user="two")

    def test_per_user_queue_limit(self):
        self.settings.per_user_queue_limit = 1
        self.engine.enqueue("hello", self.alias, user="viewer")
        with self.assertRaisesRegex(ValueError, "queue limit"):
            self.engine.enqueue("again", self.alias, user="VIEWER")

    def test_removed_job_releases_capacity_and_has_one_terminal_event(self):
        self.settings.max_queue = 1
        job = self.engine.enqueue("hello", self.alias)
        self.assertTrue(self.engine.remove(job.speech_id))
        self.assertFalse(self.engine.remove(job.speech_id))
        self.engine.enqueue("again", self.alias)
        cancelled = [event for event in self.events.recent() if event["event"] == "cancelled"]
        self.assertEqual(len(cancelled), 1)

    def test_clear_releases_lifecycle_even_before_generation(self):
        self.settings.streamerbot_actions_enabled = True
        self.settings.streamerbot_finished_action = "finished"
        integration = StreamerBotActions(self.settings, self.events)
        self.engine.enqueue("first", self.alias)
        self.engine.enqueue("second", self.alias)
        self.engine.clear()
        self.assertEqual(integration.pending.get_nowait()[0], "finished")
        self.assertTrue(integration.pending.empty())

    def test_skip_interrupts_playback_delay(self):
        self.settings.streamerbot_actions_enabled = True
        self.settings.streamerbot_queued_action = "ready"
        self.settings.streamerbot_playback_delay = 10
        ready, terminal = Event(), Event()
        self.events.subscribe(lambda _s, kind, _d: ready.set() if kind == "textqueued" else
                              terminal.set() if kind == "cancelled" else None)
        self.engine._synthesize = lambda job: b"wav"
        self.engine.audio = Mock(warning="")
        self.engine.audio.decode_wav.return_value = (b"pcm", 100)
        self.engine.enqueue("hello", self.alias)
        self.engine.start()
        self.addCleanup(self.engine.shutdown)
        self.assertTrue(ready.wait(2))
        self.engine.stop_current()
        self.assertTrue(terminal.wait(0.75))
        self.engine.audio.play.assert_not_called()

    def test_skip_during_generation_allows_next_message(self):
        generating, unblock, second = Event(), Event(), Event()
        def synthesize(job):
            if job.text == "first":
                generating.set()
                unblock.wait(3)
            else:
                second.set()
            return b"wav"
        self.engine._synthesize = synthesize
        self.engine.audio = Mock(warning="")
        self.engine.audio.decode_wav.return_value = (b"pcm", 100)
        self.engine.audio.play.return_value = True
        self.engine.enqueue("first", self.alias)
        self.engine.enqueue("second", self.alias)
        self.engine.start()
        try:
            self.assertTrue(generating.wait(2))
            self.engine.stop_current()
            self.assertTrue(second.wait(0.75))
        finally:
            unblock.set()
            self.engine.shutdown()

    def test_audio_failure_produces_error_and_terminal_event(self):
        failed = Event()
        self.events.subscribe(lambda _s, kind, _d: failed.set() if kind == "error" else None)
        self.engine._synthesize = lambda job: b"wav"
        self.engine.audio = Mock(warning="")
        self.engine.audio.decode_wav.return_value = (b"pcm", 100)
        self.engine.audio.play.return_value = False
        self.engine.enqueue("hello", self.alias)
        self.engine.start()
        try:
            self.assertTrue(failed.wait(2))
        finally:
            self.engine.shutdown()
        self.assertEqual(self.engine.history[0]["status"], "Error")

    def test_paused_pcm_does_not_advance(self):
        paused = Event()
        paused.set()
        stream = AudioPlayer._stream_pcm(b"\x01\x02\x03\x04", lambda: True, paused.is_set)
        next(stream)
        self.assertEqual(stream.send(1), b"\x00\x00")
        paused.clear()
        self.assertEqual(stream.send(1), b"\x01\x02")

    def test_corrupt_settings_recover_previous_valid_backup(self):
        self.settings.save()
        self.settings.max_queue = 12
        self.settings.save()
        self.settings.path.write_text("{broken", encoding="utf-8")
        recovered = Settings(self.settings.path)
        self.assertEqual(recovered.max_queue, 25)
        self.assertIn("recovered", recovered.recovery_notice)

    def test_subscriber_failure_cannot_break_other_integrations(self):
        self.events.subscribe(Mock(side_effect=RuntimeError("disconnected")))
        observer = Mock()
        self.events.subscribe(observer)
        self.events.emit("texttospeech", "finished", {"id": "one"})
        observer.assert_called_once()

    def test_diagnostics_exclude_messages_keys_and_paths(self):
        self.settings.api_key = "SECRET"
        self.events.emit("texttospeech", "received", {"text": "PRIVATE MESSAGE", "user": "PRIVATE USER"})
        path = Maintenance(self.settings).diagnostics(self.engine.state(), self.events.recent())
        with zipfile.ZipFile(path) as archive:
            contents = archive.read("diagnostics.json").decode()
        for private in ("SECRET", "PRIVATE MESSAGE", "PRIVATE USER", self.temp.name):
            self.assertNotIn(private, contents)

    def test_backup_restore_preserves_pre_restore_copy(self):
        maintenance = Maintenance(self.settings)
        original = Path(maintenance.backup())
        self.settings.max_queue = 99
        self.settings.save()
        maintenance.restore(original.name)
        self.assertEqual(self.settings.max_queue, 25)
        self.assertEqual(len(maintenance.backups()), 2)

    def test_queue_restoration_starts_paused(self):
        self.settings.persist_queue = True
        self.engine.enqueue("restore me", self.alias)
        restored = SpeechEngine(self.settings, EventBus())
        self.assertTrue(restored.state()["paused"])
        self.assertEqual(restored.state()["queue"][0]["text"], "restore me")

    def test_preset_exports_exclude_credentials(self):
        self.settings.api_key = "SECRET"
        self.settings.save()
        path = Maintenance(self.settings).export_presets()
        data = json.loads(Path(path).read_text())
        self.assertNotIn("api_key", data["settings"])
        self.assertEqual(data["format"], "VoxRelay-presets")

    def test_reorder_moves_a_pending_item_before_target(self):
        first = self.engine.enqueue("first", self.alias)
        second = self.engine.enqueue("second", self.alias)
        third = self.engine.enqueue("third", self.alias)
        self.assertTrue(self.engine.move_before(third.speech_id, first.speech_id))
        self.assertEqual([item["id"] for item in self.engine.state()["queue"]],
                         [third.speech_id, first.speech_id, second.speech_id])

    def test_expired_message_never_calls_provider(self):
        done = Event()
        self.settings.max_message_age = 1
        job = self.engine.enqueue("too old", self.alias)
        job.enqueued_at -= 10
        self.engine._synthesize = Mock()
        self.events.subscribe(lambda _s, kind, _d: done.set() if kind == "cancelled" else None)
        self.engine.start()
        try:
            self.assertTrue(done.wait(2))
        finally:
            self.engine.shutdown()
        self.engine._synthesize.assert_not_called()

    def test_ssml_keeps_markup_and_applies_pronunciation_to_text(self):
        self.settings.pronunciations = {"RG": "Red Gear"}
        alias = VoiceAlias("Brian", provider="polly", ssml=True)
        job = self.engine.enqueue('<speak>Hello <emphasis>RG</emphasis> today.</speak>', alias)
        self.assertIn('<emphasis>Red Gear</emphasis> today.', job.text)

    def test_ssml_cannot_split_a_blocked_word_across_tags(self):
        self.settings.blocked_words = ["spoiler"]
        alias = VoiceAlias("Brian", provider="polly", ssml=True)
        with self.assertRaisesRegex(ValueError, "blocked"):
            self.engine.enqueue('<speak>spoi<emphasis>ler</emphasis></speak>', alias)

    def test_ssml_rejects_external_content_and_declarations(self):
        alias = VoiceAlias("Brian", provider="polly", ssml=True)
        for text in ('<!DOCTYPE speak><speak>Hello</speak>', '<speak><audio src="https://example.com"/></speak>'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.engine.enqueue(text, alias)

    def test_output_test_generates_a_local_wav_without_provider(self):
        job = self.engine.test_output("Test output", preview=True)
        self.assertEqual(job.audio_bytes[:4], b"RIFF")
        self.assertEqual(job.alias.output_device, "Test output")
        self.assertEqual(job.source, "Output preview")

    def test_device_stop_does_not_lock_out_the_audio_callback(self):
        player = AudioPlayer()
        completed = Event()
        def callback():
            with player._condition:
                completed.set()
        def stop_device():
            worker = Thread(target=callback, daemon=True)
            worker.start()
            self.assertTrue(completed.wait(1), "Audio callback was locked out during stop")
            worker.join(1)
        player.device = Mock()
        player.device.stop.side_effect = stop_device
        player.stop()

    def test_start_does_not_register_prequeued_messages_twice(self):
        self.engine.enqueue("hello", self.alias)
        self.engine.pause()
        self.engine.start()
        self.engine.shutdown()
        self.assertEqual(sum(item["event"] == "received" for item in self.events.recent()), 1)
