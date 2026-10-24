# Jam implementation

User controls and recovery steps are in [Local Jam](../jam.md).

## Document protocol

The native client uses pinned Yrs 0.28.0 update-v1 documents with UTF-16 offsets. Room protocol version 3 negotiates `hello`/`welcome`, exchanges base64 CRDT `sync`/`update` messages, acknowledges applied updates by connection-local ID, and publishes ephemeral `presence`/`cursor` and participant lists. Presence can include a CRDT-relative first visible source position, a fractional line offset and a horizontal character offset; these values are bounded and stay out of the recovery journal. The initial welcome and reconnect carry room state and a state vector; clients merge retained offline edits and send the missing state. Welcome includes a stable document identity and whether the host uses durable checkpoints. When enabled, acknowledgement follows a flushed local recovery record. The standalone test client can run without storage, in which case acknowledgement covers only memory. Hosted durable recovery remains separate work.

Text is limited to 1 MiB, decoded updates to 2 MiB, and session traffic/state queues are bounded. The local undo manager retains at most 100 actions within a 1 MiB edit budget, clearing its history when that budget is reached. A limit or protocol failure is shown in Jam status; leave and start a new session with the current buffer. Jam recovery is separate from saving the source file.

## Recovery storage

Each recovery folder has a checksummed CRDT snapshot and an update journal capped at 4 MiB. The journal compacts after 128 records or 512 KiB, preserving CRDT clocks and pending edits. A partial final record is discarded during recovery; complete corrupt records stop recovery and remain available for inspection. One window at a time owns a file's recovery folder. Invitations and display names are not stored there. To keep an independent backup, leave the Jam and copy its entire recovery folder; restore that copy under the same document key before resuming. These files contain source text and remain on disk until replaced or removed; they are local recovery, not a hosted backup or indefinite collaborative undo history.

## Checks

`bash scripts/check-jam.sh` builds and runs the local checks. `cargo test --manifest-path native/jam/Cargo.toml --locked` checks native convergence, Unicode, author undo, WebSocket reconnect and protocol rejection. `tests/JamWorkbenchChecks.hx` exercises the editor integration in both themes. After building the standalone native client, `python3 tests/jam_peer_checks.py` runs two clients locally; `python3 tests/jam_recovery_checks.py` kills and restores both peers, checks secret rotation and rejects unrelated rooms; `--ssh nuc --remote-binary <path>` uses a prebuilt second client through a reverse loopback tunnel. Check the remote host's workload before compiling or running there.


The native active-tab transport is opt-in through `Config.workspace`; its contract is in [native/jam](../../native/jam/README.md). The editor's [JamSession](../../src/rayde/jam/JamSession.hx) uses the single-document path.
