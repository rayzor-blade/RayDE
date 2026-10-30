# Sandbox provider

`native/sandbox` (`rayde-sandbox`) is the interface a sandbox backend implements for RayDE's runner and for other clients that need sandboxes. It is the common denominator of what `rayde-runner` asks of MSB today, plus the options a GPU session class needs. The runner's service code does not call it yet and still shells out to `msb` directly; `rayde_runner::Msb` is the MSB backend for it.

## What a backend provides

| Need | Call |
| --- | --- |
| Say what it can do | `capabilities()`: persistent volumes, snapshots, fork, GPU, egress allowlist, warm pool, a sandbox limit |
| Persistent workspace and state disks | `create_volume`, `volume`, `remove_volume` |
| Start from an image or a snapshot | `create(SandboxSpec)`, idempotent for the same spec |
| Find what a control plane left behind | `get`, `list(labels)`, `ping` |
| Talk to the session inside | `spawn` (piped stdio, for the bridge), `run` (bounded capture with a deadline), `detach` (keeps running, no stdio: how the session is started), `copy_in` |
| Recover | `snapshot`, `verify_snapshot`, create from `Template::Snapshot` |
| Tear down | `stop`, `remove` (idempotent; owned mounts go, named volumes stay) |

A feature the backend does not advertise answers `Error::Unsupported`. A name in use with a different spec, or a volume still mounted, answers `Conflict`, the same "needs reconciliation" the runner returns as `409` today.

## How it maps to MSB 0.7.11

| Provider call | What the runner runs today |
| --- | --- |
| `create` | `msb create <image> --name --cpus --memory --security restricted --label ... --max-duration ... --mount-*` |
| `Template::Snapshot` | `msb snapshot verify`, `msb snapshot restore --name ...`, then `msb modify --label ...` |
| `get`, `list` | `msb status --all --label ... --format json` |
| `ping` | `msb ping <name>` |
| `spawn` | `msb exec <name> --quiet --stream -- <command>` with stdin and stdout piped |
| `detach` | `msb exec <name> --quiet --detach --no-stdin -- <command>` |
| `run` | `msb exec <name> --quiet --no-stdin -- ...`, output capped at 64 KiB, with a timeout |
| `copy_in` | `msb copy <host> <name>:<guest>` |
| volumes | `msb volume create/inspect/list/remove` (disk kind, ext4, a `disk.raw` the runner checks and binds) |
| `remove` | `msb remove --force <name>` (the runner removes by label pair) |
| `snapshot` | `msb snapshot create --sandbox <name> --name <snapshot>` (not yet run) |

Not mapped for MSB 0.7.11: GPU (no flag exists) and read-only mounts (option syntax not checked). A per-sandbox egress allowlist is likely possible through its `--net-rule` and `--net-default` flags, whose grammar is not mapped yet, so `Msb` reports it unsupported rather than guess. `create` takes the runner's `--deployment-profile multi-tenant` with `Security::Restricted`. MSB keeps no copy of the spec, so `Msb::create` compares labels only when a sandbox of that name exists.

## The MSB backend

`native/runner/src/msb.rs`. The argument builders and parsers are pure and unit-tested against the flags the runner uses today (a restricted image sandbox, a snapshot restore with a disk mount, status JSON, volume inspect text, exec commands). The conformance test against a real MSB is `#[ignore]`d: on a KVM host with MSB 0.7.11, set `RAYDE_MSB_CONFIG` to a runner config file and run `cargo test msb_conforms -- --ignored`. It creates and removes sandboxes and has not been run yet, so the backend is untested against a live MSB.

## Other backends

- **dynASB** (libkrun, virtio-gpu and Venus): GPU is a capability it can advertise. It has no volumes, no arbitrary process with stdio and no snapshot call today, so a provider on top of it needs those added (see dynASB's Linux bring-up epic).
- **nan8**: its actor-level `Executor` (deploy, send, subscribe) becomes a client of this interface instead of calling a backend directly.
- **Fake** (`rayde_sandbox::fake`): in memory, for client tests and for the conformance suite.

## Conformance

`rayde_sandbox::conformance::run_all(&provider, prefix)` checks idempotent create and remove, conflict rules, label selection, piped stdio, output limits and deadlines, volume persistence and refusal while mounted, and that every unadvertised feature answers `Unsupported`. A backend's tests call it with a unique prefix. The fake passes it with every feature and with none.

## Not decided

- Whether the runner moves onto the trait (a refactor of `command.rs`, `volumes.rs`, `toolchain.rs` and `service.rs`) or the trait first gets a second backend.
- A dyn-compatible form for clients that choose a backend at runtime. The trait uses `async fn` in traits for now, so it is generic, not boxed.
- Fork and warm-pool calls: advertised as capabilities, no calls yet.
- Streaming a GPU session's pictures. That is the surface protocol's job, not this interface's.
