# VoxRelay

![VoxRelay](assets/branding/1x/GitHub.png)

**Voice automation for streamers.**

VoxRelay is a Windows desktop TTS bridge built for Streamer.bot workflows. It
combines multiple voice providers, friendly voice aliases, pronunciation and
moderation rules, queue management, audio routing, playback history, and
Streamer.bot lifecycle actions in one application.

## Highlights

- VoiceStudio, Windows SAPI voices, Amazon Polly, ElevenLabs, Azure, Google Cloud TTS, IBM Watson, UberDuck, TTS.Monster, Acapela, and CereProc
- Per-alias voice, model, speed, volume, language, style, and group settings
- Dedicated playback queue with pause, resume, skip, reorder, and clear controls
- Pronunciation dictionary with randomized alternatives and optional censorship
- Message moderation for links, commands, mentions, emoji, ASCII art, and more
- Streamer.bot actions for generated, queue-added, playback-started, and finished states
- Configurable delays before playback and after queue completion
- Separate stream and preview audio devices
- Local HTTP, WebSocket, and UDP integrations
- Priorities, expiry, duplicate detection and optional paused queue recovery
- Ordered routing, favorites, profiles, backup/restore and preset sharing
- Optional OBS audio ducking, normalization, fades and output tests
- Live event inspector and private diagnostic exports

**0.5.0-preview** is the current public preview (unsigned Windows build). See
[release notes](docs/RELEASE_NOTES.md), [the user guide](docs/USER_GUIDE.md),
[Streamer.bot recipes](docs/STREAMERBOT.md), [provider adapters](docs/PROVIDERS.md),
[legal notes](docs/LEGAL.md), and the [remaining release roadmap](ROADMAP.md).

Cloud TTS usage is billed by each provider. Only use voices you are authorized to use.

## Download

[Download VoxRelay 0.5.0 preview for Windows](https://github.com/The-RedGear/VoxRelay/releases/download/v0.5.0-preview/VoxRelay-0.5.0-preview-Windows.zip)

Extract the complete folder and run `VoxRelay.exe`; Python is not required.
This is an unsigned preview build. See the [release notes and checksum](https://github.com/The-RedGear/VoxRelay/releases/tag/v0.5.0-preview).

## Provider setup

Open **Services** inside VoxRelay and configure at least one provider:

- **VoiceStudio:** normally available locally at `http://127.0.0.1:3900`.
- **Amazon Polly / ElevenLabs / Azure / Google / Watson / UberDuck / TTS.Monster / Acapela / CereProc:**
  each has its own page under **Services**. Secrets are encrypted with Windows DPAPI for this Windows account.

For speech without an account, choose **Windows voices** on the Settings setup card.
Temporary AWS credentials can also include a session token.
The Windows download includes Google service-account support. Source installs need
the optional `google-auth` package (`pip install ".[google]"`); an API key works without it.

Never commit a populated `data` directory, API keys, or service-account JSON to Git.
You must comply with each provider's Terms of Service and only use voices you are authorized to use.

## Streamer.bot

For Speaker.bot-compatible WebSocket events, configure Streamer.bot with:

- Address: `127.0.0.1`
- Port: `7581`
- Auto Connect: enabled
- Auto Reconnect: enabled

The **Streamer.bot** page in VoxRelay also provides copyable UDP commands and
optional lifecycle actions.

## Build from source

Requirements: Windows 10/11, Python 3.10 or newer, and PowerShell 5.1 or newer.

```powershell
py -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -e . pytest pyinstaller cffi
.\.venv\Scripts\python.exe -m pytest
.\.venv\Scripts\python.exe -m PyInstaller --noconfirm --clean VoxRelay.spec
```

The packaged application will be created under `dist\VoxRelay`.

## Contributing

Bug reports, feature requests, and pull requests are welcome. Read
[`CONTRIBUTING.md`](CONTRIBUTING.md) before submitting a change.

## Privacy and responsible use

VoxRelay runs locally. User settings, logs, generated audio, and history are
runtime data and are intentionally excluded from this repository. Only use
voices and credentials you own or are authorized to use.

VoxRelay is **not affiliated with** Streamer.bot, Speaker.bot, Amazon, Microsoft,
Google, ElevenLabs, IBM, or other named providers. Compatibility labels are for
configuration only. See [`docs/LEGAL.md`](docs/LEGAL.md).

## License

VoxRelay is available under the [MIT License](LICENSE). Third-party fonts,
libraries, and service trademarks are described in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and [`docs/LEGAL.md`](docs/LEGAL.md).

## Community

- [`CONTRIBUTING.md`](CONTRIBUTING.md) — issues and pull requests
- [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) — community standards
- [`SECURITY.md`](SECURITY.md) — private vulnerability reports
