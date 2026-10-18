# RayDE

The Rayzor Development Environment: a Haxe IDE built on [ashui](https://github.com/rayzor-blade/ashui)'s code editor, for two Haxe runtimes, ash (the default in-editor runner) and rayzor. ChimpMonk uses it as a library.

## Layout

- `src/rayde/lang` — the language layer, with no UI: a Haxe compilation server kept running per project, and display requests (completion, hover, definition, references, signature help, diagnostics) through the compiler's JSON-RPC display protocol, typed from the editor's buffers as well as from disk.
- `src/rayde/run` — building and running: a project is built with `haxe --connect` against its compilation server and the program run with `ash --preset application`, each as a background job whose output is read from a log, so nothing waits. Compiler messages become problems at their positions. Keep one compilation server for each project: the server caches typed modules by name, so two projects that each have a `Main` would be given each other's.
- `src/rayde/ui` — the workbench on ashui, laid out as VS Code is: a title bar naming the project, an activity bar, the Explorer, the open files as notched tabs over a breadcrumb and the code editor, the Problems and the Output of a run below, and a status bar with the runtime and the problem counts. Each region is a card with a gap between, each part resizable. Run and Stop are in the status bar until the editor can show them as code hints on the entry point.
- `src/rayde/ui/icons` — RayDE's own icons beside ashui's Remix set (`rayde.ui.Icons`). `haxe.svg` is the Haxe file icon from Visual Studio Code's built-in file icon theme, filled in Haxe Orange (#EA8220); the Haxe logo is the Haxe Foundation's.
- `tests` — checks against the real Haxe compiler, with fixture projects in `tests/fixtures`, and the workbench's snapshots.

## Use

```sh
scripts/rayde.sh path/to/build.hxml   # opens that project; Run builds it and runs it on ash
```

## Checks

```sh
scripts/check.sh      # the language and run layers against the real compiler, run with ash (ASH, or ash on PATH)
scripts/snapshot.sh   # the workbench in both themes, empty, with problems, after a run and after a failed build, into bin/snapshots
```

The UI builds against a pinned ashui commit (`ashui_rev` in `scripts/deps.sh`), checked out under `.deps` and built once; `ASHUI=<dir>` uses another checkout. hlwgpu and hlwindow are read from beside RayDE. Look at the snapshots after any change to how something looks.

Work is tracked with git-bug; `git-bug bug` lists it.
