# RayDE

The Rayzor Development Environment: a Haxe IDE built on [ashui](https://github.com/rayzor-blade/ashui)'s code editor, for two Haxe runtimes, ash (the default in-editor runner) and rayzor. ChimpMonk uses it as a library.

## Layout

- `src/rayde/lang` — the language layer, with no UI: a Haxe compilation server kept running per project, and display requests (completion, hover, definition, references, signature help, diagnostics) through the compiler's JSON-RPC display protocol, typed from the editor's buffers as well as from disk.
- `src/rayde/ui` — the workbench on ashui: the project's source tree, open files in tabs over the code editor, and the problems the compiler finds as they are edited, in resizable panes.
- `tests` — checks against the real Haxe compiler, with fixture projects in `tests/fixtures`, and the workbench's snapshots.

## Checks

```sh
scripts/check.sh      # the language layer against the real compiler, run with ash (ASH, or ash on PATH)
scripts/snapshot.sh   # the workbench in both themes, captured with ashui's snapshot tools into bin/snapshots
```

The UI builds against a pinned ashui commit (`ashui_rev` in `scripts/deps.sh`), checked out under `.deps` and built once; `ASHUI=<dir>` uses another checkout. hlwgpu and hlwindow are read from beside RayDE. Look at the snapshots after any change to how something looks.

Work is tracked with git-bug; `git-bug bug` lists it.
