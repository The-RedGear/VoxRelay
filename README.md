# VoxRelay

**Voice automation for streamers.**

VoxRelay is a Windows desktop TTS bridge built for Streamer.bot workflows. It
combines multiple voice providers, friendly voice aliases, pronunciation and
moderation rules, queue management, audio routing, playback history, and
Streamer.bot lifecycle actions in one application.

## Highlights

- VoiceStudio cloned voices and Amazon Polly
- Per-alias voice, model, speed, volume, language, style, and group settings
- Dedicated playback queue with pause, resume, skip, reorder, and clear controls
- Pronunciation dictionary with randomized alternatives and optional censorship
- Message moderation for links, commands, mentions, emoji, ASCII art, and more
- Streamer.bot actions for generated, queue-added, playback-started, and finished states
- Configurable delays before playback and after queue completion
- Separate stream and preview audio devices
- Local HTTP, WebSocket, and UDP integrations

## Download

End users should download the latest Windows package from the repository's
**Releases** page. Extract it and run `VoxRelay.exe`; Python is not required.

## Provider setup

Open **Services** inside VoxRelay and configure at least one provider:

- **VoiceStudio:** normally available locally at `http://127.0.0.1:3900`.
- **Amazon Polly:** enter an AWS region, Access Key ID, and Secret Access Key.
  VoxRelay encrypts saved keys with Windows DPAPI so they can only be decrypted
  by the same Windows account on the same computer.

Never commit a populated `data` directory or AWS credentials to Git.

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

## License

VoxRelay is available under the [MIT License](LICENSE).
