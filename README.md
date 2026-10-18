# RayDE

The Rayzor Development Environment: a Haxe IDE built on [ashui](https://github.com/rayzor-blade/ashui)'s code editor, for two Haxe runtimes, ash (the default in-editor runner) and rayzor. ChimpMonk uses it as a library.

## Layout

- `src/rayde/lang` — the language layer, with no UI: a Haxe compilation server kept running per project, and display requests (completion, hover, definition, references, signature help, diagnostics) through the compiler's JSON-RPC display protocol, typed from the editor's buffers as well as from disk.
- `src/rayde/run` — building and running: a project is built with `haxe --connect` against its compilation server and the program run with `ash --preset application`, each as a background job whose output is read from a log, so nothing waits. Compiler messages become problems at their positions. Keep one compilation server for each project: the server caches typed modules by name, so two projects that each have a `Main` would be given each other's.
- `src/rayde/ui` — the workbench on ashui, laid out as VS Code is: a title bar naming the project, an activity bar, the Explorer, the open files as notched tabs over a breadcrumb and the code editor, the Problems and the Output of a run below, and a status bar with the runtime and the problem counts. Each region is a card with a gap between, each part resizable. The Problems and Output panel starts closed; Cmd+J, the toggle at the right of the status bar, the problem counts, a run and a failed build open it, and the X at the far end of its tab row closes it. Run and Stop are in the status bar until the editor can show them as code hints on the entry point. With nothing open the editor shows a welcome page instead of tabs: the main class, go to file, commands and run beside their keys, the files opened last (kept in `.rayde/recent.txt` beside the build file), and the project at a glance.
- `src/rayde/build` — the build file as a model that edits only the lines it is asked to, so comments, order and any argument it does not know survive; `src/rayde/ui/BuildSettings.hx` is the form over it (Build tab: target and output, `--main`, `-cp`, `-lib`, `-D`, `--debug`, `--no-traces`, `--no-inline`, `--dce`, and the other arguments listed and kept). It opens from the build file in the Explorer, the gear at the foot of the activity bar, the welcome page and the command center, and each change is written to the file and read by the compiler at once.
- `native/terminal`, `src/rayde/term` and `src/rayde/ui/TerminalView.hx` — the Terminal tab of the bottom panel: the user's own shell on a pseudo-terminal. A Rust library (portable-pty for the PTY, vt100 for the emulator) runs the program and keeps its screen; the VM asks which rows changed and fetches those as runs of styled text, so a busy terminal costs a few elements a row. `TerminalView` draws each run as a text element and the backgrounds, selection, cursor, box lines and blocks on a canvas under them; `KeyMap` is what keys send, as xterm does. Ctrl+` opens it and closes the panel again. + starts another terminal beside the others and its chevron picks a shell profile (the shells `/etc/shells` lists, `$SHELL` first); a list beside the screen switches and kills them, and the bin kills the one in front.
- `src/rayde/ui/icons` — RayDE's own icons beside ashui's Remix set (`rayde.ui.Icons`). `haxe.svg` is the Haxe file icon from Visual Studio Code's built-in file icon theme, filled in Haxe Orange (#EA8220); the Haxe logo is the Haxe Foundation's.
- `tests` — checks against the real Haxe compiler, with fixture projects in `tests/fixtures`, and the workbench's snapshots.

## Use

```sh
scripts/rayde.sh path/to/build.hxml   # opens that project; Run builds it and runs it on ash
scripts/rayde.sh --build              # only rebuilds bin/rayde.hl, without opening a window
RAYDE_PANEL=terminal scripts/rayde.sh path/to/build.hxml   # opens with the bottom panel on that tab (terminal, problems or console), the terminal with the keyboard in it
```

Keys, as in VS Code (Ctrl on Linux and Windows): Cmd+P opens the command center, which goes to a file as you type, to a command after `>` (also Cmd+Shift+P) and to a line after `:` (also Cmd+G); clicking the project pill opens it too. Cmd+S saves every edited file, Cmd+W closes the tab, F12 goes to the definition of the name under the cursor, F5 runs and Shift+F5 stops. A problem in the Problems list opens its file at its line.

## Checks

```sh
scripts/check.sh      # the language and run layers against the real compiler, run with ash (ASH, or ash on PATH)
scripts/snapshot.sh   # the workbench in both themes, empty, with problems, after a run and after a failed build, into bin/snapshots
scripts/terminal-bench.sh # the terminal under a program that fills the screen as fast as it can, offscreen: poll and layout, encode (and the native library has its own `cargo test` in native/terminal)
scripts/scroll-bench.sh # frames of a long file flicked and left to decelerate, offscreen: layout, encode and finish times (ROWS=<n> sets the length; DRIFT=<frames> STEP=<px> scrolls at a steady pace; ALONE=gfib puts the editor on its own, a letter for each feature on)
```

The UI builds against a pinned ashui commit (`ashui_rev` in `scripts/deps.sh`), checked out under `.deps` and built once; `ASHUI=<dir>` uses another checkout. hlwgpu and hlwindow are read from beside RayDE. Look at the snapshots after any change to how something looks.

Work is tracked with git-bug; `git-bug bug` lists it.
