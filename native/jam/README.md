# Native Jam active-tab protocol

The editor currently uses single-document Jam sessions. The native transport also
supports an opt-in workspace session through `Config.workspace = true`; both peers
must select the same mode. It uses one worker and one WebSocket per participant.
The workspace flag enables switching the presented tab within one Jam; it does
not enumerate or broadcast the host's other open tabs. Messages use the envelope
`{"t":"workspace","message":{"t":"…",…}}` within protocol version 3.

The hosting worker generates a separate private owner credential for its own
connection. It stays out of invitations, participant lists and recovery. Guests
cannot become the host by choosing its name or peer ID. Only the host can publish
documents, select active tabs or publish preview frames. All participants can edit
published code documents, including ones the host has left.

| Message | Direction | Fields and behavior |
|---|---|---|
| `open` | Host → room | `document`, `file`, `state`: register a CRDT under a stable document ID and normalized relative path. Its snapshot is returned to the host. Guests receive it when the host presents it. |
| `request` | Participant → room | `document`: request a document previously presented by the host, for reconciling retained edits after reconnect. Unpresented documents are refused. |
| `document` | Room → participant | `document`, `file`, `state`, `vector`: merge the state and send the local diff against the room's vector. |
| `sync` | Participant → room | `document`, `id`, `update`: persist and route an update for that document. |
| `update` | Room → participants that received this document | `document`, `peer`, `update`. |
| `ack` | Room → sender | `document`, `id`: the update has been accepted and, when recovery is enabled, flushed. |
| `presence` | Participant → room | `document`, `caret`, `anchor`, optional `view`: CRDT-relative selection and viewport positions. |
| `cursor` | Room → other participants | Presence plus `peer`; validated against the specified document. |
| `activate` | Host → room | `surface`: `{"kind":"code","document":"…"}`, `{"kind":"preview","id":"…","title":"…"}` or `{"kind":"idle"}`. A newly presented code document arrives before its `active` event. |
| `active` | Room → participants | The selected `surface`; replayed after the document snapshots on reconnect. |
| `frame` | Host → room → guests | `frame`: `view`, increasing `sequence`, `width`, `height`, base64 `png`. Contains pixels only. |

A new guest receives only the current surface: the current code document, or the
current preview frame. Switching tabs retains per-document edit state without
disclosing tabs the guest has never seen. A reconnecting guest requests its
previously received documents to reconcile edits; the host's disclosure history
is retained with the recovery manifest.

The local event queue additionally emits workspace `restored` events containing
`document`, `file` and `state`, and `locally_saved` events containing `document`
and `id`. Restored state can be displayed before a connection succeeds. On the
next `document` event, merge it with the restored CRDT and publish the missing
update; replacing its text would lose offline edits. `checkpoint` remains a
session-wide command and compacts every document before `checkpointed` is emitted.
The host's registered document state and latest requested active surface are
replayed after reconnect, so commands issued while connecting are retained.

Each document keeps its own CRDT, undo history in the editor, and recovery journal.
The existing root recovery lock protects the workspace. A checksummed, atomically
replaced manifest under `workspace/manifest.json` lists the child journals, keyed
by document ID. A damaged manifest fails recovery without replacing it. Active
surfaces, cursors and preview frames are ephemeral and stay out of these journals.
Starting a fresh session replaces its recovery manifest; resuming requires
`restore = true` and the original recovery folder.

The transport accepts at most 64 documents and 4 MiB of combined encoded CRDT
state, with the existing 1 MiB text and 2 MiB decoded-update limits per document.
Preview frames are static, non-interlaced PNGs with checked chunk checksums, at
most 1280 × 720 pixels and 512 KiB encoded image data. The sender, each connection
and the UI event queue retain the latest pending frame. Ordered edits have priority;
stale frames for a departed tab are dropped. Guests should also compare the frame's
`view` with their selected preview ID before presenting it.
Use a new preview ID for each presentation and attach that ID to asynchronous
captures, so a late capture from an earlier visit cannot replace the current view.

`cargo test --manifest-path native/jam/Cargo.toml --locked` exercises the workspace
protocol and legacy sessions. The JSON-lines driver accepts `workspace: true` at
startup and `{"op":"workspace","message":{…}}` commands for peer testing.
