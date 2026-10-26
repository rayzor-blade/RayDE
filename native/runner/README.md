# MSB workspace runner

`rayde-runner` is the Rust compute provider for the local workspace pilot. The Cloudflare Worker authenticates users and coordinates recovery; this service starts `rayde-session` inside MSB guests on a separate Linux host. Durable Objects do not run the VMM.

## Build and configure

The tested host is Linux x86_64 with KVM and **MSB 0.7.11**, using its local backend. Cache `alpine:3.23` before starting. Build a static Linux session executable for the guest:

```sh
RUSTFLAGS="-C target-feature=+crt-static" cargo build \
  --manifest-path native/session/Cargo.toml --release \
  --target x86_64-unknown-linux-gnu
cargo build --manifest-path native/runner/Cargo.toml
```

Create a private random control credential in a file with mode `0600`. Keep the configuration and state directory outside the repository:

```json
{
  "listen": "127.0.0.1:9791",
  "stateRoot": "/home/runner/.rayde-session/runner/state",
  "msb": "/home/runner/.local/bin/msb",
  "sessionBinary": "/home/runner/bin/rayde-session",
  "secretFile": "/home/runner/.rayde-session/runner/secret",
  "image": "alpine:3.23",
  "memoryMib": 512,
  "cpus": 1,
  "maxWorkspaces": 2,
  "maxDurationSeconds": 3600
}
```

Run `rayde-runner --config /private/config.json`. Only loopback listeners and WebSocket addresses are accepted. Forward the port over SSH when the local Worker runs on another machine. `publicUrl`, when needed, is the loopback `ws://` base address visible through that forwarding. Configure the local Worker's `RUNNER_URL` and private `RUNNER_SECRET` accordingly. Never send either credential to browser code.

For test repositories, `localRepositories` can explicitly bind `{ "owner": 1, "repository": 111, "path": "/absolute/git/repository" }`. This bypasses GitHub authorization only for that operator-configured pairing. Leave it empty for real repository access.

## Lifecycle and isolation

The service implements the [Worker's provisioning contract](../../web/cloud/README.md#compute-provider-contract). It rechecks GitHub user/repository access, prepares a bounded Git checkout, persists the owner/repository binding, and returns a private connection. Duplicate opens reuse the same guest and credential. State is single-writer, and interrupted operations retain admission until cleanup is confirmed.

Git runs on the host with ambient configuration, hooks and filters disabled. A bare clone and bounded archive extraction avoid running project programs there. GitHub credentials are used only for authorized host requests and clone authentication; they do not enter guest files, arguments or configuration. The pilot accepts up to 10,000 entries and 64 MiB of tracked file contents. Symlinks, submodules and other unsupported entries are refused.

Guests use restricted, multi-tenant mode, no network, private owned `/workspace` and `/state` volumes, CPU/memory bounds and a maximum lifetime. The Alpine pilot supplies the session, filesystem and shell services; Haxe/Rayzor and extension-host toolchain images remain separate work.

No guest port is published. The runner authenticates WebSockets before creating an MSB command-stream bridge to the guest's loopback session port. The gateway credential stays on the host; guest-local authentication is separate. Closing a socket releases its bridge. `rayde-session bridge --port N` is a byte-faithful stdin/stdout adapter for the existing framed transport and exits on EOF.

Authenticated `POST /workspaces/delete { "id": "…", "owner": 1 }` closes connections and removes only verified runner/workspace-labelled compute. It is idempotent. Explicit deletion rotates the credential; reopening then starts a new generation. Ordinary runner shutdown preserves guests and their records for reconnect.

A missing guest or changed document-state identity returns `409` and preserves the recovery-required record. It never silently replaces a used workspace with a fresh Git clone. An agent-verified guest may restart its session process while keeping private state. Host reboots, unexpected inventory and unverifiable runtime ownership require reconciliation before signalling or replacement. Maximum-lifetime expiry is not automatic workspace recovery.

## Verification

```sh
cargo test --manifest-path native/runner/Cargo.toml
RAYDE_TEST_SESSION=/absolute/static/linux/rayde-session \
  cargo test --manifest-path native/runner/Cargo.toml --test msb -- --ignored
```

The explicit test creates and cleans up real labelled VMs. It covers authorization, duplicate opens, owner isolation, quota and unsafe-checkout failures, private credential containment, interleaved large frames, restart/reconnect, lost-compute refusal, credential rotation and deletion.

To run the full browser flow through a forwarded runner, create a private JSON file containing `url` and `secretFile`. Configure its fixed local repository as owner `1`, repository `111`, with `build.hxml` and `src/Main.hx`. From `web/cloud` run:

```sh
RAYDE_MSB_RUNNER_CONFIG=/private/runner-test.json \
  node test/browser-flow.mjs ../../bin/web/rayde
```

The fixture emulates GitHub and Cloudflare storage while the Rust Worker uses the real runner and guest. Delete the test workspace through the runner afterward. JavaScript here is test tooling; both backend services run in Rust.

This milestone needs no Cloudflare account. Production deployment still needs real authentication/domain/storage resources, private compute ingress, audited runtime isolation, revocation and usage policy. Full filesystem/Git recovery, external-write reconciliation, stable document identities and fenced compute replacement remain tracked separately; `automaticRestore` stays disabled.
