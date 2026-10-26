# Workspace sessions

A session serves one workspace (a directory) over a WebSocket, so an editor in a browser page can work on files that live elsewhere. It is `native/session`, a Rust crate with no Node in it.

```sh
cargo build --manifest-path native/session/Cargo.toml
native/session/target/debug/rayde-session --root path/to/workspace --exec
```

Session process defaults load from `~/.rayde-session/environment.json`, or `--env-file PATH` for a selected JSON file. For example:

```json
{"RAYZOR_STD_PATH":"/path/to/rayzor/compiler/haxe-std"}
```

These values reach language servers, extension hosts, programs and terminal shells. Explicit per-process environment settings take precedence. Values stay on the host and are not included in the browser handshake. A configured `RAYZOR_STD_PATH` must contain `StdTypes.hx`; changing the file takes effect on the next session launch. Rayzor's own project-specific standard-library selection still applies.

It prints the page's address and a token. `--web web/session/dist` serves the demo page and the browser client beside the socket (`cd web/session && npm install && npm run build`; the npm packages only build and test the browser bundle).

## What a client can do

Requests are JSON over `ws://host/session`; the first must be `hello` with the token.

| Area | Operations |
| --- | --- |
| Files | `fs.list`, `fs.stat`, `fs.read`, `fs.write`, `fs.mkdir`, `fs.remove`, `fs.rename`. Paths are relative to the workspace; `..` and symlinks that leave it are refused. |
| Documents | `doc.open`, `doc.update`, `doc.save`, `doc.close`. A text file is a Yrs document; clients exchange state vectors and updates, so edits made offline merge after a reconnect. The session writes the file once edits settle, and takes an edit made to the file outside the session as an edit of the document. |
| Syntax | When `hello.syntax` is true, `syntax.highlight` accepts a request id, editor `key`, filename and source snapshot; `syntax.cancel` cancels that key. Results contain line token ranges in UTF-16 units. Queries run independently of ordered workspace operations. |
| Programs | `proc.spawn`, `proc.write`, `proc.close-input`, `proc.kill`; output arrives as `proc.out` and `proc.exit` events. Only with `--exec`, only in workspace directories, and stopped when their connection closes. |
| Terminals | When `hello.terminal` is true, `term.open` starts a connection-owned PTY with a client `key`, workspace-relative `cwd`, optional `program`/`args`, `cols` and `rows`. `term.write`, `term.resize`, `term.scroll`, `term.visible` and `term.close` operate on its `tid`. Host shell profiles arrive in `hello.terminalProfiles`. |

The browser client (`web/session/src/client.js`) is local-first: edits go to a Yjs document in the page and IndexedDB first, and travel when the session is reachable.

Terminal startup emits `term.ready` or `term.failed`. `term.update` contains base64-packed screen info and changed rows, with UTF-16 column boundaries for copying. Clients acknowledge each patch with `term.ack`; further output coalesces until acknowledged. Hidden terminals keep running with bounded scrollback and stop streaming screen updates. The session caps each connection at four terminals, eight per workspace, a 300 × 100 screen, 1,000 scrollback lines and a 256 KiB input queue. Opening and PTY I/O run outside ordered workspace RPC handling. Connection loss closes its terminals; handles cannot be reused after reconnecting.

The host keeps CRDT recovery state under `~/.rayde-session/<path-hash>/state`, outside the repository. The directory hashes its canonical workspace path. Existing workspace-local state is moved there on startup; conflicting copies are preserved for recovery. `--state-root DIR` selects another private storage location for a sandbox or test host.

`hello.cacheIdentity` identifies the recovery context with a version, opaque host and workspace IDs, and a verified account ID when signed in. These IDs are stored with the private session state and survive ordinary restarts. Resetting the document-state directory creates a new recovery identity. They are cache namespaces, not access credentials.

Browser document recovery, personal history and tab layout use that identity with the socket origin/path. Reusing an endpoint or display name cannot select another workspace's recovery. A reconnect that changes workspace, account or document-state generation blocks the old editor bindings and shows one warning toast; the previous recovery data stays in IndexedDB.

The toast's **Reopen Workspace** footer button checkpoints the old recovery data and personal history, then reloads the current workspace URL for a fresh authenticated connection. A storage failure or timeout keeps the page open and reports the error. The card uses the theme's warning color, clears the status bar and stays until dismissed.

Legacy caches without a verified identity are preserved but never imported automatically. A legacy server can still serve a page, with durable recovery disabled.

## Signing in before the first edit

With `--auth-secret S --login-url URL`, anyone may look, but every change answers `auth-required` (with the login URL) until the connection sends `auth.login` with a credential signed with `S`: `base64url(payload).base64url(HMAC-SHA256)`, the payload being `{login, id, exp}`. This signed-credential mode is separate from the Cloudflare account gateway below; that gateway authenticates the connection and supplies the private compute token. `rayde-session issue --auth-secret S --login NAME --id N` mints one for development.

## Tests

`cargo test --manifest-path native/session/Cargo.toml` runs the protocol against a real socket. `cd web/session && npm test` drives the demo page in headless Chromium.

## RayDE in the browser

Build the page with `scripts/build-web.sh`. It needs Ash's `ash-channel` Haxe library, `ash_channel.wasm`, and `channel-agent.mjs`; `ASH_CHANNEL_ROOT` selects that checkout and `ASH_CHANNEL_WEB` its built side module. `WEB_LIBS` selects the window and GPU web libraries; the renderer is built from pinned sources ([build requirements](contributing/building.md)). Use matching Ash and window libraries with future-aware browser idle waits. The page agent is bundled with `web/session`'s development dependencies (`npm ci` there first).

