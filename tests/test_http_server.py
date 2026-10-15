import json
import tempfile
import time
import unittest
from pathlib import Path
from urllib.request import Request, urlopen
from unittest.mock import Mock

from voice_studio_speaker_bridge.events import EventBus
from voice_studio_speaker_bridge.server import BridgeServers
from voice_studio_speaker_bridge.settings import Settings


class HttpServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.settings = Settings(Path(self.temp.name) / "settings.json")
        self.settings.http_port = 0
        self.settings.enable_udp = False
        self.protocol = Mock()
        self.protocol.execute.return_value = {"speechId": "123"}
        self.server = BridgeServers(self.settings, self.protocol, EventBus())
        self.server.http_thread = __import__("threading").Thread(
            target=self.server._run_http, daemon=True
        )
        self.server.http_thread.start()
        for _ in range(100):
            if self.server.http_server is not None:
                break
            time.sleep(0.01)
        self.port = self.server.http_server.server_address[1]

    def tearDown(self):
        self.server.stop()
        self.temp.cleanup()

    def test_health_lists_aliases(self):
        with urlopen(f"http://127.0.0.1:{self.port}/health") as response:
            result = json.loads(response.read())
        self.assertTrue(result["ok"])
        self.assertIn("EventVoice", result["aliases"])

    def test_speak_passes_voice_and_message(self):
        body = json.dumps({"voice": "EventVoice", "message": "hello"}).encode()
        request = Request(
            f"http://127.0.0.1:{self.port}/speak",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urlopen(request) as response:
            result = json.loads(response.read())
        self.assertTrue(result["ok"])
        self.protocol.execute.assert_called_once_with(
            "Speak", {"voice": "EventVoice", "message": "hello"}
        )


if __name__ == "__main__":
    unittest.main()
