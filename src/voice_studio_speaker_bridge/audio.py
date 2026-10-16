from __future__ import annotations

import logging
import math
from threading import Condition, RLock, Event
from time import monotonic

import miniaudio


SAMPLE_RATE = 44100


class AudioPlayer:
    def __init__(self, output_device: str = ""):
        self.output_device = output_device
        self.device: miniaudio.PlaybackDevice | None = None
        self.playing = False
        self._condition = Condition(RLock())
        self._device_lock = RLock()
        self._paused = Event()
        self.warning = ""
        self.remaining_seconds = 0.0
        self.elapsed_seconds = 0.0
        self._play_duration = 0.0
        self._play_origin = 0.0
        self._play_hold = 0.0
        self._clock_running = False
        self._submitted_seconds = 0.0
        self._seek_target = None
        self.seek_revision = 0

    @staticmethod
    def list_devices() -> list[str]:
        try:
            return sorted({item["name"] for item in miniaudio.Devices().get_playbacks()}, key=str.casefold)
        except miniaudio.MiniaudioError:
            logging.exception("Could not enumerate playback devices")
            return []

    def _device_id(self):
        self.warning = ""
        if not self.output_device:
            return None
        for item in miniaudio.Devices().get_playbacks():
            if item["name"] == self.output_device:
                return item["id"]
        logging.warning("Output device %s was not found; using default", self.output_device)
        self.warning = f"Output '{self.output_device}' is unavailable. Using the Windows default."
        return None

    def decode_wav(self, wav_bytes: bytes, volume: float = 1.0, *, normalize: bool = False, fade: bool = False) -> tuple[bytes, float]:
        decoded = miniaudio.decode(
            wav_bytes,
            output_format=miniaudio.SampleFormat.SIGNED16,
            nchannels=1,
            sample_rate=SAMPLE_RATE,
        )
        samples = decoded.samples
        factor = max(0.0, min(volume, 4.0))
        if normalize and samples:
            peak = max(abs(sample) for sample in samples)
            if peak:
                factor *= min(4.0, 26000 / peak)
        if abs(factor - 1.0) > 0.001:
            for index, sample in enumerate(samples):
                samples[index] = max(-32768, min(32767, int(sample * factor)))
        if fade:
            ramp = min(int(SAMPLE_RATE * 0.012), len(samples) // 2)
            for index in range(ramp):
                gain = index / ramp
                samples[index] = int(samples[index] * gain)
                samples[-1-index] = int(samples[-1-index] * gain)
        pcm = samples.tobytes()
        duration_ms = len(pcm) / 2 / SAMPLE_RATE * 1000.0
        return pcm, duration_ms

    @staticmethod
    def _stream_pcm(source: bytes, is_playing, is_paused=lambda: False, progress=lambda index: None, seek_position=lambda: None):
        required_frames = yield b""
        index = 0
        while is_playing():
            target = seek_position()
            if target is not None:
                index = max(0, min(len(source), int(target))) // 2 * 2
            required_bytes = required_frames * 2
            if is_paused():
                # Silence preserves the stream position and keeps the device alive.
                required_frames = yield bytes(required_bytes)
                continue
            data = source[index:index + required_bytes]
            if not data:
                break
            index += len(data)
            progress(index)
            required_frames = yield data


    def arm_progress(self, pcm: bytes | int) -> float:
        """Reset progress to the start of this PCM before status becomes Playing."""
        nbytes = len(pcm) if isinstance(pcm, (bytes, bytearray)) else int(pcm)
        total = max(0.0, nbytes / (2 * SAMPLE_RATE))
        with self._condition:
            self._play_duration = total
            self._play_origin = 0.0
            self._play_hold = 0.0
            self._clock_running = False
            self._submitted_seconds = 0.0
            self._seek_target = None
            self.elapsed_seconds = 0.0
            self.remaining_seconds = total
        return total

    def _sync_play_clock(self) -> None:
        """Elapsed/remaining from wall clock over known PCM duration."""
        total = float(self._play_duration or 0.0)
        if total <= 0:
            self.elapsed_seconds = 0.0
            self.remaining_seconds = 0.0
            return
        if self._clock_running and not self._paused.is_set():
            elapsed = self._play_hold + (monotonic() - self._play_origin)
        else:
            elapsed = self._play_hold
        elapsed = max(0.0, min(total, self._submitted_seconds, elapsed))
        self.elapsed_seconds = elapsed
        self.remaining_seconds = max(0.0, total - elapsed)

    def play(self, pcm: bytes, cancel_event: Event | None = None) -> bool:
        with self._condition:
            if cancel_event is not None and cancel_event.is_set():
                return False
            self.playing = True
            total = len(pcm) / (2 * SAMPLE_RATE)
            self._play_duration = total
            self._play_hold = 0.0
            self._play_origin = 0.0
            self._clock_running = False
            self._submitted_seconds = 0.0
            self._seek_target = None
            self.elapsed_seconds = 0.0
            self.remaining_seconds = total

        def finished():
            with self._condition:
                self._sync_play_clock()
                if self.playing and not (cancel_event is not None and cancel_event.is_set()):
                    self._play_hold = self._play_duration
                    self.elapsed_seconds = self._play_duration
                    self.remaining_seconds = 0.0
                else:
                    self._play_hold = self.elapsed_seconds
                self._clock_running = False
                self.playing = False
                self._condition.notify_all()

        device = None
        def progress(index):
            with self._condition:
                if self._seek_target is not None:
                    return
                self._submitted_seconds = index / (2 * SAMPLE_RATE)
                # Device creation can take time. Begin timing only once it asks for PCM.
                if not self._clock_running and not self._paused.is_set():
                    self._play_origin = monotonic()
                    self._clock_running = True
        def seek_position():
            with self._condition:
                target = self._seek_target
                self._seek_target = None
                return target
        try:
            device = miniaudio.PlaybackDevice(
                output_format=miniaudio.SampleFormat.SIGNED16,
                nchannels=1,
                sample_rate=SAMPLE_RATE,
                device_id=self._device_id(),
                app_name="VoxRelay",
            )
            stream = self._stream_pcm(pcm,
                lambda: self.playing and not (cancel_event is not None and cancel_event.is_set()),
                self._paused.is_set, progress, seek_position)
            next(stream)
            callback_stream = miniaudio.stream_with_callbacks(stream, end_callback=finished)
            next(callback_stream)
            with self._device_lock:
                self.device = device
                device.start(callback_stream)
            remaining = len(pcm) / (2 * SAMPLE_RATE) + 5
            last_tick = monotonic()
            revision = self.seek_revision
            with self._condition:
                while self.playing:
                    self._condition.wait(timeout=0.05)
                    now = monotonic()
                    if not self._paused.is_set():
                        remaining -= now-last_tick
                    last_tick = now
                    self._sync_play_clock()
                    if revision != self.seek_revision:
                        revision = self.seek_revision
                        remaining = self.remaining_seconds + 5
                    if remaining <= 0:
                        self.warning = "Audio output stopped responding. Reconnect the device or choose another output."
                        self.playing = False
                        return False
                    if cancel_event is not None and cancel_event.is_set():
                        self.playing = False
            return not (cancel_event is not None and cancel_event.is_set())
        except miniaudio.MiniaudioError:
            logging.exception("Audio playback failed")
            finished()
            return False
        finally:
            with self._condition:
                self._sync_play_clock()
                self._play_hold = self.elapsed_seconds
                self._clock_running = False
                self.playing = False
            with self._device_lock:
                if device is not None:
                    try:
                        device.close()
                    except miniaudio.MiniaudioError:
                        logging.exception("Could not close the output device")
                self.device = None

    def seek(self, seconds: float) -> dict:
        seconds = float(seconds)
        if not math.isfinite(seconds):
            raise ValueError("Playback position must be a finite number")
        with self._condition:
            if not self.playing or self._play_duration <= 0:
                raise ValueError("No audio is currently playing")
            position = max(0.0, min(self._play_duration, seconds))
            self._seek_target = int(position * SAMPLE_RATE) * 2
            self._play_hold = self._seek_target / (2 * SAMPLE_RATE)
            self._submitted_seconds = self._play_hold
            self._play_origin = monotonic()
            self._clock_running = False
            self.elapsed_seconds = self._play_hold
            self.remaining_seconds = self._play_duration - self.elapsed_seconds
            self.seek_revision += 1
            self._condition.notify_all()
            return {"elapsedSeconds": self.elapsed_seconds, "seekRevision": self.seek_revision}

    def pause(self) -> None:
        with self._condition:
            if self._clock_running and not self._paused.is_set():
                self._sync_play_clock()
                self._play_hold = self.elapsed_seconds
                self._clock_running = False
                self._sync_play_clock()
            self._paused.set()

    def resume(self) -> None:
        with self._condition:
            if not self._paused.is_set():
                return
            self._paused.clear()
            self._play_origin = monotonic()
            self._clock_running = self.playing and self._submitted_seconds > 0
            self._sync_play_clock()

    def stop(self) -> None:
        with self._condition:
            if self._clock_running and not self._paused.is_set():
                self._sync_play_clock()
                self._play_hold = self.elapsed_seconds
            self._clock_running = False
            self.playing = False
            self._condition.notify_all()
        # A device stop can wait for its audio callback. Never hold the callback's
        # condition while waiting for the device to stop.
        with self._device_lock:
            if self.device is not None:
                try:
                    self.device.stop()
                except miniaudio.MiniaudioError:
                    logging.exception("Could not stop playback cleanly")
