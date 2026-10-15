from __future__ import annotations

from collections.abc import Callable
from collections import deque
from datetime import datetime, timezone
from copy import deepcopy
import logging
from threading import RLock, Event


EventCallback = Callable[[str, str, dict], None]


class ActionReceipt(Event):
    def __init__(self):
        super().__init__()
        self.dispatched = False


class EventBus:
    def __init__(self):
        self._callbacks: list[EventCallback] = []
        self._lock = RLock()
        self._timeline = deque(maxlen=300)
        self._action_barriers: dict[str, ActionReceipt] = {}

    def expect_action(self, speech_id: str) -> ActionReceipt:
        with self._lock:
            signal = ActionReceipt()
            self._action_barriers[speech_id] = signal
            return signal

    def acknowledge_action(self, speech_id: str, dispatched: bool = False) -> None:
        with self._lock:
            signal = self._action_barriers.pop(speech_id, None)
        if signal is not None:
            signal.dispatched = dispatched
            signal.set()

    def recent(self) -> list[dict]:
        with self._lock:
            return deepcopy(list(self._timeline))

    def subscribe(self, callback: EventCallback) -> None:
        with self._lock:
            self._callbacks.append(callback)

    def emit(self, source: str, event_type: str, data: dict) -> None:
        with self._lock:
            callbacks = list(self._callbacks)
            self._timeline.appendleft({
                "time": datetime.now(timezone.utc).isoformat(),
                "source": source, "event": event_type, "data": deepcopy(data),
            })
        for callback in callbacks:
            try:
                callback(source, event_type, deepcopy(data))
            except Exception:
                # One disconnected integration must never kill the speech worker.
                logging.exception("Event subscriber failed for %s.%s", source, event_type)
