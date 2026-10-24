# Keyboard shortcuts

Bindings follow VS Code. On Windows and Linux, read Ctrl for Cmd unless the table gives another key. Shortcuts work throughout the window; Explorer file commands such as copy, cut, paste, rename, delete and duplicate apply while Explorer has keyboard focus.

| Key | Action |
| --- | --- |
| Cmd+P | Command center: go to a file as you type. Clicking the project pill opens it too. |
| Cmd+Shift+P, or `>` in the center | Commands. |
| Ctrl+G, or `:` in the center | Go to line. |
| Cmd+F | Find in the current editor. |
| Cmd+Option+F (Ctrl+H elsewhere) | Replace in the current editor. |
| Cmd+G / Cmd+Shift+G (F3 / Shift+F3 elsewhere) | Next / previous match. |
| Cmd+S | Save every edited file. |
| Cmd+W | Close the tab. |
| F12 | Go to the definition of the name under the cursor. Command-click a symbol on macOS, or Control-click elsewhere, to go to its definition. |
| Ctrl+Space | Completion list at the caret (**Trigger Suggest**). |
| Cmd+Shift+Space | Signature of the call the caret is in (**Trigger Parameter Hints**). |
| Cmd+. | Show Code Actions for the current selection. |
| F5, Shift+F5 | Run, stop. While an extension is stopped at a breakpoint, F5 continues. |
| Cmd+Shift+B | Build the project without launching its output. |
| F9 | Toggle a breakpoint on the line (extensions). A click in the gutter does the same. |
| F10, F11, Shift+F11 | Step over, into, out (extensions). |
| Cmd+M | Minimize. |
| Ctrl+Cmd+F (Alt+Shift+Enter elsewhere) | Full screen. |

## Command center

Press Cmd+P to find a file, or click the project pill. Start with `>` for commands or `:` for a line number. Arrow keys, Page Up/Down, Home and End move through results; Enter opens the selection.

## Customize

Open **Settings > Key bindings** to change a command's shortcut. User overrides are stored in `.rayde/keybindings.json` as `{"command": ..., "key": ...}` entries; an empty `key` removes a binding.

Extension stepping and breakpoints are described in [Debugging](extensions.md#debugging). Window actions are described in [Windows and sessions](window.md).
