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

With `--auth-secret S --login-url URL`, anyone may look, but every change answers `auth-required` (with the login URL) until the connection sends `auth.login` with a credential signed with `S`: `base64url(payload).base64url(HMAC-SHA256)`, the payload being `{login, id, exp}`. For the published version, a Cloudflare Worker runs the GitHub sign-in and signs that credential; the session only verifies it. `rayde-session issue --auth-secret S --login NAME --id N` mints one for development.

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

Requests, process startup, output and shutdown use `ash.Future`. Readers park until a reply or stream event arrives; one sleeping deadline worker handles timeouts. UI polling only drains available messages. Page settings and the local sample files are stored in IndexedDB. With no session URL, RayDE opens the local sample.

The full editor currently uses file reads and explicit saves over the session. The demo client's Yjs offline document synchronization is separate; it is not yet bound to the full editor's text buffers. Remote language-server transport and PTYs are also separate work.

`node tests/web/session.mjs --dir bin/web/rayde` checks opening, editing and saving a real session file, large replies and an extension service round trip. It creates a temporary workspace from `tests/fixtures/browser-session`. `tests/SessionAsyncChecks.hx` checks concurrent replies, deadlines, early process output and disconnection under Ash.
