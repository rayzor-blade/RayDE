# Sandbox provider

`native/sandbox` (`rayde-sandbox`) is the interface a sandbox backend implements for RayDE's runner and for other clients that need sandboxes. It is the common denominator of what `rayde-runner` asks of MSB today, plus the options a GPU session class needs. `rayde-runner` talks to its sandboxes only through it: `rayde_runner::Msb` is the MSB backend, and the service is generic over any backend (`start_with`), so its open, reuse, recovery, isolation and delete flows are tested against the in-memory `Fake` without a VM (`native/runner/tests/service.rs`).

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
| `snapshot` | `msb snapshot create --sandbox <name> --name <snapshot>`; the reference is `<name>:<snapshot>` |
| `remove_snapshot` | `msb snapshot remove <reference>` |

`create` takes the runner's `--deployment-profile multi-tenant` with `Security::Restricted`. What MSB 0.7.11 cannot express, and what the live run changed, is under The MSB backend below.

## The MSB backend

`native/runner/src/msb.rs`. The argument builders and parsers are pure and unit-tested against the flags the runner uses today. The conformance suite also passes against a live MSB 0.7.11 on the Linux/KVM NUC (twice in a row, leaving no sandboxes, volumes or snapshots behind). To run it on a KVM host, set `RAYDE_MSB_CONFIG` to a runner config file and run `cargo test --lib msb_conforms -- --ignored --nocapture`; `RAYDE_MSB_TRACE=1` prints each `msb` command that failed. `cargo test --lib msb_ -- --ignored --test-threads=1` runs it together with `msb_allowlist_blocks_other_hosts`, which also needs internet access. They create and remove sandboxes labelled `owner=conformance`.

What the live run taught the backend (each was wrong in the first draft):

- A disk volume must be at least 68 MiB to format (67 fails); advertised as `min_volume_mib`.
- Mounting a named disk volume needs `kind=disk,size=<N>M`, so `create` looks up each volume's size first.
- `msb status` has no labels, only name, state, cpus and memory; labels come from `msb inspect --format json`, from `active_config` when running and `config` when stopped.
- A snapshot is named `<sandbox>:<name>` and every snapshot command takes that whole reference. Snapshots chain within a group, so removing one with children or the group head is refused (reported as `Conflict`). Snapshots can be taken while the sandbox runs.
- A command on a sandbox that does not exist fails like any other failure, so the backend checks first and answers `NotFound`.
- `msb volume list` prints "No volumes found." on stdout with exit 0.

Egress allowlist: `Network::Allow(hosts)` is `--no-net` (deny by default) plus one `--net-rule allow@<host>` per entry, where a host is a name, `*.suffix`, IP or CIDR; entries with characters that could start another rule token are refused as `Invalid`. Checked live: the allowed name connects on 443, any other name fails to resolve (the gateway answers NXDOMAIN) and a raw IP is blocked. The rule applies to all ports and protocols of that host.

Not mapped: GPU (no flag in 0.7.11) and read-only mounts (option syntax unchecked). MSB keeps no copy of the spec, so `Msb::create` judges "the same spec" by labels, cpus and memory.

## Other backends

- **dynASB** (libkrun, virtio-gpu and Venus): GPU is a capability it can advertise. It has no volumes, no arbitrary process with stdio and no snapshot call today, so a provider on top of it needs those added (see dynASB's Linux bring-up epic).
- **nan8**: its actor-level `Executor` (deploy, send, subscribe) becomes a client of this interface instead of calling a backend directly.
- **Fake** (`rayde_sandbox::fake`): in memory, for client tests and for the conformance suite. `with_program` registers a stand-in for a guest program (the runner's service tests play the session bridge this way).

## Conformance

`rayde_sandbox::conformance::run_all(&provider, prefix)` checks idempotent create and remove, conflict rules, label selection, piped stdio, output limits and deadlines, volume persistence and refusal while mounted, and that every unadvertised feature answers `Unsupported`. A backend's tests call it with a unique prefix. The fake passes it with every feature and with none.

## Not decided

- A dyn-compatible form for clients that choose a backend at runtime. The trait uses `async fn` in traits for now, so it is generic, not boxed.
- Fork and warm-pool calls: advertised as capabilities, no calls yet.
- Streaming a GPU session's pictures. That is the surface protocol's job, not this interface's.
