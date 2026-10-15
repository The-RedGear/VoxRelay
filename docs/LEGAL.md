# Legal notes for VoxRelay

This document is practical guidance for maintainers and users. **It is not legal
advice.** If you need counsel for your jurisdiction or commercial use, talk to a
lawyer.

## Software license (MIT)

VoxRelay is released under the [MIT License](../LICENSE). In plain terms (see
also [common open-source license primers](https://dev.to/buildwebcrumbs/explain-like-im-five-licenses-for-open-source-projects-16ob)):

- Others may use, copy, modify, and distribute VoxRelay, including commercially.
- They must keep the copyright notice and MIT permission notice.
- The software is provided **AS IS**, without warranty.
- Authors are not liable for damages arising from use of the software.

Contributions submitted to this repository are accepted under the same MIT
License (see [`CONTRIBUTING.md`](../CONTRIBUTING.md)).

### Why MIT for this project

MIT is a permissive license: it keeps attribution requirements while allowing
streamers and tool authors to integrate VoxRelay without forcing their own
projects to become copyleft (unlike GPL). If you fork VoxRelay, keep the MIT
notice in redistributed source and binary packages.

## No affiliation

VoxRelay is an independent project. It is **not** affiliated with, endorsed by,
or sponsored by:

- Streamer.bot
- Speaker.bot
- Amazon / AWS
- Microsoft / Azure
- Google
- ElevenLabs
- IBM
- UberDuck
- TTS.Monster
- Acapela
- CereProc
- OBS Project
- VoiceStudio, or any other third-party product named in the UI or docs

Names and logos of those products are used only to describe compatibility or
configuration steps.

## Your responsibilities when using VoxRelay

You are responsible for:

1. **Credentials** — API keys, passwords, overlay URLs, and service-account files
   you enter. Do not commit them. VoxRelay stores secrets with Windows DPAPI for
   the signed-in Windows user on that machine only.
2. **Provider terms** — Each cloud TTS provider has its own Terms of Service,
   acceptable-use, and pricing rules. Enabling an engine in VoxRelay does not
   grant you rights beyond those terms.
3. **Voice and likeness rights** — Only use voices, clones, and recordings you
   own or are licensed/authorized to use. Unauthorized voice cloning or
   impersonation may violate law and provider rules.
4. **Content you synthesize** — Chat text, moderation choices, and playback on
   stream are your responsibility.
5. **Local data** — Settings, history, logs, and generated audio under your
   `data` folder are local runtime data, not part of the open-source release.

## Redistributing builds

If you redistribute VoxRelay binaries or source:

- Include [`LICENSE`](../LICENSE).
- Include [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) (and the Inter
  OFL file when fonts are bundled).
- Do not strip copyright or attribution notices.
- Do not imply endorsement by The-RedGear or by any third-party trademark owner.

## Security reports

See [`SECURITY.md`](../SECURITY.md). Do not file public issues that include live
credentials or private user data.

## Collaboration on GitHub

Public contribution uses normal Git collaboration: forks, branches, and pull
requests reviewed before merge (see
[Git collaboration overview](https://www.geeksforgeeks.org/git/what-is-collaboration-in-git/)
and [`CONTRIBUTING.md`](../CONTRIBUTING.md)). Maintainers may decline changes
that weaken security, licensing, or user-data protections.
