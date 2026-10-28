# Landing page

`index.html`, `landing.css` and `landing.mjs` are the site. Desktop screens embed the standalone editor from `dist/index.html` in a same-origin frame. Smaller screens show `assets/editor-preview.webp` and do not fetch the WASM runtime. The public sample is [Pocket Studio](demo/README.md), a Haxe/Ashui project and companion RayScript extension built against published Haxelib packages. It uses browser storage; builds, terminals, language servers and extensions require a connected workspace session.

Regenerate the editor, including its browser agents and native side modules, from source:

```sh
bash scripts/build-site.sh
```

See [browser build prerequisites](../docs/contributing/building.md#browser-build). `dist/` is generated output; edit the sources or pinned dependency, then rebuild. Worker and dynamic-agent paths resolve beside their host module rather than beside the landing document. The frame isolates editor focus, keyboard handling and styles from the marketing page.

For local preview on a chosen port, the Rust session can serve both the site and its socket:

```sh
python3 scripts/serve-site.py --port 8731
python3 scripts/serve-site.py --port 8731 --offline
python3 scripts/serve-site.py --port 8732 --workspace path/to/build.hxml
```

The default preview automatically connects to an editable Pocket Studio workspace, including its tools and built-in extensions. `--offline` serves only the browser sample. The connected preview keeps an editable Pocket Studio copy, Git history and published Haxelib packages under `~/.rayde-session/demos/pocket-studio`. `--workspace` explicitly enables a chosen project’s tools and extensions. These local modes expose an opt-in bootstrap on the loopback preview server, allowing a clean URL without publishing credentials in site files. The launcher stops its own session with Ctrl+C. No Node backend is needed.

If another server serves the site, start the workspace session with `--origin http://127.0.0.1:PORT` for that exact page origin, then use the session URL and token fragment. Different ports are different origins; the allowlist deliberately does not trust every localhost page. Serve the site with `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` for shared WASM memory.

Remix SVG icons and the Arimo font include their licenses in `assets/notices`. The mobile preview is a capture of the actual editor.

The landing preview gets its workspace configuration automatically from its local session host; it has no connection settings UI. A stale remembered connection cannot override this preset. An existing explicit session URL is imported once and cleaned. The generated bundle contains no credentials. Platform variables travel in the host startup message, not in the query string; authenticated app workspaces still use their account gateway. Server process variables remain in `~/.rayde-session/environment.json`. Standalone workspace settings belong in Cloud Sync, tracked by `4938944c5ed3bbde8fd4b446b5c3638abb1e5b3359a211c27e6b17a013813ac3`.

The sample is packaged with `scripts/package-demo.py`. Its namespaced browser seed adds missing files atomically and preserves existing file contents. Regeneration never overwrites a visitor’s edits.

The loopback bootstrap rejects cross-origin browser requests and non-loopback Host headers, and refuses public listeners. It is disabled on ordinary sessions and account-gateway deployments. A public live demo still needs authenticated compute provisioning; a static site alone has no extension processes. Local Jam remains a desktop feature pending its browser/session transport.
