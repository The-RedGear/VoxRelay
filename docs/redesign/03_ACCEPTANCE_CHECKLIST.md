# YapLoq acceptance and regression checklist

## Navigation / visual architecture
- [ ] Sidebar labels exactly Dashboard, Voices, Queue, Services, Integrations, Settings; one word each.
- [ ] Every existing setting/action mapped to exactly one canonical home.
- [ ] No extra nested sidebar tree or tabs-within-tabs maze.
- [ ] Responsive at minimum practical window size, laptop, desktop, and high-DPI scaling.
- [ ] Dashboard has no vanity stats, voice gallery, duplicate history or giant player.
- [ ] Bottom player visible and functional on every page; safe stop/mute available.
- [ ] Switching pages preserves selected subsection/filter and appropriate unsaved-edit protections.

## Voices
- [ ] Voice list searchable, compact; Add/Edit/Duplicate/Delete/Preview work.
- [ ] Exactly one heart favorites filter; favorite assignment in Add/Edit, persists after restart.
- [ ] Existing favorites preserved or migrated with backup and verification.
- [ ] MDI uses existing app icon renderer; optional ID, default `mdi:music-note`, validation, live preview, correct browser link, no SVG/JS execution.
- [ ] No profile portraits or custom image upload workflow.
- [ ] Voice editor shows only provider-supported controls; service credentials stay in Services.
- [ ] Playlists reference voice preset IDs, support configured rotation, handle missing voices and empty playlists.
- [ ] Viewer voice assignments use stable platform+user IDs, survive restart, support reset and renames.
- [ ] Voice rules distinct from message rules; voice-selection precedence documented and tested.
- [ ] Pronunciation behavior and any existing customization retained.

## Queue / playback
- [ ] Queue and History are views inside Queue; shared canonical message state.
- [ ] Skip, remove, reorder/prioritize, replay/requeue and details work as supported.
- [ ] History status and failure reasons accurate; retention independent of live queue lifecycle.
- [ ] Context menus include appropriate actions and have discoverable alternatives.
- [ ] Player queue shortcut opens Queue's live view.
- [ ] Seek is offered only if supported; preview does not unexpectedly interrupt live playback.
- [ ] Configuration changes do not change already playing speech unexpectedly.

## Services / Integrations / Settings
- [ ] Services lists only actually supported providers; accurate states and credential tests.
- [ ] Provider secrets are handled securely and never exposed in logs or UI output.
- [ ] Streamer.bot integration validates actual supported transport/actions/events.
- [ ] Viewer `SetViewerVoice` request validates identity, allowed alias, permission, persistence, reset and error acknowledgment.
- [ ] No false success toast before confirmed operation; no invented automatic import support.
- [ ] Settings only contains app-wide/audio preferences; contextual links navigate back correctly.

## Usability / safety / quality
- [ ] Icon-only buttons have tooltips, accessible labels, keyboard focus and consistent semantics.
- [ ] One-click common live operations; short common edit flows; sensible right-click menus.
- [ ] Empty states and errors provide a useful next action, not decorative clutter.
- [ ] Keyboard navigation, contrast, screen scaling, compact/comfortable density verified.
- [ ] Existing configuration, user data, provider connections and working workflows not lost.
- [ ] Build/tests pass; manual smoke test on Windows; packaged app tested, not only dev mode.
- [ ] Every phase documents changed files, screenshots if feasible, tests, known limitations.
