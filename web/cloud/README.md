# Cloudflare workspace gateway

Authentication and workspace orchestration are Rust (`src/`), compiled to Workers WASM. The generated JavaScript is Workers SDK glue. npm dependencies are development tools and test fixtures; there is no Node production service.

## Public demo and workspace URLs

The editor bundle opens a bootstrapped example on `rayde.org` and `www.rayde.org`, with `Main.hx` already visible. `?demo=1` enables the same entry locally; `?demo=0` disables it. Demo files stay in browser storage and do not provision a private workspace. Signing in from the public demo navigates to the app host; it does not query private account APIs from the landing origin.

Set the account Worker's `APP_ORIGIN` to `https://app.rayde.org` for deployment. Its root opens Welcome/repository selection; owned workspaces open at `https://app.rayde.org/{session_id}`. The edge authenticates those pages before serving the editor, and sign-in returns to the same workspace. The browser derives its authenticated socket from the path; connection credentials stay off the URL. `ASSETS_ORIGIN` supplies the static editor bundle, including the index served for workspace paths. These hostname defaults do not configure DNS or deploy either site.

In the app, GitHub sign-in opens a separate window and updates the existing editor after the HttpOnly session cookie is verified. Keep popup windows enabled for the app origin. The callback uses a random, per-attempt BroadcastChannel because the editor's isolation policy separates its opener across the GitHub navigation. No access tokens cross that channel.

**New Project** opens the template grid, then a repository form. The selected starter is committed to a new personal GitHub repository, private by default, before compute provisioning starts. The GitHub App needs **Repository creation** and repository **Contents: read and write** permissions; existing installations must approve permission changes. Opening existing repositories only needs read access. Creation retries use a Durable Object record and refuse ambiguous creation or concurrent branch changes instead of overwriting files. A compute failure leaves the created repository available for retry.

## Local checks

The build script installs the repository's pinned Rust nightly, the `wasm32-unknown-unknown` target and `worker-build` **0.8.7**. Build tools are cached under Cargo's home, separately from other installed versions. npm dependencies are build/test tooling only.

```sh
npm ci
npm test
```

Build `native/session` before running tests. The gateway test starts an isolated Rust workspace server. GitHub and compute provisioning are mocked; tests cover OAuth/PKCE, CSRF, repository access/pagination, token refresh, Durable Object persistence, ownership checks, recovery identity across compute restarts/replacements, real workspace reads and logout disconnection. To exercise the full browser UI after building `bin/web/repositories`, run `node test/browser-flow.mjs`. It needs Chrome and the development dependencies in `web/session`.

For a locally configured GitHub App, copy `.dev.vars.example` to `.dev.vars`, fill it outside version control and run `npm run dev`. Configure the App callback to `http://127.0.0.1:8787/auth/github/callback`. Set its post-install setup URL to `http://127.0.0.1:8787/?repositories=1`. Grant the permissions above and allow users to choose installations/repositories. An expired user token can be refreshed if expiring tokens are enabled for the App. `APP_ORIGIN` is the editor origin; `ASSETS_ORIGIN` serves the built browser assets behind the same origin. `LOCAL_DEV=1` permits local HTTP/WS; omit it for deployment and use HTTPS/WSS.

## Staging deployment

The checked-in configuration targets `rayde-workspaces-staging` and its app, assets and preview custom domains. Build the Rust Worker locally and upload its compiled output:

```sh
cd web/cloud
npm ci
npm run build
npm run deploy:prebuilt -- --dry-run
npm run deploy:prebuilt
```

`npm run build` records content hashes for the Rust/build inputs and emitted artifacts in ignored `build/prebuilt.json`. Deployment refuses missing, modified or stale builds before contacting Cloudflare. `npm run deploy` is an alias for the same checked upload. Wrangler bundles the generated JavaScript glue and uploads the already compiled WASM; deployment does not invoke Cargo. Runtime variables and domains can change without recompiling Rust.

In the Worker's Cloudflare Settings → Builds, turn on **Disable builds** and cancel an existing Git-triggered build. Otherwise that separate pipeline will continue running its configured Rust build command. The repository can remain connected for reference. Compiled Worker output stays outside Git; local deployment uploads it directly to Cloudflare. The dashboard Worker name must match the Wrangler name.

