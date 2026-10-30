# Session implementation

The Rust crate `native/session` serves one workspace directory over a WebSocket. The [user guide](../session.md) covers opening workspaces, saving and reconnecting.

## Starting a session

```sh
cargo build --release --manifest-path native/session/Cargo.toml
native/session/target/release/rayde-session --root path/to/workspace --exec
```

The server prints an address and token. To serve the small browser client, build it with `(cd web/session && npm install && npm run build)` and pass `--web web/session/dist`. Node packages build and test artifacts; the session service runs in Rust.

Private CRDT state lives in `~/.rayde-session/<path-hash>/state`, keyed by the canonical workspace path. Startup migrates legacy workspace-local state there and preserves conflicting copies. `--state-root DIR` selects private storage for sandbox or test hosts.

The [MSB runner](../../native/runner/README.md) provisions isolated Linux guests for the local cloud-workspace pilot. It includes NUC testing and the private command-stream bridge used by the Worker; the user-facing session protocol is unchanged.

## Serving the full editor

Build with `scripts/build-web.sh`; see [browser build requirements](building.md#browser-build). It needs Ash's `ash-channel` Haxe library, `ash_channel.wasm` and `channel-agent.mjs`. `ASH_CHANNEL_ROOT` selects the checkout, `ASH_CHANNEL_WEB` its side module, and `WEB_LIBS` the window/GPU libraries. Use matching Ash and window libraries with future-aware browser idle waits. Run `npm ci` in `web/session` before bundling the page agent.

```sh
native/session/target/release/rayde-session --root path/to/workspace --exec \
  --web bin/web/rayde --extension-host "$PWD/bin/rayde-extension-host" \
  --extensions "$PWD/extensions"
```

The landing launcher (`scripts/serve-site.py`) uses the optimized session build too. Pass `--debug-session` when debugging the Rust service; use a release build for latency measurements.

Open the printed HTTP address with:

```text
?session=ws://127.0.0.1:7070/session&project=build.hxml#token=TOKEN
```

Substitute the actual host, port and token. HTTPS pages need `wss://`; pages served elsewhere need their exact origin allowed with `--origin`. Keep the token in the fragment, which is not sent as an HTTP request parameter.

`?demo=1` enables the local example entry during development; `?demo=0` disables it. `rayde.org` opens the example by default. The app host opens Welcome with Explorer collapsed unless a workspace is selected. Repository URLs use `app.rayde.org/{session_id}` and require authentication. Browser Open Project and Open Folder use the account service's GitHub repository chooser; native builds use their system picker. Browser platform detection determines UI and shortcut conventions independently of the compute host.

## Host environment

Process defaults load from `~/.rayde-session/environment.json`, or the JSON file selected by `--env-file PATH`:

```json
{"RAYZOR_STD_PATH":"/path/to/rayzor/compiler/haxe-std"}
```

Values reach language servers, extension hosts, programs and terminal shells. Explicit per-process settings take precedence. Values stay on the host and are omitted from the browser handshake. Restart the session after changing the file.

`RAYZOR_STD_PATH` must contain `StdTypes.hx`. Rayzor's project-specific standard-library selection still applies.

## Authentication

Requests are JSON over `ws://host/session`. The first request must be `hello` with the session token.

Optional `--auth-secret S --login-url URL` permits viewing before sign-in but returns `auth-required` for mutations. The connection authenticates with `auth.login` and a signed credential:

```text
base64url(payload).base64url(HMAC-SHA256)
payload: {login, id, exp}
```

`rayde-session issue --auth-secret S --login NAME --id N` mints a development credential. This mode is separate from the Cloudflare gateway, which authenticates the connection and supplies the private compute token.

## Files and documents

| Area | Requests | Contract |
| --- | --- | --- |
| Files | `fs.list`, `fs.stat`, `fs.read`, `fs.write`, `fs.mkdir`, `fs.remove`, `fs.rename` | Workspace-relative paths; traversal and symlinks leaving the root are refused. |
| Documents | `doc.open`, `doc.update`, `doc.save`, `doc.close`, native `doc.resolve` | Yjs/Yrs state vectors and updates synchronize shared text. Updates require an open subscription. |

`doc.open` requires an existing UTF-8 file. Create files explicitly with `fs.write`; missing-path probes create neither files nor recovery records. Reopening a subscription consumes no additional slot. Clients may share an existing document even when the workspace has reached its distinct-document limit.

The host writes settled edits to disk and incorporates outside file edits into the shared document. Moving a file or folder containing an open CRDT document, including an open destination, is refused. Native clients can explicitly move released drafts as described below; live shared renames still require coordinated path changes.

### Browser bindings and Save

`web/session/src/client.js` writes edits to Yjs and IndexedDB before sending them. Offline edits merge after reconnect; remote edits also update inactive buffers. Undo tracks the local editor's transactions. Personal history, settings and tab layout use browser storage.

The bridge maintains a CRDT projection of text acknowledged by the editor, preventing late typing from applying stale offsets to newer remote text. Bindings follow persistent buffers rather than mounted views. Closing a saved tab releases its projection, undo manager and subscription; dirty buffers remain retained.

Save waits for earlier updates to reach the host before flushing the file. Failure leaves the tab dirty and reports the error. Builds and workspace changes wait for successful saves.

### Recovery identity

`hello.cacheIdentity` supplies a version, opaque host/workspace IDs and a verified account ID when signed in. IDs persist with private state across ordinary restarts; resetting document state rotates the identity. They identify cache namespaces and confer no access.

Browser recovery, history and layout combine this identity with the socket origin/path. A changed workspace, account or state generation blocks old bindings and shows a warning toast. Previous data stays in IndexedDB. Legacy unverified caches remain preserved without automatic import; legacy servers disable durable browser recovery.

**Reopen Workspace** checkpoints local recovery and history, waits for storage, then reloads the same workspace URL. Storage errors or timeouts keep the page open. The warning card sits above the status bar, uses the warning theme color and remains until dismissed.

### Saved checkpoints

With `hello.checkpoints = 1`, `doc.save` accepts `checkpoint:true` and returns versioned, checksummed complete Yrs state captured with the saved text. Native `doc.restore {path, checkpoint}` restores a released document's graph and text, including a file absent from replacement compute. It requires write authorization and rejects active documents, invalid paths, corrupt state and incomplete graphs.

With `hello.bufferedRestore = 1`, the trusted control plane can use `doc.restore {path, checkpoint, mode:"buffer", diskSha256}` after materializing the saved UTF-8 file. Its hash must match. The recovered graph stays in checksummed private state; background flush, last-subscriber release and shutdown leave the saved file unchanged. `doc.open` reports `buffered` and `dirty`, and the browser binding marks restored edits dirty even when browser recovery already has the same text. Recovered buffers continue requiring explicit Save. Save verifies the observed disk baseline and records both sides of an in-progress disk write so interrupted saves can reopen safely; a different disk baseline requires reconciliation. This is not a filesystem compare-and-swap: external writers must be fenced or reconciled before automated restoration. Stable path identities and a complete filesystem manifest remain prerequisites.

Released drafts retain checksummed document bindings. Ordinary file mutations check them after close or restart, including canonical aliases; dirty or conflicting drafts must be saved or reconciled first. Legacy unbound records are rebound on reopen.

### Native document identities and closed moves

Native directory sessions advertise `hello.documentIdentities = 1` and `closedDocumentMoves = 1`. `doc.lookup {path}` returns the existing ID or null for a file not yet admitted, without loading its graph; `hello.documentLookup = 1` advertises this optional shortcut. `doc.open` returns an opaque `documentId`. Returning replicas supply that ID with Open, Update and Save; Open checks it under the same gate as filesystem mutations. An old path recreated as another file receives another ID. A nonempty legacy state vector cannot reopen a moved or rebound path without its ID. Missing-file probes create no document state.

After closing subscriptions, `fs.rename {from, to, preserveDocuments:true}` moves saved files while retaining released dirty graphs and their disk baselines. Its receipt contains a catalog `revision` and `documents: [{id, from, to}]`. `doc.resolve {documentId}` returns its current relative `path`, or null for a retired or unknown ID. Canonical aliases share an ID and cannot simultaneously materialize competing graphs. A final symlink is refused for draft-preserving moves; ordinary symlink moves leave the target's identity intact.

Private `documents.json` and `document-mutation.json` use checksummed, atomic writes. An intent precedes each bound move or deletion; restart verifies filesystem object identities before completing or rolling back the catalog transition. Ambiguous outcomes remain fenced without overwriting files or recovery data. Existing legacy graph files are adopted in place. Multiple legacy alias graphs require reconciliation, with both copies preserved. The catalog retains metadata rather than loaded CRDT graphs and is bounded to 16,384 identities and 8 MiB. Retired graphs remain private; explicit discard and reclamation are separate work.

These IDs belong to one native recovery namespace and its single compute authority. They are not access credentials or portable cross-host IDs. The hosted gateway internally binds durable journals and checkpoints to compute-confirmed IDs, retaining older records when a path is recreated. Browser graphs use `rayde:v3` keys containing the verified workspace/account namespace and document ID. A small IndexedDB directory stores verified path hints for offline reopening; online opens discover the current ID instead. Updates and Save carry the expected ID. An identity mismatch pauses that editor binding and preserves its recovery data.

Workspace-scoped `rayde:v2` path caches migrate only after Open accepts their state vector or bound identity. The identity graph and its source links commit before a legacy migration receipt is written. Legacy graph bytes stay intact, and linked, identity-matching late updates can be recovered after a move. Cache replay does not publish edits before this verification and storage barrier. Retired/replaced path caches remain separate. Unscoped older caches are never merged automatically.

A closed native document reopened at its moved path recovers the same browser graph. Live editor/path retargeting, personal history migration, coordinated hosted moves, cross-host identity import, external-writer reconciliation and compute leases remain outstanding. The hosted gateway advertises document identities, lookup and closed moves as unavailable and refuses `doc.lookup`, `doc.resolve` and draft-preserving moves until that integration is complete; automatic restore remains disabled.

The hosted gateway reserves restoration for its trusted control plane and stores checkpoints before acknowledging Save. See [saved document recovery](../../web/cloud/README.md#saved-document-recovery) for gateway storage and restore behavior.

### Unsaved edit journals

With `hello.journals = 1`, native `doc.update {journal:true, vector}` returns a checksummed `journal` delta and its state vector from the edit's transaction. The vector selects all missing compute changes, including outside edits. It does not force a file write.

The hosted gateway supplies the durable vector and commits each delta before returning `durableUpdate {id, sequence}`. Its `hello.durableUpdates` flag makes the browser send a barrier during synchronization even when compute already has every local edit. A failed durable write cannot become a successful synchronization merely by reconnecting.

Updates and Save share a bounded FIFO queue. Journals compact after 64 segments or 256 KiB of delta payload, reuse chunk slots and materialize a graph only for compaction or export. Saved checkpoints and journals have separate records but share the workspace's recovery quota. Storage failures preserve the previous manifest, payload and accounting.

Internal owner-checked `/journals` and `/journal {owner, id}` operations list usage and export a complete checkpoint for trusted restoration. The browser cannot access these routes. Native `journal-conflict` rejects a compute graph missing previously acknowledged history; the control plane must restore it before continuing.

This protects acknowledged browser edits and dependencies captured at their barriers. Complete filesystem/tombstone recovery, changes made after the last barrier and automatic compute replacement remain separate work. Recovery contexts still change on a fresh compute generation.

### Restore selection

Hosted filesystem writes, directory creation, removal and rename share the document recovery FIFO. A durable intent precedes compute execution; its confirmed result precedes the reply. Interrupted or uncertain operations remain recovery fences. Catalog metadata is bounded separately from document payloads, and file request bodies are not stored in this ledger.

Direct writes reserve private R2 payload space atomically with their intent, then upload or verify a workspace-scoped immutable object before compute execution. Failed uploads cannot change compute files and remain accounted for. Retained versions deduplicate by content within a workspace. The internal `/recovery/file {owner, source, mutation, revision}` exports only confirmed operation payloads with length/digest and revision checks; later moves/deletions still apply. Local tests emulate R2 without a cloud account. See [filesystem recovery](../../web/cloud/README.md#filesystem-fencing-and-restore-selection) for storage setup, quotas and current scope. Initial checkout/Git state, external writes, filesystem materialization and payload reclamation remain separate work.

Compute-confirmed Save and journal barriers atomically select a current record with a revision and payload stamp. Even an unchanged payload can supersede an older applied mutation. Historical checkpoint imports cannot select a head; changing a selected imported record invalidates it. Save refuses recovery history that compute does not contain, including deletion-only changes with unchanged vectors.

The internal owner-checked `/recovery/plan {owner, source, revision?}` lists selected records, invalidations and mutations for one compute source. A stale revision returns 409. Directory invalidations respect path boundaries, and recreating a directory does not reselect older child snapshots. Pending and uncertain operations remain blocked until reconciled.

Plans identify their scope as `confirmed-document-heads` and set `automaticRestore:false`. They cover tracked workspace-relative operations. Complete filesystem state, external changes, stable document identities and compute leases remain prerequisites for automatic restoration. A materializer must verify both the plan revision and record stamps before using it.

## Syntax and process services

| Capability | Requests and events | Behavior |
| --- | --- | --- |
| `hello.syntax` | `syntax.highlight`, `syntax.cancel` | Highlight accepts a request ID, editor key, filename and source snapshot; returns line token ranges in UTF-16 units. Cancel addresses the editor key. Queries run independently of ordered workspace operations. |
| Execution (`--exec`) | `proc.spawn`, `proc.write`, `proc.close-input`, `proc.kill`; `proc.out`, `proc.exit` | Processes run in workspace directories and terminate when their connection closes. |

Requests, process startup, output and shutdown use `ash.Future`. Readers park until replies or stream events arrive. One sleeping deadline worker handles timeouts; the UI drains available messages.

### Extensions and language servers

Each extension runs in a separate host process. Its views render in the browser, and service calls retain capability checks. The operator selects the extension-host binary and built-in directory. Execution requires `--exec` and sign-in when configured.

Stdio language servers use host executable paths, environment and workspace directories. Install Rayzor on the host's PATH and configure its standard library there. The built-in extension starts on the first Haxe document; Welcome alone leaves it asleep. Browser hover docs render Markdown.

Network loss pauses extension and LSP supervision. Reconnecting to the same recovery context restarts active hosts and replays unsaved text. Explicit LSP Stop stays stopped. Remote inspection never probes the browser machine's localhost compiler ports. Build, Run and terminals also execute on the session host.

## Installed source mounts

A native operator may repeat `--read-root DIR` for up to 32 installed library/source directories outside the editable checkout. The installed extensions root is included automatically. `hello.readRoots` advertises `{id,path}` mounts; `fs.stat`, `fs.list` and `fs.read` accept their `mount` ID plus a relative `path`. Traversal and symlink escape are refused. Mounts accept neither mutations nor document subscriptions. Files remain read-only in browser tabs, and installed extension manifests come from the actual host installation.

Prepared Linux guest setup and local VM recovery are in [the runner reference](../../native/runner/README.md). With `privateJournals = 1`, a native journal reply also follows atomic private graph persistence. Directory entries and identities are flushed before acknowledgement; the hosted gateway's separate durable storage barrier remains required.

## Terminals

When `hello.terminal` is true, `term.open` starts a connection-owned PTY. It accepts a client key, workspace-relative `cwd`, optional `program`/`args`, `cols` and `rows`. Host profiles arrive in `hello.terminalProfiles`.

| Message | Purpose |
| --- | --- |
| `term.ready`, `term.failed` | Startup result. |
| `term.write`, `term.resize`, `term.scroll`, `term.visible`, `term.close` | Operate on the terminal's `tid`. |
| `term.update` | Base64-packed screen information and changed rows, with UTF-16 column boundaries for copying. |
| `term.ack` | Acknowledge a patch; further output coalesces until acknowledged. |

Hidden terminals continue running with bounded scrollback but stop streaming screen updates. Startup and PTY I/O run outside ordered workspace RPC handling. Connection loss closes terminals; handles cannot be reused after reconnect.

## Resource limits

| Resource | Limit |
| --- | --- |
| Native connections per workspace (WebSocket and framed TCP combined) | 32 |
| Native connections per verified account in a workspace | 8 |
| Hosted connections per workspace, including upstream opens in progress | 8 |
| Shared UTF-8 file | 8 MiB |
| Unique document subscriptions per connection | 256 |
| Distinct retained documents per workspace | 512 |
| Save checkpoint payload | 4 MiB |
| Journal payload per document | 4 MiB |
| Saved checkpoint and journal records combined | 512 records / 64 MiB raw payload |
| Queued recovery operations / encoded update payload | 256 / 8 MiB |
| Queued filesystem request bodies (shared recovery queue) | 16 MiB |
| Recovery catalog mutations / heads / metadata | 1,024 / 512 / 1 MiB |
| Direct-write payload per file / retained workspace bytes | 12 MiB / 64 MiB |
| Distinct retained direct-write payloads per workspace | 1,024 |
| Terminals per connection / workspace | 4 / 8 |
| Terminal screen | 300 columns × 100 rows |
| Scrollback per terminal | 1,000 lines |
| Terminal input queue | 256 KiB |

Document-admission failures return `busy` with an instruction to close documents. Closing a subscription releases it immediately. Idle documents from disconnected clients retain a five-second reload grace before eviction. Admission limits are separate from aggregate storage, byte-rate and compute quotas.

Connection admission is atomic. Native WebSocket upgrades return HTTP 429 at capacity; framed TCP returns `busy` and closes. Account sign-in returns `busy` without replacing the current identity when its limit is reached. Native clients have ten seconds to complete `hello`; ready clients have no idle deadline. Hosted upstream opens also time out after ten seconds. Failed opens, disconnects, backend loss and sign-out release their reservations. These workspace limits do not enforce an account-wide quota across multiple workspaces.

## Cloudflare gateway

`web/cloud` implements GitHub App sign-in, account sessions, repository authorization and the workspace gateway in Rust compiled to Workers WASM. SQLite-backed Durable Objects keep account/workspace metadata. Browsers use an HttpOnly cookie; GitHub tokens and private compute credentials stay server-side.

See [gateway setup and tests](../../web/cloud/README.md). Local tests mock GitHub and compute provisioning while connecting to a real Rust session server. They do not deploy a service or provision a production sandbox. Live document authority remains in the session process; Durable Object CRDT authority and the MSB compute provider are separate integrations.

## Checks

Build the session and extension-host binaries before full-editor checks. Browser checks also need the built WASM editor and test dependencies in `web/session`.

| Command | Coverage |
| --- | --- |
| `cargo test --manifest-path native/session/Cargo.toml` | Native protocol over real sockets. |
| `(cd web/session && npm test)` | Browser client, equal-name workspace replacement, account-scoped drafts and legacy cache isolation. |
| `node tests/web/session.mjs --dir bin/web/rayde` | Open/edit/Save, large replies and extension service calls; uses `tests/fixtures/browser-session`. |
| `node tests/web/collaboration.mjs bin/web/rayde` | Two full editors with separate storage: edits, undo, Save, restart, reload and replacement-state fencing. |
| `node tests/web/extensions.mjs bin/web/rayde` | First previews, interactive updates, menu/command reload, error containment and refresh. |
| `node tests/web/lsp.mjs bin/web/rayde` | Real hosted Rayzor: semantic hover, Markdown, live diagnostics and sustained connection-loss recovery. |

The LSP browser check needs Rayzor; `RAYDE_RAYZOR_LSP` and `RAYZOR_STD_PATH` select its executable and standard library.

Haxe checks cover the bridge and workbench behavior:

- `SessionAsyncChecks`: concurrent replies, deadlines, early process output and disconnect under Ash.
- `SessionEditorChecks`: asynchronous readiness, stale projections, undo, Save failures and binding cleanup.
- `ExtensionOutputChecks`: stack locations and malformed isolated output.
- `SessionLspChecks`, `SessionLspQueueChecks`, `SessionLspReconnectChecks`: framed LSP, bounded queues, cancellation, idle wakeups, offline recovery and stale handles.

## App previews

`Preview App` builds a single Haxe/HashLink target with `-D wasm`, keeping its libraries, defines and macros. Builds run on a worker and have a timeout. The host needs Ash with WASM compilation, a compatible WASM runtime, and browser versions of the project's native libraries. Rayzor and other compilation targets are not converted implicitly.

The session keeps separate successful bytecode and WASM snapshots under `.rayde/preview-cache/`, bounded to 128 MiB per stage. Content fingerprints cover Git-visible workspace files, explicit classpaths/resources, resolved Haxelib package roots, the Haxe standard library, compiler arguments/environment and host tooling. Ash/runtime changes invalidate the WASM stage separately. Rechecks before publication prevent caching outputs under an obsolete input fingerprint. Missing, corrupt or oversized caches fall back to compilation; the cache never grants artifact access, which still requires a connection-owned preview capability.

An unavailable inventory or unsupported compiler configuration disables reuse. Macros that read external files outside these inputs or depend on time/network state need **Rebuild App Preview from Scratch**. It clears both stages. Stage durations and cache decisions appear in Build output.

Compiler executables use canonical paths and file identity stamps; source and resource files use content digests. On Unix, bounded digest memoization also checks change time so a restored modification time cannot hide an edit. Browser build scripts skip desktop renderer preparation; their renderer WASM is rebuilt only when its Rust inputs or toolchain change.

`bash scripts/build-site.sh` stages `bin/preview-tools`. Set `ASH_RUNTIME` to the WASM `ash_runtime.o` when building, or stage it explicitly:

```sh
python3 scripts/stage-preview.py --runtime /path/to/wasm/ash_runtime.o
rayde-session --root /path/to/project --exec --preview-tools /path/to/RayDE/bin/preview-tools
```

The tooling supplies a preview-only filesystem adapter and browser channel; the project's HXML and dependencies stay intact. The app frame can read and write workspace files through the editor's session client. Private host paths and process/account RPC are refused. Hosted writes use the existing durable file-operation queue.

Native sessions serve artifacts on a separate loopback port. Hosted sessions stream bounded artifact chunks through their Durable Object. Set `PREVIEW_ORIGIN` to a dedicated HTTPS origin, separate from `APP_ORIGIN`, routing to the same Worker. This origin serves preview artifacts only. Local development derives a separate hostname from `APP_ORIGIN`. Artifact capabilities expire with the connection; apps receive no account or workspace token.

For an MSB image, pass `--preview-tools /path/to/staged/tools` to `scripts/prepare-toolchain.py`. Its generated toolchain configuration enables the session's preview tooling. Existing templates remain usable without app previews. Rebuild the template to install changed tooling; its files are covered by the image integrity manifest.
