# Provider adapters

`providers.py` is the shared registry for voice discovery and synthesis. Register
a Provider with a unique key, display name, settings-aware factory, enabled
predicate and capability tuple. Adapters implement `list_voices()` and
`synthesize_wav(text, alias)`.

Discovery returns dictionaries containing `voice_id`, `name`, `provider`, `model`
and `language`. Optional `engines` and `language_name` describe provider-specific
choices. Synthesis returns a complete WAV; device playback belongs to VoxRelay.
Never play audio directly in a provider, or one request can produce two outputs.

Use bounded network timeouts. Generation cancellation discards a cancelled result
and allows the queue to advance, with at most two unresolved requests. Providers
should release streams and support cancellation themselves where practical.

Provider-specific settings belong on a service page. Store sensitive values with
Windows DPAPI, and omit them from preset exports and diagnostics. Unknown provider
keys must produce a useful error rather than silently selecting another engine.

The registry is a developer extension point; arbitrary downloaded plugin files
are not executed automatically. Add adapters in code and test discovery failure,
invalid audio, authentication failure, cancellation and voice selection.

Built-in engines (each has a Services page unless noted):

- `voicestudio` — local VoiceStudio HTTP API
- `polly` — Amazon Polly (`boto3`)
- `windows` — installed Windows SAPI voices (Settings toggle)
- `elevenlabs`, `azure`, `google`, `watson`, `uberduck`, `ttsmonster`, `acapela`, `cereproc` — cloud REST adapters

Built-in references:

- [AWS Session credentials](https://docs.aws.amazon.com/boto3/latest/reference/core/session.html)
- [AWS Polly API](https://docs.aws.amazon.com/boto3/latest/reference/services/polly.html)
- [Windows SpeechSynthesizer](https://learn.microsoft.com/en-us/dotnet/api/system.speech.synthesis.speechsynthesizer)
- [OBS WebSocket protocol](https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md)
- [OpenSpeaker](https://github.com/EvaisaDev/OpenSpeaker) (MIT) — interoperability reference for several cloud APIs

Legal and trademark notes: [LEGAL.md](LEGAL.md). Third-party licenses:
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
