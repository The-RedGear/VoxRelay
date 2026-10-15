"""Installed Windows speech voices, generated to memory without device playback."""
from __future__ import annotations

import base64
import json
import math
import os
import subprocess

from .models import VoiceAlias

SCRIPT = r"""
$ErrorActionPreference='Stop'
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Speech
$request=[Console]::In.ReadToEnd() | ConvertFrom-Json
$speech=[Speech.Synthesis.SpeechSynthesizer]::new()
try {
    if($request.operation -eq 'voices') {
        $voices=@($speech.GetInstalledVoices() | Where-Object {$_.Enabled} | ForEach-Object {
            @{provider='windows';voice_id=$_.VoiceInfo.Name;name=$_.VoiceInfo.Name;language=$_.VoiceInfo.Culture.Name;model='sapi'}
        })
        ConvertTo-Json -InputObject $voices -Depth 5 -Compress
    } else {
        if($request.voice){$speech.SelectVoice([string]$request.voice)}
        $speech.Rate=[int]$request.rate
        $stream=[IO.MemoryStream]::new()
        try {
            $speech.SetOutputToWaveStream($stream)
            if($request.ssml){$speech.SpeakSsml([string]$request.text)}else{$speech.Speak([string]$request.text)}
            $speech.SetOutputToNull()
            [Convert]::ToBase64String($stream.ToArray())
        } finally {$stream.Dispose()}
    }
} finally {$speech.Dispose()}
"""


class WindowsVoiceClient:
    def __init__(self, timeout: float = 120):
        self.timeout = timeout

    def _run(self, payload: dict, timeout: float | None = None) -> str:
        if os.name != "nt":
            raise ValueError("Installed Windows voices are available on Windows only")
        encoded = base64.b64encode(SCRIPT.encode("utf-16-le")).decode("ascii")
        result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
            input=json.dumps(payload), encoding="utf-8", capture_output=True,
            creationflags=subprocess.CREATE_NO_WINDOW, timeout=timeout or self.timeout)
        if result.returncode:
            raise ValueError("Windows could not generate speech. Check that the selected Windows voice is installed.")
        return result.stdout.lstrip("\ufeff").strip()

    def list_voices(self) -> list[dict]:
        voices = json.loads(self._run({"operation": "voices"}, timeout=10))
        return voices if isinstance(voices, list) else [voices]

    def synthesize_wav(self, text: str, alias: VoiceAlias) -> bytes:
        rate = max(-10, min(10, round(math.log2(max(0.25, min(4, alias.speed))) * 5)))
        audio = base64.b64decode(self._run({"operation": "speak", "text": text,
            "voice": alias.voice_id, "rate": rate, "ssml": alias.ssml}), validate=True)
        if audio[:4] != b"RIFF" or audio[8:12] != b"WAVE":
            raise ValueError("Windows returned invalid audio")
        return audio
