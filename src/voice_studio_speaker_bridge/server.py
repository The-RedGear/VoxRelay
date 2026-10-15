from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
import json
import logging
import socketserver
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock, Thread

from websockets import CloseCode
from websockets.sync.server import Server, ServerConnection, serve

from .events import EventBus
from .audio import AudioPlayer
from .protocol import SpeakerBotProtocol
from .settings import Settings
from .polly import PollyClient
from .voicestudio import VoiceStudioClient


@dataclass
class Connection:
    websocket: ServerConnection
    subscriptions: dict[str, set[str]] = field(default_factory=dict)
    send_lock: Lock = field(default_factory=Lock)

    def send(self, payload: str) -> None:
        # A response and a TTS event can be produced by different threads.
        # websockets requires concurrent writes to be serialized.
        with self.send_lock:
            self.websocket.send(payload)


class BridgeServers:
    def __init__(self, settings: Settings, protocol: SpeakerBotProtocol, events: EventBus):
        self.settings = settings
        self.protocol = protocol
        self.events = events
        self.events.subscribe(self.broadcast_event)
        self.connections: dict[int, Connection] = {}
        self.lock = Lock()
        self.ws_server: Server | None = None
        self.udp_server: socketserver.ThreadingUDPServer | None = None
        self.http_server: ThreadingHTTPServer | None = None
        self.ws_thread: Thread | None = None
        self.udp_thread: Thread | None = None
        self.http_thread: Thread | None = None

    def start(self) -> None:
        self.http_thread = Thread(target=self._run_http, name="HTTP server", daemon=True)
        self.http_thread.start()
        self.ws_thread = Thread(target=self._run_ws, name="WebSocket server", daemon=True)
        self.ws_thread.start()
        if self.settings.enable_udp:
            self.udp_thread = Thread(target=self._run_udp, name="UDP server", daemon=True)
            self.udp_thread.start()

    def stop(self) -> None:
        with self.lock:
            for connection in list(self.connections.values()):
                try:
                    connection.websocket.close(CloseCode.GOING_AWAY)
                except Exception:
                    pass
            self.connections.clear()
        if self.ws_server is not None:
            self.ws_server.shutdown()
        if self.udp_server is not None:
            self.udp_server.shutdown()
            self.udp_server.server_close()
        if self.http_server is not None:
            self.http_server.shutdown()
            self.http_server.server_close()
        if self.ws_thread is not None:
            self.ws_thread.join(timeout=3)
        if self.udp_thread is not None:
            self.udp_thread.join(timeout=3)
        if self.http_thread is not None:
            self.http_thread.join(timeout=3)

    def _run_http(self) -> None:
        bridge = self

        class Handler(BaseHTTPRequestHandler):
            def _reply(self, status: int, payload: dict) -> None:
                body = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:
                path = self.path.rstrip("/")
                if path == "/api/state":
                    self._reply(200, {"ok": True, "result": bridge.protocol.execute("GetState", {})})
                    return
                if path == "/api/history":
                    self._reply(200, {"ok": True, "result": bridge.protocol.execute("GetHistory", {})})
                    return
                if path == "/api/devices":
                    self._reply(200, {"ok": True, "devices": AudioPlayer.list_devices()})
                    return
                if path == "/api/voices":
                    bridge.settings.reload_if_changed()
                    voices: list[dict] = []
                    errors: list[str] = []
                    try:
                        client = VoiceStudioClient(
                            bridge.settings.voice_studio_url,
                            bridge.settings.api_key,
                            bridge.settings.request_timeout,
                        )
                        for voice in client.list_voices():
                            voice_id = str(voice.get("voice_id") or voice.get("id") or voice.get("name") or "default")
                            voices.append({
                                "provider": "voicestudio",
                                "voice_id": voice_id,
                                "name": str(voice.get("name") or voice.get("display_name") or voice_id),
                                "model": "tts-1",
                                "language": "",
                            })
                    except Exception as exc:
                        errors.append(f"VoiceStudio: {exc}")
                    if bridge.settings.polly_enabled:
                        try:
                            voices.extend(PollyClient(
                                bridge.settings.polly_region,
                                bridge.settings.polly_profile,
                                bridge.settings.polly_access_key_encrypted,
                                bridge.settings.polly_secret_key_encrypted,
                            ).list_voices())
                        except Exception as exc:
                            errors.append(f"Amazon Polly: {exc}")
                    self._reply(200, {"ok": True, "voices": voices, "errors": errors})
                    return
                if path != "/health":
                    self._reply(404, {"ok": False, "error": "Not found"})
                    return
                bridge.settings.reload_if_changed()
                self._reply(200, {
                    "ok": True,
                    "name": "VoxRelay",
                    "aliases": sorted(bridge.settings.aliases),
                })

            def do_POST(self) -> None:
                routes = {"/speak": "Speak", "/stop": "Stop", "/clear": "Clear",
                          "/pause": "Pause", "/resume": "Resume", "/skip": "Stop",
                          "/api/history/clear": "ClearHistory", "/api/history/save": "SaveHistoryAudio", "/api/queue/remove": "RemoveSpeech",
                          "/api/queue/move": "MoveSpeech"}
                command = routes.get(self.path.rstrip("/"))
                is_streamerbot_test = self.path.rstrip("/") == "/api/integrations/streamerbot/test"
                if command is None and not is_streamerbot_test:
                    self._reply(404, {"ok": False, "error": "Not found"})
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if length > 1_000_000:
                        raise ValueError("Request is too large")
                    raw = self.rfile.read(length) if length else b"{}"
                    data = json.loads(raw.decode("utf-8"))
                    if not isinstance(data, dict):
                        raise ValueError("JSON body must be an object")
                    if is_streamerbot_test:
                        state = str(data.get("state", "")).casefold()
                        event_type = {"queued": "textqueued", "queueadded": "queueadded", "playing": "playing", "finished": "finished"}.get(state)
                        if event_type is None:
                            raise ValueError("state must be queued, queueAdded, playing, or finished")
                        bridge.events.emit("texttospeech", event_type, {
                            "id": "lifecycle-test", "text": "VoxRelay lifecycle test",
                            "alias": "Test", "voiceName": "test", "source": "Settings",
                            "user": "", "duration": 0.0,
                        })
                        self._reply(200, {"ok": True, "result": {"state": state}})
                        return
                    result = bridge.protocol.execute(command, data)
                    self._reply(200, {"ok": True, "result": result})
                except (ValueError, TypeError, json.JSONDecodeError) as exc:
                    self._reply(400, {"ok": False, "error": str(exc)})
                except Exception as exc:
                    logging.exception("HTTP bridge request failed")
                    self._reply(500, {"ok": False, "error": str(exc)})

            def log_message(self, format: str, *args) -> None:
                logging.info("HTTP %s - %s", self.address_string(), format % args)

        try:
            with ThreadingHTTPServer((self.settings.http_address, self.settings.http_port), Handler) as server:
                self.http_server = server
                logging.info("HTTP server listening on http://%s:%d", self.settings.http_address, self.settings.http_port)
                server.serve_forever()
        except OSError:
            logging.exception("Could not start HTTP server")
        finally:
            self.http_server = None

    def _run_ws(self) -> None:
        try:
            with serve(self._handle_ws, self.settings.ws_address, self.settings.ws_port) as server:
                self.ws_server = server
                logging.info("WebSocket server listening on ws://%s:%d", self.settings.ws_address, self.settings.ws_port)
                server.serve_forever()
        except OSError:
            logging.exception("Could not start WebSocket server")
        finally:
            self.ws_server = None

    def _handle_ws(self, websocket: ServerConnection) -> None:
        key = id(websocket)
        with self.lock:
            self.connections[key] = Connection(websocket)
        try:
            for raw in websocket:
                if not isinstance(raw, str):
                    raw = raw.decode("utf-8")
                with self.lock:
                    connection = self.connections.get(key)
                if connection is not None:
                    connection.send(self.handle_websocket_message(raw, key))
        finally:
            with self.lock:
                self.connections.pop(key, None)

    def handle_websocket_message(self, raw: str, connection_key: int) -> str:
        request_id = ""
        try:
            data = json.loads(raw)
            request_id = data.get("id", "")
            request = str(data.get("request", ""))
            if not request_id or not request:
                raise ValueError("Request requires string id and request fields")
            if request.lower() == "subscribe":
                result = self._subscribe(connection_key, data.get("events", {}), add=True)
            elif request.lower() == "unsubscribe":
                result = self._subscribe(connection_key, data.get("events", {}), add=False)
            else:
                result = self.protocol.execute(request, data)
            return json.dumps({"id": request_id, "status": "ok", "result": result})
        except (ValueError, TypeError, json.JSONDecodeError) as exc:
            return json.dumps({"id": request_id, "status": "error", "error": str(exc)})

    def _subscribe(self, key: int, requested: dict, add: bool) -> dict:
        if not isinstance(requested, dict):
            raise ValueError("events must be an object")
        with self.lock:
            connection = self.connections.get(key)
            if connection is None:
                raise ValueError("Connection not found")
            if "*" in requested:
                connection.subscriptions = (
                    {source: set(types) for source, types in self.protocol.EVENTS.items()} if add else {}
                )
            else:
                for source, event_types in requested.items():
                    source = source.lower()
                    values = self.protocol.EVENTS.get(source, []) if "*" in event_types else event_types
                    bucket = connection.subscriptions.setdefault(source, set())
                    if add:
                        bucket.update(str(value).lower() for value in values)
                    else:
                        bucket.difference_update(str(value).lower() for value in values)
        return {"events": requested}

    def broadcast_event(self, source: str, event_type: str, data: dict) -> None:
        payload = json.dumps({
            "timeStamp": datetime.now().astimezone().isoformat(),
            "event": {"source": source, "type": event_type},
            "data": data,
        })
        with self.lock:
            connections = list(self.connections.values())
        for connection in connections:
            allowed = connection.subscriptions.get(source.lower(), set())
            if event_type.lower() not in allowed:
                continue
            try:
                connection.send(payload)
            except Exception:
                logging.exception("Could not broadcast event")

    def _run_udp(self) -> None:
        bridge = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                try:
                    raw = self.request[0].decode("utf-8").strip()
                    lines = raw.splitlines()
                    packet_type = lines[0].strip().upper() if lines else ""
                    if packet_type == "VSPEAK":
                        parts = raw.splitlines(keepends=False)
                        if len(parts) < 3:
                            raise ValueError("VSPEAK packet requires an alias and message")
                        command = "Speak"
                        data = {"voice": parts[1].strip(), "message": "\n".join(parts[2:])}
                    elif packet_type == "VCONTROL":
                        parts = lines
                        action = parts[1].strip().casefold() if len(parts) > 1 else ""
                        speech_id = parts[2].strip() if len(parts) > 2 else ""
                        controls = {
                            "pause": ("Pause", {}), "resume": ("Resume", {}),
                            "skip": ("Stop", {}), "skip current": ("Stop", {}),
                            "clear": ("Clear", {}), "clear queue": ("Clear", {}),
                            "remove": ("RemoveSpeech", {"speechId": speech_id}),
                            "moveup": ("MoveSpeech", {"speechId": speech_id, "direction": "up"}),
                            "move up": ("MoveSpeech", {"speechId": speech_id, "direction": "up"}),
                            "movedown": ("MoveSpeech", {"speechId": speech_id, "direction": "down"}),
                            "move down": ("MoveSpeech", {"speechId": speech_id, "direction": "down"}),
                        }
                        if action not in controls:
                            raise ValueError(f"Unsupported VCONTROL action: {action}")
                        command, data = controls[action]
                        if command in {"RemoveSpeech", "MoveSpeech"} and not speech_id:
                            raise ValueError(f"VCONTROL {action} requires a speechId on line 3")
                        logging.info("UDP queue control received: %s", action)
                    else:
                        data = json.loads(raw)
                        command = str(data.get("command", ""))
                    bridge.protocol.execute(command, data)
                except Exception:
                    logging.exception("Invalid UDP request")

        class ExclusiveUDPServer(socketserver.ThreadingUDPServer):
            # A reused UDP port delivers the same Streamer.bot broadcast to
            # every bridge process, causing duplicated speech.
            allow_reuse_address = False

        try:
            with ExclusiveUDPServer((self.settings.udp_address, self.settings.udp_port), Handler) as server:
                self.udp_server = server
                logging.info("UDP server listening on udp://%s:%d", self.settings.udp_address, self.settings.udp_port)
                server.serve_forever()
        except OSError:
            logging.exception("Could not start UDP server")
        finally:
            self.udp_server = None
