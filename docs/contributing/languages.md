# Language-server implementation

RayScript extensions register language servers with RayDE's asynchronous LSP client. A process belongs to its workspace registration. Opening, hiding, switching or closing editor tabs does not restart it. Closing a document sends `textDocument/didClose`, allowing the server to release its analysis.

## Startup and wakeups

The built-in [Rayzor extension](../../extensions/rayzor) is enabled by default and handles `.hx` files. It registers when the workspace opens and launches `rayzor lsp` over stdio when the first Haxe document opens. The process remains alive after its last document closes. Native replies wake the UI, so settled code tabs need no periodic LSP polling. Timers cover request and lifecycle deadlines; platforms without native wake support retain fallback polling. Startup, restart and shutdown finish even without code tabs. It contributes no sidebar view.

## Configuration and discovery

**Settings > Extensions > Rayzor Language Server** configures the executable, build file, Rayzor standard library and macro time budget. The default command `rayzor` discovers `RAYZOR_LSP`, a packaged executable, PATH, then an existing sibling development build. An explicit command path overrides discovery. The server discovers the installed Haxe standard library by default; the `stdlib` setting overrides it through `RAYZOR_STD_PATH`. RayDE leaves discovery to the server when that setting is empty. **Rayzor: Restart Language Server** applies changed settings. **Rayzor: Language Server Status** reports the registration's state.

## Protocol and recovery

The client uses [LSP framing and lifecycle](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/), JSON-RPC ids and UTF-16 document positions. Independent requests may be in flight together; replies may arrive in any order. A single writer prevents interleaved frames. Launch, pipe I/O, stderr draining and process reaping run off the UI thread. Queues and frame sizes are bounded.

Edits are coalesced before synchronization. Full and incremental servers are supported; incremental servers receive a full-document replacement range. Pending editor requests are cancelled when replaced, when their text changes or when their view is disposed. Stale request replies and versioned diagnostics are ignored. Servers publishing diagnostics without document versions cannot identify which revision an analysis belongs to. Request errors and timeouts are logged without dropping the server. Startup failure and unexpected exit trigger at most three starts per minute, with backoff and replay of open unsaved documents. The restart command resets the session after the limit.

Server stderr and protocol logs go to the owning extension's Output channel. Unregistering requests `shutdown` and `exit`, with a bounded grace period; workspace disposal terminates owned processes asynchronously.

Rayzor's current server has separate reader and writer threads and one analysis thread per session. It coalesces queued edits, analyzes changed files and then answers requests sequentially. It catches request/compiler unwinds and limits macro evaluation time. Client cancellation does not interrupt an analysis already executing in Rayzor; a slow compile delays replies while RayDE remains responsive. Native aborts, stack overflow and process termination require restart.

The initial client does not expose server-driven workspace edits, formatting, rename, semantic tokens or inlay hints. Completion snippets are not advertised. Plain insertions, imports and text edits ending at the caret are supported; unsupported replacement forms are omitted.


User controls are documented in [Language assistance](../languages.md); extension registration is in the [language-server API reference](../extensions/languages.md).
