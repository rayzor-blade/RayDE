# Checks and snapshots

```sh
scripts/check.sh        # unit and integration checks against the real compiler, run with ash
scripts/snapshot.sh     # the workbench in both schemes, driven through the UI, into bin/snapshots
SNAPSHOT_ONLY=<name> scripts/snapshot.sh   # one scenario
```

`check.sh` builds `tests/Checks.hx` without ashui: the build file model, terminal and keys, settings, theme bundles (files, colours, scoping, installing, fonts, text edits), haxelib, extensions, discovery precedence, activation, native approvals and hash enforcement, restart limits, key migration and their embedded VMs, and the compiler server (hover, completion, definition, references, signature help, diagnostics, build and run).

`snapshot.sh` builds `tests/Snapshots.hx`. Each scenario works on a copy of a fixture project under `bin/fixtures`, drives the workbench with pointer and key events, asserts on state, and captures images. Scenarios: `basic`, `full`, `broken`, `extension`, `markdown`, `views`, `extensions`, `git`, `chrome`, `debug`, `themes`, `themestudio`, `assist`. A fixture that contains a `.rayext` or a `.raytheme` opens as that kind of project. Look at the images after any change to how something looks; the docs pictures are copies of them.

The `extensions` scenario includes native approval, startup and revocation in both schemes. Its approvals use an isolated home under the fixture; it does not change your user settings.

`SNAPSHOT_ONLY=toast scripts/snapshot.sh` checks short and wrapping Git notifications in both schemes, including single-line action labels, centered button text, non-overlapping controls and action dismissal.

`SNAPSHOT_ONLY=outline scripts/snapshot.sh` exercises `tests/fixtures/full/build.hxml` with its missing library, files outside source paths, declaration navigation, unsaved syntax-error recovery and changed build defines in both schemes. Outline uses a parsing-only compiler request: explicit defines, target flags and declared library defines are preserved while build macros and dependency resolution are excluded. The core checks also cover versioned library conditions and unresolved types.

The `git` scenario builds pinned libgit2, generates a repository with branches, merges, a tag, status changes and multiple history pages, and installs the real Git extension in the fixture. It checks the SCM activity icon, grouped status, file opening, toolbar refresh and integrated sidebar graph; Ashui Resizable pointer/keyboard input, Collapsible headers and panel-state restoration; CanvasKit selection/hover, selection color compositing, fixed-scale scrolling and scrolled hit testing, a 24,000-unit virtual scene with bounded canvas size and visible-only hit regions, filtering that clamps the scroll offset, native Select/Button input, paging, cursor and owner cleanup; and recovery after a script event exception without host restart. Built-in discovery and native approvals are isolated from the user's installation.

Git checks also cover unchanged history across tab switches and worktree-only updates, external file discovery while the sidebar is visible, selected commit files in both views, toolbar spacing and icons, the native Pull options menu, and reopening the expanded graph through sidebar maximize after its tab's close button and each bulk close action (Others, Saved and All). The backend suite exercises local-remote fetch/push, upstream setup, all three pull strategies, conflicts that preserve the branch and worktree, and commit-file deltas including roots, merges, renames and deletions. The `chrome` snapshots include hovered macOS controls in both fullscreen states and both schemes.

The `basic` scenario narrows the Explorer and checks row width, scroll viewport containment and retained scroll position. `RAYDE_RESIZE_PROBE=1 SNAPSHOT_ONLY=git scripts/snapshot.sh` limits the Git scenario to sidebar resize checks in both schemes, including the mounted view and canvas size on each drag frame.

`ASHUI_FRAME_STATS=1 scripts/snapshot.sh` prints each capture's compositing layer and pointer-hook counts. The interaction probe records the same counters; use `RAYDE_PROBE_VMMAP=1` for physical-footprint measurements alongside allocation and GC statistics.

The `documents` scenario verifies that inactive code tabs keep text, bounded undo history, folds, selection and scroll while their editor views are disposed. It also checks reopening unsaved text, saving it after closing, eviction of closed saved buffers, and workspace diagnostics without a file or range. The interaction probe asserts at most one mounted code editor and reports cached document counts separately from live views. Its `codeRows` records count pooled slots and visible source lines for each editor or read-only view, and assert that short sources allocate no empty viewport slots.

