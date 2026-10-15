"""OBS WebSocket v5 audio ducking. Disabled until explicitly configured."""
from __future__ import annotations

import base64
import hashlib
import json
import logging
import uuid
from queue import Queue
from threading import RLock, Thread

from websockets.sync.client import connect

from .secrets import unprotect_windows_secret


class ObsClient:
    def __init__(self, url: str, password: str = ""):
        self.url, self.password = url, password

    @staticmethod
    def authentication(password: str, salt: str, challenge: str) -> str:
        secret = base64.b64encode(hashlib.sha256((password + salt).encode()).digest()).decode()
        return base64.b64encode(hashlib.sha256((secret + challenge).encode()).digest()).decode()

    def request(self, request_type: str, data: dict | None = None) -> dict:
        with connect(self.url, open_timeout=3, close_timeout=1) as socket:
            hello = json.loads(socket.recv(timeout=3))
            if hello.get("op") != 0:
                raise ValueError("OBS did not send a WebSocket v5 greeting")
            identification = {"rpcVersion": 1, "eventSubscriptions": 0}
            auth = hello.get("d", {}).get("authentication")
            if auth:
                identification["authentication"] = self.authentication(self.password, auth["salt"], auth["challenge"])
            socket.send(json.dumps({"op": 1, "d": identification}))
            if json.loads(socket.recv(timeout=3)).get("op") != 2:
                raise ValueError("OBS could not authenticate. Check its WebSocket password.")
            request_id = uuid.uuid4().hex
            socket.send(json.dumps({"op": 6, "d": {"requestType": request_type,
                "requestId": request_id, "requestData": data or {}}}))
            response = json.loads(socket.recv(timeout=3))
            result = response.get("d", {})
            if response.get("op") != 7 or result.get("requestId") != request_id:
                raise ValueError("OBS returned an unexpected response")
            if not result.get("requestStatus", {}).get("result"):
                raise ValueError(str(result.get("requestStatus", {}).get("comment") or "OBS request failed"))
            return result.get("responseData", {})


class ObsDucking:
    def __init__(self, settings, events):
        self.settings, self.events = settings, events
        self.active = set()
        self.lock = RLock()
        self.pending = Queue()
        self.original = None
        self.thread = Thread(target=self._run, name="OBS ducking", daemon=True)
        events.subscribe(self._event)

    def start(self):
        self.thread.start()

    def shutdown(self):
        with self.lock:
            self.active.clear()
        self.pending.put("restore")
        self.pending.put(None)
        self.thread.join(timeout=12)

    def _event(self, source, kind, data):
        if source != "texttospeech":
            return
        with self.lock:
            if kind == "received":
                self.active.add(data["id"])
            elif kind == "playing" and self.settings.obs_ducking_enabled:
                self.pending.put("duck")
            elif kind in {"finished", "cancelled", "error"}:
                self.active.discard(data["id"])
                if not self.active:
                    self.pending.put("restore")

    def _run(self):
        while True:
            command = self.pending.get()
            try:
                if command is None:
                    return
                if command == "duck":
                    with self.lock:
                        if not self.active or self.original is not None:
                            continue
                    client = ObsClient(self.settings.obs_url, unprotect_windows_secret(self.settings.obs_password_encrypted))
                    name = self.settings.obs_input
                    if not name:
                        continue
                    volume = float(client.request("GetInputVolume", {"inputName": name})["inputVolumeMul"])
                    # Keep the original before changing OBS, so restore can retry on failure.
                    self.original = (client, name, volume)
                    gain = max(0, min(1, self.settings.obs_duck_volume))
                    client.request("SetInputVolume", {"inputName": name, "inputVolumeMul": volume * gain})
                elif command == "restore" and self.original is not None:
                    with self.lock:
                        if self.active:
                            continue
                    client, name, volume = self.original
                    client.request("SetInputVolume", {"inputName": name, "inputVolumeMul": volume})
                    self.original = None
            except Exception:
                logging.exception("OBS ducking failed")
                self.events.emit("integration", "error", {"integration": "OBS", "message": "Check OBS connection and input name."})
            finally:
                self.pending.task_done()
