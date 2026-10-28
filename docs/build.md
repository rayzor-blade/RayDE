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

**Settings > Build > Run Configuration** selects the target, framework, runner and arguments. Framework presets fill the form with editable defaults. Each Haxe backend keeps its own configuration; JavaScript can use Node or a browser, Python uses Python, and native backends can launch their generated executable. Override the executable or program path for your toolchain.

For HashLink, Automatic uses Ash on Apple Silicon and `hl` elsewhere. Ash and Ashui starters select Ash. **Native AOT** compiles bytecode with Ash and runs the resulting executable; **Build / AOT arguments** accepts target triples and compiler options.

**Browser Preview** uses the same planner and target settings, with browser build flags and an HTML entry. After the first frame, the preview tab uses the app's window title and follows later title changes. An unchanged preview reuses successful compiler output and the finished bundle. Framework web builds can specify their output directory. Browser previews require an execution-enabled workspace session and the relevant compiler tooling.

Text fields save on Enter. Settings live in `.rayde/settings.json`; starter templates can configure them automatically. Folder workspaces can use a custom framework build command.

## Rayzor projects

Rayzor projects use their own compiler from the manifest folder. Run Configuration accepts native LLVM target triples for AOT and Rayzor's WASM selectors for browser builds; it does not translate them into Haxe backends. The default native profile uses `rayzor build` and `rayzor run`. Run requires a source `project.entry`; libraries without an application entry point have no Run action. `project.hxml` delegates the build to HXML and supplies RayDE's Haxe editor fallback.

Open `rayzor.toml` from Explorer for **Settings > Build**. The form covers project metadata, entry point, HXML delegation, targets, class paths, defines, cache, native libraries, resources and bundle options. Workspace manifests show member directories and their shared cache directory.

Text fields save on Enter; other controls save immediately. Comments and fields outside the form are preserved. **Edit as Text** exposes dependencies, WebAssembly hosts and custom tier configuration. Save source edits before using the form; **Reload** picks up external changes.

Workspace manifests take precedence over project sections and require a `members` array. Class paths are searched in declaration order. Rayzor parses stored target, optimization, preset, cache and bundle fields, but its current CLI uses command flags and `[tier]` settings rather than applying those fields automatically.
