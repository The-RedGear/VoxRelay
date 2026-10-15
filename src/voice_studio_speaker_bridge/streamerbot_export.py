"""Native SBAE exports using Streamer.bot's documented v10 export envelope.

The legacy v0.2.4 action schema is intentional: supported Streamer.bot versions
upgrade that schema on import. No trigger runs automatically on import.
"""
import base64
import gzip
import json
import uuid

from . import __version__


def _id(name: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_OID, "VoxRelay/" + name))


def export_actions(port: int, alias: str) -> str:
    if not 1 <= port <= 65535:
        raise ValueError("UDP port must be between 1 and 65535")
    voice = alias.strip()
    if not voice or "\n" in voice or "\r" in voice:
        raise ValueError("Choose a valid voice alias for the Speak action")
    # ``random`` / ``playlist:Name`` / ``group:Name`` are resolved at speak time.
    if voice.casefold().startswith("group:") and not voice.split(":", 1)[1].strip():
        raise ValueError("Group selector needs a group name after group:")
    if voice.casefold().startswith("playlist:") and not voice.split(":", 1)[1].strip():
        raise ValueError("Playlist selector needs a name after playlist:")
    queue_id = _id("command queue")
    commands = [("Speak", f"VSPEAK\r\n{voice}\r\n%message%\r\n%displayName%\r\n%userName%")]
    for name, token in (("Pause audio", "pause"), ("Pause after current", "pauseaftercurrent"),
                        ("Resume", "resume"), ("Skip current", "skip"),
                        ("Clear waiting", "clear"), ("Stop and clear", "clearall"),
                        ("Remove item", "remove"), ("Move item up", "moveup"), ("Move item down", "movedown")):
        payload = "VCONTROL\r\n" + token
        if token in {"remove", "moveup", "movedown"}:
            payload += "\r\n%ttsId%"
        commands.append((name, payload))
    actions = []
    for name, payload in commands:
        actions.append({"id": _id("action/"+name), "queue": queue_id, "enabled": True,
            "excludeFromHistory": False, "name": "VoxRelay - "+name, "group": "VoxRelay",
            "alwaysRun": False, "randomAction": False, "concurrent": True,
            "triggers": [], "actionGroups": [], "collapsedGroups": [],
            "actions": [{"id": _id("subaction/"+name), "weight": 0.0, "type": 2,
                "group": None, "enabled": True, "index": 0, "port": port, "payload": payload}]})
    envelope = {
        "version": 10, "exportedFrom": "0.2.4", "minimumVersion": "0.2.4",
        "meta": {"name": "VoxRelay speech and queue controls", "author": "VoxRelay",
            "version": __version__, "autoRunAction": None, "minimumVersion": "0.2.4",
            "description": "Speech and queue actions for VoxRelay. Attach your own triggers. Speak uses the selected alias, or random among Voices marked On. Item controls use ttsId. Importing can replace existing VoxRelay actions with the same names."},
        "data": {"actions": actions, "queues": [{"id": queue_id, "name": "VoxRelay commands", "blocking": False}],
            "commands": [], "websocketServers": [], "websocketClients": [], "timers": []}}
    binary = b"SBAE" + gzip.compress(json.dumps(envelope, ensure_ascii=False, separators=(",", ":")).encode("utf-8"), mtime=0)
    return base64.b64encode(binary).decode("ascii")
