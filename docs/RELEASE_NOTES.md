# YapLoq 0.5.0 — Initial release

Voice automation for streamers, with a Windows desktop app and Streamer.Bot integration.

## What's included

- Dashboard for speaking with your selected voice and replaying recent speech.
- Eleven speech services, including Windows voices, VoiceStudio, Amazon Polly, ElevenLabs, Azure and Google Cloud TTS.
- Voice aliases with custom Icônes icons, colors, favorites, playlists and routing.
- Unified queue and history with generation/playback statuses, manual ordering, recording replay, save audio and right-click actions.
- Streamer.Bot action exports, UDP speech requests and optional playback actions.
- Pronunciation and message filters, profanity rules, queue limits and cooldowns.
- Separate stream/preview audio outputs and optional OBS ducking.
- Encrypted service credentials, masked by default with show/hide controls.
- GitHub release checks, patch notes and verified in-app update downloads with backup and restart installation.

## Download and start

1. Download **YapLoq-Windows-x64-update.zip** from this release.
2. Extract the entire ZIP to a writable folder. Keep `_internal` beside `YapLoq.exe`.
3. Run **YapLoq.exe**. Python is not required.
4. Open **Services**, connect a service, then create and test an alias in **Voices**.
5. Open **Streamer.Bot** for the connection and action export instructions.

The same ZIP is the portable first-time download and the package used by the in-app updater.

## Notes

- Windows 10/11, 64-bit. This build is unsigned; Windows SmartScreen may show a warning.
- Cloud speech usage is billed by each provider. Use voices you own or have permission to use.
- Settings, history and audio remain local. Windows-encrypted credentials must be entered again on another computer or Windows account.
- The separate development preview retains its own data folder and update channel. This release does not automatically migrate preview settings.
- Provider availability, audio hardware and OBS behavior depend on your setup. See the roadmap for ongoing validation and planned improvements.

YapLoq is distributed under the MIT License. See LICENSE, THIRD_PARTY_NOTICES.md and docs/LEGAL.md.
