from __future__ import annotations

import logging
from threading import Condition, RLock

import miniaudio


SAMPLE_RATE = 44100


class AudioPlayer:
    def __init__(self, output_device: str = ""):
        self.output_device = output_device
        self.device: miniaudio.PlaybackDevice | None = None
        self.playing = False
        self._condition = Condition(RLock())

    @staticmethod
    def list_devices() -> list[str]:
        try:
            return [item["name"] for item in miniaudio.Devices().get_playbacks()]
        except miniaudio.MiniaudioError:
            logging.exception("Could not enumerate playback devices")
            return []

    def _device_id(self):
        if not self.output_device:
            return None
        for item in miniaudio.Devices().get_playbacks():
            if item["name"] == self.output_device:
                return item["id"]
        logging.warning("Output device %s was not found; using default", self.output_device)
        return None

    def decode_wav(self, wav_bytes: bytes, volume: float = 1.0) -> tuple[bytes, float]:
        decoded = miniaudio.decode(
            wav_bytes,
            output_format=miniaudio.SampleFormat.SIGNED16,
            nchannels=1,
            sample_rate=SAMPLE_RATE,
        )
        samples = decoded.samples
        if abs(volume - 1.0) > 0.001:
            factor = max(0.0, min(volume, 2.0))
            for index, sample in enumerate(samples):
                samples[index] = max(-32768, min(32767, int(sample * factor)))
        pcm = samples.tobytes()
        duration_ms = len(pcm) / 2 / SAMPLE_RATE * 1000.0
        return pcm, duration_ms

    @staticmethod
    def _stream_pcm(source: bytes, is_playing):
        required_frames = yield b""
        index = 0
        while index < len(source) and is_playing():
            required_bytes = required_frames * 2
            data = source[index:index + required_bytes]
            index += required_bytes
            if not data:
                break
            required_frames = yield data

    def play(self, pcm: bytes) -> bool:
        with self._condition:
            self.playing = True

        def finished():
            with self._condition:
                self.playing = False
                self._condition.notify_all()

        try:
            device = miniaudio.PlaybackDevice(
                output_format=miniaudio.SampleFormat.SIGNED16,
                nchannels=1,
                sample_rate=SAMPLE_RATE,
                device_id=self._device_id(),
                app_name="VoxRelay",
            )
            self.device = device
            stream = self._stream_pcm(pcm, lambda: self.playing)
            next(stream)
            callback_stream = miniaudio.stream_with_callbacks(stream, end_callback=finished)
            next(callback_stream)
            device.start(callback_stream)
            with self._condition:
                while self.playing:
                    self._condition.wait()
            device.close()
            self.device = None
            return True
        except miniaudio.MiniaudioError:
            logging.exception("Audio playback failed")
            finished()
            return False

    def stop(self) -> None:
        with self._condition:
            self.playing = False
            if self.device is not None:
                try:
                    self.device.stop()
                except miniaudio.MiniaudioError:
                    logging.exception("Could not stop playback cleanly")
            self._condition.notify_all()
