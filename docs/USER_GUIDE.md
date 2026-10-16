# YapLoq 0.5 preview

For this redesign preview, run `YapLoq-preview.exe` and use its isolated `data-preview` folder. See `YAPLOQ_PREVIEW.md` for preview limits. Standard builds use `YapLoq.exe`; keep the `_internal` folder beside the executable.
YapLoq uses the `data` folder beside the EXE. A second launch restores the
existing window rather than starting another playback service.

## First voice

Settings opens on the first launch. Choose **Windows voices** for speech without an
account, or configure a provider under **Services**. Select your stream output, use
its test button, then add an alias in **Voices** and test it.

| Service | Notes |
| --- | --- |
| VoiceStudio | Local HTTP server (often `http://127.0.0.1:3900`) |
| Windows voices | No account; enable on the Settings setup card |
| Amazon Polly | Access key + secret (optional session token or AWS profile) |
| ElevenLabs, Azure, Google, Watson, UberDuck, TTS.Monster, Acapela, CereProc | Each has its own Services page |

On the **Voices** tab, the **ON** checkbox includes an alias in Streamer.bot
**Random** Speak selection. Uncheck voices you do not want in that global pool.
Explicit alias names still speak when requested (Playground / Test), even if OFF.

For smaller custom pools (Wallace + Master Chief + Sgt Johnson only), open
**Rules → Voice playlists**, create a named playlist, check those voices, then use
`playlist:YourName` in Streamer.bot (or pick **Playlist: YourName** when exporting).

Saved keys are encrypted for the current Windows account (DPAPI). Moving `data` to
another PC or account requires entering keys again. Cloud providers bill usage on
their own accounts — YapLoq does not sell minutes.

## Streamer.bot identities

When sending speak requests over UDP, prefer:

```text
VSPEAK
YourAlias
%message%
%displayName%
%userName%
```

Use **display** (`%displayName%` or a plain `%user%` name) and **login**
(`%userName%`) on separate lines. Do not put Streamer.bot’s `%user%` object JSON on
those lines — current builds often expand it to `{"badges":...,"login":...}`, which
breaks automatic voice rules. Full recipes: [STREAMERBOT.md](STREAMERBOT.md).

## Queue

- Pause audio keeps the current playback position. Resume continues it.
- Pause after current finishes the current item before pausing.
- Clear waiting removes pending items and lets the current item finish.
- Stop & clear also cancels the current item, including generation or a delay.
- Drag an item onto another pending item to move it before that item.
- Priorities apply to pending messages; active speech is not interrupted.
- Queue time is approximate, based on known audio duration or text length.

Set per-user limits, duplicate windows and message expiry in Settings. Zero turns
off these optional limits. Queue restoration is opt-in and always starts paused.
An interrupted message may restart from the beginning after restoration.

## Rules and profiles

Routing rules are checked top to bottom. The first exact match for user, role,
source or event chooses the alias and priority. They take precedence over legacy
viewer and role mappings. Higher priorities play first.

Save rules before switching pages. Save settings before saving a profile.
Profiles contain voices, routing, dictionaries, filters and audio preferences.
They keep your current provider credentials and network ports. New incoming
messages use the loaded profile; queued messages retain their selected alias.

## Audio

An alias can override the stream output. Explicit preview sources use the preview
device. Settings provides separate stream and preview volumes, peak normalization
and short fades. Samples are clipped safely when amplified.

OBS ducking is optional. Enable OBS's WebSocket server, enter its address and
password, load inputs, choose the music/desktop input, and set its speech volume.
YapLoq remembers the original volume and restores it when the queue finishes.
Do not select the TTS input itself. A forced process termination or power loss
cannot guarantee an OBS volume restoration.

## Advanced speech

Playground's Advanced SSML option is available for Polly and Windows voices.
Use a complete `speak` document. SSML controls rate, pitch and emphasis according
to the selected engine's supported tags. Unsupported tags and malformed XML are
rejected. Normal text mode never interprets chat messages as SSML.

Windows example:

```xml
<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="en-US">
  Hello <break time="300ms"/> there.
</speak>
```

Polly example:

```xml
<speak>Hello <break time="300ms"/> there.</speak>
```

The message limit also counts SSML markup. Some Polly engines support fewer tags
than others. VoiceStudio style instructions are separate from SSML.

## History and data

Replay selected plays the cached recording, including the original random
pronunciation. Save audio exports it to the folder selected in Settings. Only
the latest 30 generated recordings remain in the cache; older history rows can
remain after their recordings expire.

Settings provides backups, restore, reset and preset import/export. Restores and
imports create a backup first. Presets omit engine credentials. Backups retain
encrypted credentials, so keep them private.

Speaker.bot migration reads only the selected `voicealiases.dat`, previews
supported Polly aliases and lists skipped engines. Review devices and rate/pitch
after import. Multi-voice aliases import the first voice; unsupported engines are
skipped. Configure credentials separately.

Activity shows the latest speech events and application log. Export diagnostics
creates a ZIP without messages, keys, usernames or local paths. It does not include
raw logs. Update checks use GitHub Releases; private or unpublished releases may
be unavailable to unauthenticated checks.

## Compatibility

YapLoq supplies Speaker.bot-compatible commands and event subscriptions over
WebSocket, plus local HTTP and UDP commands. It has its own identity and does not
reproduce every Speaker.bot provider or feature.

See also [RELEASE_NOTES.md](RELEASE_NOTES.md), [LEGAL.md](LEGAL.md), and [ROADMAP.md](../ROADMAP.md).
