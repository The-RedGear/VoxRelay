"""Dedicated preview entry point; also used as the PyInstaller entry script."""
import os
from pathlib import Path
import sys

os.environ["YAPLOQ_PREVIEW"] = "1"
os.environ["YAPLOQ_PREVIEW_ROOT"] = str(
    Path(sys.executable).resolve().parent if getattr(sys, "frozen", False)
    else Path(__file__).resolve().parent
)

from wpf_launcher import main

if __name__ == "__main__":
    raise SystemExit(main())