Store `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` and `RUNNER_SECRET` as Cloudflare Worker secrets so deployments preserve them. `GITHUB_APP_SLUG` is already a normal variable. Enable expiring user tokens on the GitHub App; leave authorization during installation disabled because RayDE starts its own state/PKCE flow. Webhooks and device flow are not implemented. Do not deploy `LOCAL_DEV`.

Project creation currently uses the signed-in user's personal account. Install the App on that account with **Repository creation: write** and **Contents: write**, and approve permission updates on the installation. An organization-owned private App can only be installed on its owning organization; it must allow installation on other accounts to support personal-account projects. The configured slug, Client ID and client secret must belong to the same App.

`WORKSPACE_FILES` binds the private `rayde-workspace-files-staging` bucket. `EDITOR_ASSETS` binds the separate `rayde-editor-assets-staging` bucket. The Rust Worker streams editor assets from that bucket on `assets-staging.rayde.org` and through app-origin asset paths; the bucket itself needs no public access. This supports editor files above the Workers Static Assets per-file limit without proxying the assets hostname back into the same Worker. Workspace pages remain uncached and owner-authorized.

For atomic updates, use [versioned browser releases](../../docs/contributing/browser-releases.md). This packages the complete landing/editor/demo bundle and verifies remote bytes before promotion; existing root objects remain the legacy fallback until a release pointer is published.

App previews use `preview-staging.rayde.org`, isolated from the authenticated editor origin. Production runner HTTPS/WSS ingress, GitHub secrets, asset publication and deployed runtime checks must be ready before testing a complete repository workspace. Domain creation alone does not provision compute. Local development uses the localhost origin overrides and `EDITOR_ASSETS_SOURCE=origin` in `.dev.vars.example`, retaining its external asset server even when Wrangler binds emulated R2.

`WORKSPACE_FILES` binds private R2 payload storage. Local tests and `wrangler dev` use emulated R2; they need no Cloudflare account. Before deployment, create the bucket named in `wrangler.jsonc` and keep public bucket access disabled. A missing binding refuses hosted file writes before compute executes them.

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

The provider must reuse the workspace ID on retry, authorize the owner/repository pairing, and perform checkout in its trusted control plane. Never expose the GitHub token to guest programs, arguments, logs, disk configuration or a public preview. Return a private connection credential, accessible only to the gateway.

For a tunnel-backed runner, configure `RUNNER_SESSION_ORIGIN` with its HTTPS origin alongside `RUNNER_URL` and the private `RUNNER_SECRET`. Both provisioning and session WebSockets require that credential. The origin setting refuses a returned session on another host before any credential is sent there. The native runner continues listening on loopback and advertises its explicit `wss://` ingress address.

The Rust [MSB runner](../../native/runner/README.md) supplies this contract for local Linux/KVM testing, including the NUC. It uses labelled, bounded guests and private command-stream transport without publishing guest ports. Its `409` recovery-required response preserves used workspace state rather than recloning it. Local GitHub/DO/R2 emulation can exercise the real runner without a Cloudflare account; this is not yet a production provisioning deployment.

The gateway supplies the compute token in the session handshake and relays the existing protocol. Its account/workspace metadata persists in Durable Objects; repository-session documents remain in the Rust session process. Cloud Sync text uses the shared journals described below. It closes upstream connections when clients disconnect. An interrupted upstream requires reconnecting. A running upstream socket keeps its actor active; this is not a fully hibernating document runner.

Each workspace admits eight connections, counting upstream handshakes in progress. Overflow returns HTTP 429 before dialing compute. Upstream opens have a ten-second deadline; failure, timeout and sign-out cancel the attempt and release its reservation. Established slots release on client close, invalid input, backend loss or sign-out. This is a workspace admission bound, separate from account-wide usage policy.

## Anonymous demo admission

This API is disabled by default. Enabling it requires `DEMO_ORIGIN`, `DEMO_RELEASE` (the pinned Pocket Studio bundle SHA-256), `DEMO_TOOLCHAIN` (the prepared image digest), and optional `DEMO_MAX_SESSIONS` (default one, maximum eight). The runner must independently allow the same source release. A mismatched toolchain cannot become ready. The browser opens the verified public source first, then starts admission after the editor renders. Attachment retains its document objects, local edits and undo history.

