from __future__ import annotations

import ctypes
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


def _single_instance() -> object | None:
    if os.name != "nt":
        return object()
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.CreateMutexW(None, False, "Local\\VoxRelay.Desktop")
    if not handle or kernel32.GetLastError() == 183:
        return None
    return handle


def _backend_ready(timeout_sec: float = 10.0) -> bool:
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        try:
            with urllib.request.urlopen("http://127.0.0.1:7582/api/state", timeout=1) as response:
                if response.status == 200:
                    return True
        except (urllib.error.URLError, TimeoutError, OSError):
            time.sleep(0.25)
    return False


def main() -> int:
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
    if not frozen:
        environment["PYTHONPATH"] = str(resource_root / "src")

    executable = Path(sys.executable) if frozen else install_root / ".venv" / "Scripts" / "python.exe"
    backend_args = [str(executable), "--backend"] if frozen else [str(executable), "-m", "voice_studio_speaker_bridge", "--headless"]
    backend = subprocess.Popen(backend_args, cwd=str(install_root), creationflags=subprocess.CREATE_NO_WINDOW, env=environment)
    if not _backend_ready():
        if backend.poll() is None:
            backend.terminate()
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
            backend.terminate()
            try:
                backend.wait(timeout=5)
            except subprocess.TimeoutExpired:
                backend.kill()
                backend.wait(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
