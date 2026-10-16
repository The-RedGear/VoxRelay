# Streamer.bot recipes

The YapLoq Streamer.bot page copies UDP payloads for speech and queue controls.
Use UDP Broadcast with port 6670, unless you changed it in YapLoq.

Alternatively, choose the Speak alias and select **Export actions (.sb)**. Import
that file using Streamer.bot's Import dialog and review its ten actions before
applying it. It does not create triggers or run an action automatically. Export
IDs are stable, so later imports update the same YapLoq actions. Keep your own
customizations under different action names or disable overwriting in the import
preview. The generator targets the official v10 export envelope (0.2.4 schema).
Live import behavior across Streamer.bot versions still needs verification.

```text
VSPEAK
Windows voice
%message%
%displayName%
%userName%
```

For a random voice among aliases marked **ON** in the Voices tab, use `random` (or `*`) on line 2:

```text
VSPEAK
random
%message%
%displayName%
%userName%
```

For a custom pool from **Rules → Voice playlists**, use `playlist:Name`:

```text
VSPEAK
playlist:Halo
%message%
%displayName%
%userName%
```

`group:Halo` still picks randomly within that alias **Group** field (ON voices only). Export actions (.sb) can select **Random (enabled voices)** or **Playlist: Name**.

Line 1 is the command, line 2 is the voice alias (or `random` / `group:Name`), line 3 is the spoken text.
Optional line 4 is the viewer display name (`%displayName%` or `%user%` when it is a
plain name), line 5 is the Twitch login (`%userName%`), and line 6 can be a role.
Do not put Streamer.bot's `%user%` object JSON on the identity lines — in current
Streamer.bot builds `%user%` often expands to a whole `{"badges":...,"login":...}`
blob. Use `%displayName%` + `%userName%` instead. Automatic voice rules match either
identity case-insensitively. A single optional identity line is also accepted and
matched as both display and login. If a JSON user object still arrives, YapLoq
extracts `name` / `login` automatically.

```text
VCONTROL
pause
```

Control tokens: `pause`, `pauseaftercurrent`, `resume`, `skip`, `clear`, `clearall`,
`remove`, `moveup`, `movedown`. The last three require the speech ID on line three.
`clear` keeps current speech; `clearall` stops current speech too.

HTTP uses port 7582 by default:

| POST endpoint | JSON body |
| --- | --- |
| `/speak` | `{"voice":"Windows voice","message":"Hello","source":"Twitch","user":"viewer","role":"subscriber","event":"reward","priority":10}` |
| `/pause` | `{}` |
| `/pause-after-current` | `{}` |
| `/resume` | `{}` |
| `/skip` | `{}` |
| `/clear` | `{}` |
| `/clear-all` | `{}` |
| `/api/queue/remove` | `{"speechId":"id"}` |
| `/api/queue/move` | `{"speechId":"id","direction":"up"}` |
| `/api/profiles/load` | `{"profile":"Quiet"}` |

WebSocket uses port 7581. Send a request with a unique ID:

```json
{"id":"queue-pause","request":"Pause"}
```

```json
{"id":"scene-profile","request":"LoadProfile","profile":"Quiet"}
```

Subscribe to events:

```json
{"id":"events","request":"Subscribe","events":{"texttospeech":["received","generating","engineprocessed","playing","finished","cancelled","error"]}}
```

The lifecycle follows received → generating → engineprocessed → textqueued →
playing → finished, cancelled or error. Cached replay and output tests can skip
generation. Raw events describe each job. Configured Queued and Playing actions
announce a queue session once; Finished waits for every registered job to end.

The pre-playback delay starts after the Queued action's HTTP request completes.
It applies when that action was actually dispatched, rather than inserting the
same delay between every item. Streamer.bot may run an action asynchronously;
HTTP acknowledgement does not prove all of its sub-actions have finished.

Lifecycle arguments include `ttsState`, `ttsId`, `ttsText`, `ttsAlias`, `ttsVoice`,
`ttsSource`, `ttsUser` and `ttsDuration`. The test buttons exercise configured
actions without adding fake items to the live queue's lifecycle state.

Additional per-message hooks cover Received, Generating, Generated, Failed and
Cancelled/Skipped. Individual failure and cancellation hooks use `itemError` and
`itemCancelled` as ttsState, separately from the queue-session Finished hook.

To change profiles with an OBS scene, attach an HTTP or WebSocket LoadProfile
request to the scene action in Streamer.bot. To animate an avatar, use Queued,
Playing and Finished actions; use Queue added for a pulse when another message
joins an active session.
