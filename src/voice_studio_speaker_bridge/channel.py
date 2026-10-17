"""Preview boundaries shared by desktop and playback service."""
import os
from pathlib import Path


def is_preview() -> bool:
    return os.environ.get("YAPLOQ_PREVIEW") == "1"


def instance_name(part: str) -> str:
    return "Local\\" + ("YapLoq.Preview" if is_preview() else "YapLoq") + "." + part


def preview_data_dir() -> Path:
    # Deliberately ignore the production data override. No automatic migration.
    root = os.environ.get("YAPLOQ_PREVIEW_ROOT")
    if not root:
        raise RuntimeError("Start preview using yaploq_preview.py or YapLoq-preview.exe")
    return Path(root).resolve() / "data-preview"


def apply_preview_limits(settings) -> None:
    if not is_preview():
        return
    settings.http_address = settings.ws_address = "127.0.0.1"
    settings.http_port, settings.ws_port = 17582, 17581
    # Keep desktop endpoints isolated, but honor integration settings so preview
    # can receive real speech and exercise Streamer.Bot/OBS connections.
    settings.persist_queue = False
