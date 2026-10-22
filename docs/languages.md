# Language servers

RayScript extensions register language servers with RayDE's asynchronous LSP client. A process belongs to its workspace registration. Opening, hiding, switching or closing editor tabs does not restart it. Closing a document sends `textDocument/didClose`, allowing the server to release its analysis.

## Rayzor

The built-in [Rayzor extension](../extensions/rayzor) is enabled by default and handles `.hx` files. It registers when the workspace opens and launches `rayzor lsp` over stdio when the first Haxe document opens. The process remains alive after its last document closes. It contributes no sidebar view.

**Settings > Extensions > Rayzor Language Server** configures the executable, build file, Rayzor standard library and macro time budget. The default command `rayzor` discovers `RAYZOR_LSP`, a packaged executable, PATH, then an existing sibling development build. An explicit command path overrides discovery. The server discovers the installed Haxe standard library by default; the `stdlib` setting overrides it through `RAYZOR_STD_PATH`. RayDE leaves discovery to the server when that setting is empty. **Rayzor: Restart Language Server** applies changed settings. **Rayzor: Language Server Status** reports the registration's state.

The bottom status bar shows the registered server and its state, including stopped or failed sessions. Its logo spins during startup and while Rayzor analyses the active file; the tooltip names the file being indexed. Analysis of other open files does not keep a finished active file spinning. Click it for **Start**, **Restart**, **Stop**, extension settings or Output. Stop suspends the process until explicitly started; opening or editing a file does not relaunch it. Start and Restart replay the current unsaved buffers. These controls keep the existing configuration; apply changed Rayzor settings with **Rayzor: Restart Language Server**.

Hover popovers render Markdown with syntax-highlighted fenced code, emphasis, inline code, lists and links. Explicit `plaintext` responses remain literal. Long documentation scrolls within the popover, whose rendered content is released when it closes.

RayDE routes completion, hover, signature help, definitions, diagnostics and Outline to Rayzor by default. Build and Run continue to use the selected project runtime. Disabling Rayzor or reaching its restart limit restores the Haxe display fallback. Conflicting registrations for the same file extension are rejected.

## Extension API

The manifest requires `"capabilities": ["languages.register"]`. This grants process launch and document synchronization for the registered extensions, including unsaved buffers.

```haxe
import rayde.languages.registerServer;
import rayde.languages.unregisterServer;
import rayde.languages.servers;

await registerServer({
  id: 'rayzor', name: 'Rayzor', languages: ['haxe'], fileExtensions: ['.hx'],
  diagnosticProgress: true,
  transport: {kind: 'stdio', command: 'rayzor', args: ['lsp']},
  initializationOptions: {hxml: 'build.hxml', macroBudgetMs: 5000}
});
```

The first language id is sent in `didOpen`. Optional `lazy: true` defers process launch until the first matching document opens. `transport.env` optionally supplies string environment variables. `${workspaceFolder}` expands in the executable, arguments and environment values. The working directory is the workspace root. Arguments are passed directly, without a shell. Optional `settings` supplies the result of `workspace/configuration` queries. `diagnosticProgress: true` opts into active-document activity tracking for servers that publish diagnostics after every analysis, including an empty list. The status icon spins until diagnostics for the current document arrive; stale versioned results are ignored. Rayzor enables this by default.

`registerServer` returns the id before startup completes. Registering the same id again replaces that extension's session. `unregisterServer(id)` removes it; `servers()` returns that extension's registrations and states. Disabling, reloading or stopping an extension releases its servers. An event-fiber exception alone does not stop the registration.

## Protocol and recovery

The client uses [LSP framing and lifecycle](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/), JSON-RPC ids and UTF-16 document positions. Independent requests may be in flight together; replies may arrive in any order. A single writer prevents interleaved frames. Launch, pipe I/O, stderr draining and process reaping run off the UI thread. Queues and frame sizes are bounded.

Edits are coalesced before synchronization. Full and incremental servers are supported; incremental servers receive a full-document replacement range. Pending editor requests are cancelled when replaced, when their text changes or when their view is disposed. Stale request replies and versioned diagnostics are ignored. Servers publishing diagnostics without document versions cannot identify which revision an analysis belongs to. Request errors and timeouts are logged without dropping the server. Startup failure and unexpected exit trigger at most three starts per minute, with backoff and replay of open unsaved documents. The restart command resets the session after the limit.

Server stderr and protocol logs go to the owning extension's Output channel. Unregistering requests `shutdown` and `exit`, with a bounded grace period; workspace disposal terminates owned processes asynchronously.

Rayzor's current server has separate reader and writer threads and one analysis thread per session. It coalesces queued edits, analyzes changed files and then answers requests sequentially. It catches request/compiler unwinds and limits macro evaluation time. Client cancellation does not interrupt an analysis already executing in Rayzor; a slow compile delays replies while RayDE remains responsive. Native aborts, stack overflow and process termination require restart.

The initial client does not expose server-driven workspace edits, formatting, rename, semantic tokens or inlay hints. Hover documentation requests plain text. Completion snippets are not advertised. Plain insertions, imports and text edits ending at the caret are supported; unsupported replacement forms are omitted.