Same-origin `POST /api/demo/open` returns a preparing lease immediately and sets a short-lived HttpOnly cookie. `GET /api/demo/status` reports preparation; `/api/demo/socket` upgrades only the cookie's workspace. `POST /api/demo/retry` retries that lease, and `POST /api/demo/end` releases it. GitHub sign-in and sign-out do not change anonymous ownership. Caller-supplied repository, release and workspace IDs are ignored. No runner credential enters the browser.

The separate `DemoAdmissions` and `DemoWorkspaceSession` Durable Objects enforce a fifteen-minute lifetime, five-minute idle deadline, bounded admission/retries and aggregate capacity. Status polling does not extend idle time. Cleanup disconnects the visitor, waits for an unfinished launch, deletes compute and disks, then purges that workspace's private recovery payloads. Failed cleanup keeps its capacity reserved for retry. Deploy the `v3` migration before enabling admission; keep the landing, asset and preview origins separate.

For local acceptance, prepare a release with `python3 scripts/site_release.py prepare` from the repository root. From `web/cloud`, run `node dev/demo-dev.mjs PRIVATE_CLIENT_JSON --release RELEASE_DIRECTORY`. The private JSON names the loopback runner URL, credential file, toolchain digest and demo release as `url`, `secretFile`, `toolchain` and `release`. This development emulator runs the Rust Worker and real runner; it verifies and stages the immutable release into local R2 before promoting it, including the isolated cached app preview. Without `--release`, the harness uses `--assets URL` for editor assets only.

## Saved document recovery

Hosted Save requests a complete, checksummed CRDT snapshot from compute and commits it to the workspace Durable Object before returning success to the editor. The browser receives a small checkpoint receipt; the snapshot stays on the service side. A failed durable write returns a Save failure even if compute already wrote the file, so the editor retains its dirty state. Hosts advertise `hello.checkpoints = 1`; older hosts must be updated before hosted Save can confirm recovery.

Snapshots are keyed by document identity, path and native recovery generation within the workspace object. The gateway captures identities from successful compute opens and verifies them on Update and Save. Recreating a deleted path allocates separate records; its predecessor's checkpoint and journal remain exportable. Existing unbound records gain an identity only after compute proves it contains their acknowledged history. Saves for the same identity merge their Yrs states, so an older reply cannot roll back saved edits or deleted text. Incompatible histories are refused; fresh compute generations remain separate. Chunk payloads, manifest and quota index commit together through the storage bulk API; replacing a shorter snapshot also clears obsolete chunk payloads. The prototype bounds encoded state to 4 MiB per record, 512 records and 64 MiB of state payload per workspace. These implementation bounds do not define paid storage tiers or a Cloud Sync bucket's size.

Exports include `manifest.documentId` for bound records. Trusted `/checkpoint/import` calls include that `documentId` when updating the same record. Imports without one remain historical, unbound records and cannot replace a different bound document's selected head. Browser identity migration and coordinated hosted moves are still pending; hosted `documentIdentities` and `closedDocumentMoves` remain disabled.

The trusted control plane can call the Durable Object's internal `/checkpoints` (IDs and usage), `/checkpoint` (`{owner, id}`), and `/checkpoint/import` (`{owner, path, source, checkpoint}`) operations. They are not public Worker routes. After selecting a saved generation, a provider can restore a released document on replacement compute with native `doc.restore {path, checkpoint}` before starting workspace programs. That operation checks write authorization, path containment, checksum and complete CRDT state; it refuses a document already materialized in memory. Browser-forwarded `doc.restore` is denied.

For an unsaved journal, materialize the selected saved file first, then use native `doc.restore {path, checkpoint, mode:"buffer", diskSha256}` with `hello.bufferedRestore = 1`. The existing UTF-8 file must match the supplied SHA-256. This installs the graph in private session state without writing it to the file; background flush, close and restart preserve the distinction. A pending Save records the graph and both disk hashes together, allowing recovery before or after its disk write. Explicit Save checks the disk baseline; unrelated changes stop recovery rather than replacing either version. These checks do not fence concurrent external writes, and the provider must still supply a consistent filesystem/Git manifest, stable identities and compute leases before automatic recovery can be enabled.