To use an existing workspace and installed extensions:

```sh
native/session/target/debug/rayde-session --root path/to/workspace --exec \
  --web bin/web/rayde --extension-host "$PWD/bin/rayde-extension-host" \
  --extensions "$PWD/extensions"
```

Open the printed HTTP address with `?session=ws://127.0.0.1:7070/session&project=build.hxml#token=TOKEN`. Use the actual host, port and printed token; a published HTTPS page needs a `wss://` session. A page served elsewhere needs its exact origin allowed with `--origin`. The token belongs in the fragment, which is not sent as an HTTP request parameter.

The page mounts the session's directory and saves files there. Extensions run in separate processes on the session machine; their views render in the browser and their service calls keep the existing capability checks. The server operator selects the host binary and built-in extension directory. Execution still requires `--exec` and, when configured, sign-in.

In the browser, Open Project and Open Folder open the GitHub repository chooser. The account service authenticates the user and prepares or reuses that repository's remote workspace. Startup shows progress, and the session URL restores it on reload. Native builds keep their system picker. The compute host's operating system does not choose the editor's UI or keyboard conventions.

Requests, process startup, output and shutdown use `ash.Future`. Readers park until a reply or stream event arrives; one sleeping deadline worker handles timeouts. UI polling only drains available messages. Page settings are stored in IndexedDB. On `rayde.org`, RayDE opens the local example with `Main.hx` already visible. `?demo=1` enables that entry in development, and `?demo=0` disables it. On the app host, an empty entry opens Welcome with Explorer collapsed; repository workspaces use `app.rayde.org/{session_id}` and require authentication.

Text tabs in the full browser editor use Yjs documents synchronized with the session's Yrs documents. Typing continues offline; IndexedDB retains edits for reconnect and reload. Remote edits update inactive buffers too. Undo affects this editor's own transactions. Save waits for earlier updates to reach the session before flushing its file; a failed save leaves the tab dirty and reports the error. Builds and workspace changes wait for successful saves. Personal recovery history and tab layout stay in browser storage, scoped to the workspace.

The browser bridge keeps a CRDT projection of the text the editor has acknowledged, so late typing cannot apply stale offsets to newer remote text. Binding lifetime follows the persistent buffer, not its mounted view. A closed, saved tab releases its projection, undo manager and document subscription; dirty buffers stay retained. The session also writes shared edits to files as they settle.

Stdio language servers run on the session machine, using its executable paths, environment and workspace directory. Install `rayzor` on that host's PATH (and configure its standard library there). The built-in Rayzor extension starts it when a Haxe document opens; Welcome alone leaves it asleep. Hover documentation renders Markdown in the browser. Network loss pauses extension and language-server supervision; reconnect to the same recovery context restarts active hosts and replays unsaved document text. An explicit language-server Stop remains stopped. Remote code inspection never probes the editor's localhost compiler ports; Build, Run and terminals execute on the session host.

The server currently refuses moving a file or folder while it contains an open CRDT document, including an open destination. Shared-document renames require stable document identities and coordinated path changes before this restriction can be lifted.

`node tests/web/session.mjs --dir bin/web/rayde` checks opening, editing and saving a real session file, large replies and an extension service round trip. It creates a temporary workspace from `tests/fixtures/browser-session`. `tests/SessionAsyncChecks.hx` checks concurrent replies, deadlines, early process output and disconnection under Ash. `SessionEditorChecks` covers asynchronous readiness, stale projections, undo, save failure and binding cleanup. `node tests/web/collaboration.mjs bin/web/rayde` drives two full WASM editors with separate browser storage through edits, undo, Save, session restart, reload and replacement-state fencing. `web/session`'s browser tests also cover equal-name workspace replacement, account-scoped drafts and legacy cache isolation.

`node tests/web/extensions.mjs bin/web/rayde` checks first-open previews, interactive updates, menu and command reload, runtime error containment and browser refresh against a real extension host. `ExtensionOutputChecks` covers stack locations and malformed isolated output.

`SessionLspChecks`, `SessionLspQueueChecks` and `SessionLspReconnectChecks` cover framed remote LSP, bounded queues, cancellation, idle wakeups, offline recovery and stale process handles. `node tests/web/lsp.mjs bin/web/rayde` opens the full browser editor with the built-in extension and a real session-hosted Rayzor, then checks semantic hover, Markdown, live diagnostics and recovery after a sustained connection loss. It needs built session and extension-host binaries plus Rayzor; `RAYDE_RAYZOR_LSP` and `RAYZOR_STD_PATH` select its executable and standard library.

## Cloudflare account gateway

`web/cloud` implements GitHub App sign-in, account sessions, repository authorization and the workspace gateway in Rust compiled to Workers WASM. SQLite-backed Durable Objects keep account and workspace metadata. The browser uses an HttpOnly cookie; GitHub tokens and private compute credentials stay on the server. Node packages only build and test the browser and Worker artifacts.

See [the gateway setup](../web/cloud/README.md) for local tests and configuration. The local tests mock GitHub and the compute provisioning API, then connect to a real Rust session server. They do not deploy a service or provision a production sandbox. The document store still lives in the session process; Durable Object CRDT authority and the MSB compute provider remain separate integrations.
