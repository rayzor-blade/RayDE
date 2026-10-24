# Registering language servers

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

RayDE also advertises LSP work-done progress and displays `$/progress` titles, messages and percentages. Rayzor's `experimental.rayzorIndexProgress` client capability enables background workspace reports; `rayzor/indexProgress` carries `scope: "workspace"`, a qualified module `subject`, `phase: "scanning"` and a `completed` file count, followed by `state: "ready"`. Document reports carry `uri`, `version`, `subject`, `phase`, `completed` and optional `total`. A server advertising `experimental.analysisStatusProvider` finishes document activity with `rayzor/analysisStatus` (`state: "ready"`), rather than diagnostics alone. Progress is cleared on shutdown and when the last code tab closes; it adds no welcome-page polling.

`registerServer` returns the id before startup completes. Registering the same id again replaces that extension's session. `unregisterServer(id)` removes it; `servers()` returns that extension's registrations and states. Disabling, reloading or stopping an extension releases its servers. An event-fiber exception alone does not stop the registration.

See [Writing an extension](../extensions.md) for installation and capabilities, [Language assistance](../languages.md) for user controls, and the [client implementation](../contributing/languages.md) for transport and recovery details.
