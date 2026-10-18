# RayDE

The Rayzor Development Environment: a Haxe IDE built on [ashui](https://github.com/rayzor-blade/ashui)'s code editor, for two Haxe runtimes, ash (the default in-editor runner) and rayzor. ChimpMonk uses it as a library.

## Layout

- `src/rayde/lang` — the language layer, with no UI: a Haxe compilation server kept running per project, and display requests (completion, hover, definition, references, signature help, diagnostics) through the compiler's JSON-RPC display protocol, typed from the editor's buffers as well as from disk.
- `src/rayde/run` — building and running: a project is built with `haxe --connect` against its compilation server and the program run with `ash --preset application`, each as a background job whose output is read from a log, so nothing waits. Compiler messages become problems at their positions. Keep one compilation server for each project: the server caches typed modules by name, so two projects that each have a `Main` would be given each other's.
- `src/rayde/ui` — the workbench on ashui: the project's source tree, open files in tabs over the code editor, and the problems the compiler finds as they are edited, in resizable panes, with Run and Stop in the top bar and the console of a run beside the problems.
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
