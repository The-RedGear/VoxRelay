from __future__ import annotations

import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request


def _run_backend() -> int:
    from voice_studio_speaker_bridge.app import main

    sys.argv = [sys.argv[0], "--headless"]
    return int(main() or 0)


def _self_test(output: Path) -> int:
    """Exercise the frozen runtime without starting servers or playing audio."""
    result = {"ok": False}
    try:
        import _cffi_backend
        from voice_studio_speaker_bridge import __version__
        from voice_studio_speaker_bridge.audio import AudioPlayer
        from voice_studio_speaker_bridge.models import VoiceAlias
        from voice_studio_speaker_bridge.providers import registry
        from voice_studio_speaker_bridge.windows_voices import WindowsVoiceClient
        resource_root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
        for name in ("VoxRelay.ps1", "VoxRelay.xaml", "ImportPreview.xaml"):
            if not (resource_root / name).is_file():
                raise RuntimeError(f"Missing desktop resource: {name}")
        client = WindowsVoiceClient()
        voices = client.list_voices()
        if not voices:
            raise RuntimeError("No installed Windows voices are available for the runtime check")
        wav = client.synthesize_wav("VoxRelay runtime check.", VoiceAlias("Check", provider="windows", voice_id=voices[0]["voice_id"]))
        pcm, duration = AudioPlayer().decode_wav(wav)
        from xml.etree import ElementTree
        namespace = "http://www.w3.org/2001/10/synthesis"
        root = ElementTree.Element("{"+namespace+"}speak", {"version": "1.0",
            "{http://www.w3.org/XML/1998/namespace}lang": voices[0]["language"]})
        root.text = "VoxRelay "
        pause = ElementTree.SubElement(root, "{"+namespace+"}break", {"time": "100ms"})
        pause.tail = "is ready."
        ssml_wav = client.synthesize_wav(ElementTree.tostring(root, encoding="unicode"),
            VoiceAlias("Check", provider="windows", voice_id=voices[0]["voice_id"], ssml=True))
        result.update(ok=True, version=__version__, providers=list(registry.providers),
                      wavBytes=len(wav), pcmBytes=len(pcm), durationMs=duration, ssmlWavBytes=len(ssml_wav))
    except Exception as exc:
        result["error"] = str(exc)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    return 0 if result["ok"] else 1


def _single_instance() -> object | None:
    if os.name != "nt":
        return object()
    kernel32 = ctypes.windll.kernel32
    kernel32.CreateMutexW.argtypes = (wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR)
    kernel32.CreateMutexW.restype = wintypes.HANDLE
    handle = kernel32.CreateMutexW(None, False, "Local\\VoxRelay.Desktop")
    if not handle or kernel32.GetLastError() == 183:
        kernel32.OpenEventW.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR)
        kernel32.OpenEventW.restype = wintypes.HANDLE
        event = kernel32.OpenEventW(2, False, "Local\\VoxRelay.Restore")
        if event:
            kernel32.SetEvent(wintypes.HANDLE(event))
            kernel32.CloseHandle(wintypes.HANDLE(event))
        if handle:
            kernel32.CloseHandle(wintypes.HANDLE(handle))
        return None
    return handle


def _backend_ready(timeout_sec: float = 10.0, port: int = 7582) -> bool:
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state", timeout=1) as response:
                if response.status == 200:
                    return True
        except (urllib.error.URLError, TimeoutError, OSError):
            time.sleep(0.25)
    return False


def main() -> int:
    if "--self-test-output" in sys.argv:
        return _self_test(Path(sys.argv[sys.argv.index("--self-test-output")+1]))
    if "--backend" in sys.argv:
        return _run_backend()

    instance = _single_instance()
    if instance is None:
        return 0

    frozen = bool(getattr(sys, "frozen", False))
    install_root = Path(sys.executable).resolve().parent if frozen else Path(__file__).resolve().parent
    resource_root = Path(getattr(sys, "_MEIPASS", install_root))
    data_root = install_root / "data"
    data_root.mkdir(parents=True, exist_ok=True)

    environment = dict(os.environ)
    environment["VOXRELAY_DATA_DIR"] = str(data_root)
    environment["VSB_EXTERNAL_BACKEND"] = "1"
    environment["VOXRELAY_PARENT_PID"] = str(os.getpid())
    if not frozen:
        environment["PYTHONPATH"] = str(resource_root / "src")

    local_python = install_root / ".venv" / "Scripts" / "python.exe"
    executable = Path(sys.executable) if frozen or not local_python.is_file() else local_python
    backend_args = [str(executable), "--backend"] if frozen else [str(executable), "-m", "voice_studio_speaker_bridge", "--headless"]
    backend = subprocess.Popen(backend_args, cwd=str(install_root), creationflags=subprocess.CREATE_NO_WINDOW, env=environment)
    port = 7582
    for filename in ("settings.json", "settings.json.bak"):
        try:
            config = json.loads((data_root / filename).read_text(encoding="utf-8-sig"))
            candidate = int(config.get("http_port", 7582))
            if 1 <= candidate <= 65535:
                port = candidate
            break
        except (OSError, ValueError, TypeError, AttributeError):
            continue
    if not _backend_ready(port=port):
        if backend.poll() is None:
            backend.terminate()
        ctypes.windll.user32.MessageBoxW(None, "VoxRelay could not start. Check data/bridge.log for details, and close any other running copy.", "VoxRelay", 0x10)
        return 1

    startupinfo = subprocess.STARTUPINFO()
    startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startupinfo.wShowWindow = 0
    shell = subprocess.Popen(
        ["powershell.exe", "-STA", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(resource_root / "VoxRelay.ps1")],
        cwd=str(install_root), env=environment, startupinfo=startupinfo,
    )
    try:
        return int(shell.wait() or 0)
    finally:
        if backend.poll() is None:
            kernel32 = ctypes.windll.kernel32
            kernel32.OpenEventW.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR)
            kernel32.OpenEventW.restype = wintypes.HANDLE
            signal = kernel32.OpenEventW(2, False, "Local\\VoxRelay.BackendStop")
            if signal:
                kernel32.SetEvent(wintypes.HANDLE(signal))
                kernel32.CloseHandle(wintypes.HANDLE(signal))
            else:
                backend.terminate()
            try:
                backend.wait(timeout=30)
            except subprocess.TimeoutExpired:
                backend.kill()
                backend.wait(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
