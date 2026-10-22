# Editor and keys

The built-in [Rayzor language server](languages.md) provides Haxe services over stdio. Extensions can register servers for other languages.

The startup project picker offers recent projects, **Open Existing Project** and **New Project**. Open an `.hxml` build, `haxelib.json` library or `rayzor.toml` project. New Project creates a Haxe application, Haxe library or Rayzor application inside a new folder; existing folders are never overwritten. Library manifests supply source paths, dependencies and `extraParams.hxml`. Rayzor manifests supply source paths, defines and the entry point, or delegate to an HXML file. Rayzor projects run with `rayzor run`; libraries without an application entry point omit Run. Manifests open as code in the Explorer; the Build settings form edits HXML files.

The Explorer lists every file type, including dotfiles, with folders first and Haxe files before other files. Configuration files and other languages open in the editor; supported images open in the previewer. Explorer and tab icons use Remix and a bundled MIT-licensed Devicon language subset; unknown types use the file-code icon.

Key bindings follow VS Code. On Linux and Windows read Ctrl for Cmd. **Settings > Key bindings** edits them; user changes are stored in `.rayde/keybindings.json` as `{"command": ..., "key": ...}` entries, and an empty `key` removes a binding.

## Keys

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
| F5, Shift+F5 | Run, stop. While an extension is stopped at a breakpoint, F5 continues. |
| F9 | Toggle a breakpoint on the line (extensions). A click in the gutter does the same. |
| F10, F11, Shift+F11 | Step over, into, out (extensions). |
| Cmd+M | Minimize. |
| Ctrl+Cmd+F (Alt+Shift+Enter elsewhere) | Full screen. |

The command center searches the complete file catalog while mounting only the visible result rows. Folder scans run in a worker and refresh the list without resetting typed text. Arrow keys, Page Up/Down, Home and End navigate the results; Enter opens the selection. Closing the center releases its rows.

## Editor

Each project remembers its file-tab order and active tab. Reopening restores existing files, Settings and available extension view tabs; inactive code editors load when selected. Unsaved text and undo history recover through local history. Closing all tabs keeps the next launch empty.

- Hovering a name in a Haxe file shows its type and documentation; hovering an underlined range shows the problem. Diagnostic popups render Markdown, including inline code, highlighted code blocks, emphasis and links. Long documentation scrolls within the popup. Hover documentation is requested from the language server; revisiting an unchanged open tab keeps its existing LSP document version.
- **Completion.** The list opens after `.` and at the first character of a word, or with Ctrl+Space. Typing narrows it (prefix, word starts, letters in order). Up, Down, Page Up, Page Down, Home and End move; Enter or Tab inserts the row; Escape closes. Each row has a kind letter, the item's type and, for the selected row, its documentation. Items come from the compiler's display server and reflect the buffer as typed, not the saved file.
- **Signature help.** `(` and `,` open the signatures of the call the caret is in, with the current argument in bold. The popover follows typing and moves with the caret; it closes at the call's `)` or on Escape.

![Completion list narrowed to charAt, with its documentation](images/editor-completion.png)

![Signature help with the second argument emphasised](images/editor-signature.png)
- Problems come from the active language server, the fallback Haxe compiler and the last build. A problem in the Problems list opens its file at its line. Only the visible rows and a small overscan are mounted.
- Problems decoding, Output log processing and terminal I/O run independently of the UI. Superseded diagnostic requests are cancelled. Hidden Output views release their controls while retaining text and scroll position; reopening shows the latest data. Terminal sessions keep running when the panel closes.
- Output renders ANSI foreground and background colors (standard, bright, 256-color and RGB), bold, dim, italic, underline, strikethrough and inverse text. Reset sequences restore severity colors. Selection and copying use plain text without escape sequences; cursor-control sequences are ignored.
- Each editor has a minimap and code folding.
- Explorer folders load their file rows on first expansion and keep them for subsequent expansions.
- The build file (`build.hxml`) opens as a form in **Settings > Build**.

Find and Replace use Ashui's compact floating glass panel. Enter/Shift+Enter in Find navigate matches; Enter in Replace replaces one, and Cmd+Enter/Ctrl+Enter replaces all. Replace All uses one undo operation within the editor's history limits. Escape closes the panel. The command palette and key-binding settings also expose **Find**, **Replace**, **Find Next** and **Find Previous**.

Enable `.*` for regular expressions and enter a bare pattern such as `item(\d+)`; no `~/…/` wrapper is required. Optional Haxe literals such as `~/item(\d+)/i` supply explicit flags. Regex replacement supports captures such as `$1`; `$$` inserts a dollar sign. `Aa` selects case-sensitive matching and underlined `Ab` selects whole words. Invalid patterns show an error. Search inputs survive switching tabs while their mounted controls and match caches are released.

## Image previews

PNG, JPEG (`.jpg`, `.jpe`, `.jpeg`), BMP, GIF, ICO, WebP, AVIF and SVG files open in an image tab. Drag to pan, scroll to zoom, or use the toolbar to fit the image, view it at 100%, change background contrast or refresh it. GIF previews show the first frame.

SVG tabs can switch between preview and source using the toolbar. The preview uses unsaved edits, and switching preserves undo history. The Explorer context menu also offers **Open Preview** and **Open in Editor** for SVG files.

Inactive image tabs release their decoded pixels and vector documents, retaining only navigation state. BMP, GIF, ICO and AVIF decoding runs on a background worker; closing or hiding a preview cancels its pending result.

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
