from __future__ import annotations

import json
import logging
from queue import Empty, Queue
from threading import Event, RLock, Thread, Timer
from urllib.request import Request, urlopen

from .events import EventBus
from .settings import Settings


class StreamerBotActions:
    """Run optional Streamer.bot actions for TTS lifecycle events."""

    EVENT_SETTINGS = {
        "textqueued": ("queued", "streamerbot_queued_action"),
        "queueadded": ("queueAdded", "streamerbot_queue_added_action"),
        "playing": ("playing", "streamerbot_playing_action"),
        "finished": ("finished", "streamerbot_finished_action"),
        "cancelled": ("cancelled", "streamerbot_finished_action"),
        "error": ("error", "streamerbot_finished_action"),
    }

    def __init__(self, settings: Settings, events: EventBus):
        self.settings = settings
        self.pending: Queue[tuple[str, dict] | None] = Queue()
        self.stop_event = Event()
        self.state_lock = RLock()
        self.finish_timer: Timer | None = None
        self.active_speech_ids: set[str] = set()
        self.batch_is_playing = False
        self.batch_queued_announced = False
        self.thread = Thread(target=self._run, name="Streamer.bot actions", daemon=True)
        events.subscribe(self._on_event)

    def start(self) -> None:
        if not self.thread.is_alive():
            self.thread.start()

    def shutdown(self) -> None:
        self.stop_event.set()
        with self.state_lock:
            if self.finish_timer is not None:
                self.finish_timer.cancel()
                self.finish_timer = None
        self.pending.put(None)
        if self.thread.is_alive():
            self.thread.join(timeout=3)

    def _on_event(self, source: str, event_type: str, data: dict) -> None:
        if source.casefold() != "texttospeech":
            return
        mapped = self.EVENT_SETTINGS.get(event_type.casefold())
        if mapped is None:
            return
        self.settings.reload_if_changed()
        if not self.settings.streamerbot_actions_enabled:
            return
        state, setting_name = mapped
        speech_id = str(data.get("id", ""))
        if state == "queueAdded":
            with self.state_lock:
                if speech_id:
                    self.active_speech_ids.add(speech_id)
            self._cancel_finished_timer()
        elif state == "queued":
            with self.state_lock:
                if speech_id:
                    self.active_speech_ids.add(speech_id)
                if self.batch_queued_announced:
                    return
                self.batch_queued_announced = True
            self._cancel_finished_timer()
        elif state == "playing":
            self._cancel_finished_timer()
            with self.state_lock:
                if self.batch_is_playing:
                    return
                self.batch_is_playing = True
        elif state in {"finished", "cancelled", "error"}:
            with self.state_lock:
                if speech_id:
                    self.active_speech_ids.discard(speech_id)
                queue_is_idle = not self.active_speech_ids
                if queue_is_idle:
                    self.batch_is_playing = False
                    self.batch_queued_announced = False
            if not queue_is_idle:
                return
        action = str(getattr(self.settings, setting_name, "")).strip()
        if action:
            arguments = self._arguments(state, data)
            if state in {"finished", "cancelled", "error"}:
                self._schedule_finished(action, arguments)
            else:
                if state == "playing":
                    self._cancel_finished_timer()
                self.pending.put((action, arguments))

    def _schedule_finished(self, action: str, arguments: dict) -> None:
        delay = max(0.0, min(10.0, float(self.settings.streamerbot_finished_delay)))
        self._cancel_finished_timer()
        if delay <= 0:
            self.pending.put((action, arguments))
            return
        timer = Timer(delay, self._release_finished, args=(action, arguments))
        timer.daemon = True
        with self.state_lock:
            self.finish_timer = timer
        timer.start()

    def _release_finished(self, action: str, arguments: dict) -> None:
        with self.state_lock:
            self.finish_timer = None
        if not self.stop_event.is_set():
            self.pending.put((action, arguments))

    def _cancel_finished_timer(self) -> None:
        with self.state_lock:
            if self.finish_timer is not None:
                self.finish_timer.cancel()
                self.finish_timer = None

    @staticmethod
    def _arguments(state: str, data: dict) -> dict:
        return {
            "ttsState": state,
            "ttsId": str(data.get("id", "")),
            "ttsText": str(data.get("text", "")),
            "ttsAlias": str(data.get("alias", "")),
            "ttsVoice": str(data.get("voiceName", "")),
            "ttsSource": str(data.get("source", "")),
            "ttsUser": str(data.get("user", "")),
            "ttsDuration": float(data.get("duration", 0.0) or 0.0),
        }

    def _run(self) -> None:
        while not self.stop_event.is_set():
            try:
                item = self.pending.get(timeout=0.5)
            except Empty:
                continue
            if item is None:
                self.pending.task_done()
                break
            action, arguments = item
            try:
                self._post_action(action, arguments)
            except Exception:
                logging.exception("Could not run Streamer.bot lifecycle action %s", action)
            finally:
                self.pending.task_done()

    def _post_action(self, action: str, arguments: dict) -> None:
        identifier = "id" if self._looks_like_guid(action) else "name"
        body = json.dumps({"action": {identifier: action}, "args": arguments}).encode("utf-8")
        request = Request(
            self.settings.streamerbot_http_url.rstrip("/") + "/DoAction",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urlopen(request, timeout=3) as response:
            if response.status not in (200, 204):
                raise OSError(f"Streamer.bot returned HTTP {response.status}")

    @staticmethod
    def _looks_like_guid(value: str) -> bool:
        parts = value.split("-")
        return len(parts) == 5 and [len(part) for part in parts] == [8, 4, 4, 4, 12]
