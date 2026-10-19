# Writing an extension

RayDE extensions are written in RayScript, run in a process of their own, and describe what they add in a `.rayext` file. The example is a Markdown preview, in [`tests/fixtures/markdown`](../tests/fixtures/markdown): a **Preview** item in the Explorer's menu opens the file rendered in a tab beside the code, redrawn on each save.

![The Explorer's menu for README.md, with Preview at the right end of its item](images/markdown-menu.png)

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

Every field has a place in the **Extension** page of Settings. The page writes the file on each change and leaves entries it does not know as written. *Open as JSON* opens the text.

## Views

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
| `sidebar` | the side panel, in the Explorer's place | in the activity bar, selected while the view is showing |
| `secondary` | the right side bar | in the activity bar; it shows or hides the side bar |
| `panel` | a tab of the bottom panel | in the activity bar; it shows or hides the tab |
| `editor` | a tab among the open files | in the activity bar; it opens the tab |

Views in the same location share it: the sidebar shows one at a time, switched with the icons; panel and editor views are a tab each; side bar views stack. Each view has its own title, `icon` (an SVG file or the name of one of RayDE's) and `tools`, which are buttons in the header handled with `onTool(id, handler)`. A script changes the first view's title with `setTitle(text)`. A name that is no view's id goes to the first view, and a view is mounted again, not added to, when the extension reloads.

Mounting a view the config does not declare is reported in the Studio's console. A tab is the exception: `mount(view, 'tab:Title')` needs no declaration, and is how a command presents something.

The **Views** card of the Extension page declares, edits and removes views, each with its location, title, icon and actions.

![The Views card, with a block for each view](images/views-config.png)

## Commands and menus

A command is an id the script registers a handler for:

```
registerCommand('preview', (args) -> show(args.path));
```

A menu item runs a command with `{path, kind}` of what the menu was opened on, where `kind` is `file` or `folder`. It appears when its `when` holds: all of the conditions it gives must match. `kind` is `file` or `folder`, `ext` lists extensions with their dot (compared without regard to case), and `name` is a pattern in which `*` matches any run of characters (`README*`).

There are two menu locations:

| Location | Where | Runs on |
| --- | --- | --- |
| `explorer/context` | the right-click menu of a file or folder in the Explorer | that row |
| `editor/title` | the editor's `…` menu | the file in front |

![The editor's menu, with Preview for the file in front](images/markdown-title-menu.png)

Commands are also in the command center (`>`), with the file in front, or the one selected in the Explorer, as `path`. Each is bound as `ext.<id>` in **Key bindings**, and a menu shows its key beside the item.

An `icon`, on a command or on one menu item (the item's own wins), is an SVG file relative to the config, or the name of one of RayDE's own icons (`eye`, `refresh`, `star`; the Extension page lists them). A menu shows it at the right end of the item. A file that is missing is reported as a problem on the config.

## Hooks

Editor events reach an extension only if it asks for them with `onHook(name, handler)`:

| Hook | Called with | When |
| --- | --- | --- |
| `project.opened` | `{root}` | the project folder, once, when the extension subscribes |
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
| `activeFile()` | `workspace.read` | the path of the file in front, or null |
| `root()` | `workspace.read` | the project folder |
| `openFile(path)` | `workspace.read` | opens the file in a tab |
| `writeFile(path, text)` | `workspace.write` | writes the file; an open buffer is updated too |

Paths are resolved against the project folder, and one outside it is refused. Calls return promises, so a script `await`s them. `readFile` answers from the buffer when a file is open, which is why the preview shows an edit as soon as it is saved.

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

## The Extension Studio

Opening a `.rayext` runs the extension. Its views are drawn in the Preview at the `location` each declares; an extension with no view shows only the tabs it opens. The Studio's console, activity and elements are in the Extension tab of the bottom panel.

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
scripts/check.sh                                           # the extension in a real rayscript-host, with the workbench's answers played by the test
SNAPSHOT_ONLY=markdown scripts/snapshot.sh                 # the menu, the tab, a save, closing it, and the config form, into bin/snapshots
SNAPSHOT_ONLY=debug scripts/snapshot.sh                    # a breakpoint, the stop, the variables, stepping and going on
```

The host, `rayscript-host`, is found beside RayDE (`../rayscript/target/release`) or named by `RAYSCRIPT_HOST`. Its protocol, one JSON object a line in each direction, is documented in the crate.

## Limits

- One extension per project, and one process for it.
- `setTitle` changes the first view's title; the others keep the title they declare.
- The Explorer of an extension project lists its `sources` and the config, not the whole folder: the sample lists `docs` as a source so `README.md` has a menu.
- Only `workspace.read` and `workspace.write` are backed by a service. The other capabilities in the form (`process.spawn`, `net.fetch`, `terminal`, `clipboard`) are recorded in the config and not yet acted on.
- The Preview lays text out box by box, so inline emphasis inside a paragraph needs the per-word markup `words()` produces; ashui's inline flow is not attached to extension markup.
- A menu icon sits inside the item's label, at its right end, until ashui's menu items take an icon of their own.
- A call that a built-in makes back into the script (`array.map(f)`, a computed value, an effect) cannot be stopped in, and the extension does not stop on an error or on a `debugger` statement.
- Evaluation takes names, members and indexes only, and the variables of an enclosing function that a closure captures are not named.
