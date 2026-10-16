from __future__ import annotations

import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

from voice_studio_speaker_bridge.channel import is_preview, instance_name, preview_data_dir


def _run_backend() -> int:
    from voice_studio_speaker_bridge.app import main

    sys.argv = [sys.argv[0], "--headless"]
    return int(main() or 0)


def _verify_package(output: Path) -> int:
    """Check the actual frozen distribution without devices, servers or credentials."""
    result = {"ok": False}
    try:
        import _cffi_backend
        import io
        import tempfile
        import wave
        from voice_studio_speaker_bridge import __version__
        from voice_studio_speaker_bridge.audio import AudioPlayer
        from voice_studio_speaker_bridge.providers import registry
        from voice_studio_speaker_bridge.settings import Settings

        root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
        resources = ["VoxRelay.ps1", "VoxRelay.xaml", "ImportPreview.xaml",
                     "assets/RuleEditors.ps1", "assets/ProfanityPanel.xaml",
                     "assets/ProfanityDialog.xaml", "assets/profanity-defaults.json",
                     "assets/VoxRelay-logo.png", "assets/VoxRelay.ico", "assets/VoxRelay-tray.ico",
                     "assets/fonts/Poppins/Poppins-Regular.ttf", "assets/fonts/Poppins/OFL.txt"]
        if is_preview():
            resources.append("assets/YapLoqShell.ps1")
        for name in resources:
            if not (root / name).is_file():
                raise RuntimeError(f"Missing packaged resource: {name}")
        with tempfile.TemporaryDirectory(prefix="voxrelay-package-") as folder:
            settings = Settings(Path(folder) / "settings.json")
            if not settings.profanity_rules:
                raise RuntimeError("Default moderation rules did not load")
        with io.BytesIO() as stream:
            with wave.open(stream, "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(24000)
                wav.writeframes(b"\0" * 4800)
            pcm, duration = AudioPlayer().decode_wav(stream.getvalue())
        if not pcm or duration <= 0:
            raise RuntimeError("Packaged audio decoder failed")
        result.update(ok=True, version=__version__, providers=list(registry.providers),
                      checkedResources=len(resources), durationMs=duration,
                      frozen=bool(getattr(sys, "frozen", False)))
    except Exception as exc:
        result["error"] = str(exc)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    return 0 if result["ok"] else 1


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
    handle = kernel32.CreateMutexW(None, False, instance_name("Desktop"))
    if not handle or kernel32.GetLastError() == 183:
        kernel32.OpenEventW.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR)
        kernel32.OpenEventW.restype = wintypes.HANDLE
        event = kernel32.OpenEventW(2, False, instance_name("Restore"))
        if event:
            kernel32.SetEvent(wintypes.HANDLE(event))
            kernel32.CloseHandle(wintypes.HANDLE(event))
        if handle:
            kernel32.CloseHandle(wintypes.HANDLE(handle))
        return None
    return handle


def _backend_ready(timeout_sec: float = 10.0, port: int = 7582, token: str = "") -> bool:
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        try:
            endpoint = "/api/identity" if token else "/api/state"
            with urllib.request.urlopen(f"http://127.0.0.1:{port}{endpoint}", timeout=1) as response:
                if response.status == 200:
                    if token:
                        identity = json.loads(response.read())
                        if identity.get("launchId") != token or identity.get("channel") != "yaploq-preview":
                            return False
                        if identity.get("ready"):
                            return True
                        time.sleep(0.1)
                        continue
                    return True
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            time.sleep(0.25)
    return False


