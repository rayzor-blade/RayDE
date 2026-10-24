# Build and Run

**Build** compiles the project. **Run** builds and launches it.

| Action | Toolbar | Shortcut | Menu / command center |
| --- | --- | --- | --- |
| Build | Hammer | Cmd+Shift+B | Build Project |
| Run | Play | F5 | Run |
| Stop | Stop | Shift+F5 | Stop |

Build and Run save edited files first. Compiler messages appear in [Output and Problems](panels.md). **Open Build Settings** edits the configuration without starting a build.

## Haxe projects

Build invokes the selected HXML with the configured Haxe compiler. Explicit targets, output paths and multiple compilations are preserved. A single-compilation HXML with no target produces HashLink bytecode; an explicit `--no-output` remains a check without output.

Open the build file from Explorer to edit it under **Settings > Build**. Library manifests supply source paths, dependencies and `extraParams.hxml`; `haxelib.json` opens as code.

## Runners

**Settings > Run** selects Automatic, Ash or HashLink for the workspace. Ash and Ashui starters choose Ash. HashLink starters use Ash on Apple Silicon and `hl` elsewhere. Changes apply to the next run and are stored as `run.runner` in `.rayde/settings.json`.

A folder workspace without a Haxe project descriptor has no Haxe build or runner. Follow its project's own tooling instructions.

## Rayzor projects

Rayzor projects use `rayzor build` and `rayzor run` from their manifest folder. Run requires a source `project.entry`; libraries without an application entry point have no Run action. `project.hxml` delegates the build to HXML and supplies RayDE's Haxe editor fallback.

Open `rayzor.toml` from Explorer for **Settings > Build**. The form covers project metadata, entry point, HXML delegation, targets, class paths, defines, cache, native libraries, resources and bundle options. Workspace manifests show member directories and their shared cache directory.

Text fields save on Enter; other controls save immediately. Comments and fields outside the form are preserved. **Edit as Text** exposes dependencies, WebAssembly hosts and custom tier configuration. Save source edits before using the form; **Reload** picks up external changes.

Workspace manifests take precedence over project sections and require a `members` array. Class paths are searched in declaration order. Rayzor parses stored target, optimization, preset, cache and bundle fields, but its current CLI uses command flags and `[tier]` settings rather than applying those fields automatically.
