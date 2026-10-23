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
- `scripts/rayde.sh`, packaging and Git checks/snapshots build pinned libgit2 with CMake and a C compiler, generating the built-in Git manifest with its library hash. The source archive is fetched with curl and verified with shasum; Git fixtures/checks use Python 3.
- The local Jam core in `native/jam` uses pinned Yrs 0.28.0 and tokio-tungstenite 0.28.0. It is linked into `rayscript.hdll`; its standalone JSON-lines client needs neither Haxe nor the sibling RayScript checkout.
- Rust 1.98 or newer and the sibling `rayscript` checkout supply the embedded extension runtime. `scripts/build-rayscript.sh` builds `native/rayscript` into the existing `../rayscript/target` and stages `bin/rayscript.hdll`; `RAYSCRIPT_TARGET_DIR` selects another shared target. No `rayscript-host` executable is required to run RayDE.
- Rayzor is the default Haxe language server. Builds stage an existing `RAYZOR_LSP` executable, sibling `rayzor/target/release/rayzor`, or Rayzor on PATH, plus the available `RAYZOR_STD_PATH` or sibling `compiler/haxe-std`. They do not build Rayzor. The staged executable retains its linked-library requirements; release packages need a distributable Rayzor build. Without an available server, RayDE falls back to the Haxe display service after bounded startup attempts.
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
| `RAYDE_ASH=<path>` | ash for the packaged launchers. |
| `RAYZOR_LSP=<path>` | Rayzor LSP executable for staging and automatic discovery. |
| `RAYZOR_STD_PATH=<folder>` | Rayzor standard library for staging and server launch. |
| `ASHUI_FRAME_STATS=1` | Log frame timings and compositing layers, plus loop wake-ups, busy time and pointer hooks. |

One editor window at a time while testing: check `pgrep -fl rayde.hl` before launching another.
