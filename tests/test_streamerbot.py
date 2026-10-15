import json
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from voice_studio_speaker_bridge.events import EventBus
from voice_studio_speaker_bridge.settings import Settings
from voice_studio_speaker_bridge.streamerbot import StreamerBotActions


class StreamerBotActionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.settings = Settings(Path(self.temp.name) / "settings.json")
        self.settings.streamerbot_actions_enabled = True
        self.settings.streamerbot_queued_action = "Sock Puppet Incoming"
        self.settings.streamerbot_queue_added_action = "Sock Puppet Queue Pulse"
        self.settings.streamerbot_playing_action = "Sock Puppet Talking"
        self.settings.streamerbot_finished_action = "Sock Puppet Hide"
        self.events = EventBus()
        self.integration = StreamerBotActions(self.settings, self.events)

    def tearDown(self):
        self.temp.cleanup()

    def test_lifecycle_events_queue_configured_actions_and_arguments(self):
        data = {"id": "abc", "text": "hello", "alias": "Wallace", "voiceName": "voice-1",
                "source": "Streamer.bot", "user": "viewer", "duration": 123.0}
        self.events.emit("texttospeech", "textqueued", data)
        self.events.emit("texttospeech", "playing", data)
        self.events.emit("texttospeech", "finished", data)
        queued = [self.integration.pending.get_nowait() for _ in range(3)]
        self.assertEqual([item[0] for item in queued], [
            "Sock Puppet Incoming", "Sock Puppet Talking", "Sock Puppet Hide"
        ])
        self.assertEqual(queued[1][1]["ttsState"], "playing")
        self.assertEqual(queued[1][1]["ttsAlias"], "Wallace")

    @patch("voice_studio_speaker_bridge.streamerbot.urlopen")
    def test_action_is_sent_by_name_using_streamerbot_http_api(self, mocked_open):
        mocked_open.return_value.__enter__.return_value.status = 204
        self.integration._post_action("Sock Puppet Talking", {"ttsState": "playing"})
        request = mocked_open.call_args.args[0]
        payload = json.loads(request.data.decode("utf-8"))
        self.assertEqual(request.full_url, "http://127.0.0.1:7474/DoAction")
        self.assertEqual(payload["action"], {"name": "Sock Puppet Talking"})
        self.assertEqual(payload["args"]["ttsState"], "playing")

    def test_finished_action_waits_for_configured_delay(self):
        self.settings.streamerbot_finished_delay = 0.05
        self.events.emit("texttospeech", "finished", {"id": "abc"})
        self.assertTrue(self.integration.pending.empty())
        time.sleep(0.1)
        action, arguments = self.integration.pending.get_nowait()
        self.assertEqual(action, "Sock Puppet Hide")
        self.assertEqual(arguments["ttsState"], "finished")

    def test_new_playback_cancels_a_pending_finished_action(self):
        self.settings.streamerbot_finished_delay = 0.1
        self.events.emit("texttospeech", "finished", {"id": "first"})
        self.events.emit("texttospeech", "playing", {"id": "second"})
        action, arguments = self.integration.pending.get_nowait()
        self.assertEqual(action, "Sock Puppet Talking")
        self.assertEqual(arguments["ttsId"], "second")
        time.sleep(0.15)
        self.assertTrue(self.integration.pending.empty())

    def test_finished_action_waits_until_every_queued_item_is_done(self):
        first = {"id": "first"}
        second = {"id": "second"}
        self.events.emit("texttospeech", "queueadded", second)
        self.events.emit("texttospeech", "textqueued", first)
        self.integration.pending.get_nowait()
        self.integration.pending.get_nowait()
        self.events.emit("texttospeech", "finished", first)
        self.assertTrue(self.integration.pending.empty())
        self.events.emit("texttospeech", "finished", second)
        action, arguments = self.integration.pending.get_nowait()
        self.assertEqual(action, "Sock Puppet Hide")
        self.assertEqual(arguments["ttsId"], "second")

    def test_active_queue_uses_added_action_and_does_not_restart_playback_action(self):
        self.events.emit("texttospeech", "textqueued", {"id": "first"})
        self.events.emit("texttospeech", "playing", {"id": "first"})
        self.integration.pending.get_nowait()
        self.integration.pending.get_nowait()
        self.events.emit("texttospeech", "queueadded", {"id": "second"})
        action, arguments = self.integration.pending.get_nowait()
        self.assertEqual(action, "Sock Puppet Queue Pulse")
        self.assertEqual(arguments["ttsState"], "queueAdded")
        self.events.emit("texttospeech", "playing", {"id": "second"})
        self.assertTrue(self.integration.pending.empty())

    def test_second_item_uses_added_action_even_before_playback_starts(self):
        self.events.emit("texttospeech", "queueadded", {"id": "second"})
        self.events.emit("texttospeech", "textqueued", {"id": "first"})
        first = self.integration.pending.get_nowait()
        second = self.integration.pending.get_nowait()
        self.assertEqual(first[0], "Sock Puppet Queue Pulse")
        self.assertEqual(first[1]["ttsState"], "queueAdded")
        self.assertEqual(second[0], "Sock Puppet Incoming")

    def test_ready_events_after_first_do_not_repeat_queued_action(self):
        self.events.emit("texttospeech", "queueadded", {"id": "second"})
        self.events.emit("texttospeech", "textqueued", {"id": "first"})
        self.integration.pending.get_nowait()
        self.integration.pending.get_nowait()
        self.events.emit("texttospeech", "textqueued", {"id": "second"})
        self.assertTrue(self.integration.pending.empty())

    def test_cleared_items_finish_the_queue_session(self):
        self.events.emit("texttospeech", "queueadded", {"id": "second"})
        self.events.emit("texttospeech", "textqueued", {"id": "first"})
        self.integration.pending.get_nowait()
        self.integration.pending.get_nowait()
        self.events.emit("texttospeech", "cancelled", {"id": "first"})
        self.assertTrue(self.integration.pending.empty())
        self.events.emit("texttospeech", "cancelled", {"id": "second"})
        action, arguments = self.integration.pending.get_nowait()
        self.assertEqual(action, "Sock Puppet Hide")
        self.assertEqual(arguments["ttsState"], "cancelled")


if __name__ == "__main__":
    unittest.main()
