import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import Mock

from voice_studio_speaker_bridge.events import EventBus
from voice_studio_speaker_bridge.server import BridgeServers
from voice_studio_speaker_bridge.settings import Settings


class UdpServerTests(unittest.TestCase):
    def _send(self, payload: bytes):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        settings = Settings(Path(temp.name) / "settings.json")
        settings.udp_port = 0
        protocol = Mock()
        server = BridgeServers(settings, protocol, EventBus())
        self.addCleanup(server.stop)
        server.udp_thread = threading.Thread(target=server._run_udp, daemon=True)
        server.udp_thread.start()
        for _ in range(100):
            if server.udp_server is not None:
                break
            time.sleep(0.01)
        port = server.udp_server.server_address[1]
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            client.sendto(payload, ("127.0.0.1", port))
        for _ in range(100):
            if protocol.execute.called:
                break
            time.sleep(0.01)
        return protocol

    def test_plain_speak_packet(self):
        with tempfile.TemporaryDirectory() as temp:
            settings = Settings(Path(temp) / "settings.json")
            settings.udp_port = 0
            protocol = Mock()
            server = BridgeServers(settings, protocol, EventBus())
            server.udp_thread = threading.Thread(target=server._run_udp, daemon=True)
            server.udp_thread.start()
            for _ in range(100):
                if server.udp_server is not None:
                    break
                time.sleep(0.01)
            port = server.udp_server.server_address[1]
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                client.sendto(b"VSPEAK\nEventVoice\nhello \"quoted\" world", ("127.0.0.1", port))
            for _ in range(100):
                if protocol.execute.called:
                    break
                time.sleep(0.01)
            server.stop()
            protocol.execute.assert_called_once_with(
                "Speak", {"voice": "EventVoice", "message": 'hello "quoted" world'}
            )

    def test_simple_queue_control_packets(self):
        cases = [
            (b"VCONTROL\r\npause", "Pause", {}),
            (b"VCONTROL\nresume", "Resume", {}),
            (b"VCONTROL\nskip", "Stop", {}),
            (b"VCONTROL\nclear", "Clear", {}),
            (b"VCONTROL\nremove\nabc-123", "RemoveSpeech", {"speechId": "abc-123"}),
            (b"VCONTROL\nmoveup\nabc-123", "MoveSpeech", {"speechId": "abc-123", "direction": "up"}),
            (b"VCONTROL\nmovedown\nabc-123", "MoveSpeech", {"speechId": "abc-123", "direction": "down"}),
        ]
        for payload, command, data in cases:
            with self.subTest(payload=payload):
                protocol = self._send(payload)
                protocol.execute.assert_called_once_with(command, data)


if __name__ == "__main__":
    unittest.main()
