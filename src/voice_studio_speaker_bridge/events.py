from __future__ import annotations

from collections.abc import Callable
from threading import RLock


EventCallback = Callable[[str, str, dict], None]


class EventBus:
    def __init__(self):
        self._callbacks: list[EventCallback] = []
        self._lock = RLock()

    def subscribe(self, callback: EventCallback) -> None:
        with self._lock:
            self._callbacks.append(callback)

    def emit(self, source: str, event_type: str, data: dict) -> None:
        with self._lock:
            callbacks = list(self._callbacks)
        for callback in callbacks:
            callback(source, event_type, data)
