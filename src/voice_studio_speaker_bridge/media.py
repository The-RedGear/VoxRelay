"""Convert provider audio payloads into WAV bytes for the playback pipeline."""
from __future__ import annotations

import io
import wave

import miniaudio


def pcm_to_wav(pcm: bytes, *, sample_rate: int = 16000, channels: int = 1, sample_width: int = 2) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(sample_width)
        wav.setframerate(sample_rate)
        wav.writeframes(pcm)
    return output.getvalue()


def to_wav(audio: bytes, *, pcm_rate: int | None = None) -> bytes:
    if not audio:
        raise ValueError("Provider returned empty audio")
    if audio[:4] == b"RIFF" and audio[8:12] == b"WAVE":
        return audio
    if pcm_rate is not None:
        return pcm_to_wav(audio, sample_rate=pcm_rate)
    decoded = miniaudio.decode(
        audio,
        output_format=miniaudio.SampleFormat.SIGNED16,
        nchannels=1,
        sample_rate=16000,
    )
    return pcm_to_wav(decoded.samples.tobytes(), sample_rate=16000)
