# Changelog

## 0.5.0 preview

Adds Speaker.bot-compatible cloud TTS engines: ElevenLabs, Azure Speech,
Google Cloud TTS, IBM Watson, UberDuck, TTS.Monster, Acapela, and CereProc.
Credentials live under Services > Engines (Polly and Windows stay on their
existing pages). Secrets use the same Windows DPAPI protection as Polly.

## 0.4.0 preview

Adds queue safeguards, active-audio pause, paused recovery, ordered routing,
profiles, Windows voices, SSML, OBS ducking, output controls, data maintenance,
voice search/favorites, event diagnostics and native Streamer.bot action exports.

Fixes interrupted settings writes, long skip delays, duplicate lifecycle
registration, tests contaminating the live queue, unnecessary history refreshes,
incorrect alias-profile selection, missing editable dropdown controls, silent
playback failures, custom-port startup checks and a UDP shutdown race.

The preview is unsigned. Native Streamer.bot imports and live OBS/device/DPI
checks remain release gates; see ROADMAP.md. The existing 0.3 installation is
unchanged by this build.
