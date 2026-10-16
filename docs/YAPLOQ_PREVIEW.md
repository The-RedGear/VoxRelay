# YapLoq preview branch

This preview includes isolated runtime boundaries, six-page navigation, a purple
Dashboard with clear speech/setup actions, Queue/History and the persistent player.
Production `main`, `VoxRelay.spec` and both existing workflows are unchanged.

## Run from source

Use Windows, PowerShell 5.1 and Python 3.12. Create a repository-local `.venv`,
install `requirements-preview.txt`, then install the project with
`python -m pip install --no-deps --no-build-isolation -e .`.
Run `.venv\Scripts\python.exe yaploq_preview.py` from the repository root.
Use the dedicated preview entry point; `wpf_launcher.py` retains the production path.

## Build

```
python -m PyInstaller --noconfirm --clean --distpath dist-preview --workpath build-preview YapLoq-preview.spec
```

Keep the complete `dist-preview/YapLoq-preview` directory. The executable needs
its `_internal` folder. Preview runtime data lives in `data-preview` beside the
executable (or in the source checkout during development). It does not import
production settings, history, credentials or recovery queues automatically.

Preview uses loopback HTTP 17582 and WebSocket 17581. UDP, Streamer.bot lifecycle
actions, OBS ducking, queue recovery and production update checks are disabled.
These restrictions are enforced on every settings load, including backup/profile
reload. The preview data path deliberately ignores `VOXRELAY_DATA_DIR`.
Cloud providers can be configured manually for testing and may incur provider costs.

Desktop/backend mutexes, Restore/BackendStop events, taskbar identity and tray
tooltip are separated from VoxRelay. Preview never kills VoxRelay.Tray or modifies
production tray registry entries. The launcher only opens the shell after both
preview servers are ready and a fresh launch identifier matches. A port occupied
by an unrelated service causes startup to fail rather than attach to it.

The player uses the existing real playback/seek/queue handlers. Ctrl+Shift+S stops
playback and clears waiting speech. Queue and Audio shortcuts open their canonical
pages. Dashboard speech and existing voice tests still use the shared playback
queue; independent preview playback is not implemented in this slice. Global
volume still lives in Settings and is applied by the existing engine when audio
is decoded; no instantaneous volume slider is claimed.

## Verification

- `python -m pytest -q`
- `powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File tests/test_wpf_functions.ps1`
- `powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File tests/test_history_rules_ui.ps1`
- `powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File tests/test_branding.ps1`
- `powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File tests/smoke_wpf.ps1`
- `powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File tests/test_yaploq_shell.ps1`

The shell test can render screenshots with `-OutputDirectory <folder>` without
starting a real speech backend. Screenshots are UI verification, not evidence of
successful cloud-provider or Streamer.bot calls.

## Remaining slices

Voice editor/favorites/MDI identifier support, stable viewer preferences,
playlist rotation extensions, SetViewerVoice and permission/acknowledgment
contracts, settings consolidation and full accessibility polish remain separate
changes. Legacy rule precedence and serialized keys are preserved here. Windows
voice enablement now has a dedicated editor in the Services dropdown. Rules are
one workspace under Queue, covering voice selection, routing, message filtering
and queue limits. The old voiceRules route redirects to this same workspace.
No schema/API migration, release publication, production updater change or tag
is part of this slice. Live production/preview coexistence, audio-device behavior
and Streamer.bot still require manual verification.

## Navigation and motion update

Services opens to a short setup guide. Its persistent dropdown selects a provider;
Back to setup and the sidebar Services button return directly to the guide.
Selection changes queue a page transition after the input event completes, and
the picker is retained rather than rebuilt inside its own SelectionChanged event.
Page navigation is guarded against re-entry. Failed navigation preserves the
previous page and writes details to `data-preview/ui-errors.log`.

Hover/focus styling, section transitions, stronger page entrances and queue-change
reveals are included. Motion respects the Windows animation preference.
The shell regression test exercises 132 provider selections plus repeated sidebar
clicks and hover events, verifies direct back navigation and failed-route recovery.

## Branding

Keep the original microphone logo mark in the title bar, sidebar, About area and
app/tray icons, paired with the YapLoq name. Dashboard copy describes text-to-speech
directly: “Turn text into speech.” Action icons inherit their button foreground
so accent buttons and selected navigation retain the correct contrast.