Native file mutations also protect released recovered drafts through checksummed, host-local path bindings. Moves, directory deletion and replacement through aliases refuse unsaved or conflicting buffers after restart. Clean matching graphs return to ordinary file-backed recovery before the mutation; their CRDT history is retained. Legacy unbound buffers must be reopened to bind them before filesystem mutations. This is draft protection, not distributed document identity or a filesystem transaction against external writers.

## Unsaved edit recovery

Hosted `doc.update` acknowledgements wait for a Durable Object journal write. Hosts advertise `hello.journals = 1`; the gateway requests a delta against its durable vector and strips that private payload from browser replies. The browser receives `durableUpdate {id, sequence}`. Its `hello.durableUpdates` flag also requests a barrier on reconnect, even when compute already has every local edit. A failed write keeps edits unsynchronized in browser recovery.

Journals use a complete baseline followed by incremental deltas. They compact after 64 segments or 256 KiB of tail payload and reuse bounded chunk slots. Small usage counters change on each write; the full ID registry changes only when a record is admitted. Journals and Save checkpoints share 512 records and 64 MiB of raw payload per workspace; each record is bounded to 4 MiB. These are prototype guards, separate from paid storage tiers.

The internal owner-checked `/journals` and `/journal {owner, id}` operations list usage and export a complete checkpoint for trusted `doc.restore`. They are not public routes. Updates and Save share FIFO ordering, at most 256 queued operations and 8 MiB of encoded update payload. Native graph history missing a durable vector is refused with `journal-conflict` until the control plane restores it.

This protects acknowledged browser edits and compute dependencies captured at their barriers. Complete filesystem/tombstone recovery, changes after the last barrier, automatic compute restoration, leases, retention/cleanup and hibernation remain separate work. Journal availability alone does not establish full workspace continuity.

## Filesystem fencing and restore selection

Hosted `fs.write`, `fs.mkdir`, `fs.remove` and `fs.rename` use the same bounded FIFO as document recovery. Compute executes only after a mutation intent is durable. Confirmed outcomes return a `recoveryMutation` receipt; unknown outcomes remain fences. The ledger stores paths, outcomes and write-payload references. Its prototype limits are 1,024 mutations, 512 selected document heads and 1 MiB of metadata. File requests may reserve up to 16 MiB of queue space; document updates retain their 8 MiB admission bound.

Direct file writes reserve payload space with the intent, then upload to immutable, SHA-256-addressed R2 objects scoped to the workspace object. Compute receives the request only after upload or verified reuse. Failed/interrupted uploads remain accounted for; upload failures never reach compute. Text, binary and empty files are supported. Retained payloads survive overwrite/delete and deduplicate within a workspace. The prototype allows 12 MiB per file and 64 MiB / 1,024 distinct payloads per workspace, separate from document recovery and paid-tier limits. Retention and reclamation are not yet implemented.

Confirmed Save and journal records update a selected head atomically with their payload and accounting. Direct writes and directory operations invalidate older matching heads. Same-content barriers can reselect a record; recreating a directory cannot revive older child snapshots. Historical imports cannot promote a selection, and Save refuses imported history missing from compute.

The trusted control plane calls `/recovery/plan {owner, source, revision?}` to list records, invalidations and mutation outcomes. The source is mandatory and ownership is checked; the endpoint is not public. A stale revision returns 409. Selected records carry a payload stamp for verification during materialization.

`/recovery/file {owner, source, mutation, revision}` exports a confirmed write's bytes as base64. Source and revision are mandatory; pending, uncertain and refused operations cannot be exported. Length and SHA-256 are checked on export, and the catalog revision is checked again after object I/O. This is an `operation-payload`, not the current file contents: a materializer must apply the complete ordered history and respect later moves/deletions. Neither this route nor R2 object keys are exposed through the public gateway.

The response is a partial `confirmed-document-heads` catalog with `automaticRestore:false`. Full filesystem state, reconciliation of external/program writes and path identities, and fenced compute leases are required before automatic restoration. Uncertain mutations cannot be cleared by a later snapshot alone. `node test/browser-flow.mjs <bundle> --buffered-restore` checks the restored dirty tab in the full WASM editor, an initial Save before typing, unsaved edits staying off disk, durable Save and reload.

## Recovery identity

