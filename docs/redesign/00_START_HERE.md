# YapLoq Codex — Start Here

You are working in the **actual YapLoq/VoxRelay repository**, not a hypothetical application. Read `01_PRODUCT_SPEC.md` in full. This brief records product decisions from the owner; it does not assert that any proposed feature or API already exists.

## Your first assignment: audit, do not redesign yet
1. Inspect README, app startup, UI framework and layout, dependencies, icon rendering, services/providers, voice data models, favorites, playlists, viewer voice preferences, rules, queue/history, audio playback, Streamer.bot integration, configuration, storage, tests, packaging and release setup.
2. Identify actual filenames, components/classes, and current behavior. Cite source paths and symbols in your report. Do not assume the old VoxRelay name has already been migrated to YapLoq.
3. Produce the deliverables in `02_AUDIT_OUTPUT_TEMPLATE.md` and compare the repository against `01_PRODUCT_SPEC.md`.
4. Identify features already implemented, missing, incomplete, duplicated, or at risk. Distinguish confirmed code findings from proposals.
5. Do **not** remove working features, rewrite storage, or change external contracts until the audit and migration plan have been reviewed.
6. Stop and request approval for the proposed navigation, data migrations, and phased implementation plan. Ask only questions that materially block a decision.

## Product requirements that must not drift
- Top-level sidebar exactly: **Dashboard, Voices, Queue, Services, Integrations, Settings**. No extra top-level entries.
- Spotify-inspired persistent bottom player on every page; no duplicate oversized player on Dashboard.
- Compact dashboard for live operation, not statistics or administrative settings.
- **Voices** owns voice editing, playlists, favorites, viewer voice assignments, voice selection rules and pronunciation. **Queue** owns queue/history and message admission/moderation rules.
- Favorites: one heart **filter** in voice list; favorite status set in voice Add/Edit. Preserve existing favorites through migration.
- Voice icons: reuse **existing MDI icon renderer**, not Lucide. Optional MDI icon identifier, default `mdi:music-note`, live preview, validation/fallback, link to https://icones.js.org/collection/mdi. No custom profile photos.
- Viewer default voices are persisted in YapLoq and can be changed via a proposed structured Streamer.bot request. Verify the actual transport and supported API before implementing. Stable platform user IDs, alias/public permission validation, acknowledgments, reset.
- **Services** owns TTS providers and credentials; **Integrations** owns Streamer.bot connections/events/actions/mapping; **Settings** owns app/audio/global preferences.
- Right-click contextual actions, icon-first controls with labels where necessary, keyboard accessibility, low click counts, clean density, no nested-tab maze.
- Existing working functionality, user settings and stored data must be preserved.

## Workflow
**Audit → Owner approval → Foundation/shell → Queue/player → Voices → Services/Integrations → Settings/polish → Regression verification.** Work in small, reviewable steps. For each step: explain changed files, decisions, migrations, test results, limitations and screenshots when possible. Do not claim a control works unless it is wired to real behavior.