`SNAPSHOT_ONLY=commandcenter scripts/snapshot.sh` checks a 429-file command catalog in both schemes. Closed palettes enumerate no files and own no rows. It verifies filter/mode changes, action selection, line navigation, repeated closes, reopening during the close animation, and return to baseline for styled identities (including detached panels), registered text and pointer hooks. Its node counts describe UI ownership, not process footprint or a fixed byte cost per element.

`RAYDE_MEMORY_PROBE=1 SNAPSHOT_ONLY=git scripts/snapshot.sh` profiles repeated Git history open/close cycles alongside three editor tabs. Each `memory-probe:` JSON line reports the live VM heap/fibers, layout nodes, canvas CPU/GPU table storage, shared renderer textures and Ash heap statistics. `RAYDE_MEMORY_CYCLES` controls the repeats (default 5). Captures are offscreen; use process RSS and physical-footprint measurements alongside these counters.

`scripts/interaction-bench.sh` profiles first opens of ten code tabs, then repeated tab and Explorer/Git switches in both schemes. It closes the history and code tabs, then repeats a code tab's open/close cycle to expose surviving watches. It reuses one render target without PNG readbacks in measured frames, with wall-clock timers and the window's collection policy. JSON records under `bin/interaction-probe` separate action, scheduler, CSS, flush, layout and drawing time/allocation; they also count registered watches, CodeEditors, disposed component hosts, Explorer entries/nodes and each minimap's GPU table storage (excluding driver overhead) and CPU upload buffers. The process pauses at every checkpoint while the sampler reads RSS. On macOS, `RAYDE_PROBE_VMMAP=1` also captures physical-footprint summaries at selected checkpoints; `RAYDE_PROBE_SCALE=2` uses a Retina-sized target. Final checkpoints separate two collections, a nonblocking GPU poll and a queue drain. `RAYDE_PROBE_POLL=0` disables RayDE's progress hook for comparison; `RAYDE_PROBE_SCHEME=dark` or `light` limits the run.

Run the interaction probe with `ASH_GC_DEBUG_ROOTS=1 ASH_GC_STATS=1` to include collection statistics and retention chains in `bin/interaction-probe/run.log`. The sampler acknowledges checkpoints through temporary files while the application sleeps between polls. The `open-tabs-idle` and `open-tabs-collected` checkpoints keep all ten document tabs open while idle canvas CPU storage is released; later checkpoints close the tabs. `RAYDE_PROBE_OUTPUT=<name>` saves a separate run under `bin/<name>`. `RAYDE_PROBE_PROGRAM=<bytecode>` selects a separately compiled comparison build.

`RAYDE_PROBE_SOURCE=<file>` copies one file into the isolated fixture and profiles its first open and close instead of the ten-tab sequence. `RAYDE_PROBE_FOLDERS=<count>` adds ten Haxe files in each closed folder to measure Explorer overhead. For native timings, build the snapshot bytecode with `ash --build bin/snapshots-native bin/snapshots.hl`, then run `python3 tests/interaction_probe.py bin/snapshots-native --native` with the same probe variables. Disable GC debug logging for latency comparisons.

Background diagnostic checks cover unsaved buffers, replacement and cancellation of stale requests, and requests larger than the command-line limit. The UI uses one asynchronous compiler job at a time, independently of the interactive display server's module cache.

`native/rayscript` has focused Rust tests for unmount cleanup, idle collection, fiber exception recovery, cancellation before late service replies, and shutdown with waiting scripts. Run `CARGO_TARGET_DIR=../rayscript/target cargo test --manifest-path native/rayscript/Cargo.toml --release`.

The same suite loads all 731 bundled TextMate scopes and representative aliases, checks incremental multiline state and native-session disposal, and renders GFM, math and Mermaid with malformed-input recovery. `SNAPSHOT_ONLY=markdownpreview scripts/snapshot.sh` installs the production Markdown extension and checks Explorer rows at the project root and inside/outside source folders, lazy folder loading and Markdown file opening (including uppercase suffixes), command activation, Remix icon/no sidebar entry, live unsaved buffers, tab reuse and reopen, stable text/watch registries and SVG cleanup, heading/file links, table alignment, equal-size task checkboxes, code highlighting in preview and ordinary Rust tabs, plus Mermaid wheel zoom, drag pan and fit in both schemes.

