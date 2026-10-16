import os
import sys
import subprocess
from pathlib import Path
import wpf_launcher


def test_desktop_child_errors_are_retained_and_logs_rotate(tmp_path):
    log = tmp_path / 'desktop-host.log'
    log.write_bytes(b'x' * 2_000_001)
    flags = {'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {}
    process = wpf_launcher._start_logged_process(
        [sys.executable, '-c', 'import sys; print("diagnostic", file=sys.stderr); sys.exit(7)'], log, **flags)
    assert process.wait(timeout=10) == 7
    assert 'diagnostic' in log.read_text()
    assert log.with_suffix('.previous.log').stat().st_size == 2_000_001
