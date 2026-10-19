# Checks and snapshots

```sh
scripts/check.sh        # unit and integration checks against the real compiler, run with ash
scripts/snapshot.sh     # the workbench in both schemes, driven through the UI, into bin/snapshots
SNAPSHOT_ONLY=<name> scripts/snapshot.sh   # one scenario
```

`check.sh` builds `tests/Checks.hx` without ashui: the build file model, terminal and keys, settings, theme bundles (files, colours, scoping, installing, fonts, text edits), haxelib, extensions, discovery precedence, activation, native approvals and hash enforcement, restart limits, key migration and their embedded VMs, and the compiler server (hover, completion, definition, references, signature help, diagnostics, build and run).

`snapshot.sh` builds `tests/Snapshots.hx`. Each scenario works on a copy of a fixture project under `bin/fixtures`, drives the workbench with pointer and key events, asserts on state, and captures images. Scenarios: `basic`, `full`, `broken`, `extension`, `markdown`, `views`, `extensions`, `git`, `chrome`, `debug`, `themes`, `themestudio`, `assist`. A fixture that contains a `.rayext` or a `.raytheme` opens as that kind of project. Look at the images after any change to how something looks; the docs pictures are copies of them.

The `extensions` scenario includes native approval, startup and revocation in both schemes. Its approvals use an isolated home under the fixture; it does not change your user settings.

The `git` scenario builds pinned libgit2, generates a repository with branches, merges, a tag, status changes and multiple history pages, and installs the real Git extension in the fixture. It checks the SCM activity icon, grouped status, file opening, toolbar refresh and integrated sidebar graph; Ashui Resizable pointer/keyboard input, Collapsible headers and panel-state restoration; CanvasKit selection/hover, selection color compositing, fixed-scale scrolling and scrolled hit testing, a 24,000-unit virtual scene with bounded canvas size and visible-only hit regions, filtering that clamps the scroll offset, native Select/Button input, paging, cursor and owner cleanup; and recovery after a script event exception without host restart. Built-in discovery and native approvals are isolated from the user's installation.

Git checks also cover selected commit files in both views, toolbar spacing and icons, and the native Pull options menu. The backend suite exercises local-remote fetch/push, upstream setup, all three pull strategies, conflicts that preserve the branch and worktree, and commit-file deltas including roots, merges, renames and deletions. The `chrome` snapshots include hovered macOS controls in both fullscreen states and both schemes.

The `basic` scenario narrows the Explorer and checks row width, scroll viewport containment and retained scroll position. `RAYDE_RESIZE_PROBE=1 SNAPSHOT_ONLY=git scripts/snapshot.sh` limits the Git scenario to sidebar resize checks in both schemes, including the mounted view and canvas size on each drag frame.

`ASHUI_FRAME_STATS=1 scripts/snapshot.sh` prints each capture's compositing layer and pointer-hook counts. The interaction probe records the same counters; use `RAYDE_PROBE_VMMAP=1` for physical-footprint measurements alongside allocation and GC statistics.

The `documents` scenario verifies that inactive code tabs keep text, bounded undo history, folds, selection and scroll while their editor views are disposed. It also checks reopening unsaved text, saving it after closing, eviction of closed saved buffers, and workspace diagnostics without a file or range. The interaction probe asserts at most one mounted code editor and reports cached document counts separately from live views.

`RAYDE_MEMORY_PROBE=1 SNAPSHOT_ONLY=git scripts/snapshot.sh` profiles repeated Git history open/close cycles alongside three editor tabs. Each `memory-probe:` JSON line reports the live VM heap/fibers, layout nodes, canvas CPU/GPU table storage, shared renderer textures and Ash heap statistics. `RAYDE_MEMORY_CYCLES` controls the repeats (default 5). Captures are offscreen; use process RSS and physical-footprint measurements alongside these counters.

`scripts/interaction-bench.sh` profiles first opens of ten code tabs, then repeated tab and Explorer/Git switches in both schemes. It closes the history and code tabs, then repeats a code tab's open/close cycle to expose surviving watches. It reuses one render target without PNG readbacks in measured frames, with wall-clock timers and the window's collection policy. JSON records under `bin/interaction-probe` separate action, scheduler, CSS, flush, layout and drawing time/allocation; they also count registered watches, CodeEditors, disposed component hosts, Explorer entries/nodes and each minimap's GPU table storage (excluding driver overhead) and CPU upload buffers. The process pauses at every checkpoint while the sampler reads RSS. On macOS, `RAYDE_PROBE_VMMAP=1` also captures physical-footprint summaries at selected checkpoints; `RAYDE_PROBE_SCALE=2` uses a Retina-sized target. Final checkpoints separate two collections, a nonblocking GPU poll and a queue drain. `RAYDE_PROBE_POLL=0` disables RayDE's progress hook for comparison; `RAYDE_PROBE_SCHEME=dark` or `light` limits the run.

Run the interaction probe with `ASH_GC_DEBUG_ROOTS=1 ASH_GC_STATS=1` to include collection statistics and retention chains in `bin/interaction-probe/run.log`. The `open-tabs-idle` and `open-tabs-collected` checkpoints keep all ten document tabs open while idle canvas CPU storage is released; later checkpoints close the tabs. `RAYDE_PROBE_OUTPUT=<name>` saves a separate run under `bin/<name>`.

`RAYDE_PROBE_SOURCE=<file>` copies one file into the isolated fixture and profiles its first open and close instead of the ten-tab sequence. `RAYDE_PROBE_FOLDERS=<count>` adds ten Haxe files in each closed folder to measure Explorer overhead. For native timings, build the snapshot bytecode with `ash --build bin/snapshots-native bin/snapshots.hl`, then run `python3 tests/interaction_probe.py bin/snapshots-native --native` with the same probe variables. Disable GC debug logging for latency comparisons.

Background diagnostic checks cover unsaved buffers, replacement and cancellation of stale requests, and requests larger than the command-line limit. The UI uses one asynchronous compiler job at a time, independently of the interactive display server's module cache.

`native/rayscript` has focused Rust tests for unmount cleanup, idle collection, fiber exception recovery, cancellation before late service replies, and shutdown with waiting scripts. Run `CARGO_TARGET_DIR=../rayscript/target cargo test --manifest-path native/rayscript/Cargo.toml --release`.

`scripts/check-git.sh` builds pinned libgit2 and checks the [Git native backend](../git.md) through the real extension host. `--benchmark` also measures status on a 10k-file repository. These checks require CMake, a C compiler, curl, shasum, Python 3 and Git.

## Benchmarks

```sh
scripts/terminal-bench.sh   # terminal under a program that fills the screen, offscreen: poll, layout, encode
scripts/scroll-bench.sh     # a long file flicked and left to decelerate, offscreen: layout, encode, finish times
```

| Variable | Effect on `scroll-bench.sh` |
| --- | --- |
| `ROWS=<n>` | Length of the file. |
| `DRIFT=<frames>`, `STEP=<px>` | Scroll at a steady pace. |
| `ALONE=<letters>` | The editor on its own, a letter for each feature on (`ALONE=gfib`). |

The terminal's native library has its own `cargo test` in `native/terminal`.
