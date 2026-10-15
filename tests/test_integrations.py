import json
import base64
import gzip
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from voice_studio_speaker_bridge.events import EventBus
from voice_studio_speaker_bridge.maintenance import Maintenance
from voice_studio_speaker_bridge.models import SpeechJob, VoiceAlias
from voice_studio_speaker_bridge.obs import ObsClient, ObsDucking
from voice_studio_speaker_bridge.protocol import SpeakerBotProtocol
from voice_studio_speaker_bridge.providers import Provider, ProviderRegistry
from voice_studio_speaker_bridge.settings import Settings
from voice_studio_speaker_bridge.streamerbot import StreamerBotActions
from voice_studio_speaker_bridge.streamerbot_export import export_actions


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.settings = Settings(Path(self.temp.name) / "settings.json")

    def test_routing_first_match_overrides_legacy_rule_and_sets_priority(self):
        self.settings.aliases["Priority"] = VoiceAlias("Priority")
        self.settings.user_voice_rules["viewer"] = "EventVoice"
        self.settings.routing_rules = [
            {"field": "source", "value": "Twitch", "alias": "Priority", "priority": 20},
            {"field": "user", "value": "viewer", "alias": "EventVoice", "priority": 50},
        ]
        engine = Mock()
        engine.enqueue.return_value = SpeechJob("hi", self.settings.aliases["Priority"])
        SpeakerBotProtocol(self.settings, engine).execute("Speak", {"message": "hi", "user": "viewer", "source": "twitch"})
        self.assertEqual(engine.enqueue.call_args.args[1].name, "Priority")
        self.assertEqual(engine.enqueue.call_args.kwargs["priority"], 20)

    def test_provider_failure_keeps_other_provider_voices(self):
        registry = ProviderRegistry()
        bad = Mock(side_effect=RuntimeError("offline"))
        good = Mock()
        good.list_voices.return_value = [{"id": "one", "name": "One"}]
        registry.register(Provider("bad", "Offline", bad, lambda _: True, ()))
        registry.register(Provider("good", "Working", lambda _: good, lambda _: True, ()))
        voices, errors = registry.voices(self.settings)
        self.assertEqual(voices[0]["provider"], "good")
        self.assertEqual(errors, ["Offline: offline"])

    def test_speakerbot_migration_previews_supported_and_skipped_aliases(self):
        preview = Maintenance.preview_speakerbot({"aliases": [
            {"name": "Brian", "voices": [{"name": "Amazon Polly - British English - Brian (neural)", "volume": 0.8}]},
            {"name": "Other", "voices": [{"name": "Other engine - voice"}]},
        ]})
        self.assertEqual(preview["settings"]["aliases"]["Brian"]["voice_id"], "Brian")
        self.assertEqual(preview["skipped"][0]["name"], "Other")

    def test_profile_switch_does_not_change_credentials_or_network_ports(self):
        self.settings.api_key = "secret"
        self.settings.http_port = 9000
        self.settings.stream_volume = 0.4
        self.settings.save()
        maintenance = Maintenance(self.settings)
        maintenance.save_profile("Quiet")
        self.settings.api_key = "new secret"
        self.settings.http_port = 9001
        self.settings.stream_volume = 1
        self.settings.save()
        maintenance.load_profile("Quiet")
        self.assertEqual(self.settings.stream_volume, 0.4)
        self.assertEqual(self.settings.api_key, "new secret")
        self.assertEqual(self.settings.http_port, 9001)

    def test_profile_path_cannot_escape_profile_directory(self):
        with self.assertRaises(ValueError):
            Maintenance(self.settings).save_profile("../elsewhere")

    def test_lifecycle_simulator_never_registers_live_queue_items(self):
        self.settings.streamerbot_actions_enabled = True
        self.settings.streamerbot_queued_action = "queued"
        events = EventBus()
        integration = StreamerBotActions(self.settings, events)
        events.emit("integrationtest", "textqueued", {"id": "test"})
        self.assertEqual(integration.pending.get_nowait()[0], "queued")
        self.assertFalse(integration.active_speech_ids)
        self.assertFalse(integration.batch_queued_announced)

    def test_queued_action_acknowledges_after_request_completes(self):
        self.settings.streamerbot_actions_enabled = True
        self.settings.streamerbot_queued_action = "queued"
        events = EventBus()
        integration = StreamerBotActions(self.settings, events)
        integration._post_action = Mock()
        integration.start()
        try:
            signal = events.expect_action("one")
            events.emit("texttospeech", "textqueued", {"id": "one"})
            self.assertTrue(signal.wait(2))
            integration._post_action.assert_called_once()
        finally:
            integration.shutdown()

    def test_obs_authentication_matches_independent_sha256_vector(self):
        result = ObsClient.authentication("supersecretpassword",
            "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=",
            "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY=")
        # Verified independently with .NET SHA256, following OBS's two-stage hash.
        self.assertEqual(result, "1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4=")

    @patch("voice_studio_speaker_bridge.obs.ObsClient")
    def test_obs_restores_original_volume_only_after_queue_finishes(self, client_type):
        client = client_type.return_value
        client.request.side_effect = lambda kind, data: {"inputVolumeMul": 0.8} if kind == "GetInputVolume" else {}
        self.settings.obs_ducking_enabled = True
        self.settings.obs_input = "Music"
        self.settings.obs_duck_volume = 0.25
        events = EventBus()
        integration = ObsDucking(self.settings, events)
        integration.start()
        try:
            events.emit("texttospeech", "received", {"id": "one"})
            events.emit("texttospeech", "received", {"id": "two"})
            events.emit("texttospeech", "playing", {"id": "one"})
            integration.pending.join()
            events.emit("texttospeech", "finished", {"id": "one"})
            self.assertEqual(client.request.call_count, 2)
            events.emit("texttospeech", "finished", {"id": "two"})
            integration.pending.join()
            self.assertEqual(client.request.call_args.args,
                ("SetInputVolume", {"inputName": "Music", "inputVolumeMul": 0.8}))
        finally:
            integration.shutdown()

    def test_reset_creates_recoverable_backup(self):
        self.settings.max_queue = 55
        self.settings.save()
        maintenance = Maintenance(self.settings)
        backup = maintenance.reset("RESET")
        self.assertEqual(self.settings.max_queue, 25)
        self.assertEqual(json.loads(Path(backup).read_text())["max_queue"], 55)

    def test_streamerbot_export_has_valid_envelope_and_no_auto_run(self):
        encoded = export_actions(6670, "Windows voice")
        binary = base64.b64decode(encoded, validate=True)
        self.assertEqual(binary[:4], b"SBAE")
        envelope = json.loads(gzip.decompress(binary[4:]))
        self.assertEqual(envelope["version"], 10)
        self.assertIsNone(envelope["meta"]["autoRunAction"])
        actions = envelope["data"]["actions"]
        self.assertEqual(len(actions), 10)
        self.assertTrue(all(not action["triggers"] for action in actions))
        self.assertEqual(actions[0]["actions"][0]["payload"], "VSPEAK\r\nWindows voice\r\n%rawInput%")
        self.assertTrue(all(action["actions"][0]["port"] == 6670 for action in actions))
        self.assertIn("VCONTROL\r\nclearall", [action["actions"][0]["payload"] for action in actions])

    def test_extra_error_hook_runs_before_queue_session_finishes(self):
        self.settings.streamerbot_actions_enabled = True
        self.settings.streamerbot_error_action = "message failed"
        self.settings.streamerbot_finished_action = "queue done"
        events = EventBus()
        integration = StreamerBotActions(self.settings, events)
        events.emit("texttospeech", "received", {"id": "one"})
        events.emit("texttospeech", "received", {"id": "two"})
        events.emit("texttospeech", "error", {"id": "one"})
        action, arguments = integration.pending.get_nowait()
        self.assertEqual(action, "message failed")
        self.assertEqual(arguments["ttsState"], "itemError")
        self.assertTrue(integration.pending.empty())

    def test_private_release_unavailable_is_not_reported_as_up_to_date(self):
        from urllib.error import HTTPError
        with patch("voice_studio_speaker_bridge.maintenance.urlopen", side_effect=HTTPError("https://example.com", 404, "missing", {}, None)):
            result = Maintenance.check_updates()
        self.assertFalse(result["checked"])
        self.assertNotIn("available", result)
