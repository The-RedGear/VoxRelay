import sys
from pathlib import Path
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from voice_studio_speaker_bridge.audio import AudioPlayer, SAMPLE_RATE


class MediaClockTests(unittest.TestCase):
    def test_http_seek_route_changes_position(self):
        import json
        import time
        import urllib.request
        from threading import RLock, Thread
        from types import SimpleNamespace
        from voice_studio_speaker_bridge.engine import SpeechEngine
        from voice_studio_speaker_bridge.events import EventBus
        from voice_studio_speaker_bridge.protocol import SpeakerBotProtocol
        from voice_studio_speaker_bridge.server import BridgeServers
        engine = SpeechEngine.__new__(SpeechEngine)
        engine._lock = RLock()
        engine._current = SimpleNamespace(speech_id='current', status='Playing')
        engine.audio = AudioPlayer()
        engine.audio.arm_progress(2 * SAMPLE_RATE * 30)
        engine.audio.playing = True
        settings = SimpleNamespace(http_address='127.0.0.1', http_port=0)
        servers = BridgeServers(settings, SpeakerBotProtocol(settings, engine), EventBus())
        thread = Thread(target=servers._run_http, daemon=True)
        thread.start()
        try:
            deadline = time.monotonic() + 3
            while servers.http_server is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertIsNotNone(servers.http_server)
            port = servers.http_server.server_port
            request = urllib.request.Request(f'http://127.0.0.1:{port}/api/playback/seek',
                data=json.dumps(dict(seconds=17.25, speechId='current')).encode(),
                headers={'Content-Type': 'application/json'})
            with urllib.request.urlopen(request, timeout=3) as response:
                result = json.load(response)
            self.assertTrue(result['ok'])
            self.assertEqual(result['result']['elapsedSeconds'], 17.25)
            self.assertEqual(engine.audio._seek_target, int(17.25 * SAMPLE_RATE) * 2)
        finally:
            servers.stop()
            thread.join(3)

    def test_seeking_changes_pcm_and_preserves_pause(self):
        player = AudioPlayer()
        player.arm_progress(2 * SAMPLE_RATE * 30)
        player.playing = True
        player.pause()
        result = player.seek(12.5)
        self.assertEqual(result['elapsedSeconds'], 12.5)
        self.assertEqual(result['seekRevision'], 1)
        self.assertTrue(player._paused.is_set())
        self.assertEqual(player._seek_target, 25 * SAMPLE_RATE)
        self.assertEqual(player.remaining_seconds, 17.5)
        player.seek(-20)
        self.assertEqual(player.elapsed_seconds, 0)
        player.seek(200)
        self.assertEqual(player.elapsed_seconds, 30)
        with self.assertRaises(ValueError):
            player.seek(float('nan'))
        with self.assertRaises(ValueError):
            player.seek(float('inf'))
        player.playing = False
        with self.assertRaises(ValueError):
            player.seek(1)

    def test_stream_seeks_forward_and_backward_with_same_clip(self):
        targets = [None]
        paused = [False]
        def consume():
            target = targets[0]
            targets[0] = None
            return target
        stream = AudioPlayer._stream_pcm(b'abcdefghijklmnop', lambda: True,
                                        lambda: paused[0], lambda index: None, consume)
        next(stream)
        self.assertEqual(stream.send(2), b'abcd')
        targets[0] = 10
        self.assertEqual(stream.send(2), b'klmn')
        paused[0] = True
        targets[0] = 2
        self.assertEqual(stream.send(2), bytes(4))
        paused[0] = False
        self.assertEqual(stream.send(2), b'cdef')

    def test_seek_cannot_target_next_queue_item(self):
        from threading import RLock
        from types import SimpleNamespace
        from voice_studio_speaker_bridge.engine import SpeechEngine
        engine = SpeechEngine.__new__(SpeechEngine)
        engine._lock = RLock()
        engine._current = SimpleNamespace(speech_id='current', status='Playing')
        engine.audio = AudioPlayer()
        engine.audio.arm_progress(2 * SAMPLE_RATE * 10)
        engine.audio.playing = True
        with self.assertRaises(ValueError):
            engine.seek(5, 'previous')
        self.assertEqual(engine.seek(5, 'current')['elapsedSeconds'], 5)

    def test_pcm_duration_and_pause_resume_are_stable(self):
        player = AudioPlayer()
        self.assertEqual(player.arm_progress(2 * SAMPLE_RATE * 30), 30)
        self.assertEqual(player.elapsed_seconds, 0)
        player.playing = True
        player._submitted_seconds = 30
        player._clock_running = True
        player._play_origin = 100
        with patch('voice_studio_speaker_bridge.audio.monotonic', return_value=105):
            player.pause()
            self.assertEqual(player.elapsed_seconds, 5)
        with patch('voice_studio_speaker_bridge.audio.monotonic', return_value=200):
            player._sync_play_clock()
            self.assertEqual(player.elapsed_seconds, 5)
            player.resume()
        with patch('voice_studio_speaker_bridge.audio.monotonic', return_value=202):
            player.resume()  # Repeated Resume must not restart the clock.
            player._sync_play_clock()
            self.assertEqual(player.elapsed_seconds, 7)
            self.assertEqual(player.remaining_seconds, 23)
        player.arm_progress(2 * SAMPLE_RATE * 2)
        self.assertEqual(player.elapsed_seconds, 0)
        self.assertEqual(player.remaining_seconds, 2)

    def test_clock_cannot_outrun_submitted_audio(self):
        player = AudioPlayer()
        player.arm_progress(2 * SAMPLE_RATE * 30)
        player._clock_running = True
        player._play_origin = 100
        player._submitted_seconds = 1.5
        with patch('voice_studio_speaker_bridge.audio.monotonic', return_value=200):
            player._sync_play_clock()
            self.assertEqual(player.elapsed_seconds, 1.5)
            player.pause()
            self.assertEqual(player._play_hold, 1.5)

    def test_pcm_stream_pauses_without_skipping_samples(self):
        paused = [False]
        positions = []
        stream = AudioPlayer._stream_pcm(b'abcdefghijkl', lambda: True, lambda: paused[0], positions.append)
        next(stream)
        self.assertEqual(stream.send(2), b'abcd')
        paused[0] = True
        self.assertEqual(stream.send(2), bytes(4))
        self.assertEqual(positions, [4])
        paused[0] = False
        self.assertEqual(stream.send(2), b'efgh')
        self.assertEqual(stream.send(8), b'ijkl')
        self.assertEqual(positions, [4, 8, 12])


if __name__ == '__main__':
    unittest.main()
