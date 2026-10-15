from __future__ import annotations

import logging
import json
import random
import re
import shutil
import io
import math
import struct
import wave
from xml.etree import ElementTree
from datetime import datetime
from pathlib import Path
from queue import Empty, Queue
from threading import Event, Lock, RLock, Thread, BoundedSemaphore
from time import monotonic

from .audio import AudioPlayer
from .events import EventBus
from .models import SpeechJob, VoiceAlias
from .settings import Settings
from .polly import PollyClient
from .voicestudio import VoiceStudioClient
from .providers import registry


class SpeechEngine:
    AUDIO_CACHE_LIMIT = 30

    def __init__(self, settings: Settings, events: EventBus):
        self.settings = settings
        self.events = events
        self.audio = AudioPlayer(settings.output_device)
        self.pending: Queue[SpeechJob | None] = Queue()
        self._stop = Event()
        self._paused = Event()
        self._enabled = True
        self._current: SpeechJob | None = None
        self._lock = RLock()
        self._admission_lock = RLock()
        self._pause_after_current = False
        self._recent_requests: dict[tuple, float] = {}
        self._generation_slots = BoundedSemaphore(2)
        self._history_lock = Lock()
        self._last_global_request = 0.0
        self._last_user_request: dict[str, float] = {}
        self.history_path = settings.path.parent / "history.json"
        self.history: list[dict] = self._load_history()
        self._trim_audio_cache()
        self.thread = Thread(target=self._run, name="Speech queue", daemon=True)
        self.queue_path = settings.path.parent / "queue.json"
        if settings.persist_queue:
            self._restore_queue()

    def _save_queue(self) -> None:
        if not self.settings.persist_queue:
            try:
                self.queue_path.unlink(missing_ok=True)
            except OSError:
                logging.exception("Could not remove the inactive recovery file")
            return
        try:
            with self._lock, self.pending.mutex:
                jobs = ([self._current] if self._current else []) + list(self.pending.queue)
                values = [{"text": job.text, "alias": job.alias.to_dict(), "name": job.alias.name,
                           "source": job.source, "user": job.user, "priority": job.priority,
                           "timestamp": job.timestamp}
                          for job in jobs if job and not job.cancelled and job.status not in {"Finished", "Error", "Cancelled", "Skipped", "Removed"}]
            temporary = self.queue_path.with_suffix(".tmp")
            temporary.parent.mkdir(parents=True, exist_ok=True)
            temporary.write_text(json.dumps(values, indent=2), encoding="utf-8")
            temporary.replace(self.queue_path)
        except OSError:
            logging.exception("Could not save the pending speech queue")

    def _restore_queue(self) -> None:
        try:
            values = json.loads(self.queue_path.read_text(encoding="utf-8"))
            restored = []
            for value in values[:self.settings.max_queue]:
                job = SpeechJob(value["text"], VoiceAlias.from_dict(value["name"], value["alias"]),
                    source=value.get("source", "Restored"), user=value.get("user", ""),
                    priority=int(value.get("priority", 0)), timestamp=value["timestamp"])
                age = max(0, (datetime.now().astimezone() - datetime.fromisoformat(job.timestamp.replace("Z", "+00:00"))).total_seconds())
                job.enqueued_at = monotonic() - age
                if not self.settings.max_message_age or age < self.settings.max_message_age:
                    restored.append(job)
            if restored:
                self._paused.set()
                for job in restored:
                    self.pending.put(job)
        except FileNotFoundError:
            pass
        except (OSError, ValueError, TypeError, KeyError):
            logging.exception("Could not restore speech queue")

    def _cache_file_path(self, job: SpeechJob) -> Path:
        cache_folder = self.settings.path.parent / "audio_cache"
        cache_folder.mkdir(parents=True, exist_ok=True)
        alias = re.sub(r"[^A-Za-z0-9._-]+", "_", job.alias.name).strip("._") or "Voice"
        try:
            created = datetime.fromisoformat(job.timestamp.replace("Z", "+00:00")).astimezone()
        except ValueError:
            created = datetime.now().astimezone()
        stamp = created.strftime("%Y-%m-%d_%H-%M-%S-%f")[:-3]
        candidate = cache_folder / f"{alias}_{stamp}.wav"
        suffix = 2
        while candidate.exists():
            candidate = cache_folder / f"{alias}_{stamp}-{suffix}.wav"
            suffix += 1
        return candidate

    def _trim_audio_cache(self) -> None:
        cache_folder = self.settings.path.parent / "audio_cache"
        if not cache_folder.is_dir():
            return
        try:
            files = sorted(
                cache_folder.glob("*.wav"),
                key=lambda path: (path.stat().st_mtime_ns, path.name.casefold()),
            )
            for path in files[:-self.AUDIO_CACHE_LIMIT]:
                path.unlink(missing_ok=True)
        except OSError:
            logging.exception("Could not trim generated audio cache")

    def start(self) -> None:
        if not self.thread.is_alive():
            with self.pending.mutex:
                restored_jobs = list(self.pending.queue)
            for job in restored_jobs:
                if job and not job.registered:
                    self.events.emit("texttospeech", "received", self._event_data(job))
                    job.registered = True
            self.thread.start()

    def shutdown(self) -> None:
        if self._stop.is_set():
            return
        with self._admission_lock:
            self._save_queue()
            self._stop.set()
            with self._lock, self.pending.mutex:
                if self._current:
                    self._current.cancelled = True
                    self._current.cancel_event.set()
                abandoned = [job for job in self.pending.queue if job and not job.cancelled]
                for job in abandoned:
                    job.cancelled = True
                    job.cancel_event.set()
            for job in abandoned:
                self.events.emit("texttospeech", "cancelled", self._event_data(job))
        self.audio.stop()
        self.pending.put(None)
        if self.thread.is_alive():
            self.thread.join(timeout=5)

    def enqueue(self, text: str, alias: VoiceAlias, source: str = "Manual", user: str = "", priority: int = 0) -> SpeechJob:
        # All transport threads share one admission boundary for limits/cooldowns.
        with self._admission_lock:
            return self._enqueue(text, alias, source, user, priority)

    def _enqueue(self, text: str, alias: VoiceAlias, source: str, user: str, priority: int) -> SpeechJob:
        if self._stop.is_set():
            raise ValueError("VoxRelay is shutting down")
        if not self._enabled:
            raise ValueError("TTS is disabled")
        self.settings.reload_if_changed()
        text = self._prepare_ssml(text, user, alias) if alias.ssml else self._prepare_text(text, user)
        if not text:
            raise ValueError("Message is empty")
        if len(text) > self.settings.max_characters:
            raise ValueError(f"Message exceeds the {self.settings.max_characters}-character limit")
        if self.pending.qsize() >= self.settings.max_queue:
            raise ValueError(f"Speech queue is full ({self.settings.max_queue} items)")
        now = monotonic()
        self._recent_requests = {key: stamp for key, stamp in self._recent_requests.items()
                                 if now - stamp < self.settings.duplicate_window}
        duplicate_key = (user.casefold(), alias.name, text.casefold())
        if self.settings.duplicate_window and duplicate_key in self._recent_requests:
            raise ValueError("This message is already in the recent speech queue")
        if user and self.settings.per_user_queue_limit:
            with self._lock, self.pending.mutex:
                jobs = list(self.pending.queue) + ([self._current] if self._current else [])
                count = sum(job is not None and not job.cancelled and job.user.casefold() == user.casefold()
                            for job in jobs)
            if count >= self.settings.per_user_queue_limit:
                raise ValueError(f"{user} has reached their queue limit")
        if self.settings.global_cooldown and now - self._last_global_request < self.settings.global_cooldown:
            raise ValueError("The global speech cooldown is still active")
        user_key = user.casefold().strip()
        if user_key and self.settings.per_user_cooldown:
            last = self._last_user_request.get(user_key, 0.0)
            if now - last < self.settings.per_user_cooldown:
                raise ValueError(f"{user} is still on speech cooldown")
            self._last_user_request[user_key] = now
        self._last_global_request = now
        self._recent_requests[duplicate_key] = now
        job = SpeechJob(text=text, alias=alias, source=source or "Manual", user=user,
                        priority=max(-100, min(100, int(priority))))
        with self._lock:
            queue_is_active = (self._current is not None and self._current.status not in {"Finished", "Error", "Cancelled", "Skipped"}) or self.pending.qsize() > 0
            # Register the first job too, before a fast worker can finish it.
            self.events.emit("texttospeech", "received", self._event_data(job))
            job.registered = True
            self.pending.put(job)
            with self.pending.mutex:
                items = sorted(self.pending.queue, key=lambda item: -item.priority if item else -101)
                self.pending.queue.clear()
                self.pending.queue.extend(items)
        # The first item announces itself only after synthesis completes. Items
        # joining that session still publish their immediate queue pulse.
            if queue_is_active:
                self.events.emit("texttospeech", "queueadded", self._event_data(job))
            self._save_queue()
        return job

    def _prepare_ssml(self, text: str, user: str, alias: VoiceAlias) -> str:
        provider = registry.providers.get(alias.provider)
        if provider is None or "ssml" not in provider.capabilities:
            raise ValueError("This engine does not support SSML. Turn off Advanced SSML or choose another voice.")
        if "<!" in text or len(text) > 100000:
            raise ValueError("SSML declarations and oversized documents are not supported")
        try:
            root = ElementTree.fromstring(text)
        except ElementTree.ParseError as exc:
            raise ValueError("SSML must be valid XML inside a <speak> element") from exc
        if root.tag.rsplit("}", 1)[-1] != "speak":
            raise ValueError("SSML must start with a <speak> element")
        nodes = list(root.iter())
        allowed = {"speak", "p", "s", "break", "prosody", "emphasis", "say-as", "sub", "phoneme", "lang", "mark", "voice"}
        if len(nodes) > 1000 or any(node.tag.rsplit("}", 1)[-1] not in allowed for node in nodes):
            raise ValueError("SSML contains an unsupported element")
        plain = "".join(root.itertext())
        # Validate the combined text too, so markup cannot split a blocked word.
        self._prepare_text(plain, user)
        for node in nodes:
            for attribute in ("text", "tail"):
                value = getattr(node, attribute)
                if value and value.strip():
                    prepared = self._prepare_text(value, user)
                    leading = re.match(r"\s*", value).group()
                    trailing = re.search(r"\s*$", value).group()
                    setattr(node, attribute, leading + prepared + trailing)
        return ElementTree.tostring(root, encoding="unicode")


    @staticmethod
    def _normalize_viewer(user: str) -> str:
        text = str(user or "").strip()
        if not text:
            return ""
        if text.startswith("%") and text.endswith("%"):
            return ""
        if text.startswith("{") and ('"login"' in text or '"badges"' in text):
            try:
                import json
                parsed = json.loads(text)
            except Exception:
                return ""
            if isinstance(parsed, dict):
                return str(
                    parsed.get("login")
                    or parsed.get("name")
                    or parsed.get("displayName")
                    or ""
                ).strip()
            return ""
        return text

    def _prepare_text(self, text: str, user: str) -> str:
        text = text.strip()
        if self.settings.ignore_command_messages:
            text = re.sub(r"(?<!\S)!\S+", "", text)
        if self.settings.ignore_mention_messages:
            text = re.sub(r"(?<!\S)@\S+", "", text)
        visible = [char for char in text if not char.isspace()]
        if self.settings.block_ascii_art and len(visible) >= 8:
            symbol_count = sum(not char.isalnum() for char in visible)
            if symbol_count / len(visible) >= 0.45:
                raise ValueError("Message looks like ASCII art")
        if self.settings.strip_non_ascii:
            text = "".join(
                char for char in text
                if ord(char) < 128 or char.isalnum() or char.isspace() or self._is_emoji(char)
            )
        if self.settings.strip_emojis:
            text = "".join(char for char in text if not self._is_emoji(char) and ord(char) not in {0x200D, 0xFE0F})
        text = re.sub(r"\s+", " ", text).strip()
        user = self._normalize_viewer(user)
        user_key = user.casefold().strip()
        blocked_users = {value.casefold() for value in self.settings.user_blocklist}
        allowed_users = {value.casefold() for value in self.settings.user_allowlist}
        if user_key in blocked_users:
            raise ValueError(f"{user} is blocked from speech")
        if allowed_users and user_key and user_key not in allowed_users:
            raise ValueError(f"{user} is not on the speech allowlist")
        if self.settings.block_links and re.search(r"https?://|www\.", text, re.IGNORECASE):
            raise ValueError("Links are not allowed in speech")
        if self.settings.strip_links:
            text = re.sub(r"(?:https?://|www\.)\S+", "", text, flags=re.IGNORECASE)
            text = re.sub(r"\s+", " ", text).strip()
        lowered = text.casefold()
        for phrase in self.settings.blocked_words:
            if phrase.strip() and re.search(self._replacement_pattern(phrase), text, re.IGNORECASE):
                raise ValueError("Message contains a blocked word or phrase")
        if self.settings.block_excess_caps:
            letters = [char for char in text if char.isalpha()]
            if len(letters) >= 12 and sum(char.isupper() for char in letters) / len(letters) > 0.8:
                raise ValueError("Message contains excessive capital letters")
        if self.settings.collapse_repeated_characters:
            text = re.sub(r"(.)\1{4,}", r"\1\1\1", text, flags=re.IGNORECASE)
        for old, new in self.settings.replacements.items():
            if old:
                text = re.sub(self._replacement_pattern(old), lambda _match, replacement=new: replacement, text, flags=re.IGNORECASE)
        for old, alternatives_text in self.settings.pronunciations.items():
            if old:
                alternatives = [value.strip() for value in alternatives_text.split(",") if value.strip()]
                if alternatives:
                    text = re.sub(
                        self._replacement_pattern(old),
                        lambda _match, choices=alternatives: random.choice(choices),
                        text,
                        flags=re.IGNORECASE,
                    )
        return text

    @staticmethod
    def _replacement_pattern(value: str) -> str:
        """Match a configured term without replacing it inside a larger word."""
        pattern = re.escape(value)
        if value and (value[0].isalnum() or value[0] == "_"):
            pattern = r"(?<!\w)" + pattern
        if value and (value[-1].isalnum() or value[-1] == "_"):
            pattern += r"(?!\w)"
        return pattern

    @staticmethod
    def _is_emoji(char: str) -> bool:
        code = ord(char)
        return (
            0x1F000 <= code <= 0x1FAFF
            or 0x2600 <= code <= 0x27BF
            or 0x2300 <= code <= 0x23FF
            or code in {0x00A9, 0x00AE, 0x203C, 0x2049, 0x2122, 0x2139}
        )

    def _load_history(self) -> list[dict]:
        try:
            value = json.loads(self.history_path.read_text(encoding="utf-8"))
            return value if isinstance(value, list) else []
        except (OSError, ValueError, TypeError):
            return []

    def _record_history(self, job: SpeechJob) -> None:
        entry = self._job_dict(job)
        with self._history_lock:
            self.history.insert(0, entry)
            removed = self.history[max(1, self.settings.history_limit):]
            del self.history[max(1, self.settings.history_limit):]
            for old in removed:
                try:
                    old_path = Path(str(old.get("audioPath", "")))
                    if old_path.parent == self.settings.path.parent / "audio_cache":
                        old_path.unlink(missing_ok=True)
                except OSError:
                    logging.exception("Could not remove expired cached audio")
            try:
                self.history_path.parent.mkdir(parents=True, exist_ok=True)
                temp = self.history_path.with_suffix(".tmp")
                temp.write_text(json.dumps(self.history, indent=2), encoding="utf-8")
                temp.replace(self.history_path)
            except OSError:
                logging.exception("Could not save speech history")

    @staticmethod
    def _job_dict(job: SpeechJob) -> dict:
        return {"id": job.speech_id, "timestamp": job.timestamp, "text": job.text,
                "alias": job.alias.name, "voice": job.alias.voice_id, "source": job.source,
                "user": job.user, "status": job.status, "duration": job.duration_ms,
                "error": job.error, "audioPath": job.audio_path, "priority": job.priority,
                "provider": job.alias.provider}

    def replay_history(self, speech_id: str) -> SpeechJob:
        with self._history_lock:
            entry = next((item for item in self.history if item.get("id") == speech_id), None)
        if not entry:
            raise ValueError("History item was not found")
        path = Path(str(entry.get("audioPath", "")))
        if not path.is_file() or path.resolve().parent != (self.settings.path.parent / "audio_cache").resolve():
            raise ValueError("This recording has expired from the audio cache. Speak the message again in Playground.")
        alias = self.settings.get_alias(str(entry.get("alias", "")))
        if alias is None:
            alias = VoiceAlias(str(entry.get("alias", "Voice")), provider=str(entry.get("provider", "voicestudio")))
        with self._admission_lock:
            job = self.enqueue(str(entry.get("text", "")), alias, source="History recording")
            job.text = str(entry.get("text", ""))
            job.audio_path = str(path)
        return job

    def test_output(self, device: str, preview: bool = False) -> SpeechJob:
        output = io.BytesIO()
        with wave.open(output, "wb") as wav:
            wav.setparams((1, 2, 44100, 0, "NONE", "not compressed"))
            wav.writeframes(b"".join(struct.pack("<h", int(7000 * math.sin(2 * math.pi * 440 * index / 44100)
                * min(1, index / 500, (22050-index) / 500))) for index in range(22050)))
        with self._admission_lock:
            job = self.enqueue("Audio output test", VoiceAlias("Output test", output_device=device or "[Default]"),
                               source="Output preview" if preview else "Output test")
            job.audio_bytes = output.getvalue()
        return job

    def save_history_audio(self, speech_id: str) -> str:
        self.settings.reload_if_changed()
        target_folder = self.settings.voice_save_folder.strip()
        if not target_folder:
            raise ValueError("Choose a voice save folder in Settings first")
        with self._history_lock:
            entry = next((item for item in self.history if item.get("id") == speech_id), None)
        if entry is None:
            raise ValueError("History item was not found")
        source_text = str(entry.get("audioPath", ""))
        source = Path(source_text) if source_text else None
        if source is None or not source.is_file():
            raise ValueError("Recorded audio is not available for this history item")
        folder = Path(target_folder).expanduser()
        folder.mkdir(parents=True, exist_ok=True)
        alias = re.sub(r"[^A-Za-z0-9._-]+", "_", str(entry.get("alias", "voice"))).strip("._") or "voice"
        stamp = re.sub(r"[^0-9]", "", str(entry.get("timestamp", "")))[:14]
        destination = folder / f"{stamp or 'voice'}_{alias}_{speech_id[:8]}.wav"
        shutil.copy2(source, destination)
        return str(destination)

    def state(self) -> dict:
        if self.settings.reload_if_changed():
            with self._admission_lock:
                self._save_queue()
        with self._lock, self.pending.mutex:
            current = self._job_dict(self._current) if self._current else None
            queued = [self._job_dict(job) for job in self.pending.queue if job is not None and not job.cancelled]
        estimate = sum(item.get("duration", 0)/1000 or len(item["text"])/14 for item in queued)
        if current:
            estimate += self.audio.remaining_seconds if current["status"] == "Playing" else (current["duration"]/1000 or len(current["text"])/14)
        return {"enabled": self._enabled, "paused": self._paused.is_set(), "current": current,
                "queue": queued, "queueLength": len(queued), "audioWarning": self.audio.warning,
                "pauseAfterCurrent": self._pause_after_current,
                "estimatedWaitSeconds": round(estimate, 1)}

    def history_items(self) -> list[dict]:
        with self._history_lock:
            return list(self.history)

    def clear_history(self) -> None:
        with self._history_lock:
            for item in self.history:
                try:
                    audio_path = Path(str(item.get("audioPath", "")))
                    if audio_path.parent == self.settings.path.parent / "audio_cache":
                        audio_path.unlink(missing_ok=True)
                except OSError:
                    logging.exception("Could not remove cached history audio")
            self.history.clear()
            try:
                self.history_path.unlink(missing_ok=True)
            except OSError:
                logging.exception("Could not clear speech history")

    def remove(self, speech_id: str) -> bool:
        removed = None
        with self.pending.mutex:
            for job in list(self.pending.queue):
                if job is not None and job.speech_id == speech_id:
                    self.pending.queue.remove(job)
                    self.pending.unfinished_tasks -= 1
                    if self.pending.unfinished_tasks == 0:
                        self.pending.all_tasks_done.notify_all()
                    job.cancelled = True
                    job.cancel_event.set()
                    job.status = "Removed"
                    removed = job
                    break
        if removed:
            self._record_history(removed)
            self.events.emit("texttospeech", "cancelled", self._event_data(removed))
            with self._admission_lock:
                self._save_queue()
        return removed is not None

    def move(self, speech_id: str, direction: int) -> bool:
        with self.pending.mutex:
            queue = self.pending.queue
            items = list(queue)
            index = next((i for i, job in enumerate(items) if job is not None and job.speech_id == speech_id), -1)
            target = index + direction
            if index < 0 or target < 0 or target >= len(items):
                return False
            items[index], items[target] = items[target], items[index]
            queue.clear()
            queue.extend(items)
            return True

    def _event_data(self, job: SpeechJob) -> dict:
        return {
            "id": job.speech_id,
            "timestamp": job.timestamp,
            "text": job.text,
            "duration": job.duration_ms,
            "engineName": registry.providers[job.alias.provider].name if job.alias.provider in registry.providers else job.alias.provider,
            "voiceName": job.alias.voice_id,
            "alias": job.alias.name,
            "source": job.source,
            "user": job.user,
            "pitch": 0.0,
            "volume": job.alias.volume,
            "rate": job.alias.speed,
        }

    def move_before(self, speech_id: str, before_id: str) -> bool:
        with self._admission_lock, self.pending.mutex:
            items = list(self.pending.queue)
            job = next((item for item in items if item and item.speech_id == speech_id), None)
            target = next((item for item in items if item and item.speech_id == before_id), None)
            if job is None or target is None or job is target:
                return False
            items.remove(job)
            items.insert(items.index(target), job)
            self.pending.queue.clear()
            self.pending.queue.extend(items)
        with self._admission_lock:
            self._save_queue()
        return True

    def pause(self) -> None:
        self._paused.set()
        self.audio.pause()

    def pause_after_current(self) -> None:
        self._pause_after_current = True
        if self._current is None:
            self._paused.set()

    def resume(self) -> None:
        self._pause_after_current = False
        self._paused.clear()
        self.audio.resume()

    def enable(self) -> None:
        self._enabled = True

    def disable(self) -> None:
        self._enabled = False

    def stop_current(self) -> None:
        with self._lock:
            if self._current:
                self._current.cancelled = True
                self._current.cancel_event.set()
                self._current.status = "Skipped"
        self.audio.stop()

    def clear(self) -> None:
        with self._admission_lock:
            self._clear()
            self._save_queue()

    def clear_all(self) -> None:
        with self._admission_lock:
            self._clear()
            self.stop_current()
            self._save_queue()

    def _clear(self) -> None:
        removed: list[SpeechJob] = []
        while True:
            try:
                job = self.pending.get_nowait()
                if job is not None:
                    job.cancelled = True
                    job.cancel_event.set()
                    job.status = "Removed"
                    removed.append(job)
                self.pending.task_done()
            except Empty:
                break
        # Cleared jobs never reach the worker, so publish their terminal
        # events here and let lifecycle integrations close the queue session.
        for job in removed:
            self._record_history(job)
            self.events.emit("texttospeech", "cancelled", self._event_data(job))

    def _wait_ready(self, job: SpeechJob, delay: float = 0) -> bool:
        remaining = delay
        while not self._stop.is_set() and not job.cancelled:
            if self._paused.is_set():
                if job.cancel_event.wait(0.025):
                    return False
                continue
            if remaining <= 0:
                return True
            start = monotonic()
            if job.cancel_event.wait(min(remaining, 0.025)):
                return False
            remaining -= monotonic() - start
        return False

    def _client(self) -> VoiceStudioClient:
        return VoiceStudioClient(
            self.settings.voice_studio_url,
            self.settings.api_key,
            self.settings.request_timeout,
        )

    def _synthesize(self, job: SpeechJob) -> bytes:
        return registry.client(job.alias.provider, self.settings).synthesize_wav(job.text, job.alias)

    def _generate(self, job: SpeechJob) -> bytes | None:
        # Requests may not support cancellation. Let a cancelled request finish
        # in the background, while bounding orphaned requests to two at a time.
        while not self._generation_slots.acquire(timeout=0.025):
            if job.cancelled or self._stop.is_set():
                return None
        result: Queue = Queue(maxsize=1)
        def generate():
            try:
                result.put((self._synthesize(job), None))
            except Exception as exc:
                result.put((None, exc))
            finally:
                self._generation_slots.release()
        Thread(target=generate, name="Audio generation", daemon=True).start()
        while not job.cancelled and not self._stop.is_set():
            try:
                wav, error = result.get(timeout=0.025)
            except Empty:
                continue
            if error:
                raise error
            return wav
        return None

    def _run(self) -> None:
        while not self._stop.is_set():
            with self._admission_lock, self._lock:
                try:
                    job = self.pending.get_nowait()
                except Empty:
                    job = None
                    empty = True
                else:
                    empty = False
                if job is not None:
                    self._current = job
            if empty:
                self._stop.wait(0.025)
                continue
            if job is None:
                self.pending.task_done()
                break
            try:
                if not self._wait_ready(job):
                    job.status = "Cancelled"
                    continue
                if self.settings.max_message_age and monotonic() - job.enqueued_at > self.settings.max_message_age:
                    job.status = "Cancelled"
                    job.error = "Message expired before playback"
                    continue
                job.status = "Generating"
                if job.audio_bytes is not None:
                    wav = job.audio_bytes
                elif job.source == "History recording" and job.audio_path:
                    wav = Path(job.audio_path).read_bytes()
                else:
                    self.events.emit("texttospeech", "generating", self._event_data(job))
                    wav = self._generate(job)
                if wav is None:
                    job.status = "Cancelled"
                    continue
                try:
                    cache_path = self._cache_file_path(job)
                    cache_path.write_bytes(wav)
                    job.audio_path = str(cache_path)
                    self._trim_audio_cache()
                except OSError:
                    logging.exception("Could not cache generated voice audio")
                if job.cancelled:
                    job.status = "Cancelled"
                    continue
                preview = "preview" in job.source.casefold()
                volume = job.alias.volume * (self.settings.preview_volume if preview else self.settings.stream_volume)
                job.pcm, job.duration_ms = self.audio.decode_wav(wav, volume,
                    normalize=self.settings.normalize_audio, fade=self.settings.fade_audio)
                self.events.emit("texttospeech", "engineprocessed", self._event_data(job))
                # "Queued" now means the audio is ready. This gives external
                # actions time to prepare an avatar/scene before playback.
                barrier = None
                if self.settings.streamerbot_actions_enabled and self.settings.streamerbot_queued_action.strip():
                    barrier = self.events.expect_action(job.speech_id)
                self.events.emit("texttospeech", "textqueued", self._event_data(job))
                if barrier is not None:
                    job.status = "Waiting for action"
                    deadline = monotonic() + 10
                    while not barrier.is_set() and monotonic() < deadline:
                        if not self._wait_ready(job, 0.025):
                            break
                    self.events.acknowledge_action(job.speech_id)
                playback_delay = 0.0
                if barrier is not None and barrier.dispatched:
                    playback_delay = max(0.0, min(10.0, float(self.settings.streamerbot_playback_delay)))
                job.status = "Waiting" if playback_delay else "Ready"
                if not self._wait_ready(job, playback_delay):
                    job.status = "Cancelled"
                    continue
                if job.cancelled:
                    job.status = "Cancelled"
                    continue
                self.events.emit("texttospeech", "playing", self._event_data(job))
                job.status = "Playing"
                # Only explicit preview sources use the preview device.
                # Matching bare "test" incorrectly sent pronunciation / voice
                # checks to headphones while stream speech used another device.
                source_key = job.source.casefold()
                if "preview" in source_key:
                    preview_device = self.settings.preview_output_device
                    chosen = job.alias.output_device or preview_device or self.settings.output_device
                    self.audio.output_device = "" if chosen == "[Default]" else chosen
                else:
                    chosen = job.alias.output_device or self.settings.output_device
                    self.audio.output_device = "" if chosen == "[Default]" else chosen
                played = self.audio.play(job.pcm, cancel_event=job.cancel_event)
                if played and not job.cancelled:
                    job.status = "Finished"
                    self.events.emit("texttospeech", "finished", self._event_data(job))
                elif job.cancelled:
                    job.status = "Cancelled"
                else:
                    raise RuntimeError("Audio output failed. Check the selected output device in Settings.")
            except Exception as exc:
                logging.exception("Speech job failed")
                data = self._event_data(job)
                data["error"] = str(exc)
                job.status = "Error"
                job.error = str(exc)
                self.events.emit("texttospeech", "error", data)
            finally:
                self.events.acknowledge_action(job.speech_id)
                if job.status in {"Cancelled", "Skipped"}:
                    self.events.emit("texttospeech", "cancelled", self._event_data(job))
                self._record_history(job)
                with self._lock:
                    self._current = None
                    if self._pause_after_current:
                        self._paused.set()
                        self._pause_after_current = False
                if not self._stop.is_set():
                    with self._admission_lock:
                        self._save_queue()
                self.pending.task_done()
