# MSB workspace runner

`rayde-runner` is the Rust compute provider for the local workspace pilot. The Cloudflare Worker authenticates users and coordinates recovery; this service starts `rayde-session` inside MSB guests on a separate Linux host. Durable Objects do not run the VMM.

## Build and configure

The tested host is Linux x86_64 with KVM and **MSB 0.7.11**, using its local backend. Cache `alpine:3.23` for filesystem-only checks, or prepare the complete toolchain below. Build a static Linux session executable for the guest:

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

## Toolchain template

Prepare a disk template on a compatible **Ubuntu 26.04 x86_64** KVM host. Supply Linux Ash, Rayzor and `rayde-extension-host` binaries, Rayzor's matching `compiler/haxe-std`, and the official Haxe **4.3.6 Linux64** archive. The script checks the pinned Haxe archive hash, ELF architecture, native dependencies and guest file checksums. Use binaries built for the guest ABI.

```sh
python3 scripts/prepare-toolchain.py \
  --ash /opt/build/ash/ash \
  --rayzor /opt/build/rayzor \
  --extension-host /opt/build/rayde-extension-host \
  --stdlib /opt/build/rayzor-src/compiler/haxe-std \
  --haxe-archive /opt/downloads/haxe-4.3.6-linux64.tar.gz \
  --output /private/toolchain.json
```

Preparation runs in a disposable, network-enabled builder. It installs Git, Neko and published `ashui`, `ashui-components` and `ashui-icons` 0.2.2, compiles/runs a Haxe/Ash probe and builds Pocket Studio. It installs platform-correct built-in extension manifests, records installed package versions and file hashes, then captures and verifies a disk-only MSB snapshot. Builder compute is removed afterward; keep the verified snapshot. This explicit preparation is separate from page startup. Package repositories may change; preserve the resulting template and digest rather than treating a later rebuild as the same image.

Copy the output object's `snapshot` and `digest` into the runner configuration as `"toolchain": { ... }`, and use `"memoryMib": 1024`. Each launch verifies snapshot integrity, installed files and the expected manifest identity. The runner copies its configured static session executable into the guest, loads `/opt/rayde/environment.json`, and starts supervised extension hosts there. Installed sources use read-only session mounts. Existing live workspaces refuse a different toolchain identity until migrated.

## Lifecycle and isolation

The service implements the [Worker's provisioning contract](../../web/cloud/README.md#compute-provider-contract). It rechecks GitHub user/repository access, prepares a bounded Git checkout, persists the owner/repository binding, and returns a private connection. Duplicate opens reuse the same guest and credential. State is single-writer, and interrupted operations retain admission until cleanup is confirmed.

Git runs on the host with ambient configuration, hooks and filters disabled. A bare clone and bounded archive extraction avoid running project programs there. GitHub credentials are used only for authorized host requests and clone authentication; they do not enter guest files, arguments or configuration. The pilot accepts up to 10,000 entries and 64 MiB of tracked file contents. Symlinks, submodules and other unsupported entries are refused.

Guests use restricted, multi-tenant mode, no network, private owned `/workspace` and `/state` volumes, CPU/memory bounds and a maximum lifetime. The Alpine profile supplies session, filesystem and shell services. The prepared template also supplies Haxe, Ash, Rayzor, standard libraries, published Ashui packages and supervised built-in extension hosts. User guests have no network; dependency installation requires a prepared template or a future controlled package service.

No guest port is published. The runner authenticates WebSockets before creating an MSB command-stream bridge to the guest's loopback session port. The gateway credential stays on the host; guest-local authentication is separate. Closing a socket releases its bridge. `rayde-session bridge --port N` is a byte-faithful stdin/stdout adapter for the existing framed transport and exits on EOF.

Authenticated `POST /workspaces/delete { "id": "…", "owner": 1 }` closes connections and removes only verified runner/workspace-labelled compute. It is idempotent. Explicit deletion rotates the credential; reopening then starts a new generation. Ordinary runner shutdown preserves guests and their records for reconnect.

`persistentDisks` defaults to true: `/workspace` and `/state` use separate named ext4 disks, bound to the runner/workspace and a private marker. A missing verified guest can be replaced from the same toolchain while attaching those disks. Replacement is serialized, closes stale connections, rotates the transport credential and generation, and requires the exact previous document-state identity. Concurrent reconnects share the replacement. Retries are bounded to three per two minutes. The gateway reauthorizes repository access and requests recovery only from providers advertising this capability; private credentials never reach the browser.

Session journal replies follow private graph persistence, and file/identity directory entries are flushed before acknowledgements. The Cloudflare gateway still commits its own durable recovery barriers. Explicit workspace deletion removes the labelled compute and its verified disks; ordinary runner shutdown preserves them.

Missing disks, changed identities, unexpected inventory and unverifiable runtime ownership require reconciliation. Legacy records without disk bindings retain their refusal behavior. Host reboots with unverifiable runtime state, lost host storage and cross-host restoration remain separate work. Recovery never substitutes a fresh Git clone for a used workspace.

## Verification

```sh
cargo test --manifest-path native/runner/Cargo.toml
RAYDE_TEST_SESSION=/absolute/static/linux/rayde-session \
  RAYDE_TEST_TOOLCHAIN=/private/toolchain.json \
  cargo test --manifest-path native/runner/Cargo.toml --test msb -- --ignored
```

The explicit test creates and cleans up real labelled VMs. It covers authorization, duplicate opens, owner isolation, quota and unsafe-checkout failures, private credential containment, interleaved large frames, restart/reconnect, lost-VM replacement, acknowledged CRDT insertion/deletion history, credential rotation and disk deletion. With `RAYDE_TEST_TOOLCHAIN` it also checks Haxe/Ash execution, Rayzor LSP symbols and Git native loading. Omit that variable for the bare Alpine profile.

To run the full browser flow through a forwarded runner, create a private JSON file containing `url` and `secretFile`. Configure its fixed local repository as owner `1`, repository `111`, with `build.hxml` and `src/Main.hx`. From `web/cloud` run:

```sh
RAYDE_MSB_RUNNER_CONFIG=/private/runner-test.json \
  node test/browser-flow.mjs ../../bin/web/rayde
```

The fixture emulates GitHub and Cloudflare storage while the Rust Worker uses the real runner and guest. Delete the test workspace through the runner afterward. JavaScript here is test tooling; both backend services run in Rust.

This milestone needs no Cloudflare account. Production deployment still needs real authentication/domain/storage resources, private compute ingress, audited runtime isolation, revocation and usage policy. Cross-host filesystem/Git materialization and reconciliation remain outstanding. Local disk-preserving replacement does not establish full cloud-backup recovery; the recovery catalog’s `automaticRestore` stays disabled.
