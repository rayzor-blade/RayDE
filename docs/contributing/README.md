# Contributing

| Document | Contents |
| --- | --- |
| [Building and running](building.md) | Scripts, dependencies, environment variables. |
| [Checks and snapshots](checks.md) | `check.sh`, `snapshot.sh`, benchmarks. |
| [Packaging](packaging.md) | App icon and per-platform launchers. |

## Layout

| Path | Contents |
| --- | --- |
| `src/rayde/ui` | Workbench and its parts, written with ashui's HXX markup; `rayde.css` is the stylesheet. |
| `src/rayde/ext` | Extensions: manifest, host process, Studio, debugger, hooks. |
| `src/rayde/theme` | Theme bundles: file model, builder, CSS scoping, install, Studio model. |
| `src/rayde/lang` | The Haxe compiler server and the display requests. |
| `src/rayde/run`, `build`, `term`, `keys`, `settings`, `files` | Runner, build file model, terminal, key bindings, settings, file operations. |
| `tests` | `Checks.hx`, `Snapshots.hx`, benchmarks and fixture projects. |
| `themes` | Example theme bundles. |
| `docs` | User chapters. |

## Issues

Work is tracked with git-bug: `git-bug bug` lists it, `git-bug bug show <id>` reads one. A commit cites its issue with a `git-bug: <64-character id>` trailer.
