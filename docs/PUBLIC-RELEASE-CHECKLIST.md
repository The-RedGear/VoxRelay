# Public release checklist

Use this before flipping the GitHub repository from **private** to **public**
and before publishing a Windows Release build.

## License and notices

- [x] Root [`LICENSE`](../LICENSE) is MIT with current copyright holder
- [x] `pyproject.toml` declares `license = { text = "MIT" }`
- [x] [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) lists Inter OFL + deps
- [x] [`assets/INTER-LICENSE.txt`](../assets/INTER-LICENSE.txt) ships with fonts
- [x] [`docs/LEGAL.md`](LEGAL.md) covers MIT summary, trademarks, user duties
- [ ] Packaged `dist/VoxRelay` includes LICENSE + THIRD_PARTY_NOTICES + docs/LEGAL.md

## Security and secrets

- [x] `.gitignore` excludes `data/`, `.env`, AWS/Google credential patterns
- [x] No secret-like strings found in tree scan (re-run before release)
- [x] [`SECURITY.md`](../SECURITY.md) describes private reporting + DPAPI scope
- [ ] GitHub **Private vulnerability reporting** enabled on the repo
- [ ] Confirm `data/` was never force-added; scrub history if it was

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
- [ ] Release notes remind users that cloud TTS usage is billed by providers

## Pre-publish commands

```powershell
cd "R:\RedGear\[1] Applications\VoxRelay-src"
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
