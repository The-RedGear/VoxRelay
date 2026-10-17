# YapLoq release roadmap

Implemented items have automated coverage or runtime verification. The 0.5 build
remains a preview until the live checks at the end are complete.

## Next priorities — essential before release

1. [ ] Reliable high-volume Streamer.Bot input: configurable queue capacity,
   visible rejection reasons, and end-to-end burst tests comparing sent,
   accepted and completed requests. Do not silently discard overflow.
2. [ ] Connection diagnostics: listener health, port conflicts, received-request
   counts and a clear setup test. Preview must support real integrations.
3. [ ] Alias-safe automation: flag missing/renamed aliases and provide a repair
   path for existing Streamer.Bot actions and routing rules.
4. [ ] Queue stability: finish live checks for fixed row order, manual moves,
   replay, selection and scroll retention under sustained traffic.
5. [ ] Release blockers: fix the UI callback crash-logging regression test, then
   verify packaged restart, audio-device recovery and OBS restoration live.

Defer additional providers and cosmetic expansion until these are verified.

## Reliability
- [x] Responsive skip/clear through generation, delay and playback
- [x] Pause active audio and pause after current
- [x] Atomic settings writes with automatic backup recovery
- [x] Concurrent queue admission and lifecycle regression tests
- [x] Stable history selection and reduced queue refreshes
- [x] Device fallback warning and playback watchdog
- [x] Diagnostics excluding credentials, messages, usernames and paths
- [x] Portable credential recovery guidance
- [x] Keyboard focus rings, control labels and small-screen window sizing
- [x] Duplicate-launch restore signal and graceful backend shutdown

## Release experience
- [x] First-run setup card with a no-account Windows voice option
- [x] Manual and optional startup update checks; version display
- [x] Settings backup, restore and reset
- [x] Speaker.bot alias migration preview (supported Polly aliases)
- [x] Voice search, engine filters, favorites and test playback
- [x] Context actions for item lists, Dashboard voices, service settings and Streamer.Bot exports
- [x] Alias icons, colors and selection highlights in Queue and History
- [x] Single ordered, full-height Queue list with contextual actions and alias-colored generation indicators
- [x] Provider/integration connection controls and local output test tone
- [x] Saved credentials displayed masked by default, with Show/Hide controls and automatic re-masking
- [x] Streamer.bot command templates and setup guide
- [x] Export/import aliases, dictionaries and routing presets
- [ ] Signed Windows distribution (requires a signing identity)

## Queue and routing
- [x] Priority, duplicate detection, per-user limits and message expiry
- [x] Clear waiting and stop-and-clear controls
- [x] Optional queue recovery, always paused
- [x] Drag-and-drop queue ordering and approximate wait time
- [x] Ordered routing rules for user, role, source and event
- [x] Named profiles and profile-switch commands for Streamer.bot scene actions

## Engines and audio
- [x] Shared provider registry and adapter documentation
- [x] Installed Windows voice provider, verified with real synthesis in memory
- [x] Per-alias output, speed and volume
- [x] Peak normalization, clipping protection and fades
- [x] Optional OBS input ducking and restoration
- [x] Provider-aware SSML (including pitch markup) and VoiceStudio style controls
- [x] Separate stream/preview volumes and output tests

## Automation
- [x] Complete per-message event timeline and optional action hooks
- [x] Event inspector and isolated action simulator
- [x] HTTP, UDP and WebSocket recipes
- [x] Native Streamer.bot action export generator using the official v10 envelope
- [x] Provider/plugin authoring documentation
- [x] Windows build workflow and packaged runtime self-test

## Required live checks before a public release

- [ ] Import generated `.sb` actions in supported Streamer.bot versions and test each command
- [ ] Live OBS duck/restore, including disconnect/reconnect during speech
- [ ] Unplug/reconnect actual audio hardware during playback
- [ ] Narrator and keyboard audit on the running desktop
- [ ] Physical 125%, 150%, 200% DPI and mixed-monitor maximize/restore checks
- [ ] Tray restore after Explorer restart and Windows shutdown/restart checks
- [ ] Choose and verify the next cloud provider with its actual account

No live Streamer.bot configuration or production data was modified to test the
import generator. Automated OBS tests use a simulated client. Layout checks cover
1180×760, 980×640 and 936×516; they do not replace physical monitor testing.
