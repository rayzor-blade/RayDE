# Building and running

```sh
scripts/rayde.sh                        # Welcome, with opening and creation choices
scripts/rayde.sh path/to/workspace       # any folder, including non-Haxe projects
scripts/rayde.sh path/to/build.hxml      # open a Haxe project; Run builds it and runs it on ash
scripts/rayde.sh path/to/name.rayext     # open an extension project
scripts/rayde.sh path/to/name.raytheme   # open a theme project
scripts/rayde.sh --build                 # rebuild bin/rayde.hl without opening a window
scripts/rayde.sh --native --build        # also compile bin/rayde ahead of time
scripts/rayde.sh --native build.hxml     # rebuild and open with the native executable
```

## Dependencies

- `haxe` and `ash` on `PATH` (`ASH=<path>` names another ash).
- ashui is pinned to a commit (`ashui_rev` in `scripts/deps.sh`), checked out under `.deps` and built once. `ASHUI=<dir>` builds against another checkout.
- hlwgpu and hlwindow are read from beside RayDE (`HLWGPU`, `HLWINDOW`).
- `scripts/rayde.sh`, packaging and Git checks/snapshots build pinned libgit2 with CMake and a C compiler, generating the built-in Git manifest with its library hash. The source archive is fetched with curl and verified with Python 3; Git fixtures/checks also use Python 3. Packaging needs Python 3.11 or newer, plus `patchelf` on Linux or an MSVC developer environment on Windows.
- The local Jam core in `native/jam` uses pinned Yrs 0.28.0 and tokio-tungstenite 0.28.0. It is linked into `rayscript.hdll`; its standalone JSON-lines client needs neither Haxe nor the sibling RayScript checkout.
- Rust 1.98 or newer and the sibling `rayscript` checkout supply the embedded extension runtime. `scripts/build-rayscript.sh` builds `native/rayscript` into the existing `../rayscript/target` and stages `bin/rayscript.hdll`; `RAYSCRIPT_TARGET_DIR` selects another shared target. No `rayscript-host` executable is required to run RayDE.
- Rayzor is the default Haxe language server. Development builds stage an existing `RAYZOR_LSP` executable, sibling `rayzor/target/release/rayzor`, or Rayzor on PATH, plus the available `RAYZOR_STD_PATH` or sibling `compiler/haxe-std`. They do not build Rayzor. CI builds its pinned source; distribution packages require both the server and standard library and bundle non-system native dependencies. Without an available server in a development run, RayDE falls back to the Haxe display service after bounded startup attempts. See [packaging](packaging.md) for CI setup.
- The same library embeds the pinned shared syntax registry and native Markdown/math/Mermaid renderers. `node scripts/update-grammars.mjs` updates grammar data from a checksum-verified archive; normal builds require neither Node nor a browser. Packaging includes the bundled data's notices.
- Image previews bundle `image` and `avif-decode` for BMP, GIF, ICO and AVIF conversion. The decoders need no external image tools or system AVIF library; their versions and dependencies are locked in Cargo.lock.
- Source `scripts/deps.sh` from bash only.

## Environment

| Variable | Effect |
| --- | --- |
| `RAYDE_PANEL=<tab>` | Open the bottom panel on `terminal`, `problems` or `console`. |
| `RAYDE_SETTINGS=<section>` | Open Settings on `build`, `libraries`, `terminal`, `appearance`, `keys` or `extensions`. |
| `RAYDE_EXTENSIONS=<folder>` | Built-in extensions folder instead of the packaged or source folder. |
| `RAYDE_THEMES=<folder>` | User theme folder instead of `~/.rayde/themes`. |
| `RAYDE_OPAQUE=1` | Opaque window instead of a transparent one. |
| `RAYZOR_LSP=<path>` | Rayzor LSP executable for staging and automatic discovery. |
| `RAYZOR_STD_PATH=<folder>` | Rayzor standard library for staging and server launch. |
| `ASHUI_FRAME_STATS=1` | Log frame timings and compositing layers, plus loop wake-ups, busy time and pointer hooks. |

One editor window at a time while testing: check `pgrep -fl rayde.hl` before launching another.

## Browser build

`scripts/build-web.sh` stages the page in `bin/web/rayde` using Ash and Ashui's built web libraries (see the script's header for `WEB_LIBS`). Serve it with `ash serve bin/web/rayde`. The page carries Arimo for UI text, JetBrains Mono for code, and a small Noto symbol subset for missing shortcut glyphs. Fonts register before layout; a browser has no system fonts for the renderer to fall back to.

`node tests/web/page.mjs --visitor Mac --probe --shots bin/web/probe` opens the page in Chrome, opens and edits `Main.hx`, and writes screenshots and `probe.json`. Install the test dependencies in `web/session` first. `--dir` selects another build; `--env ASH_GC_STATS=1 --env ASHUI_FRAME_STATS=1 --all` includes runtime and frame logs. The probe records WASM memory, process RSS by browser role, logical GPU texture/buffer bytes, shader pipeline creation times and completed submissions. Logical resource sizes exclude driver overhead; WASM capacity is not live heap usage. Instrumentation is served only by this test, leaving the built page unchanged.

Normal builds use the committed font assets. To regenerate them from pinned official sources, install `fonttools[woff]==4.67.0` in a virtual environment and run `python scripts/web-fonts.py`; `--check` verifies the shortcut glyphs without downloading anything. The font licenses are in `assets/notices/font-*-OFL.txt`.
