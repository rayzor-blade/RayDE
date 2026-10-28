# Pocket Studio

A project board built with Haxe and Ashui, plus a RayScript workspace extension. Explore the source, change a component, restyle a task card or add an extension command.

## Run the app

Install Haxe and Ash, then the published libraries:

```sh
haxelib install ashui-components 0.1.5
haxelib install ashui-icons 0.1.5
haxe build.hxml
ash bin/pocket-studio.hl
```

All library dependencies come from Haxelib. `src` is this project's own source folder; there are no sibling-repository library paths.

## Explore

- `src/Main.hx` opens the app. `ui/BoardApp.hx` composes the board.
- `state/BoardStore.hx` owns reactive state, filtering and task transitions.
- `ui/` contains reusable header, stats, column, card and inspector views.
- `data/tasks.json` is the saved board. **Save board** writes a new snapshot.
- `styles/app.css` controls the app's surfaces and task cards.

## Develop the extension

Open `extensions/pocket-tools/ext/main.rays` in RayDE. Its parent manifest supplies imports, workspace-read permission, commands, views and a stylesheet. The Preview displays the reactive Pocket Tools panel. Click **Refresh summary**, or run **Pocket Studio: Refresh Summary**. Use **Reload Extension** after changing a script or stylesheet.

`summary.rays` transforms saved task data. `panel.rays` renders the UI. Try adding a count, changing a label or registering another command.

The browser-only landing sample supports browsing and editing. To run the app or extension, connect a session with tools enabled. For local development, from RayDE's repository run:

```sh
python3 scripts/serve-site.py --workspace site/demo/build.hxml
```

The connection is remembered on that browser origin. Dependencies and tools must be installed on the session host. Your edits in the browser sample never overwrite this source directory.
