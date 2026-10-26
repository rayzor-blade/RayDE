# Editor implementation

User instructions are in [Editor](../editor.md).

## Documents and editor lifetime

Only the active code tab in each editor group mounts an editor. Inactive tabs keep text, undo/redo, selection, scroll and folded regions; their completed syntax caches are packed together in memory and reused when revisiting an unchanged file.

Hover documentation is requested from the language server; revisiting an unchanged open tab keeps its existing LSP document version.

## Syntax highlighting

`EditorSyntax` selects immediate built-in grammars. Native editors use incremental `TextMateSyntax` sessions for other languages. Browser editors use `SessionSyntax` for the shared TextMate registry, retaining built-in colors while a result is pending. Haxe/RayScript keep their HXX-aware grammar, and JSON stays local.

`SessionSyntax` debounces source changes through an ash-future worker, cancels superseded work, and applies only a matching snapshot at a frame boundary. Its reactive highlighter updates the mounted editor without changing selection, scroll or undo history. The response table is consumed into `CodeDocument`'s packed tokens and released; hiding the editor cancels the query and removes its hook.

The Rust `native/syntax` crate shares grammar data and scope mapping with native previews. Session syntax queries run on at most two blocking workers independently of ordered file/document RPCs. Queries require an authenticated session, but do not require program execution permission. Limits are 2 MiB of source, 32,768 lines, 100,000 tokens and 16,384 bytes per tokenized line. Unknown extensions stay plain; sources exceeding the limits retain their built-in fallback.

Run `cargo test --manifest-path native/syntax/Cargo.toml`, `SessionSyntaxChecks`, ashui's `CodeReactiveSyntax`, and `node tests/web/syntax.mjs bin/web/rayde` for grammar, ownership and browser checks.

## Editor groups

`EditorGroups` owns a binary layout of groups and resizable splits. Each tab belongs to one group: document state, history and extension-mounted roots remain singular. `Workbench.open` is the union used by workspace services; `Workbench.active` follows the focused group's active tab. Group-local signals control page visibility so focusing another pane does not remount a visible editor. Group shortcuts are intercepted before caret navigation, and completion/code-action ownership follows focus. Sessions retain the layout, proportions and group selections alongside the existing flat tab catalog; older sessions still open as one group.

`EditorTabDrag` coordinates one window's gesture and registered pane bounds. It starts after a movement threshold, hit-tests insertion slots with the source tab excluded, and commits through `EditorGroups.move`. Reordering leaves the active editor mounted; transfers keep the same document and collapse an emptied source pane. Pointer/flush hooks and the edge-scroll timer are removed on release, cancellation, source removal or disposal. Drop feedback ignores pointer events, and the release click is suppressed after dragging.

`TabContextMenu` provides one lazy menu per tab strip. Actions capture the clicked file, including `editor/title` extension actions. Bulk closes stay within that group, and opening the menu leaves inactive editors unmounted. Structural actions run after the popup restores focus. Run `SNAPSHOT_ONLY=tab-context scripts/snapshot.sh` for interaction checks and screenshots in both themes.

After the selected page is laid out, `EditorTabSnapshot` captures it once into a thumbnail texture, bounded to 320 × 220 pixels. The page's inner wrapper starts at its parent's origin, so subtree capture keeps its layout without the strip or card border. It draws through the window's existing renderer before the frame, sharing its device and atlases; pointer movement only positions the captured texture. `FileTabs.preview` shares the strip's notch drawing above the borderless thumbnail. No additional editor, renderer or pixel readback is needed. The settled hook, texture, view and bind group are released when the gesture ends.

## Command center

The command center searches the complete file catalog while mounting only the visible result rows. Folder scans run in a worker and refresh the list without resetting typed text. Arrow keys, Page Up/Down, Home and End navigate the results; Enter opens the selection. Closing the center releases its rows.

## Code actions

**Show Code Actions** (Cmd+., Ctrl+. elsewhere with the default keymap) lists actions from the active document's providers. Opt-in providers also put icons beside their target lines; clicking a shared line opens a chooser. The configured Haxe main class gets a **Run Project** icon that uses the normal save/build/run path. Other entry points can be supplied by extensions. Actions belong to a document version and disappear when it changes or its tab becomes inactive. Extension edits to the current document form one undo step. See the [provider API](../extensions.md#code-actions).

Ordinary code tabs enable ashui's `compactGutter`: marker and fold columns occupy space only when the document uses them, including offscreen lines. RayScript tabs with a debugger retain the empty marker column so users can set breakpoints. Column changes share the editor's geometry used by text, selections, hit testing and hints.

## Panels

Problems come from the active language server, the fallback Haxe compiler and the last build. A problem in the Problems list opens its file at its line. Only the visible rows and a small overscan are mounted.

Problems decoding, Output log processing and terminal I/O run independently of the UI. Superseded diagnostic requests are cancelled. Hidden Output views release their controls while retaining text and scroll position; reopening shows the latest data. Terminal sessions keep running when the panel closes.

