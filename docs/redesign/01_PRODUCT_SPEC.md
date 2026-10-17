# YapLoq — Final UI/UX Redesign Brief for Codex

## Mission
Redesign YapLoq as a polished, compact, fast Windows TTS control application for streamers. The highest priority is **clear information architecture and task flow**, not adding visual decoration. Preserve working functionality, data, and integrations. **Audit the repository before implementation; this document describes desired behavior, not confirmed existing code.**

## Mandatory first pass: inspect, report, plan
1. Read the actual repository, README, dependencies, UI entry points, state/data models, TTS providers, voice preset/favorites logic, queue/history, Streamer.bot transport/actions, settings, audio routing, persistence, and tests.
2. Inventory every current screen, tab, setting, action, popup, and context menu. Produce a **Keep / Move / Merge / Rework / Remove** mapping; identify features that would otherwise be lost.
3. Map primary user journeys: first launch; connect a provider; create/test/edit a voice; favorite/filter; make a playlist; assign a viewer's default voice; viewer sets voice in chat; send/test speech; operate live queue; replay history; diagnose provider/connection/audio issues.
4. Identify technical constraints, migrations, unsupported capabilities, and ambiguities. Do not invent APIs or assume Streamer.bot supports a particular installation mechanism.
5. Present proposed screen map and phased implementation plan before large destructive refactors. Keep functionality working incrementally.

## Navigation — exactly six single-word top-level destinations
- **Dashboard** — operate TTS live.
- **Voices** — create, customize, organize, and assign voices.
- **Queue** — queued speech, history, message-specific controls, moderation/rules.
- **Services** — TTS providers, credentials, provider availability/quotas where available.
- **Integrations** — Streamer.bot and external communication, actions, variable mapping, events, chat commands.
- **Settings** — app-wide audio output/routing, appearance, startup, shortcuts, updates, backups, diagnostics.

Use a compact sidebar. Avoid nested sidebar trees and tabs-within-tabs. Subsections may use a compact section switcher when necessary, with no more depth than justified. The **persistent bottom player** is visible on every destination.

## Design and interaction principles
- Desktop-native, dark YapLoq styling: primary #B6A3FF, hover #C9BCFF, pressed #9580ED; background #15131D; raised #1E1A27; secondary #282231; border #50485C; text #F6F3FA; muted #B9B2C2; success #62DDB3; warning #F2C879; error #F08092.
- **Use the project's existing Material Design Icons (MDI) system**, with icon browsing at https://icones.js.org/collection/mdi. Do not introduce Lucide or a second icon library.
- Icons on all actions. Icon-only for unmistakable contextual actions (play, pause, skip, edit, delete, search, favorite filter); icon + short text when ambiguity exists (Add Voice, Map Variable, Test Connection, etc.). Tooltips and accessible labels for icon-only controls.
- Compact, efficient, restrained. No oversized cards, decorative statistics, redundant headings, duplicated player panels, repetitive explanatory copy, profile portraits, or ornamental empty states.
- One canonical home per setting/feature, with contextual shortcuts to that same implementation; no duplicate sources of truth.
- Frequent live actions one click; typical edits two or three interactions. Right-click context menus plus discoverable alternatives, inline editing, compact popovers, keyboard shortcuts, Ctrl+K search if feasible, drag/reorder where appropriate, undo for reversible destructive actions.
- Quick actions stay in place; moderate editors use side panels; complex workflows use focused resizable windows. Restore window positions, page/filter/scroll state; don't discard edits without warning.
- Comfortable/Compact density options, responsive desktop layout, clear focus and keyboard navigation, sensible errors/empty states, confirmation only for high-risk operations.

## Dashboard — operate, don't administer
- Minimal live control surface: compact active/default voice picker, test-speech input, short upcoming-queue preview, concise connection/service status.
- Player controls **only** in the persistent bottom player, not duplicated in a giant Now Playing card.
- Do not put voice galleries, playlist editors, full history, provider credentials, integration mappings, vanity statistics, or a large quick-actions grid here.
- Empty queue: concise 'Queue empty' state with useful next action; disconnected state: direct reconnect/troubleshoot shortcut.
- Dashboard queue preview shares the canonical queue state; opening full queue takes user to Queue page.