On a successful handshake, the gateway scopes browser recovery to its Durable Object, logical workspace and verified owner, together with the compute document-state identity. Ordinary compute restarts retain recovery when that state directory is preserved. A fresh compute disk changes the recovery context and requires reopening rather than replaying an older replica into a new baseline. The provider must preserve or restore the document state to retain that continuity. The local MSB runner now preserves named workspace/state disks and replaces missing VMs from the same verified toolchain, with bounded retries and generation/credential rotation. The gateway serializes recovery requests, rechecks repository access and consumes refreshed credentials privately. Cross-host restoration of bound compute recovery metadata remains separate integration work. Backends without a recovery identity disable durable browser recovery.

Deployment also needs a real GitHub App, secrets configured with Wrangler, a sandbox provider, scoped compute ingress, repository revocation handling for active sessions, and storage/usage policy. Local tests do not establish those production properties. Do not enable process execution in an unisolated development session.

## Shared Cloud Sync document histories

The Rust gateway supports shared text histories. Restored browser sessions and configured desktop development workspaces attach fresh supported documents through the existing editor bridge. Pushed notices request missing history through the same durable exchange used by Open/edit/Save barriers. Production desktop sign-in remains separate work. Existing unbound session graphs remain on snapshot sync; untagged browser caches pause before mixing with a cloud history.

An authenticated owner or that workspace's publish capability can POST to `/api/sync/workspaces/{id}/documents/open` with `{path,generation}`. The file must be published UTF-8 text. The response contains a complete Yrs update, `seed`, `lineage`, `sequence`, `vector`, current text `sha256`, and saved-file `anchor`. Independent replicas apply that update before making edits. The seed is deterministic and bound to workspace, path and the generation where its lineage began. Recreating a retired path allocates another lineage.

POST `/documents/exchange` with `{path,lineage,from,update}`. The last two fields are base64 Yjs v1 encodings: `from` is the last acknowledged server vector, and `update` includes every edit since it. Concurrent updates merge; retries are idempotent. The response supplies missing history and the new vector/sequence. Deletions travel even when vectors are unchanged. A missing dependency or stale lineage returns 409 without changing the acknowledged head. The native transport is `rayde_sync::client::documents`; its blocking I/O belongs on a worker.

GET `/documents/watch` upgrades to a hibernatable WebSocket, authenticated by the owner's cookie or workspace publish capability. Cookie upgrades require `Origin: APP_ORIGIN`; native credentials travel only in headers. After `{ev:"ready",version:1,workspace}`, send `{op:"subscribe",path,lineage,sequence}` using the last privately persisted journal sequence. The server sends `{ev:"changed",path,lineage,sequence}` only after the canonical commit. Fetch missing history through `/documents/exchange`, validate and persist it, then send `{op:"ack",path,lineage,sequence}`. `{op:"unsubscribe",path}` releases a document. A retired notice adds `retired:true`; preserve local recovery and reopen rather than adopting a replacement history.

Only one notice per document may await acknowledgement; later changes coalesce behind it. Limits are 32 connections, 256 documents per connection, 512 subscriptions per workspace, 64 KiB per message or connection record, and 512 messages/128 KiB received per second. Missing acknowledgements close the socket after 60 seconds. Persisted subscription records and small socket attachments permit actor hibernation without retaining graphs. Expiry alarms, owner access revocation (`POST /access/revoke`), and account logout fence live subscriptions. Closing the last watcher cancels its alarm. Local fixtures exercise these rules; deployed Cloudflare hibernation still requires verification.

The workspace Durable Object serializes exchanges with snapshot publication. A snapshot may keep a pending head or integrate its exact text; replacing or deleting pending shared text is refused. Integrating a head preserves its CRDT history. Replacing a clean file retires that lineage, so stale replicas cannot write into a recreated path. Binary files and structural changes remain snapshot operations.

Each journal commit atomically stores metadata, quota and new chunks before replying. Journals compact after 64 segments or 256 KiB of deltas. Checksums and dependency checks reject incomplete storage; idle objects retain encoded history rather than materialized graphs. Limits are 1 MiB of text and 4 MiB of encoded history per file, 64 MiB per workspace and 256 path slots including retired paths. Payloads count against workspace and account allowances. Retired payloads are cleared; retired path slots remain bounded metadata. These are pilot implementation limits, separate from paid storage tiers.
