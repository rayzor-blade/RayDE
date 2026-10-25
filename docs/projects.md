# Projects

Welcome offers three ways to start:

- **Open Folder** opens any folder, including a non-Haxe project. No project descriptor is required.
- **Open Project** selects an `.hxml`, `.cbproj`, `haxelib.json`, `rayzor.toml`, extension or theme project.
- **New Project** creates a project from a starter template.

Recent projects and folders open directly from Welcome. These commands are also available in the File menu and command center. Opening from an empty Welcome uses that window; opening another project from an existing workspace creates a new window.

## Create a project

Choose a starter card, enter a name and parent folder, then select **Create Project**. The dialog shows its requirements and first build command. Existing directories are never overwritten.

The gallery includes application, game and library starters, including Ash, Ashui, Rayzor and Haxe frameworks. Follow the generated project's README to install its dependencies and run it.

The Tink Web Application starter includes a Coconut browser UI and an optional Tink Web API for Node.js, with separate `build.hxml` and `server.hxml` targets. The Ceramic starter opens as a folder workspace with `ceramic.yml`; use Ceramic's CLI to set up and build its targets.

Extensions can add [custom starters](extensions.md#project-starters) to the gallery.

## Next steps

Browse files in [Explorer](explorer.md), choose a runner in [Build and Run](build.md), or learn how [windows and tabs are restored](window.md#restoring-a-session).

## Caribou projects

A `.cbproj` is a Caribou project: one program in Haxe with Lua, Python and Wren modules beside it. RayDE does not read the file's rules itself. It asks `caribou project <file> --json` for the resolved project (name, entry, languages and the exact Haxe arguments), uses those arguments for completion and diagnostics, and shows anything Caribou says is wrong with the file in **Problems** as workspace problems. A workspace `.cbproj` with `members` opens but has nothing to run; open a member to run it.

**Run** and **Build** run `caribou run <name>.cbproj` and `caribou build <name>.cbproj` in the project folder, with the output streamed to the console and Caribou's findings written to `.rayde/run/diagnostics.jsonl`. Compile errors, failed reloads and runtime errors with a file and range land in **Problems** at their line; the others are workspace problems. Stop ends the process. Caribou builds into the project's own `target/`.

RayDE finds `caribou` from `CARIBOU`, beside RayDE, on `PATH`, or in a sibling `../caribou/target/{release,debug}`. Lua, Python and Wren files open with syntax highlighting.

