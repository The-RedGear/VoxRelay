# Security policy

Please do not publicly disclose vulnerabilities that could expose credentials,
execute unintended commands, or access private files.

Report security issues privately through GitHub's **Report a vulnerability**
feature when it is available for this repository. Include reproduction steps,
the affected version, and the expected impact. Do not include real credentials
or private user data in the report.

## Credential handling

YapLoq credentials must never be committed to the repository. Secrets entered
in the desktop app (AWS keys, ElevenLabs / Azure / Google / Watson / UberDuck /
TTS.Monster tokens, Acapela / CereProc passwords, OBS passwords, and similar
values) are protected with Windows DPAPI for the current Windows user account on
that machine.

Do not share:

- `data/settings.json` from a real machine
- DPAPI ciphertext blobs (they decrypt for that Windows user)
- Overlay URLs that embed API keys
- Google service-account JSON files
- Diagnostic exports that still contain secrets

## Scope

In scope: YapLoq source, packaged Windows builds published by this project,
and the local HTTP / WebSocket / UDP listeners as documented.

Out of scope: vulnerabilities solely in third-party TTS providers, Streamer.bot,
Speaker.bot, OBS, or the operator's own network configuration.