## Persistent bottom player
- Spotify-inspired, compact three-zone layout: left current speaker/message/voice; center play/pause/skip/stop and playback progress; right queue shortcut, output, volume/mute.
- Always available on all six pages. Prominent emergency stop/mute; live-safe behavior.
- Show seek controls only if the playback engine actually supports seeking; otherwise show read-only progress.
- Voice preview/test must not unexpectedly interrupt or enter live queue; distinguish preview playback from live TTS.
- Queue button opens Queue page on active queue view.

## Voices — all voice customization lives here
Suggested internal sections: **Voices / Playlists / Viewers / Rules / Pronunciation**. Keep them shallow and task-based.

### Voice list and editor
- Searchable compact list/rows; add, edit, duplicate, delete, preview; filters and multiselect/bulk actions where helpful.
- **Favorites:** ONE heart filter button in the list (on/off). Favorite status is edited in the Add/Edit Voice editor, not via multiple redundant favorite/unfavorite buttons. Optional noninteractive favorite indicator in rows. Single persisted `isFavorite` concept, with migration from current behavior if needed.
- **Voice icons:** no profile images, custom avatars, image uploads, or cropping. Optional MDI icon identifier in Add/Edit Voice; default `mdi:music-note`. Show live preview; validate against the project's actual supported icon loader and fall back gracefully. Small link labeled 'Browse icons' to https://icones.js.org/collection/mdi. Accept/normalize copied MDI identifiers if technically feasible, never execute pasted SVG/JS code. Store icon ID only.
- Voice editor owns name, provider/model selection, supported speed/pitch/volume/style parameters, icon, favorite, chat alias/public availability as applicable. Hide unsupported provider controls rather than pretending they work.
- Keep provider credentials in Services, with contextual 'Configure service' link.

### Playlists
- Reusable collections referencing saved voice presets, not copies. Random, sequential, weighted modes where feasible; optional no-immediate-repeat. Define behavior for unavailable voices, deletion, empty playlists, and selection scope (per message vs viewer).
- Playlist creation/editing remains in Voices. Playlists can be assigned as defaults or via rules.

### Viewer voice assignments
- Searchable viewer list with stable platform + user ID, display name, assigned voice/playlist, reset/clear action, source/reason inspection.
- Voice preference persists across restarts. Handle rename, duplicate display names, deleted/unavailable voices, and reset to channel default.
- Right-click message can offer 'Set viewer's default voice' without duplicating assignment state.

### Voice rules and pronunciation
- Voice rules determine **how a message sounds**: viewer/role conditions, selection of preset/playlist, defaults/fallbacks. Pronunciation dictionary with global and per-voice overrides if supported.
- Message admission/moderation/cooldowns/priority rules do **not** live here; those belong in Queue.

### Proposed voice precedence (verify against existing behavior and agree before migration)
1. Explicit per-message voice override.
2. Saved viewer preference.
3. Applicable voice-selection rule.
4. Default preset or playlist.
5. Fallback available voice.

Expose 'Why this voice?' on message detail. Voice config changes affect future speech; playing speech remains unchanged. Define whether already-queued speech retains its resolved voice (recommended: yes unless explicitly reassigned).

## Queue — live queue and history together
- Single top-level **Queue** page with simple **Queue / History** switch, not separate sidebar entries.
- Queue: now speaking, upcoming messages, reorder/prioritize, skip, remove, change message voice, inspect details. History: completed/skipped/failed, search/filter, replay/requeue, failure reason.
- Rich context menu: replay, prioritize, change voice, assign viewer default, copy, remove, details as applicable. Keep inline primary actions discoverable.
- Message rules/moderation (cooldowns, filtering, priority/fairness, expiration) belong here, with compact access to rule editor; avoid confusing message rules with voice rules.
- Distinguish live queue state from persistent history storage/retention; do not blindly merge their data lifecycle.
- Shared queue model between dashboard preview, Queue page, and player.

## Services — provider management
- Dedicated overview listing actual supported TTS providers and status. Do **not** invent installed providers or claim fake availability.
- Each provider has focused editor for enable/disable, credentials, connection test, provider-specific configuration, capabilities, quotas/cost if exposed, and error troubleshooting.
- Do not put individual voice tuning, playlist assignments, or audio output devices here.
- Clear shortcut from a voice's editor to the relevant provider config; return to previous context afterward.

