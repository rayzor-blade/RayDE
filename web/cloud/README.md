# Cloudflare workspace gateway

Authentication and workspace orchestration are Rust (`src/`), compiled to Workers WASM. The generated JavaScript is Workers SDK glue. npm dependencies are development tools and test fixtures; there is no Node production service.

## Public demo and workspace URLs

The editor bundle opens a bootstrapped example on `rayde.org` and `www.rayde.org`, with `Main.hx` already visible. `?demo=1` enables the same entry locally; `?demo=0` disables it. Demo files stay in browser storage and do not provision a private workspace. Signing in from the public demo navigates to the app host; it does not query private account APIs from the landing origin.

Set the account Worker's `APP_ORIGIN` to `https://app.rayde.org` for deployment. Its root opens Welcome/repository selection; owned workspaces open at `https://app.rayde.org/{session_id}`. The edge authenticates those pages before serving the editor, and sign-in returns to the same workspace. The browser derives its authenticated socket from the path; connection credentials stay off the URL. `ASSETS_ORIGIN` supplies the static editor bundle, including the index served for workspace paths. These hostname defaults do not configure DNS or deploy either site.

## Local checks

Install Rust's `wasm32-unknown-unknown` target and `worker-build` **0.8.7**, matching the pinned Workers SDK:

```sh
rustup target add wasm32-unknown-unknown
cargo install worker-build --version 0.8.7 --locked
npm ci
npm test
```

Build `native/session` before running tests. The gateway test starts an isolated Rust workspace server. GitHub and compute provisioning are mocked; tests cover OAuth/PKCE, CSRF, repository access/pagination, token refresh, Durable Object persistence, ownership checks, recovery identity across compute restarts/replacements, real workspace reads and logout disconnection. To exercise the full browser UI after building `bin/web/repositories`, run `node test/browser-flow.mjs`. It needs Chrome and the development dependencies in `web/session`.

For a locally configured GitHub App, copy `.dev.vars.example` to `.dev.vars`, fill it outside version control and run `npm run dev`. Configure the App callback to `http://127.0.0.1:8787/auth/github/callback`. Set its post-install setup URL to `http://127.0.0.1:8787/?repositories=1`. Grant repository Contents read access and allow users to choose installations/repositories. An expired user token can be refreshed if expiring tokens are enabled for the App. `APP_ORIGIN` is the editor origin; `ASSETS_ORIGIN` serves the built browser assets behind the same origin. `LOCAL_DEV=1` permits local HTTP/WS; omit it for deployment and use HTTPS/WSS.

GitHub authorization tokens are kept in account Durable Object storage. Browser responses contain a safe account view, a CSRF token, repository metadata and workspace status. Account cookies are HttpOnly and SameSite=Lax, with Secure on HTTPS. OAuth state expires after ten minutes; account sessions expire after seven days. Sign-out removes the account and disconnects its workspace sockets. Repository access is checked again on workspace opening and socket connection.

## Compute provider contract

The workspace Durable Object calls a trusted provisioning service, either the `RUNNER` service binding or `RUNNER_URL`, authenticated with `RUNNER_SECRET`:

```text
POST /workspaces/open
Authorization: Bearer <runner secret>

{ id, owner, repository: { id, fullName, branch, cloneUrl, ... },
  checkout: { accessToken } }

response: { url: "wss://private-compute/session", token: "private token",
            project: "build.hxml" }
```

The provider must reuse the workspace ID on retry, authorize the owner/repository pairing, and perform checkout in its trusted control plane. Never expose the GitHub token to guest programs, arguments, logs, disk configuration or a public preview. Return a private connection credential, accessible only to the gateway. This repository does not yet supply a production provisioning provider. The MSB host runtime can be used to implement one; a Durable Object coordinates it rather than hosting the VMM.

The gateway supplies the compute token in the session handshake and relays the existing protocol. Its account/workspace metadata persists in Durable Objects; document authority currently remains in the Rust session process. It closes upstream connections when clients disconnect. An interrupted upstream requires reconnecting. A running upstream socket keeps its actor active; this is not a fully hibernating document runner.

## Saved document recovery

Hosted Save requests a complete, checksummed CRDT snapshot from compute and commits it to the workspace Durable Object before returning success to the editor. The browser receives a small checkpoint receipt; the snapshot stays on the service side. A failed durable write returns a Save failure even if compute already wrote the file, so the editor retains its dirty state. Hosts advertise `hello.checkpoints = 1`; older hosts must be updated before hosted Save can confirm recovery.

Snapshots are keyed by path and native recovery generation within the workspace object. Saves in the same generation merge their Yrs states, so an older reply cannot roll back saved edits or deleted text. Incompatible histories are refused; fresh compute generations remain separate. Chunk payloads, manifest and quota index commit together through the storage bulk API; replacing a shorter snapshot also clears obsolete chunk payloads. The prototype bounds encoded state to 4 MiB per record, 512 records and 64 MiB of state payload per workspace. These implementation bounds do not define paid storage tiers or a Cloud Sync bucket's size.

The trusted control plane can call the Durable Object's internal `/checkpoints` (IDs and usage), `/checkpoint` (`{owner, id}`), and `/checkpoint/import` (`{owner, path, source, checkpoint}`) operations. They are not public Worker routes. After selecting a saved generation, a provider can restore a released document on replacement compute with native `doc.restore {path, checkpoint}` before starting workspace programs. That operation checks write authorization, path containment, checksum and complete CRDT state; it refuses a document already materialized in memory. Browser-forwarded `doc.restore` is denied.

These are explicit Save checkpoints. Unsaved-update journaling, complete filesystem/tombstone recovery, automatic compute restoration, leases, retention/cleanup and hibernation remain separate work. The current browser reconnect fence remains in force; checkpoint availability alone does not establish full workspace continuity.

On a successful handshake, the gateway scopes browser recovery to its Durable Object, logical workspace and verified owner, together with the compute document-state identity. Ordinary compute restarts retain recovery when that state directory is preserved. A fresh compute disk changes the recovery context and requires reopening rather than replaying an older replica into a new baseline. The provider must preserve or restore the document state to retain that continuity; durable CRDT authority remains a separate integration. Backends without a recovery identity disable durable browser recovery.

Deployment also needs a real GitHub App, secrets configured with Wrangler, a sandbox provider, scoped compute ingress, repository revocation handling for active sessions, and storage/usage policy. Local tests do not establish those production properties. Do not enable process execution in an unisolated development session.
