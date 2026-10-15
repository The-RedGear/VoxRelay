# Third-party notices

This file lists third-party material distributed with VoxRelay or used to build
it. VoxRelay itself is licensed under the MIT License (see [`LICENSE`](LICENSE)).

## Bundled assets

### Inter typeface

VoxRelay includes the **Inter** typeface by Rasmus Andersson.

- License: SIL Open Font License, Version 1.1
- Full text: [`assets/INTER-LICENSE.txt`](assets/INTER-LICENSE.txt)


### Material Symbols (Pictogrammers / Google)

UI glyphs are from the [Material Symbols](https://icones.js.org/collection/material-symbols) /
Material Design Icons collection (Apache License 2.0).

- Icons: Apache-2.0 — https://www.apache.org/licenses/LICENSE-2.0
- Source browse: https://icones.js.org/collection/mdi and Material Symbols sets on Iconify

## Python dependencies

Runtime and build dependencies retain their own licenses. Packaged releases may
include wheels or compiled modules from these projects. Check each package's
metadata for the authoritative license text.

| Package | Typical license | Role |
|---|---|---|
| boto3 / botocore | Apache-2.0 | Amazon Polly API client |
| miniaudio | MIT-style (see package) | Audio decode / playback |
| websockets | BSD-3-Clause | WebSocket server |
| google-auth (optional) | Apache-2.0 | Google Cloud service-account auth |
| PyInstaller (build) | GPL-2.0-or-later with Bootloader exception | Windows packaging |
| pytest (dev) | MIT | Tests |
| cffi (build/runtime helper) | MIT | Native bindings used by audio stack |

Exact versions are pinned by your install environment or release build.

## External services (not redistributed)

VoxRelay can call third-party speech APIs. Those services are **not** part of
this repository. Using them requires your own accounts and acceptance of each
provider's terms, including but not limited to:

- Amazon Web Services / Amazon Polly
- Microsoft Azure Cognitive Services Speech
- Google Cloud Text-to-Speech
- ElevenLabs
- IBM Watson Text to Speech
- UberDuck
- TTS.Monster
- Acapela Group cloud TTS
- CereProc / CereVoice cloud TTS
- Local VoiceStudio instances you operate
- Streamer.bot / Speaker.bot integrations you configure

API request shapes for several cloud engines were cross-checked against public
documentation and against [OpenSpeaker](https://github.com/EvaisaDev/OpenSpeaker)
(MIT License) as an interoperability reference. VoxRelay does not redistribute
OpenSpeaker source code.

## Trademarks

Product and company names above are trademarks of their respective owners.
Use of those names is for identification only. See [`docs/LEGAL.md`](docs/LEGAL.md).
