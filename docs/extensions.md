# Writing an extension

RayDE extensions are written in RayScript and describe what they add in a `.rayext` file. The example is a Markdown preview, in [`tests/fixtures/markdown`](../tests/fixtures/markdown): a **Preview** item in the Explorer's menu opens the file rendered in a tab beside the code, redrawn on each save.

![The Explorer's menu for README.md, with Preview at the right end of its item](images/markdown-menu.png)

## Installed extensions

RayDE runs installed extensions in Haxe, extension and theme projects. Each extension has its own VM. Script-only extensions run on a runtime thread inside RayDE. Extensions declaring native libraries run their VM and libraries in a dedicated headless `rayde-extension-host` process, including built-in native extensions; opening the Extension Studio is not required.

In a browser workspace, every extension runs in its own process on the session host. Its preview renders in the browser, including interactive controls and live reload. The session needs execution enabled and an extension host installed; see [session host setup](contributing/session.md#serving-the-full-editor).

Uncaught RayScript exceptions fail the affected fiber and are reported in the extension's Output channel; other fibers and subsequent events continue in the same host. The VM uses Krio script fibers; a script exception does not panic RayDE. A fault in an extension-declared native library can terminate its host without terminating RayDE. Host exit clears the extension's views, tabs and command registrations. A supervised restart starts a fresh VM and does not replay the failed command.

| Scope | Folder |
| --- | --- |
| Built-in | Packaged with RayDE, under `extensions/`. |
| User | `~/.rayde/extensions/<id>/`. |
| Workspace | `.rayde/extensions/<id>/` under the project root. |

A folder contains a `.rayext` file and its scripts. The config's `id` identifies the extension; it defaults to the config's file name without its extension. A workspace copy replaces a user copy of the same id, which replaces the built-in copy. Opening a `.rayext` project replaces the installed copy with the development project and enables the Studio's controls and mocks.

![Two extensions in a Haxe project](images/extensions-workspace.png)

**Settings > Extensions** shows scope, state, the activation event, host state and capabilities. Its toggle stops or enables an extension for the workspace. Disabled ids are stored under `extensions.disabled` in `.rayde/settings.json`; the field overrides the same field in `~/.rayde/settings.json`.

![Installed extensions and a contributed setting](images/extensions-settings.png)

An extension starts on one of its `activationEvents`:

```json
{
  "id": "markdown",
  "activationEvents": ["workspaceContains:**/*.md", "onCommand:preview", "onView:preview"]
}
```

- `onStartup`: when the workspace opens. This is the default when `activationEvents` is absent. An empty list leaves the extension inactive.
- `workspaceContains:<glob>`: a matching path under the project root. `*` and `?` match within a path segment; `**` crosses folders.
- `onCommand:<id>`: when a contributed command is chosen. `*` matches several command ids. The command waits until the script registers its handler.
- `onView:<id>`: when the activity bar opens that view.
- `onNewProject`: when the project template gallery opens, including on a fresh Welcome window. These extensions stay inactive until needed.
- `onCodeActions:<language>`: when an active code editor requests actions for that language, such as `onCodeActions:haxe`. No provider host starts just for Welcome or an inactive tab.

Views, commands and menu items from enabled extensions share the workbench. Views and command bindings are identified by their owning extension. A failed host is restarted at most three times in a minute; after the limit it stays stopped until disabled and enabled again. **Output** has a channel per extension for logs, errors and restart reports, alongside the Build channel.

The status bar identifies extensions that are starting or preparing a command. An empty extension view shows loading feedback until its content arrives; stopped or failed views offer **Show Output**. View tools enable when their extension and content are ready.

`contributes.keybindings` supplies defaults such as `[{"command": "preview", "key": "mod+alt+p"}]`. Saved user bindings override them. The full command key is `ext.<extension-id>.<command>`; a saved `ext.<command>` binding migrates when exactly one installed extension declares that command. Ambiguous old bindings are kept for manual reassignment.

`contributes.configuration` accepts a schema with `properties`: boolean, string, number, integer and enum fields render under the extension's name in Settings. Values are stored in the `extension.<id>` section of the settings file, with workspace values overriding user values and schema defaults. A `describe` command returning structured state is the convention for extension inspection.

## The pieces

An extension is a folder with a config file and some scripts:

```
markdown/
  markdown.rayext        config: what the extension is and what it contributes
  ext/main.rays          entry script
  ext/markdown.rays      a module the entry script imports
  ext/preview.svg        the icon of the Preview command
  docs/README.md         a file to try it on
```

`scripts/rayde.sh path/to/markdown.rayext` opens the folder as an extension project: the Explorer lists the source folders, the config opens as a form, and the extension runs in the **Extension Studio**, which reloads it while it is edited and shows what it draws.

### The config

```json
{
  "name": "Markdown Preview",
  "main": "ext/main.rays",
  "sources": ["ext", "docs"],
  "capabilities": ["workspace.read"],
  "contributes": {
    "commands": [{"id": "preview", "title": "Preview", "icon": "ext/preview.svg"}],
    "menus": {
      "explorer/context": [{"command": "preview", "when": {"kind": "file", "ext": [".md", ".markdown"]}}],
      "editor/title": [{"command": "preview", "when": {"kind": "file", "ext": [".md", ".markdown"]}}]
    }
  }
}
```

- `main` is the entry script. `sources` are the folders it can import from (`import markdown.words;` reads `ext/markdown.rays`, since the first source is the import root) and the folders the Explorer shows.
- `capabilities` are what the extension may ask the workbench for. `workspace.read` lets it read files; `workspace.write` lets it write them. A call without the capability is rejected with the name of the one it needs.
- There is no `view`: the extension only handles hooks and commands and presents tabs, so it takes no place in the layout, and the Explorer keeps the sidebar. An extension gets a view only by asking for one, under [Views](#views).
- `contributes` adds commands and menu items, below.
- A top-level `icon` names an SVG file or a built-in icon such as `markdown`. It identifies the extension and its dynamically opened tabs; otherwise the first view's icon is used.

The **Extension** page of Settings edits these fields and preserves entries it does not expose. *Open as JSON* opens the text, including native declarations.

### Native libraries

Declare each library under `natives`, with a matching `native:<name>` capability:

```json
{
  "capabilities": ["native:git2"],
  "natives": {
    "git2": {
      "path": "natives/libgit2.dylib",
      "sha256": "<64 hexadecimal digits>"
    }
  }
}
```

The name is the logical library in a RayScript `native "git2"` block. Paths are relative to the `.rayext` file. Absolute paths, traversal and symlinks outside the extension folder are rejected. The host verifies SHA-256 against a private copy before making any declared library available; replacing the installed file afterwards cannot change those bytes. The copied directory layout is preserved for dependencies between declared libraries.

**Settings > Extensions** shows each library's path, hash and approval state. User, workspace and development extensions wait for every library to be approved. **Approve** grants native execution; **Revoke** stops the host and clears its views. Approvals are stored under `extensions.nativeApprovals` in `~/.rayde/settings.json`, bound to the extension id and location, library name, path and hash. Workspace settings cannot grant approval. A changed path, hash or extension location requires approval again. Built-ins are pre-approved and still undergo the same host validation. Validation failures appear in the extension's Output channel and block execution until it is restarted.

Approval trusts the extension's scripts to call native code with your account permissions. Process isolation contains native memory faults; it does not sandbox C code or verify script declarations against a library's ABI. Hashes cover declared library files; the operating system resolves their dependencies. Ship non-system dependencies as declared libraries, keeping their relative layout. The current native ABI target is macOS arm64.

The host executable is packaged beside RayDE and never resolved through the workspace or `PATH`. Missing hosts fail startup rather than falling back to embedded native execution. Standard output is reserved for the extension protocol; native diagnostics should use standard error. Native host messages are validated and capped at 16 MiB each; transport queues are bounded by bytes and message count. Standard error retains a bounded diagnostic tail. Pipe I/O, process launch and reaping run on workers, and output or exit wakes the UI without an idle polling timer where platform wake support is available.

#### Memory ownership

Third-party native extension authors are responsible for their native allocations, library caches, handles and background work. They must bound retained data, pair allocations with the library's matching release functions, and clean up resources when work completes, fails or is cancelled and when views or the extension close. Native handle declarations must describe the correct destructor and ownership relationships; borrowed memory must remain valid for every call that uses it. RayScript collection cannot reclaim arbitrary allocations or internal caches inside a native library.

RayDE maintainers are responsible for the VM, the native bridge and resources owned by the editor, including extension presentations, copied messages and decoded images. A bridge or lifecycle defect that retains an extension's resources is a RayDE defect. Our recommended built-in extensions also fall under RayDE's memory and performance maintenance, including their native dependencies.

**Settings > Extensions** identifies native hosts by process ID, and their process command lines include the extension ID for memory attribution. Each native host owns its private heap; RayDE does not impose a hard limit on that heap. Stopping, disabling or reloading the extension requests cleanup without blocking the UI. If cleanup has not completed after one second, RayDE terminates and reaps the host, reclaiming its process-owned memory even if a native call or destructor is stuck. Losing the parent input pipe also ends the host after a bounded cleanup period. RayDE's own native renderer, decoders and embedded services remain editor-owned and are outside this extension process boundary.

## Project starters

A RayScript extension can add starter cards to **New Project** without a sidebar or a view. Declare `"activationEvents": ["onNewProject"]` and `"capabilities": ["projects.register"]` in its manifest, then register the starter from its main script:

```haxe
import rayde.projects.registerStarter;
import rayde.projects.unregisterStarter;

var starter = await registerStarter({
  id: 'console',
  name: 'Console Application',
  category: 'Applications',
  description: 'A starter from my extension.',
  target: 'Cross-platform',
  icon: 'terminal',
  requirements: 'Haxe and Ash',
  command: 'haxe build.hxml',
  runner: 'ash',
  run: {framework: 'ash', targets: {hl: {runner: 'ash', flags: ['--preset', 'application']}}},
  entry: 'build.hxml',
  files: [
    {path: 'build.hxml', text: '-cp src\n-main Main\n-hl bin/app.hl\n'},
    {path: 'src/Main.hx', text: 'class Main { static function main() { trace("Hello, {{name}}!"); } }\n'}
  ]
});

// Optional: remove a starter while the extension keeps running.
registerCommand('removeStarter', _ -> await unregisterStarter(starter));
```

`id` is local to the extension; the returned id is namespaced, so extensions cannot replace one another's starters or the built-ins. Registering the same id replaces its definition. Stopping, disabling, restarting or revoking `projects.register` removes that extension's registrations. The open gallery follows these changes and selects another visible starter if its selection disappears.

`name`, `id` and `files` are required. `category` is `Applications`, `Games` or `Libraries` and defaults to `Applications`; `target` defaults to `Cross-platform`. `icon` is a named RayDE icon or an SVG path inside the extension (at most 64 KiB). `entry` names an included `.hxml`, `haxelib.json` or `rayzor.toml`; omit it or use an empty string to open the generated directory as a folder workspace. Optional `runner` is `auto`, `ash` or `hashlink`, stored in the new workspace's Run settings. `run` supplies editable Run Configuration defaults: `framework`, `target`, and target-keyed `targets` / `previews` objects. A profile can set `compiler`, `runner`, `mode` (`process`, `aot`, `browser`), `executable`, `flags`, `arguments`, `compilerFlags`, `buildCommand`, `buildFlags`, `program`, `previewDirectory` and `previewEntry`. Argument fields are arrays of strings. Metadata merges into `.rayde/settings.json` without replacing unrelated settings. `command` describes the first terminal command; scaffolding does not execute it. `docs` can name the starter's documentation URL.

Files contain UTF-8 text. RayDE substitutes `{{name}}` in their contents after the user enters a project name; file paths are literal, relative paths. Absolute paths, traversal, duplicate names and file/folder collisions are refused before creation. Creation runs on a worker in a new directory and never overwrites an existing folder. A starter is limited to 256 files, 1 MiB per file and 4 MiB total. The live catalog retains at most 16 starters per extension, 64 total and 8 MiB of text.

The runnable fixture is [Console Starter](../tests/fixtures/starters/console/main.rays).

## Code actions

Providers use the same registry for the editor's gutter hints and **Show Code Actions** chooser. No view or sidebar contribution is needed. Add `"activationEvents": ["onCodeActions:haxe"]` and `"capabilities": ["codeActions.provide", "workspace.read", "workspace.write"]` to the manifest; `workspace.write` is required only for actions that return edits.

```haxe
import rayde.codeActions.registerProvider;
import rayde.codeActions.respond;

onHook('codeActions.request', e -> {
  var start = e.context.range.from;
  var end = e.context.range.to;
  var selected = e.context.text.substring(start, end);
  await respond(e.request, selected.length == 0 ? [] : [
    {id: 'uppercase', title: 'Convert selection to uppercase', kind: 'refactor.rewrite', icon: 'edit',
     range: {from: start, to: end},
     edits: [{from: start, to: end, text: selected.toUpperCase()}]}
  ]);
});

var provider = await registerProvider({
  id: 'text-tools', languages: ['haxe'], kinds: ['refactor'], automatic: false
});
```

Subscribe before registering. `id` is local to the extension; the returned provider id is opaque and can be passed to `unregisterProvider(id)`. Registering the same local id replaces it. Providers select `languages` (lowercase language ids) or `extensions` (without a dot); either match is sufficient. Optional `kinds` restricts replies to those kinds and their dotted children. Kinds are extensible: `quickfix`, `refactor.rewrite`, `source.organizeImports`, `run` and `debug` can share this API. Automatic hints require explicit `automatic: true`; otherwise only an invoked chooser calls the provider.

Each request is `{request, provider, context}`. `provider` is the local id. `context` contains `path`, `language`, `text`, `version`, `range`, `trigger` (`automatic` or `invoked`) and up to 100 diagnostics (`from`, `to`, `message`, `severity`). Invoked requests carry the selection or caret; automatic requests cover the document. **All RayScript API ranges are Unicode character offsets**, matching RayScript's `length`, `indexOf` and `substring`, with an exclusive `to`. RayDE converts them to the native editor's positions, including text containing emoji. Source snapshots are sent only for files inside the workspace and never require the provider to retain editor instances.

Reply once with `await respond(e.request, actions)`. Each action needs a unique `id`, `title`, `kind`, and either `edits` or `command`. Optional `range` defaults to the request's range, `icon` names a RayDE icon, `preferred` orders actions on the same range, and `disabled` explains why an action cannot run. Edits are non-overlapping `{from, to, text}` replacements in the requested document. They apply together through the editor's undo system. Other files are not accepted as edit targets.

A command is local to the owning extension, registered with `registerCommand`. Its handler receives `{path, version, range, arguments}`; `arguments` comes from the action's optional JSON payload. When an action has both edits and a command, the edits apply first. A command cannot use an action payload to invoke another extension or a workbench command. The built-in Run provider uses the same native registry and routes through RayDE's project runner.

`onHook('codeActions.cancel', e -> ...)` signals a superseded request, tab change, provider removal or timeout. Stop work and discard source data for that token. Responses after cancellation, after four seconds or from another owner return `false`. Before execution RayDE checks that the active document and version still match; actions are consumed once. Call `await invalidate()` from `rayde.codeActions` when external provider state changes. This schedules a fresh request for the active editor. Edits, diagnostics and provider changes also refresh actions; caret movement alone does not rescan the document.

Only one active-document session is retained per window. Closing or switching tabs cancels pending requests and drops results. Stopping, disabling, restarting, changing an extension identity or revoking its provide/read/write grants removes its providers. Limits are 16 providers per extension, 64 per window, 128 actions per response, 512 per document, 128 edits per action, 256 KiB of inserted text per action and 32 KiB of command arguments. A response is limited to 1 MiB and current results to 4 MiB. Documents larger than 4 MiB of editor text are skipped.

Native providers register with [CodeActions](../src/rayde/actions/CodeActions.hx) and the typed structures in [CodeAction](../src/rayde/actions/CodeAction.hx). Dispatch and cancellation callbacks support asynchronous workers or a future language-server adapter without changing the consumers. Native ranges use editor positions. The [Run provider](../src/rayde/actions/EntryPointActions.hx) scans the configured main class on a data-only worker; the [RayScript fixture](../tests/fixtures/codeactions/main.rays) exercises hooks, edits, owner commands and invalidation. LSP code-action requests are not wired in by this change.

## Views

Language extensions can instead register [workspace language servers](extensions/languages.md) through `rayde.languages`, without a view or sidebar contribution.

A view is a part of the layout that shows an extension continuously, as opposed to a tab opened for a file. The Markdown preview declares none. Views are declared with `view` (one) or `views` (several):

```json
"views": [
  {"id": "main", "title": "Overview", "icon": "home", "location": "sidebar",
   "tools": [{"id": "refresh", "title": "Refresh", "icon": "refresh"}]},
  {"id": "inspector", "title": "Inspector", "icon": "eye", "location": "secondary"},
  {"id": "log", "title": "Log", "icon": "list", "location": "panel"}
]
```

and each is mounted under its id:

```
mount(() -> <Overview/>, 'main');
mount(() -> <Inspector/>, 'inspector');
mount(() -> <Log lines={lines}/>, 'log');
```

![Three views of one extension: the sidebar, the right side bar and the bottom panel](images/views.png)

| Location | Where | Its icon |
| --- | --- | --- |
| `explorer` | a collapsible, resizable Explorer section | no activity-bar icon |
| `sidebar` | the side panel, in the Explorer's place | in the activity bar, selected while the view is showing |
| `secondary` | the right side bar | in the activity bar; it shows or hides the side bar |
| `panel` | a tab of the bottom panel | in the activity bar; it shows or hides the tab |
| `editor` | a tab among the open files | in the activity bar; it opens the tab |

Views in the same location share it: the sidebar shows one at a time, switched with the icons; panel and editor views are a tab each; side bar views stack. Each view has its own title, `icon` (an SVG file or the name of one of RayDE's) and `tools`, which are buttons in the header handled with `onTool(id, handler)`. A script changes the first view's title with `setTitle(text)`. A name that is no view's id goes to the first view, and a view is mounted again, not added to, when the extension reloads.

Mounting a view the config does not declare is reported in the Studio's console. A tab is the exception: `mount(view, 'tab:Title')` needs no declaration, and is how a command presents something.

The **Views** card of the Extension page declares, edits and removes views, each with its location, title, icon and actions.

![The Views card, with a block for each view](images/views-config.png)

### Stylesheets

An extension can ship local CSS for its content and surrounding view headers. List files relative to the `.rayext` file; later files take precedence:

```json
"styles": ["styles/base.css", "styles/dashboard.css"]
```

Selectors are relative to the extension's views and tabs. `:view` (also `:root`, `html` or `body` at the start of a selector) selects the wrapper itself:

```css
:view { --panel-tint: #102030; --text-primary: #e0efff; }
.rayde-studio-bar { background: #203040; }
.rayde-studio-surface { background: var(--panel-tint); }
.rayde-heading { color: #ffee00; }
.caption { color: #b0c0d0; }
```

These rules override RayDE's shared header and surface CSS within that extension. Explicit element properties, including RayDE's compiled Tw styles, still take precedence; RayScript utility classes participate in the normal CSS cascade. Use theme variables such as `var(--text-primary)` for colors that should follow the user's theme.

`@media`, `@supports`, `@container`, `@layer` and `@keyframes` are supported. Write full selectors; nested style rules using `&` are skipped. Keyframe names and literal references in `animation`/`animation-name` are local to the extension; use identifiers directly rather than passing animation names through custom properties. `@import`, `@font-face`, other at-rules and declarations containing `url()` are skipped with a message in the extension's Output channel. Each sheet must be a `.css` file inside the extension folder, including resolved symlink targets, and no larger than 256 KiB.

**Reload extension** rereads the sheets. Invalid or missing CSS keeps the last working version and reports the problem in Output. Closing the last mounted view or tab releases the sheets; other extensions and windows keep their own styles. See the [dashboard fixture](../tests/fixtures/views/styles/dashboard.css) for a complete example.

## Commands and menus

A command is an id the script registers a handler for:

```
registerCommand('preview', (args) -> show(args.path));
```

A menu item runs a command with `{path, kind}` of what the menu was opened on, where `kind` is `file` or `folder`. It appears when its `when` holds: all of the conditions it gives must match. `kind` is `file` or `folder`, `ext` lists extensions with their dot (compared without regard to case), and `name` is a pattern in which `*` matches any run of characters (`README*`).

Menu locations:

| Location | Where | Runs on |
| --- | --- | --- |
| `explorer/context` | the right-click menu of a file or folder in the Explorer | that row |
| `editor/title` | the editor's `…` menu and tab right-click menus | the file in front, or the clicked tab |
| `editor/context` | the code editor's right-click menu | the clicked file; also receives `range: {from, to}` as UTF-16 offsets in its current buffer |

![The editor's menu, with Preview for the file in front](images/markdown-title-menu.png)

Commands are also in the command center (`>`), with the file in front, or the one selected in the Explorer, as `path`. Each is bound as `ext.<extension-id>.<command>` in **Key bindings**, and a menu shows its key beside the item.

An `icon`, on a command or on one menu item (the item's own wins), is an SVG file relative to the config, or the name of one of RayDE's own icons (`eye`, `refresh`, `star`; the Extension page lists them). A menu shows it at the right end of the item. A file that is missing is reported as a problem on the config.

## Hooks

Editor events reach an extension only if it asks for them with `onHook(name, handler)`:

| Hook | Called with | When |
| --- | --- | --- |
| `project.opened` | `{root}` | the project folder, once, when the extension subscribes |
| `view.visibility` | `{id, visible}` | declared view attached or detached; the visibility of each declared view is replayed on subscribe |
| `active.changed` | `{path}` | the editor in front changed; `path` is null for a page that is not a file; also sent on subscribe |
| `file.opened` | `{path}` | an editor tab opened for a file |
| `file.closed` | `{path}` | an editor tab closed |
| `file.changed` | `{path}` | a buffer was edited; repeats within 300 ms become one call per file |
| `file.saved` | `{path}` | a buffer was written to disk |

The preview uses `file.saved` to redraw: its handler reads the file again and sets the signal the view reads.

```
onHook('file.saved', (e) -> {
  for (p in open) {
    if (p.path == e.path) p.source.value = await readFile(e.path);
  }
});
```

A name that is not in the table is reported in the Studio's console. The **Hooks** card of the Extension page lists the events and shows which the running extension listens for.

![The Hooks card, with file.saved listened for](images/markdown-hooks.png)

## Reading files

The extension asks the workbench for files through the `rayde.workspace` module:

| Function | Capability | Returns |
| --- | --- | --- |
| `readFile(path)` | `workspace.read` | the text of the file, as the editor holds it when the file is open |
| `readBytes(path)` | `workspace.read` | base64-encoded file bytes, limited to 8 MiB |
| `activeFile()` | `workspace.read` | the path of the file in front, or null |
| `root()` | `workspace.read` | the project folder |
| `openFile(path)` | `workspace.read` | opens the file in a tab |
| `writeFile(path, text)` | `workspace.write` | writes the file; an open buffer is updated too |

Paths are resolved against the project folder. Reads and source navigation also accept the build's declared class paths and library source roots resolved in Dependencies; writes remain restricted to the project folder. Other paths are refused with the requested path and workspace in the error. Calls return promises, so a script `await`s them. `readFile` answers from the buffer when a file is open, which is why the preview shows an edit as soon as it is saved.

`rayde.settings.get(key, fallback?)` returns a promise for the calling extension's own setting. Workspace values under `extension.<id>` in `.rayde/settings.json` override user values in `~/.rayde/settings.json`, then the manifest's configuration default and finally the supplied fallback. Reading this section needs no workspace capability and cannot access another extension's section.

`rayde.window.notify(message, kind='info')` shows an Ashui toast and records the message in the extension's Output channel. Kinds are `info`, `success`, `warning` and `error`. Output uses the theme's error, warning and success colors for those messages, including multiline entries. The text remains selectable and copyable. The toast's **Show Output** action opens that channel. The extension's manifest supplies the toast title; no workspace capability is required.

`rayde.window.setStatusItem(id, item)` puts an item at the left of the status bar, before the runtime; a null `item` removes it. `item` is `{text, icon?, detail?, detailIcon?, tooltip?, view?, command?}`: icons are names from the icon set, `detail` is a second, lighter group of text, `view` shows one of the extension's own sidebar views when pressed (without folding it if it is already in front) and `command` runs one of its commands. An item is replaced by setting the same id again, and every item an extension set goes when it stops or is disabled. No capability is needed.

`rayde.window.focusView(root)` focuses an existing tab mounted by this extension. `rayde.window.openExternal(url)` requires `window.openExternal` and opens HTTP, HTTPS or mailto links in the system handler. Both return promises.

The pure native modules `rayde.syntax` and `rayde.markdown` supply the [shared syntax registry](syntax.md) and [Markdown renderer](markdown.md). The `markdown-view` bridge consumes the renderer's JSON document string, draws its Ashui content, and emits `link` events with `{href}` for file or external links. Same-document anchors are handled within the view, including headings in blocks that have not been mounted. Native Markdown content is virtualized by document block, with small mount batches and data-only height caches for scroll restoration.

Set the rendered document's `baseFile` to its source path before serializing it. The bridge resolves local image references relative to that file through `workspace.read`, with the workspace path and size checks. Cached documents need no base64 image payloads; only the visible Markdown view loads and owns decoded image resources.

Scrollable bridge divs accept `virtualizeImages={true}` to opt into Ashui's viewport image residency. Image dimensions remain in layout while offscreen decoded pixels are released; compressed sources support reload on reentry, and the renderer reclaims atlas capacity. It defaults to false. A nested explicit false opts out; shared visible or unmanaged bitmap uses remain resident.

## Showing a tab

`mount(view, name)` puts a view where the extension's view goes. A name that starts with `tab:` opens an editor tab titled with the rest of it:

```
mount(() -> <Document source={source} path={path}/>, 'tab:Preview of ' + name(path));
```

![The preview, in a tab beside the file it renders](images/markdown-tab.png)

Closing the tab tells the extension, which unmounts the view; the cleanups the view registered with `onCleanup` run. The preview uses that to forget the file:

```
function Document(props) {
  onCleanup(() -> forget(props.path));
  ...
}
```

Markdown is a few hundred lines of RayScript in [`markdown.rays`](../tests/fixtures/markdown/ext/markdown.rays): `blocks(source)` splits a document into headings, paragraphs, lists, quotes, fenced code and rules, and `words(line)` breaks a line into words tagged with the emphasis, code or link they came from. The view is ordinary markup, `<div>`, `<span>` and utility classes, which the Preview draws with the same classes as ashui (`flex`, `gap-2`, `text-sm`, `bg-surface-elevated`).

## Ashui controls and interactive drawing

Extension markup can use native Ashui components through the same view bridge:

```haxe
var branch = signal('all');
<ui-select value={branch} options={[{value:'all', label:'All references'}]}
  onChange={e -> branch.value = e.value}/>;
<ui-button variant="outline" disabled={busy} onClick={() -> refresh()}>Refresh</ui-button>;
```

`ui-button` accepts text or markup children, `disabled`, `variant` (`primary`, `secondary`, `outline`, `ghost`, `link`, `destructive`) and `size` (`sm`, `md`, `lg`). `ui-select` accepts `value`, `disabled`, `size` and `options`: `{value, label, disabled?}` records. It emits `change` with `{value}`. Both use Ashui's focus and keyboard handling. Their default row height is 32 px; numeric `height` permits 16–256 px for dense lists. CSS sets the wrapper's width, placement and component custom properties.

`ui-button copyText={text}` copies that text to the system clipboard when the user activates the button. It grants no clipboard read access. Git uses it to copy full commit and parent hashes while displaying shortened labels.

`ui-icon` renders Ashui's named icon set through its `name` property, at 16 px by default. Icon buttons accept `size="icon"`, `aria-label` and a static `tooltip`, for example `<ui-button size="icon" tooltip="Maximize graph"><ui-icon name="maximize"/></ui-button>`. The tooltip also supplies the accessible label. `maximize` uses the pack's `fullscreen-line` SVG; `fetch`, `pull`, `push`, `focus` and `filter-off` are also available.

Use `file` instead of `name` to show a file's Explorer icon, for example `<ui-icon file={entry.path}/>`. This shares RayDE's filename and language mappings, colours and fallback icon without reading the file.

`ui-avatar` accepts `profile={...}` with `id`, `remote`, `author` and `email` fields. The `net.profiles` capability enables public author lookups for GitHub, GitLab.com and Bitbucket Cloud; other remotes and unavailable accounts show initials. Requests use system `curl` on a worker with bounded responses and timeouts, without credentials. Author images are shared across repositories on the same provider. The memory cache retains at most 128 entries and 2 MiB of compressed images. A disk cache in `~/.rayde/cache/git-avatars` survives restarts, capped at 128 entries and 8 MiB. Saved images are reused without network access for seven days and remain available if a later refresh fails. Visible presentations own and release their decoded 64 px bitmaps; disk reads and writes stay on the profile worker.

The adapters use [GitHub commit authors](https://docs.github.com/en/rest/commits/commits), [GitLab's public-email avatar API](https://docs.gitlab.com/api/avatar/) and [Bitbucket commit authors](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-commits/). GitHub noreply addresses and exact public email matches can resolve accounts for unpublished commits. Restricted profiles, rate limits, missing `curl` and offline failures fall back quietly.

Git graphs supply `hoverCard` on `canvas-kit` after a brief hover delay. A card contains the full local commit message, author and avatar. Its capped message body scrolls independently and stays open while the pointer enters it. Expanded graphs mount avatars only for visible rows. Diff headers show the selected commit's author, or explicitly label the base commit for working-tree comparisons.

`ui-menu` is Ashui's native DropdownMenu with an icon-sized chevron trigger. It takes `tooltip`, `disabled` and `options` (`{value, label, disabled?}`), and emits `select` with `{value}`. Its keyboard navigation, focus restoration and dismissal use the native component.

`code-diff` is Ashui's CodeDiff: two texts compared. It takes `original` and `modified` strings, `language` (`haxe`, `json`, `rust`, `typescript`, `javascript`, `css`, `python`, `lua` or `plain`), `layout` (`inline` or `split`) and `navigation` (a bar with the change count and previous/next buttons, fixed once mounted). Markup children occupy the left side of that same header, so titles and custom controls share the navigation row. All but `navigation` can be signals. It is read-only and fills its parent.

`canvas-kit` retains a serializable drawing scene and runs Ashui CanvasKit in the editor:

```haxe
var drawing = signal({
  bounds: {x:0, y:0, width:300, height:160},
  commands: [
    {type:'path', path:[['M',40,80],['C',100,80,160,40,220,40]], color:'textLink', stroke:2},
    {type:'circle', x:40, y:80, radius:6, color:'accent'},
    {type:'text', x:60, y:85, text:'Commit', color:'textPrimary', size:13}
  ],
  regions: [{id:'commit', x:20, y:60, width:260, height:40}]
});
<canvas-kit class="flex-1 min-h-0" scene={drawing}
  onClick={e -> select(e.region)}/>;
```

Scene commands are painted in order. Coordinates and sizes are content units. Colors are RGB integers or camelCase Ashui theme tokens; command `alpha` defaults to 1 and multiplies the theme color's alpha. `stroke` is a constant screen-pixel width; zero fills a shape.

| Command | Fields |
| --- | --- |
| `path` | `path`: arrays `['M',x,y]`, `['L',x,y]`, `['C',x1,y1,x2,y2,x,y]`, `['Z']`. |
| `circle` | `x`, `y`, `radius`. |
| `rect` | `x`, `y`, `width`, `height`, optional corner `radius`. |
| `text` | `text`, `x`, baseline `y`, optional `size` and `weight`. |

`regions` are unique string ids with rectangular bounds, used for local hover and selection. `selected` accepts an array of ids. Optional handlers receive `click` `{region,x,y,shift,control,meta}`, `hover` `{region}` (null on leave) and `selectionChange` `{ids}`. Event coordinates are local screen coordinates.

The wheel zooms at the pointer; dragging empty space or using the middle/right button pans. Shift-drag selects a rectangle. Commit positions remain script data; gestures do not move the drawing's objects. Painting, hover highlighting, pan and zoom run locally without script calls per frame. Scene updates decode paths once and cull offscreen shapes and text; paths remain in paint order.

For linear lists, set `navigation="scroll"` when mounting the canvas. Ashui Scroll uses a nonpainting spacer for the full scene extent, with native wheel/trackpad scrolling and scrollbars. The canvas stays viewport-sized at fixed scale and renders only visible geometry and hit regions. Hover and region selection remain available; pan/zoom gestures are disabled. Coordinates start at the content's top left. Only `reset` commands apply in this mode, resetting the scroll position; it otherwise survives presentation rebuilds. Both Git graph views use this mode.

For scrolling graphs whose labels sit above the shapes, `textRendering="native"` places visible text commands in pooled Ashui text elements. They use the shared glyph atlas instead of tessellating each string into triangles. Offscreen labels are omitted and pointer input passes through to the canvas. The default `paths` mode preserves drawing order and supports transformed text. Both properties are fixed while mounted.

Set `command` to `{action:'fit'}`, `{action:'reset'}` or `{action:'zoom',factor:1.25}`. A changed `sequence` field repeats an otherwise identical command. Commands run after layout; `fit` uses full scene `bounds`, including offscreen regions. The viewport survives tab presentation rebuilds, and native control owners are disposed when views are hidden or removed. Invalid live properties report an extension error and preserve the last accepted property. Drawing, region and aggregate path-segment lists are limited to 50,000 entries.

`ui-panel-group` composes Ashui `Resizable`, `ResizablePanel`, `Collapsible`, `CollapsibleTrigger` and `CollapsibleContent` into vertical, named panels:

```haxe
<ui-panel-group class="flex-1 min-h-0" panels={[
  {id:'changes', title:'Changes', open:true, minSize:32},
  {id:'graph', title:'Graph', open:true, size:324, minSize:32}
]}>
  <div slot="changes" class="flex-1 min-h-0 overflow-auto">Changes</div>
  <div slot="graph" class="flex-1 min-h-0">Graph</div>
</ui-panel-group>;
```

`size` and `minSize` are layout pixels; an unsized panel shares the remaining space. Native divider dragging, arrow-key resizing and double-click reset apply. Headers toggle with pointer, Enter or Space. Closing a panel reduces it to its header; reopening restores its expanded size. Panel sizes and open states survive presentation rebuilds. `onPanelChange` receives `{id,open}`. The panel list is fixed for a mounted group (at most 16, with unique ids); children route through their `slot` property. Panel content owns its own scrolling.

The [Git history graph](git.md) combines these controls with a RayScript DAG layout and native libgit2 history pages.

## The Extension Studio

Opening a `.rayext` runs the extension. Its views are drawn in the Preview at the `location` each declares; an extension with no view shows only the tabs it opens. The Studio's console, activity and elements are in the Extension tab of the bottom panel.

Open a `.rays` file, then choose **Preview Extension** from its gutter code action, the **Code Actions** menu, or the eye button beside the tabs. The preview opens in a side sheet and leaves your editor splits in place. Source files open with the preview hidden.

Main scripts and source modules find the declaring `.rayext` in their parent folders. The preview runs its main script with the manifest's settings, imports, capabilities and styles. A script with no declaring manifest runs as a standalone preview.

![An extension's view in the sidebar, in the Explorer's place](images/studio-sidebar.png)

- **Reload:** saving or typing reloads the extension after a pause of 0.4 s; *Disable live reload* in the view's `…` menu leaves reloading to Run. A script with an error does not replace what was drawn: the last view that ran stays, marked as such, and the error is in Problems on its line.
- **Console:** what the script traces, and every error with its place, which opens the file there.
- **Activity:** the calls, hooks and commands that went to and from the extension, and what answered each.
- **Elements:** the tree the extension drew, with the events each node listens for.
- **Mocks:** a module the extension imports from elsewhere is answered from the `mocks` file of the config (`ext/studio.mocks.json`) while it is developed, and a mock takes precedence over a real answer from the workbench, so a script can be tried against files that are not in the project.

![The activity list, with a command, the read it made and its answer](images/studio-activity.png)

## Debugging

An extension stops at a breakpoint and its state can be inspected.

- **Setting:** click in the gutter beside a line of a `.rays` file, or put the cursor on it and choose **Toggle Breakpoint** (F9). A red dot marks the line.
- **Storage:** breakpoints are kept with the project (`breakpoints` in `.rayde/settings.json`) and move with the text. A line with no code moves the breakpoint to the next line that has some.
- **List:** the Debug part of the panel lists them; a row opens its line and its button removes the breakpoint.

The extension stops before the marked line runs. The editor goes to the line and marks it, and the Extension panel shows **Debug**:

- the toolbar: **Continue** (F5, which is Run while the extension is stopped), **Pause** (F6, for a script that is running), **Step Over** (F10), **Step Into** (F11) and **Step Out** (Shift+F11);
- the **call stack**, innermost first; choosing a frame opens its line and shows its variables;
- the **variables** of the frame, its locals and then those of its module; a value with members (an array, an object, a map, a signal) opens to show them;
- a field that **evaluates** a name and a path of members and indexes in the frame (`entry.amount`, `todo.items[2].title`), not arithmetic or calls.

![The extension stopped on the line that updates the total, with its call stack and breakpoints](images/debug-stopped.png)

Nothing of the extension runs while it is stopped: events and hooks that arrive are held and run when it continues, and what the stopped code changed in the view is drawn then. A breakpoint in a handler stops the extension when the view is clicked or a header action is chosen.

![An expression evaluated in the frame, and a variable opened](images/debug-variables.png)

The debugger is in the VM and costs nothing without breakpoints: a breakpoint replaces one instruction, with the original kept.

## Trying it

```sh
scripts/rayde.sh tests/fixtures/markdown/markdown.rayext   # right-click docs/README.md, choose Preview
scripts/check.sh                                           # embedded extension VMs, with the workbench's answers played by the test
scripts/check-native-extensions.sh                         # native crashes, bounded transport, cleanup and idle window waking
SNAPSHOT_ONLY=markdown scripts/snapshot.sh                 # the menu, the tab, a save, closing it, and the config form, into bin/snapshots
SNAPSHOT_ONLY=extensions scripts/snapshot.sh               # two installed extensions, commands, restart, configuration and toggles
SNAPSHOT_ONLY=debug scripts/snapshot.sh                    # a breakpoint, the stop, the variables, stepping and going on
```

`native/rayscript` provides `rayscript.hdll`, loaded through Haxe externs, and the headless `rayde-extension-host` executable. Script-only VMs use in-memory queues. Native extension VMs use bounded asynchronous pipes, with VM values and native pointers staying inside their host process. Both modes register RayDE's Markdown and syntax services. Queued output and runtime completion wake the UI loop; quiet extension VMs need no supervisor poll timer. Delayed replies, live reload and activation timeouts keep their own deadlines. Platforms without native wake support retain fallback polling. Closing a tab cancels its event fibers and their spawned children, unmounts the view, and requests collection at a safepoint. Late service replies do not resume cancelled fibers. Hiding a sidebar releases its presentation and requests collection while retaining its mounted view state. Disabling, reloading or closing the workspace requests VM cleanup; isolated native hosts have a bounded shutdown period before forced termination. Collection requests and shutdown do not block the UI thread. The generic standalone `rayscript-host` remains available for backend tooling.

## Limits

- `setTitle` changes the first view's title; the others keep the title they declare.
- The Explorer of an extension project lists its `sources` and the config, not the whole folder: the sample lists `docs` as a source so `README.md` has a menu.
- `workspace.read`, `workspace.write` and `window.openExternal` are backed by services. The other capabilities in the form (`process.spawn`, `net.fetch`, `terminal`, `clipboard`) are recorded in the config and not yet acted on.
- The Preview lays text out box by box, so inline emphasis inside a paragraph needs the per-word markup `words()` produces; ashui's inline flow is not attached to extension markup.
- A menu icon sits inside the item's label, at its right end, until ashui's menu items take an icon of their own.
- A call that a built-in makes back into the script (`array.map(f)`, a computed value, an effect) cannot be stopped in, and the extension does not stop on an error or on a `debugger` statement.
- Evaluation takes names, members and indexes only, and the variables of an enclosing function that a closure captures are not named.
