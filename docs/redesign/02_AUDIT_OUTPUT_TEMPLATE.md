# Codex audit deliverable — complete before implementation

## 1. Repository facts
- Commit/branch examined; framework, runtime, app entry points, state management, persistence, packaging.
- Actual supported providers, icon library and icon renderer, audio playback engine, Streamer.bot transport and supported calls.
- Tests/build commands and current baseline results.

## 2. Existing feature inventory
For **every** page, section, dialog, control, setting, menu and important action provide:
| Existing location | File/symbol | Actual behavior | Proposed home | Keep / Move / Merge / Rework / Remove | Risk / migration |
|---|---|---|---|---|---|

## 3. Proposed navigation and interaction map
Show all six top-level pages and the subsections/actions, plus persistent player, context menus, side panels, separate editors and shortcut routes. Mark each feature's **one canonical owner**.

## 4. End-to-end journeys
For each journey show entry point, user steps/clicks, resulting state, persistence, error/fallback and exit/return context:
- First launch -> connect provider -> create voice -> preview/test.
- Favorite in voice editor -> heart filter in list.
- Paste MDI identifier -> preview -> save -> reload.
- Create playlist -> configure selection -> set default.
- Assign viewer default manually and from message context.
- Viewer uses Streamer.bot `!voice` command -> validate -> acknowledge -> future TTS -> reset.
- Queue skip/reorder -> history replay -> explain failure.
- Provider credentials failure vs Streamer.bot failure vs output device failure.
- Emergency stop while navigating across pages.

## 5. Data/API changes and migration
Inventory schemas and settings for voices, favorites, icons, playlists, viewer assignments, aliases, rules, queue/history, provider credentials. Specify backward-compatible migration, backup, rollback, idempotency, stable IDs, default values, and error handling. State whether a change is optional/new or a migration of existing data.

## 6. Risks / unresolved decisions
List only decisions requiring owner input; include recommended defaults and consequences. Verify provider-specific capabilities and Streamer.bot API constraints rather than inventing them.

## 7. Implementation plan
PR-sized phases with file groups, dependencies, test strategy, acceptance criteria, and a clear no-regression checkpoint. Stop for approval before implementation.
