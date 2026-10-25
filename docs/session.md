# Workspace sessions

A session serves one workspace (a directory) over a WebSocket, so an editor in a browser page can work on files that live elsewhere. It is `native/session`, a Rust crate with no Node in it.

```sh
cargo build --manifest-path native/session/Cargo.toml
native/session/target/debug/rayde-session --root path/to/workspace --exec
```

It prints the page's address and a token. `--web web/session/dist` serves the demo page and the browser client beside the socket (`cd web/session && npm install && npm run build`; the npm packages only build and test the browser bundle).

## What a client can do

Requests are JSON over `ws://host/session`; the first must be `hello` with the token.

| Area | Operations |
| --- | --- |
| Files | `fs.list`, `fs.stat`, `fs.read`, `fs.write`, `fs.mkdir`, `fs.remove`, `fs.rename`. Paths are relative to the workspace; `..` and symlinks that leave it are refused. |
| Documents | `doc.open`, `doc.update`, `doc.save`, `doc.close`. A text file is a Yrs document; clients exchange state vectors and updates, so edits made offline merge after a reconnect. The session writes the file once edits settle, and takes an edit made to the file outside the session as an edit of the document. |
| Programs | `proc.spawn`, `proc.write`, `proc.close-input`, `proc.kill`; output arrives as `proc.out` and `proc.exit` events. Only with `--exec`, only in workspace directories, and stopped when their connection closes. |

The browser client (`web/session/src/client.js`) is local-first: edits go to a Yjs document in the page and IndexedDB first, and travel when the session is reachable.

## Signing in before the first edit

With `--auth-secret S --login-url URL`, anyone may look, but every change answers `auth-required` (with the login URL) until the connection sends `auth.login` with a credential signed with `S`: `base64url(payload).base64url(HMAC-SHA256)`, the payload being `{login, id, exp}`. This signed-credential mode is separate from the Cloudflare account gateway below; that gateway authenticates the connection and supplies the private compute token. `rayde-session issue --auth-secret S --login NAME --id N` mints one for development.

## Tests

`cargo test --manifest-path native/session/Cargo.toml` runs the protocol against a real socket. `cd web/session && npm test` drives the demo page in headless Chromium.

## RayDE in the browser

Build the page with `scripts/build-web.sh`. It needs Ash's `ash-channel` Haxe library, `ash_channel.wasm`, and `channel-agent.mjs`; `ASH_CHANNEL_ROOT` selects that checkout and `ASH_CHANNEL_WEB` its built side module. `WEB_LIBS` selects the ashui, window and GPU web libraries. Use matching Ash and window libraries with future-aware browser idle waits. The page agent is bundled with `web/session`'s development dependencies (`npm ci` there first).

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

The full editor currently uses file reads and explicit saves over the session. The demo client's Yjs offline document synchronization is separate; it is not yet bound to the full editor's text buffers. Remote language-server transport and PTYs are also separate work.

The server currently refuses moving a file or folder while it contains an open CRDT document, including an open destination. Shared-document renames require stable document identities and coordinated path changes before this restriction can be lifted.

`node tests/web/session.mjs --dir bin/web/rayde` checks opening, editing and saving a real session file, large replies and an extension service round trip. It creates a temporary workspace from `tests/fixtures/browser-session`. `tests/SessionAsyncChecks.hx` checks concurrent replies, deadlines, early process output and disconnection under Ash.

## Cloudflare account gateway

`web/cloud` implements GitHub App sign-in, account sessions, repository authorization and the workspace gateway in Rust compiled to Workers WASM. SQLite-backed Durable Objects keep account and workspace metadata. The browser uses an HttpOnly cookie; GitHub tokens and private compute credentials stay on the server. Node packages only build and test the browser and Worker artifacts.

See [the gateway setup](../web/cloud/README.md) for local tests and configuration. The local tests mock GitHub and the compute provisioning API, then connect to a real Rust session server. They do not deploy a service or provision a production sandbox. The document store still lives in the session process; Durable Object CRDT authority and the MSB compute provider remain separate integrations.
