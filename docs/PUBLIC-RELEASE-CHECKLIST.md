# Public release checklist

Use this before flipping the GitHub repository from **private** to **public**
and before publishing a Windows Release build.

## License and notices

- [x] Root [`LICENSE`](../LICENSE) is MIT with current copyright holder
- [x] `pyproject.toml` declares `license = { text = "MIT" }`
- [x] [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) lists Inter OFL + deps
- [x] [`assets/INTER-LICENSE.txt`](../assets/INTER-LICENSE.txt) ships with fonts
- [x] [`docs/LEGAL.md`](LEGAL.md) covers MIT summary, trademarks, user duties
- [x] Packaged `dist/VoxRelay` includes LICENSE + THIRD_PARTY_NOTICES + docs/ (incl. LEGAL.md) + root `LEGAL.md` / `RELEASE_NOTES.md` via `windows-build.yml`

## Version identity

- [x] `pyproject.toml` / `__version__` / `version_info.txt` / Settings UI all say **0.5.0**
- [x] [`docs/RELEASE_NOTES.md`](RELEASE_NOTES.md) drafted for the GitHub Release body
- [x] USER_GUIDE / CHANGELOG / README aligned to 0.5 preview

## Security and secrets

- [x] `.gitignore` excludes `data/`, `.env`, AWS/Google credential patterns
- [x] No secret-like strings found in tree scan (re-run before release)
- [x] [`SECURITY.md`](../SECURITY.md) describes private reporting + DPAPI scope
- [ ] GitHub **Private vulnerability reporting** enabled on the repo
- [x] Confirm `data/` was never force-added; tracked history checked before publication

## Community / collaboration

- [x] [`CONTRIBUTING.md`](../CONTRIBUTING.md) — PR rules + MIT grant
- [x] [`CODE_OF_CONDUCT.md`](../CODE_OF_CONDUCT.md)
- [x] Issue / PR templates under `.github/`
- [x] CI workflows for tests / Windows build
- [ ] Repo visibility set to **Public** when ready (currently private)
- [ ] Default branch protection + required PR reviews for `main` (recommended)

## Product disclaimers

- [x] README states no affiliation with Streamer.bot / Speaker.bot / cloud vendors
- [x] README warns about provider ToS and authorized voice use
- [x] Release notes remind users that cloud TTS usage is billed by providers

## Live gates (still manual)

- [ ] Import generated `.sb` actions and test Speak + queue controls
- [ ] Smoke Windows + VoiceStudio + at least one cloud provider from Playground and UDP
- [ ] Publish GitHub Release `v0.5.0-preview` with the Windows zip
- [ ] Flip repo to Public after the Release exists

## Pre-publish commands

```powershell
cd "path\to\VoxRelay"
git status
python -m pytest -q
# optional secret scan
# git grep -iE "AKIA[0-9A-Z]{16}|BEGIN PRIVATE KEY|xi-api-key"
```

Then publish a GitHub Release artifact built by `windows-build.yml` or a local
PyInstaller run that copies LICENSE and notices into the zip.

## After going public

- Watch Issues for credential paste accidents; delete and rotate immediately
- Keep dependency licenses updated when adding packages
- Do not accept PRs that remove LICENSE, notices, or DPAPI secret handling
