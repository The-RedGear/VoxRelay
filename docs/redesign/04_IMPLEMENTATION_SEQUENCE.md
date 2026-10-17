# Approved-order implementation sequence (subject to audit findings)

## Phase 0 — Audit and baseline (no UI rewrite)
Document code, feature relocation, user flows, actual MDI renderer, persistence, Streamer.bot APIs, tests and migration needs. Run existing tests/build. Obtain owner approval.

## Phase 1 — Foundation and shell
Define reusable design tokens, navigation, consistent icon/button/input/menu/panel patterns, layout density, page state restoration and shared data access. Six top-level routes. No mock controls.

## Phase 2 — Live operation
Persistent three-zone player; shared playback state; minimal Dashboard; Queue/History with existing queue controls, contextual actions and safe emergency stop. Avoid duplicate player functionality.

## Phase 3 — Voices
Consolidate editor/list and favorites; optional MDI identifier; playlists; viewer assignments; voice rules and pronunciation; aliases and permissions; migration and tests. Avoid forcing a provider wizard for routine voice edits.

## Phase 4 — Services and Integrations
Provider list/editors with real status/credentials tests. Streamer.bot configuration, action/event selection and variable mapping. Add viewer voice command contract only after validating actual transport and import/export possibilities.

## Phase 5 — Settings and polish
Global/audio settings relocation, keyboard shortcuts, search/command palette if feasible, context menus, density, diagnostics, backups and robust empty/error states.

## Release gate
Compare every feature from audit against final implementation; verify migrations, restart persistence, Windows packaging, accessibility, provider failure, Streamer.bot disconnection, live playback safety and regression tests. No lost functionality and no placeholder UI presented as functional.
