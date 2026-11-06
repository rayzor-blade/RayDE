# Landing demo container

The anonymous landing workspace uses its own Cloudflare Container per admitted visitor. Dedicated workspaces continue using the MSB runner. Initial app Preview loads cached WASM in the browser; this container supplies real Rayzor, extensions, files, terminal and changed-source builds.

## Prepare the image

On a Linux x86_64 builder, use `scripts/prepare-toolchain.py` with the same released Ash executable, matching native web tooling, Haxe archive, Linux Rayzor release/provenance and extension host as the [toolchain reference](../../runner/README.md#toolchain-template). Supply `--session`, `--preview-operator`, `--preview-tools` and `--demo-bundle` too. Replace `--output` with:

```sh
--container-context /private/rayde-demo-context \
--base ubuntu:26.04@sha256:VERIFIED_BASE_IMAGE_DIGEST
```

This only stages a build context; it starts no VM, daemon or deployment. Build it with an OCI builder, targeting `linux/amd64`. Package installation, Haxe/WASM compilation and Rayzor warming happen during that build. Preparation requires zero settled Rayzor errors and reuse by a fresh process. The image contains published Ashui 0.2.4. Its prepared source and caches live at `/workspace/project`; startup runs `rayde-session container` directly, with no shell build script. Each visitor gets a separate writable image layer. No host credential is included in the context.

Extract the SHA-256 of `/opt/rayde/toolchain.json` and `/opt/rayde/demo-workspace.json` from the built image for `DEMO_TOOLCHAIN` and `DEMO_RELEASE`. Pin the resulting OCI image digest when configuring deployment. A mismatched identity cannot become ready.

## Worker configuration

The `v4` migration and `DEMO_CONTAINERS` binding are defined in `web/cloud/wrangler.jsonc`. They are dormant until an image is configured and anonymous admission is enabled. Add a reviewed container application:

```jsonc
"containers": [{
  "class_name": "DemoContainer",
  "scheduling_policy": "durable_object",
  "images": {"base": {"image": "registry.cloudflare.com/ACCOUNT/IMAGE@sha256:DIGEST"}},
  "max_instances": 2
}]
```

Set `DEMO_COMPUTE=containers`, `DEMO_ORIGIN`, `DEMO_RELEASE`, `DEMO_TOOLCHAIN`, `DEMO_MAX_SESSIONS=2` and the landing asset route before enabling the live demo. The controller selects `basic` (1 GiB / ¼ vCPU) and disables Internet egress. Measure changed-source builds before choosing a larger instance. No `RUNNER_SECRET`, GitHub token or private repository is sent into these containers.

Admission still enforces the fifteen-minute hard deadline, five-minute idle deadline and bounded retries. Both the Rust entrypoint and Durable Object enforce expiry. Cleanup must confirm container destruction before freeing capacity and purging private recovery data. Lease provider selection persists, so changing configuration cannot send an older MSB lease to container cleanup.

Reconnect reuses a running container. If a previously ready container is lost, it refuses to replace visitor files with the public image. Durable edit payloads remain available for recovery; automatic restoration of a complete ephemeral filesystem is not enabled by this provider.

The control path follows Cloudflare's [Durable Object Container API](https://developers.cloudflare.com/containers/api/durable-object-container/). Local Miniflare tests emulate the container port/lifecycle only. An actual OCI boot and deployed two-visitor acceptance remain required before enabling this on the public landing page.

`tools/ProbeDemoContainer.hx` supplies the headless service checks. Compile it with RayDE's shared Haxe arguments and `-D rayde_remote`, then run its bytecode with `ASH_WORKERS=4`. It accepts `HOST:PORT TOKEN_FILE ACTION MARKER`; actions are `services`, `absent`, `write` and `read`. The service check exercises real process output, child environment isolation, JavaScript/Rust/TOML syntax and interactive terminal input. Use the other actions across separate visitors and reconnects to verify filesystem and namespace isolation.
