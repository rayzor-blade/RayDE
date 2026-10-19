# Building and running

```sh
scripts/rayde.sh path/to/build.hxml      # open a Haxe project; Run builds it and runs it on ash
scripts/rayde.sh path/to/name.rayext     # open an extension project
scripts/rayde.sh path/to/name.raytheme   # open a theme project
scripts/rayde.sh --build                 # rebuild bin/rayde.hl without opening a window
```

## Dependencies

- `haxe` and `ash` on `PATH` (`ASH=<path>` names another ash).
- ashui is pinned to a commit (`ashui_rev` in `scripts/deps.sh`), checked out under `.deps` and built once. `ASHUI=<dir>` builds against another checkout.
- hlwgpu and hlwindow are read from beside RayDE (`HLWGPU`, `HLWINDOW`).
- Packaging and `scripts/check-git.sh` build pinned libgit2 with CMake and a C compiler. The source archive is fetched with curl and verified with shasum; Git checks use Python 3.
- Source `scripts/deps.sh` from bash only.

## Environment

| Variable | Effect |
| --- | --- |
| `RAYDE_PANEL=<tab>` | Open the bottom panel on `terminal`, `problems` or `console`. |
| `RAYDE_SETTINGS=<section>` | Open Settings on `build`, `libraries`, `terminal`, `appearance`, `keys` or `extensions`. |
| `RAYDE_EXTENSIONS=<folder>` | Built-in extensions folder instead of the packaged or source folder. |
| `RAYDE_THEMES=<folder>` | User theme folder instead of `~/.rayde/themes`. |
| `RAYDE_OPAQUE=1` | Opaque window instead of a transparent one. |
| `RAYDE_ASH=<path>` | ash for the packaged launchers. |

One editor window at a time while testing: check `pgrep -fl rayde.hl` before launching another.