Markdown checks also cover embedded HTML, HTML5 recovery, centered headings and sized SVG/raster images, native disclosures and the contextual **Open Preview** action. Repeated preview switches assert bitmap disposal, no retained image payloads in the cached document, bounded decoded raster dimensions, and restored scroll/disclosure state. The `[markdown-images]` line reports decoded pixel bytes and cached document size separately; it does not measure driver memory or the shared GPU atlas allocation.

The production Markdown view mounts only blocks around the scroll viewport, in short batches. It retains block heights and text measurement keys across hiding and remounting. The two-image document checks that offscreen image blocks have no mounted bitmap, then repeatedly scrolls between both ends and verifies remount and close cleanup. A longer document checks bounded native block counts, offscreen heading navigation and viewport restoration after switching to code. The surrounding scroll view also opts into image residency for images within mounted blocks. Ashui's `ImageResidencyPixels` test separately checks default-off behavior, shared sources, nested opt-outs, SVG atlas eviction, smaller atlas textures and pixel equality across reloads and atlas repacks.

Markdown scrolling preloads in the direction of travel, keeps a small reversal buffer and trims it after movement stops. Height corrections preserve the visible anchor within layout. `markdown-scroll-bench.sh` sends phased wheel gestures through long, varying paragraphs, including a slow tail and upward movement into unmeasured content. It asserts visible block coverage, anchor continuity and bounded mounted views, and reports UI frame median, p95 and worst times. Per-frame timing excludes GPU readback; a final PNG goes to the snapshot directory. Use `LIGHT=1` for the light theme or `--native` to compile the probe ahead of time.

`scripts/check-git.sh` builds pinned libgit2 and checks the [Git native backend](../git.md) through the real extension host. `--benchmark` also measures status on a 10k-file repository. These checks require CMake, a C compiler, curl, shasum, Python 3 and Git.

## Benchmarks

```sh
scripts/terminal-bench.sh   # terminal under a program that fills the screen, offscreen: poll, layout, encode
scripts/scroll-bench.sh     # a long file flicked and left to decelerate, offscreen: layout, encode, finish times
scripts/markdown-scroll-bench.sh  # phased Markdown glides, slow tails and reversals, with a preview snapshot
scripts/extension-bench.sh  # cold/repeat Markdown and Git opens, worker timings and longest UI turns
scripts/extension-bench.sh --native  # the same probe compiled ahead of time
```

The extension probe renders at 1280×800 without PNG readback. It records time to the first ready frame, the longest uninterrupted UI turn, and UI transport, message application, style, layout, draw and collection stages. Worker command/pump and Markdown rendering timings are separate and may overlap UI work. It uses the real embedded runtime, Git extension and a repository with branches and merges; Markdown includes math, Mermaid, syntax highlighting and a local SVG. Three fresh-process runs go to `bin/extension-bench`; set `RAYDE_PROBE_OUTPUT` to keep comparisons, `RAYDE_PROBE_RUNS` to change the repetition count, or `RAYDE_PROBE_MARKDOWN=README.md` to substitute a document (its adjacent `assets` directory is copied too). GC root/stat logging is disabled for these latency measurements. `RAYDE_EXTENSION_TIMING=1` also enables the same stage logging in the application.

| Variable | Effect on `scroll-bench.sh` |
| --- | --- |
| `ROWS=<n>` | Length of the file. |
| `DRIFT=<frames>`, `STEP=<px>` | Scroll at a steady pace. |
| `ALONE=<letters>` | The editor on its own, a letter for each feature on (`ALONE=gfib`). |

The terminal's native library has its own `cargo test` in `native/terminal`.


`SNAPSHOT_ONLY=explorer scripts/snapshot.sh` checks the Explorer's native Collapsible/Resizable sections, compiler Outline including unsaved edits, active-file Git history, dependency source expansion and opening in tabs, Outline declaration jumps and compact indentation, local revision preview and undoable restore, persistent undo/redo and visibility cleanup in both schemes. The core suite separately checks never-staged recovery, external disk changes, abandoned edit states, renamed journals, bounded patch compaction and malformed checkpoints.
