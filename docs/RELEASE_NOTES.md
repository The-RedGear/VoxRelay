# YapLoq 0.5.0 preview — release notes

**Base version:** `0.5.0`
**Status:** redesign-branch preview; no YapLoq release tag has been published.

## Highlights

- New YapLoq microphone branding, Poppins typography and cleaner, rounded UI
- Click-to-seek media bar with smoother progress and selected-History playback
- Replay existing recordings without duplicate cache files; one History/cache limit
- Collapsible profanity rules with whole-word variants, replacements and hidden words
- Easier setup guides and sliders paired with exact limit/cooldown values

- Cloud TTS engines: ElevenLabs, Azure Speech, Google Cloud TTS, IBM Watson, UberDuck, TTS.Monster, Acapela, CereProc (plus VoiceStudio, Windows SAPI, Amazon Polly)
- Per-provider Services pages with Windows DPAPI-encrypted secrets
- Streamer.bot speak payload hardened for display vs login (`%displayName%` / `%userName%`)
- Voices **ON** checkboxes + Speak `random` for the global enabled pool
- **Rules → Voice playlists** — named pools via `playlist:Name` (also in Streamer.bot export)
- Playground script box, scrollbar thumbs, VoiceStudio and Streamer.bot page UI polish

## Download

1. Download a successful YapLoq preview build from the branch's Actions workflow.
2. Extract the folder. Keep `_internal` beside `YapLoq-preview.exe`.
3. Run `YapLoq-preview.exe` — Python is not required.

Also included in the zip: `LICENSE`, `THIRD_PARTY_NOTICES.md`, `LEGAL.md`, `CHANGELOG.md`, and the `docs/` folder.

This build passes the automated test suite, desktop layout/branding checks, and
a frozen-runtime check for bundled resources and audio decoding. Provider billing,
live integrations and your audio hardware should still be tested before a stream.

## Important before you stream

- **Provider billing:** cloud TTS usage is billed by each vendor under their own Terms of Service. YapLoq does not sell voice minutes.
- **Authorized voices only:** only use voices and cloned models you own or are licensed to use.
- **Unsigned binary:** Windows SmartScreen may warn on first run. Code signing is planned; see `ROADMAP.md`.
- **Secrets stay local:** API keys are encrypted with Windows DPAPI for the current Windows user. Moving `data/` to another PC or account requires re-entering keys.
- **Not affiliated** with Streamer.bot, Speaker.bot, Amazon, Microsoft, Google, ElevenLabs, IBM, or other named providers.

## Streamer.bot quick start

Recommended UDP speak payload:

```text
VSPEAK
YourAlias
%message%
%displayName%
%userName%
```

Do **not** put Streamer.bot’s `%user%` object on identity lines — in current builds it often expands to JSON (`badges` / `login`) and breaks voice rules and Helix lookups. Prefer `%displayName%` + `%userName%`.

For random selection, use `random` (Voices marked **ON**) or `playlist:YourPlaylist` from **Rules → Voice playlists**.

Export a starter `.sb` from **Services → Streamer.bot → Export actions**, import it in Streamer.bot, then attach your own triggers.

## Still preview / verify yourself

Live checks still open before calling this a final release (see `ROADMAP.md`):

- Import `.sb` actions in your Streamer.bot version and test Speak + queue controls
- OBS duck/restore during disconnects
- Audio device unplug during playback
- DPI / tray / Narrator on physical hardware

## Privacy

Settings, logs, generated audio, and history live in the local `data` folder and are not part of the Git repository. Export diagnostics strips messages, keys, usernames, and local paths.

## License

MIT — see `LICENSE`, `THIRD_PARTY_NOTICES.md`, and `docs/LEGAL.md`.