def main() -> int:
    if "--verify-package-output" in sys.argv:
        return _verify_package(Path(sys.argv[sys.argv.index("--verify-package-output")+1]))
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
    data_root = preview_data_dir() if is_preview() else Path(os.environ.get("VOXRELAY_DATA_DIR") or install_root / "data")
    data_root.mkdir(parents=True, exist_ok=True)

    environment = dict(os.environ)
    environment["VOXRELAY_DATA_DIR"] = str(data_root)
    environment["VSB_EXTERNAL_BACKEND"] = "1"
    environment["VOXRELAY_PARENT_PID"] = str(os.getpid())
    token = str(uuid.uuid4()) if is_preview() else ""
    environment["YAPLOQ_LAUNCH_ID"] = token

    # Prefer a live src/ package + Python when present so hotfixes (e.g. provider
    # enable flags) apply without waiting for a full PyInstaller rebuild.
    src_root = install_root / "src"
    live_package = src_root / "voice_studio_speaker_bridge"
    local_pythonw = install_root / ".venv" / "Scripts" / "pythonw.exe"
    local_python = install_root / ".venv" / "Scripts" / "python.exe"
    python_candidates: list[Path] = []
    # Prefer pythonw so backend/helper launches never allocate a console.
    if local_pythonw.is_file():
        python_candidates.append(local_pythonw)
    if local_python.is_file():
        python_candidates.append(local_python)
    if not frozen:
        python_candidates.append(Path(sys.executable))
    for candidate in (
        Path(r"C:\Program Files\Python314\python.exe"),
        Path(r"C:\Program Files\Python313\python.exe"),
        Path(r"C:\Program Files\Python312\python.exe"),
    ):
        if candidate.is_file() and candidate not in python_candidates:
            python_candidates.append(candidate)
    which_python = shutil.which("python")
    if which_python:
        which_path = Path(which_python)
        if which_path.is_file() and which_path not in python_candidates:
            python_candidates.append(which_path)

    if live_package.is_dir() and python_candidates:
        environment["PYTHONPATH"] = str(src_root)
        backend_args = [str(python_candidates[0]), "-m", "voice_studio_speaker_bridge", "--headless"]
    elif frozen:
        backend_args = [str(sys.executable), "--backend"]
    else:
        environment["PYTHONPATH"] = str(resource_root / "src")
        executable = local_python if local_python.is_file() else Path(sys.executable)
        backend_args = [str(executable), "-m", "voice_studio_speaker_bridge", "--headless"]
    no_window = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
    backend = subprocess.Popen(
        backend_args,
        cwd=str(install_root),
        creationflags=no_window,
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    port = 17582 if is_preview() else 7582
    for filename in (() if is_preview() else ("settings.json", "settings.json.bak")):
        try:
            config = json.loads((data_root / filename).read_text(encoding="utf-8-sig"))
            candidate = int(config.get("http_port", 7582))
            if 1 <= candidate <= 65535:
                port = candidate
            break
        except (OSError, ValueError, TypeError, AttributeError):
            continue
    if not _backend_ready(port=port, token=token):
        if backend.poll() is None:
            backend.terminate()
        folder = "data-preview" if is_preview() else "data"
        ctypes.windll.user32.MessageBoxW(None, f"Could not start the playback service. Check {folder}/bridge.log and close any copy using its ports.", "YapLoq Preview" if is_preview() else "VoxRelay", 0x10)
        return 1

    # Detach from any console inherited from python.exe so a terminal window
    # does not stay open (closing it would kill the whole app).
    if os.name == "nt":
        try:
            ctypes.windll.kernel32.FreeConsole()
        except Exception:
            pass

    startupinfo = subprocess.STARTUPINFO()
    startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startupinfo.wShowWindow = 0
    shell = subprocess.Popen(
        ["powershell.exe", "-STA", "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", str(resource_root / "VoxRelay.ps1")],
        cwd=str(install_root),
        env=environment,
        startupinfo=startupinfo,
        creationflags=no_window,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        return int(shell.wait() or 0)
    finally:
        if backend.poll() is None:
            kernel32 = ctypes.windll.kernel32
            kernel32.OpenEventW.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR)
            kernel32.OpenEventW.restype = wintypes.HANDLE
            signal = kernel32.OpenEventW(2, False, instance_name("BackendStop"))
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
