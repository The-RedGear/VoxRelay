# In-app updates

The title-bar update icon opens the single update window. Mint means a newer
release is available. Downloads run in the background. A downloaded update is
kept when the window or app is closed. Restart is always a user choice.

If speech is active, schedule the update after the current speech and waiting
queue finish. New requests postpone that restart. Reopen Updates to cancel it.
The backend atomically checks idle state and stops admission before installation;
it never clears a live queue to install an update.

Settings are backed up before closing. The external Windows helper waits for the
desktop, launcher and backend to exit, backs up replaced files and core user data,
applies the staged package, and checks both backend identity/version and desktop
readiness. A startup or copy failure attempts rollback and reports its outcome.
Backups remain under the app data folder's `updates/<id>/rollback` directory.
No installer elevation or duplicate user-facing executable is required. A
read-only installation must be moved to a writable folder before applying.

## Release publishing contract

- Source: `https://api.github.com/repos/The-RedGear/YapLoq/releases?per_page=100`.
- Stable receives published non-prerelease versions `vMAJOR.MINOR.PATCH`.
- Preview receives GitHub prereleases with `-preview.N`, `-beta.N`, or `-rc.N`.
- Drafts, other channels, same versions and older versions are not upgrades.
- Upload exactly `YapLoq-Windows-x64-update.zip` for stable, or
  `YapLoq-preview-Windows-x64-update.zip` for preview, as a **release asset**.
- The package version/channel must match the release tag. Include the bundled
  `update-manifest.json` created by `tools/package_update.py`. Do not rename a
  stable build to a preview build or publish a CI artifact wrapper ZIP.
- GitHub's asset metadata must expose a SHA-256 `digest`. The app checks size,
  hash, manifest, safe paths and channel before installation. Old releases with
  no compatible verified asset still show notes, but cannot be installed in-app.
- Release notes come from the GitHub Release body and are displayed as text,
  never executable HTML. Include any migration warnings there.
- The release should be public. API failures/private repositories are reported
  as unavailable, not as "up to date". No GitHub credentials are requested.

The build workflows prepare ZIP artifacts only. They **do not publish releases**
and have no release-write permission. Download the actual update ZIP from the
artifact and attach it when explicitly publishing a matching GitHub Release.
Version the source before a stable build. Preview CI supplies an ordered
`<source-version>-preview.<run-number>` package version automatically.

SHA-256 obtained through GitHub HTTPS verifies download integrity and the trusted
release asset, not independent publisher signing. Signed Windows distribution
remains a separate release requirement. Never publish an untrusted build.

## Validation

`tests/test_updates.py` covers release selection, unsafe archives, verification,
download persistence and idle admission. `tests/test_update_helper.py` runs the
real Windows helper on disposable installations, including startup rollback and
data preservation. `tests/test_updates_ui.ps1` covers the desktop window states.
Before public rollout, test an actual signed/versioned release update on Windows
with streaming integrations, locked files, interrupted downloads and real audio.
