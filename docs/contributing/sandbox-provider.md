# Sandbox provider

`native/sandbox` (`rayde-sandbox`) is the interface a sandbox backend implements for RayDE's runner and for other clients that need sandboxes. It is the common denominator of what `rayde-runner` asks of MSB today, plus the options a GPU session class needs. Nothing calls it yet: the runner still shells out to `msb` directly.

## What a backend provides

| Need | Call |
| --- | --- |
| Say what it can do | `capabilities()`: persistent volumes, snapshots, fork, GPU, egress allowlist, warm pool, a sandbox limit |
| Persistent workspace and state disks | `create_volume`, `volume`, `remove_volume` |
| Start from an image or a snapshot | `create(SandboxSpec)`, idempotent for the same spec |
| Find what a control plane left behind | `get`, `list(labels)`, `ping` |
| Talk to the session inside | `spawn` (piped stdio, for the bridge), `run` (bounded capture with a deadline), `copy_in` |
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
| `run` | `msb exec <name> --quiet --no-stdin -- ...`, output capped at 64 KiB, with a timeout |
| `copy_in` | `msb copy <host> <name>:<guest>` |
| volumes | `msb volume create/inspect/list/remove` (disk kind, ext4, a `disk.raw` the runner checks and binds) |
| `remove` | `msb remove --force --label ... --label ...` |

Not expressible in MSB 0.7.11: GPU, and a per-sandbox egress allowlist beyond what its network flags give. Its `capabilities()` would say so.

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
