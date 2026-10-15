# Streamer.bot recipes

The VoxRelay Streamer.bot page copies UDP payloads for speech and queue controls.
Use UDP Broadcast with port 6670, unless you changed it in VoxRelay.

Alternatively, choose the Speak alias and select **Export actions (.sb)**. Import
that file using Streamer.bot's Import dialog and review its ten actions before
applying it. It does not create triggers or run an action automatically. Export
IDs are stable, so later imports update the same VoxRelay actions. Keep your own
customizations under different action names or disable overwriting in the import
preview. The generator targets the official v10 export envelope (0.2.4 schema).
Live import behavior across Streamer.bot versions still needs verification.

```text
VSPEAK
Windows voice
%rawInput%
```

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
