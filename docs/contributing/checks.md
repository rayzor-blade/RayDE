# Checks and snapshots

```sh
scripts/check.sh        # unit and integration checks against the real compiler, run with ash
scripts/snapshot.sh     # the workbench in both schemes, driven through the UI, into bin/snapshots
SNAPSHOT_ONLY=<name> scripts/snapshot.sh   # one scenario
```

`check.sh` builds `tests/Checks.hx` without ashui: the build file model, terminal and keys, settings, theme bundles (files, colours, scoping, installing, fonts, text edits), haxelib, extensions, discovery precedence, activation, native approvals and hash enforcement, restart limits, key migration and their host processes, and the compiler server (hover, completion, definition, references, signature help, diagnostics, build and run).

`snapshot.sh` builds `tests/Snapshots.hx`. Each scenario works on a copy of a fixture project under `bin/fixtures`, drives the workbench with pointer and key events, asserts on state, and captures images. Scenarios: `basic`, `full`, `broken`, `extension`, `markdown`, `views`, `extensions`, `git`, `chrome`, `debug`, `themes`, `themestudio`, `assist`. A fixture that contains a `.rayext` or a `.raytheme` opens as that kind of project. Look at the images after any change to how something looks; the docs pictures are copies of them.

The `extensions` scenario includes native approval, startup and revocation in both schemes. Its approvals use an isolated home under the fixture; it does not change your user settings.

The `git` scenario builds pinned libgit2, generates a repository with branches, merges, a tag, status changes and multiple history pages, and installs the real Git extension in the fixture. It checks the SCM activity icon, grouped status, file opening, toolbar refresh and integrated sidebar graph; Ashui Resizable pointer/keyboard input, Collapsible headers and panel-state restoration; CanvasKit selection/hover, pan/zoom/fit, native Select/Button input, paging, cursor and owner cleanup; and recovery after a script event exception without host restart. Built-in discovery and native approvals are isolated from the user's installation.

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