## Integrations — external communication
- Streamer.bot connection state/config, event/action selection, variable mapping, viewer chat voice commands, and event triggers in one coherent workspace. Search actions rather than manually entering IDs when API supports it.
- Progressive disclosure: simple templates for common workflows, advanced argument mapping and conditions only when needed.
- Propose a **SetViewerVoice** request contract with platform, stable user ID, display name, and requested voice/alias/preset ID. YapLoq validates allowed voice, persists preference, and returns success/failure; Streamer.bot handles chat command trigger and response.
- Example viewer chat: `!voice amy`, `!voice random`, `!voice reset`; actual command names and permissions configurable. Public chat aliases must be distinct, validated, and restrictable (e.g. private or costly voices not automatically exposed).
- Treat structured request/argument mapping as the interface; do not infer semantics from arbitrary variable names. Confirm actual transport and Streamer.bot API capabilities before implementation. Do not promise automatic action installation/import unless verified; provide a documented manual setup or generated action export as appropriate.
- Distinguish connection acknowledgment from confirmed action completion; provide actionable errors.

## Settings — application-wide preferences only
- Audio output/routing, monitor vs broadcast where supported, volume/limiting, hot-swap behavior, app startup/tray, update channel, appearance/density, shortcuts, storage/backup/export, diagnostics/logs.
- Keep provider credentials in Services; voice tuning in Voices; Streamer.bot mapping in Integrations; message rules in Queue.
- Quick volume/output control available in bottom player but opens canonical Settings audio configuration for advanced changes.

## Core user journeys / acceptance tests
1. New user can connect a service, create a voice, preview it, and speak a test without encountering Streamer.bot-specific settings.
2. User finds a voice, marks it Favorite in editor, then filters list with ONE heart filter; persists on restart.
3. User pastes a valid MDI icon identifier into voice editor; preview renders; invalid code safely falls back to music note; browse link opens correct MDI collection.
4. User builds playlist, selects rotation, sets it as default, and receives predictable fallback when voice unavailable.
5. User assigns a viewer default voice from Voices and from a message context shortcut; both update the same persisted assignment.
6. Streamer.bot viewer command requests voice by alias, YapLoq validates/acknowledges, future speech uses selection; reset works; invalid/private voice rejected clearly.
7. User can skip/reorder a queued message and replay a history message quickly, without navigating to Settings.
8. User can fix broken provider credentials in Services; broken Streamer.bot connection in Integrations; output device issue in Settings > Audio.
9. Dashboard remains uncluttered at typical laptop and desktop sizes; persistent player is visible and functional on every page.
10. Keyboard navigation, tooltips, focus, accessible contrast, state persistence, and live emergency stop are tested.
11. No functionality lost in migration; no duplicate settings or conflicting persistence; existing voice assignments and favorites are migrated safely.

## Implementation order
**P0 — Audit and architecture:** repo inventory, feature map, user-flow map, data migration plan, reusable design tokens/icons/controls, tests for existing behaviors.

**P1 — Shell and live operation:** six-item sidebar, persistent bottom player, minimalist dashboard, Queue/History unified UI, shared state and live-safe actions.

**P2 — Voices consolidation:** voice editor/list, favorites simplification, MDI icons, playlists, viewer assignments, voice rules, pronunciation, migrations.

**P3 — Services and Integrations:** provider overview/editors; Streamer.bot connection/actions/mapping; chat voice preference contract and templates.

**P4 — Settings and polish:** settings consolidation, audio controls, command palette/shortcuts, context menus, responsiveness, density, accessibility, diagnostics, backup/update UX.

At every phase: implement incrementally, test, and verify no regressions. Do not create static mockup-only controls masquerading as working functionality. If something is unsupported, identify it explicitly and propose the smallest reliable implementation.

## Definition of done
- Each feature has one intuitive home and task-completion shortcuts without duplicate ownership.
- All six top-level labels are exactly one word: Dashboard, Voices, Queue, Services, Integrations, Settings.
- A streamer can operate TTS during a live broadcast without digging through configuration screens.
- Every existing feature is accounted for in the migration inventory.
- No decorative clutter, fake stats, duplicate players, profile portraits, or second icon service.
- Core journeys pass end-to-end tests and persist correctly across restart.

## Codex delivery request
Before coding, return: (a) current architecture findings with file references; (b) current-to-proposed feature relocation matrix; (c) final screen/component map; (d) required schema/API migrations; (e) risks and open questions; (f) prioritized implementation PR/task breakdown with test strategy. Then implement in small reviewable phases, reporting changed files, screenshots where practical, tests run, and remaining limitations.