`rayde.term.Terminal` selects the native engine or a browser `RemoteTerminal` mirror. The Rust session reuses `native/terminal` without its optional HashLink FFI. Browser screen updates arrive through the session receiver, coalesce behind acknowledgements and wake the UI; the view has no terminal polling timer. Only changed rows update their controls, identical resize requests are suppressed, and hidden views suspend screen delivery. RPC failures retain an error state and release their remote PTY. Run `RemoteTerminalChecks`, `cargo test --manifest-path native/session/Cargo.toml --test terminal`, and `node tests/web/terminal.mjs bin/web/rayde`; set `RAYDE_TERMINAL_NO_EXEC=1` for the unavailable-session browser case.

Output renders ANSI foreground and background colors (standard, bright, 256-color and RGB), bold, dim, italic, underline, strikethrough and inverse text. Reset sequences restore severity colors. Selection and copying use plain text without escape sequences; cursor-control sequences are ignored.

## Preview resources

Inactive image tabs release their decoded pixels, vector documents and cached GPU image entries, retaining only navigation state. The atlas repacks for the remaining images instead of keeping its largest texture after previews close. BMP, GIF, ICO and AVIF decoding runs on a background worker; closing or hiding a preview cancels its pending result.

## Extension readiness

`Connection.progress()` distinguishes host/script startup from commands queued until registration. Its progress callback updates Studio and extension status without a polling loop. `Studio.loadingMessage()` also follows visible surfaces awaiting mounted roots. View tools bind their disabled state to readiness; stopped or failed empty views link to Output. A reload can keep the previous successful view while the replacement starts.

## Extension styles

`ExtensionStyles` owns one parsed sheet per canonical manifest path in each `UiContext`. View and tab wrappers carry both the extension id and a manifest-path token; selectors and keyframe names are rewritten before the native CSS parser receives them. Each mount holds a disposer tied to its original manifest and context. The last disposer removes the sheet. A content digest detects reloads without depending on filesystem timestamp resolution, and failed reads/parses retain the last successful sheet. Manifest id or stylesheet-list changes rebuild the wrappers. The author-facing format is in [Stylesheets](../extensions.md#stylesheets).

## Windows and startup

Windows share the GPU and desktop event loop while keeping project services and appearance separate. On macOS, file and folder browsers open as asynchronous sheets attached to the requesting window. Other platforms run their native picker on a worker. Project creation continues on a worker after selecting a location.

`rayde.ui.WindowChrome` is what the controls ask of the window. Without a window, as in the snapshots, it records the requests.

Launch overrides for Settings and panels are listed under [build environment](building.md#environment).

## Status bar

The right end of the bottom status bar names the language of the file in front (from its name: `Haxe`, `JSON`, `Plain Text` for an unknown extension) and, last, the project's runtime. Pages that are not files, such as Welcome or Settings, and image previews show no language; a local history revision shows its file's. Extensions' status items, such as the Git branch, sit at the left.

## Code context menu

`EditorContextMenu` wraps each mounted editor. Its rows exist only while open; selection survives the menu's focus change, and actions target the editor and split pane that opened it. The context-menu key and Shift+F10 anchor it at the caret. `editor/context` contributions receive the file and selection offsets through the existing command activation path.

`EditorCommands` exposes language actions to the command center and keymaps, gates requests on server capabilities, and rejects stale results. Rename and formatting validate all text edits before changing buffers, retain per-file undo, and leave disk files unsaved. File operations and edits needing confirmation are rejected. `DocumentHistory.edit` applies patches to unmounted document data without constructing an editor.

Run `SNAPSHOT_ONLY=context-menu scripts/snapshot.sh` for interaction, LSP and extension checks and screenshots in both themes.

## Live history comparisons

`DocumentsPart` owns one `FileComparison` per source file under a virtual history-diff tab. A comparison retains its source buffer while open, but only its visible `HistoryDiff` mounts a worker, watch and completion hook. Hiding cancels pending work; closing releases the catalog, baseline, hunks and author labels. These transient tabs are excluded from session restoration and close when their source is renamed or deleted.

`GitHistory` runs read-only Git commands on the comparison worker, with bounded redirected output, cancellation and a timeout. It discovers the repository from the source file, including dependency paths. The catalog holds HEAD and up to forty commits at the current pathname; rename traversal is not included. Missing Git, untracked files and unborn repositories still allow local comparisons. Git data refreshes explicitly; no idle Git polling occurs.

`LocalHistory.snapshot` transfers immutable patch metadata to the worker. Optional revision authors and compacted base ownership remain compatible with older journals. `LineOwners` preserves untouched line authors across patch insertions/deletions; no-op Save checkpoints do not change ownership. The worker maps HEAD blame through the unsaved buffer, then supplies known local authors for changed lines. Unattributed edits remain explicit rather than borrowing a previous committer's name. No email metadata is retained for hints.

Features register `Contributions.editAuthor` for the edit being checkpointed and `comparisonSource` for a fixed comparison snapshot. Jam supplies the actual update sender's display name and its initial synchronized text. Recovery or updates from an unknown sender use `Jam sync`; historical CRDT operations are not retroactively assigned to a guessed participant. Baseline text stays fixed until the user selects another source. Worker requests coalesce and stale results never replace a newer buffer. Each open diff retains one ownership checkpoint, applying only later patches until compaction requires a rebuild. Comparisons are limited to text files within the preview size limit.
