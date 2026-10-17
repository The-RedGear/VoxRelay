# Changelog

## 0.5.0 — Initial YapLoq release

- Six-page desktop interface: Dashboard, Voices, Queue, Services, Streamer.Bot and Settings.
- Custom voice icons from Icônes, alias colors, favorites, playlists and routing.
- Unified queue and history with stable order, recording replay and context actions.
- Dashboard recent speech stays visible through playback completion.
- Masked service credentials with show/hide controls.
- In-app GitHub release checks, patch notes, verified update downloads and restart installation.

### Earlier development work

- Applies the supplied YapLoq microphone and wordmark to the title bar,
  sidebar, About panel, Windows executable/window icons, tray and README banner.
  Original vector masters and reproducible icon exports are included.

- History media-bar playback uses the selected recording without copying or
  regenerating it. Missing recordings are hidden; History and cache share one limit.
- Whole-row History selection, wrapped playlist rows and rounded frames.
- Collapsible profanity rules with per-word toggles, variants, replacement
  alternatives, remove/block actions, and words hidden by default.
- Sliders with exact-value entry for limits and cooldowns.
- Smoother playback progress, seeking, responsive polling, collapsible setup guides,
  rounded control states and locally bundled Poppins typography.

Adds Speaker.bot-compatible cloud TTS engines: ElevenLabs, Azure Speech,
Google Cloud TTS, IBM Watson, UberDuck, TTS.Monster, Acapela, and CereProc.
Each engine has a Services page. Secrets use the same Windows DPAPI protection
as Polly.

Also in this preview:

- Streamer.bot UDP speak identity handling (display vs login; reject `%user%` JSON blobs)
- Allowlist / protocol hardening for speak requests
- Voices **ON** toggles for the global `random` Speak pool; Streamer.bot export can use Random
- **Rules → Voice playlists** for named pools (`playlist:Name`) usable in Speak, routing, and export
- Playground multi-line script layout, pill scrollbars, VoiceStudio and Streamer.bot UI cleanup
- Packaging copies `LICENSE`, notices, `LEGAL.md`, and `docs/` into the Windows zip

The build is **unsigned**. Cloud TTS is billed by each provider. Native Streamer.bot
imports and live OBS/device/DPI checks remain release gates; see `ROADMAP.md` and
`docs/RELEASE_NOTES.md`.

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
