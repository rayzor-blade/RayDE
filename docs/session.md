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
