# Contributing

| Document | Contents |
| --- | --- |
| [Building and running](building.md) | Scripts, dependencies, environment variables. |
| [Checks and snapshots](checks.md) | `check.sh`, `snapshot.sh`, benchmarks. |
| [Packaging](packaging.md) | App icon and per-platform launchers. |

## Layout

| Path | Contents |
| --- | --- |
| `src/rayde/ui` | The workbench and the views it shows, written with ashui's HXX markup; `rayde.css` is the stylesheet. `Contributions` is the registry that commands, bar items, side views and editor hooks register in; `Features` lists the built-in features that install through a `Host`. |
| `src/rayde/ui/workbench` | The workbench's parts, one module each: terminal, explorer, panels, run and build, extensions, language servers, code actions, debugging, menus, projects, themes, key maps, the editor and its documents, and the shell (layout, bars, commands). `Workbench` owns the shared state and creates them; a part reaches the rest through `wb`. |
| `src/rayde/ext` | Extensions: manifest, host process, Studio, debugger, hooks. |
| `src/rayde/theme` | Theme bundles: file model, builder, CSS scoping, install, Studio model. |
| `src/rayde/lang` | The Haxe compiler server and the display requests. |
| `src/rayde/run`, `build`, `term`, `keys`, `settings`, `files` | Runner, build file model, terminal, key bindings, settings, file operations. |
| `tests` | `Checks.hx`, `Snapshots.hx`, benchmarks and fixture projects. |
| `themes` | Example theme bundles. |
| `docs` | User chapters. |

## Issues

Work is tracked with git-bug: `git-bug bug` lists it, `git-bug bug show <id>` reads one. A commit cites its issue with a `git-bug: <64-character id>` trailer.
