# Editor implementation

User instructions are in [Editor](../editor.md).

## Documents and editor lifetime

Only the active code tab mounts an editor. Inactive tabs keep text, undo/redo, selection, scroll and folded regions; their completed syntax caches are packed together in memory and reused when revisiting an unchanged file.

Hover documentation is requested from the language server; revisiting an unchanged open tab keeps its existing LSP document version.

## Command center

The command center searches the complete file catalog while mounting only the visible result rows. Folder scans run in a worker and refresh the list without resetting typed text. Arrow keys, Page Up/Down, Home and End navigate the results; Enter opens the selection. Closing the center releases its rows.

## Code actions

**Show Code Actions** (Cmd+., Ctrl+. elsewhere with the default keymap) lists actions from the active document's providers. Opt-in providers also put icons beside their target lines; clicking a shared line opens a chooser. The configured Haxe main class gets a **Run Project** icon that uses the normal save/build/run path. Other entry points can be supplied by extensions. Actions belong to a document version and disappear when it changes or its tab becomes inactive. Extension edits to the current document form one undo step. See the [provider API](../extensions.md#code-actions).

## Panels

Problems come from the active language server, the fallback Haxe compiler and the last build. A problem in the Problems list opens its file at its line. Only the visible rows and a small overscan are mounted.

Problems decoding, Output log processing and terminal I/O run independently of the UI. Superseded diagnostic requests are cancelled. Hidden Output views release their controls while retaining text and scroll position; reopening shows the latest data. Terminal sessions keep running when the panel closes.

Output renders ANSI foreground and background colors (standard, bright, 256-color and RGB), bold, dim, italic, underline, strikethrough and inverse text. Reset sequences restore severity colors. Selection and copying use plain text without escape sequences; cursor-control sequences are ignored.

## Preview resources

Inactive image tabs release their decoded pixels, vector documents and cached GPU image entries, retaining only navigation state. The atlas repacks for the remaining images instead of keeping its largest texture after previews close. BMP, GIF, ICO and AVIF decoding runs on a background worker; closing or hiding a preview cancels its pending result.

## Extension readiness

`Connection.progress()` distinguishes host/script startup from commands queued until registration. Its progress callback updates Studio and extension status without a polling loop. `Studio.loadingMessage()` also follows visible surfaces awaiting mounted roots. View tools bind their disabled state to readiness; stopped or failed empty views link to Output. A reload can keep the previous successful view while the replacement starts.

## Windows and startup

Windows share the GPU and desktop event loop while keeping project services and appearance separate. On macOS, file and folder browsers open as asynchronous sheets attached to the requesting window. Other platforms run their native picker on a worker. Project creation continues on a worker after selecting a location.

`rayde.ui.WindowChrome` is what the controls ask of the window. Without a window, as in the snapshots, it records the requests.

Launch overrides for Settings and panels are listed under [build environment](building.md#environment).

## Status bar

The right end of the bottom status bar names the language of the file in front (from its name: `Haxe`, `JSON`, `Plain Text` for an unknown extension) and, last, the project's runtime. Pages that are not files, such as Welcome or Settings, and image previews show no language; a local history revision shows its file's. Extensions' status items, such as the Git branch, sit at the left.
