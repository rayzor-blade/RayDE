# Editor and keys

Key bindings follow VS Code. On Linux and Windows read Ctrl for Cmd. **Settings > Key bindings** edits them; user changes are stored in `.rayde/keybindings.json` as `{"command": ..., "key": ...}` entries, and an empty `key` removes a binding.

## Keys

| Key | Action |
| --- | --- |
| Cmd+P | Command center: go to a file as you type. Clicking the project pill opens it too. |
| Cmd+Shift+P, or `>` in the center | Commands. |
| Cmd+G, or `:` in the center | Go to line. |
| Cmd+S | Save every edited file. |
| Cmd+W | Close the tab. |
| F12 | Go to the definition of the name under the cursor. |
| Ctrl+Space | Completion list at the caret (**Trigger Suggest**). |
| Cmd+Shift+Space | Signature of the call the caret is in (**Trigger Parameter Hints**). |
| F5, Shift+F5 | Run, stop. While an extension is stopped at a breakpoint, F5 continues. |
| F9 | Toggle a breakpoint on the line (extensions). A click in the gutter does the same. |
| F10, F11, Shift+F11 | Step over, into, out (extensions). |
| Cmd+M | Minimize. |
| Ctrl+Cmd+F (Alt+Shift+Enter elsewhere) | Full screen. |

## Editor

- Hovering a name in a Haxe file shows its type and documentation; hovering an underlined range shows the problem.
- **Completion.** The list opens after `.` and at the first character of a word, or with Ctrl+Space. Typing narrows it (prefix, word starts, letters in order). Up, Down, Page Up, Page Down, Home and End move; Enter or Tab inserts the row; Escape closes. Each row has a kind letter, the item's type and, for the selected row, its documentation. Items come from the compiler's display server and reflect the buffer as typed, not the saved file.
- **Signature help.** `(` and `,` open the signatures of the call the caret is in, with the current argument in bold. The popover follows typing and moves with the caret; it closes at the call's `)` or on Escape.

![Completion list narrowed to charAt, with its documentation](images/editor-completion.png)

![Signature help with the second argument emphasised](images/editor-signature.png)
- Problems come from the Haxe compiler's display server and from the last build. A problem in the Problems list opens its file at its line.
- Each editor has a minimap and code folding.
- Explorer folders load their file rows on first expansion and keep them for subsequent expansions.
- The build file (`build.hxml`) opens as a form in **Settings > Build**.

## Settings

| Section | Contents |
| --- | --- |
| Build | The build file as a form. |
| Libraries | haxelib libraries. |
| Terminal | Profiles and terminal options. |
| Color scheme | Scheme, built-in and custom themes, window controls. See [Theme bundles](themes.md). |
| Key bindings | Bindings per command. |
| Extensions | Extension settings. |

`RAYDE_SETTINGS=<section>` opens the Settings page on a section at launch (`build`, `libraries`, `terminal`, `appearance`, `keys`, `extensions`). `RAYDE_PANEL=<tab>` opens the bottom panel on `terminal`, `problems` or `console`.
