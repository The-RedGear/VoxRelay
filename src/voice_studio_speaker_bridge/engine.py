from __future__ import annotations

import logging
import json
import random
import re
import shutil
from datetime import datetime
from pathlib import Path
from queue import Empty, Queue
from threading import Event, Lock, Thread
from time import monotonic

from .audio import AudioPlayer
from .events import EventBus
from .models import SpeechJob, VoiceAlias
from .settings import Settings
from .polly import PollyClient
from .voicestudio import VoiceStudioClient


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
        self._lock = Lock()
        self._history_lock = Lock()
        self._last_global_request = 0.0
        self._last_user_request: dict[str, float] = {}
        self.history_path = settings.path.parent / "history.json"
        self.history: list[dict] = self._load_history()
        self._trim_audio_cache()
        self.thread = Thread(target=self._run, name="Speech queue", daemon=True)

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
            self.thread.start()

    def shutdown(self) -> None:
        self._stop.set()
        self.audio.stop()
        self.pending.put(None)
        if self.thread.is_alive():
            self.thread.join(timeout=5)

    def enqueue(self, text: str, alias: VoiceAlias, source: str = "Manual", user: str = "") -> SpeechJob:
        if not self._enabled:
            raise ValueError("TTS is disabled")
        self.settings.reload_if_changed()
        text = self._prepare_text(text, user)
        if not text:
            raise ValueError("Message is empty")
        if len(text) > self.settings.max_characters:
            raise ValueError(f"Message exceeds the {self.settings.max_characters}-character limit")
        if self.pending.qsize() >= self.settings.max_queue:
            raise ValueError(f"Speech queue is full ({self.settings.max_queue} items)")
        now = monotonic()
        if self.settings.global_cooldown and now - self._last_global_request < self.settings.global_cooldown:
            raise ValueError("The global speech cooldown is still active")
        user_key = user.casefold().strip()
        if user_key and self.settings.per_user_cooldown:
            last = self._last_user_request.get(user_key, 0.0)
            if now - last < self.settings.per_user_cooldown:
                raise ValueError(f"{user} is still on speech cooldown")
            self._last_user_request[user_key] = now
        self._last_global_request = now
        job = SpeechJob(text=text, alias=alias, source=source or "Manual", user=user)
        with self._lock:
            queue_is_active = self._current is not None or self.pending.qsize() > 0
        self.pending.put(job)
        # The first item announces itself only after synthesis completes. Items
        # joining that session still publish their immediate queue pulse.
        if queue_is_active:
            self.events.emit("texttospeech", "queueadded", self._event_data(job))
        return job

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
            if phrase.strip() and phrase.casefold() in lowered:
                raise ValueError("Message contains a blocked word or phrase")
        if self.settings.block_excess_caps:
            letters = [char for char in text if char.isalpha()]
            if len(letters) >= 12 and sum(char.isupper() for char in letters) / len(letters) > 0.8:
                raise ValueError("Message contains excessive capital letters")
        if self.settings.collapse_repeated_characters:
            text = re.sub(r"(.)\1{4,}", r"\1\1\1", text, flags=re.IGNORECASE)
        for old, new in self.settings.replacements.items():
            if old:
                text = re.sub(self._replacement_pattern(old), new, text, flags=re.IGNORECASE)
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
                "error": job.error, "audioPath": job.audio_path}

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
        with self._lock:
            current = self._job_dict(self._current) if self._current else None
        with self.pending.mutex:
            queued = [self._job_dict(job) for job in self.pending.queue if job is not None and not job.cancelled]
        return {"enabled": self._enabled, "paused": self._paused.is_set(), "current": current,
                "queue": queued, "queueLength": len(queued)}

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
        with self.pending.mutex:
            for job in self.pending.queue:
                if job is not None and job.speech_id == speech_id:
                    job.cancelled = True
                    job.status = "Removed"
                    return True
        return False

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
            "engineName": "Amazon Polly" if job.alias.provider == "polly" else "VoiceStudio",
            "voiceName": job.alias.voice_id,
            "alias": job.alias.name,
            "source": job.source,
            "user": job.user,
            "pitch": 0.0,
            "volume": job.alias.volume,
            "rate": job.alias.speed,
        }

    def pause(self) -> None:
        self._paused.set()

    def resume(self) -> None:
        self._paused.clear()

    def enable(self) -> None:
        self._enabled = True

    def disable(self) -> None:
        self._enabled = False

    def stop_current(self) -> None:
        with self._lock:
            if self._current:
                self._current.cancelled = True
                self._current.status = "Skipped"
        self.audio.stop()

    def clear(self) -> None:
        removed: list[SpeechJob] = []
        while True:
            try:
                job = self.pending.get_nowait()
                if job is not None:
                    job.cancelled = True
                    job.status = "Removed"
                    removed.append(job)
                self.pending.task_done()
            except Empty:
                break
        # Cleared jobs never reach the worker, so publish their terminal
        # events here and let lifecycle integrations close the queue session.
        for job in removed:
            self.events.emit("texttospeech", "cancelled", self._event_data(job))

    def _client(self) -> VoiceStudioClient:
        return VoiceStudioClient(
            self.settings.voice_studio_url,
            self.settings.api_key,
            self.settings.request_timeout,
        )

    def _synthesize(self, job: SpeechJob) -> bytes:
        if job.alias.provider == "polly":
            if not self.settings.polly_enabled:
                raise ValueError("Amazon Polly is disabled in Settings")
            return PollyClient(
                region=self.settings.polly_region,
                profile=self.settings.polly_profile,
                access_key_encrypted=self.settings.polly_access_key_encrypted,
                secret_key_encrypted=self.settings.polly_secret_key_encrypted,
            ).synthesize_wav(job.text, job.alias)
        return self._client().synthesize_wav(job.text, job.alias)

    def _run(self) -> None:
        while not self._stop.is_set():
            job = self.pending.get()
            if job is None:
                self.pending.task_done()
                break
            with self._lock:
                self._current = job
            try:
                while self._paused.is_set() and not self._stop.wait(0.1):
                    pass
                if self._stop.is_set() or job.cancelled:
                    job.status = "Cancelled"
                    continue
                job.status = "Generating"
                wav = self._synthesize(job)
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
                job.pcm, job.duration_ms = self.audio.decode_wav(wav, job.alias.volume)
                self.events.emit("texttospeech", "engineprocessed", self._event_data(job))
                # "Queued" now means the audio is ready. This gives external
                # actions time to prepare an avatar/scene before playback.
                self.events.emit("texttospeech", "textqueued", self._event_data(job))
                playback_delay = 0.0
                if self.settings.streamerbot_actions_enabled and self.settings.streamerbot_queued_action.strip():
                    playback_delay = max(0.0, min(10.0, float(self.settings.streamerbot_playback_delay)))
                if playback_delay > 0 and self._stop.wait(playback_delay):
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
                    self.audio.output_device = "" if preview_device == "[Default]" else (preview_device or self.settings.output_device)
                else:
                    self.audio.output_device = self.settings.output_device
                played = self.audio.play(job.pcm)
                if played and not job.cancelled:
                    job.status = "Finished"
                    self.events.emit("texttospeech", "finished", self._event_data(job))
                elif job.cancelled:
                    job.status = "Cancelled"
            except Exception as exc:
                logging.exception("Speech job failed")
                data = self._event_data(job)
                data["error"] = str(exc)
                job.status = "Error"
                job.error = str(exc)
                self.events.emit("texttospeech", "error", data)
            finally:
                if job.status in {"Cancelled", "Skipped"}:
                    self.events.emit("texttospeech", "cancelled", self._event_data(job))
                self._record_history(job)
                with self._lock:
                    self._current = None
                self.pending.task_done()
