# Packaging

The icon is `assets/rayde-icon.png`, a rounded square on a transparent margin. `scripts/icons.sh` derives each platform's icon from it into `assets/icons`, which is committed. Only a change to the icon needs ImageMagick (`magick`), and on macOS `iconutil`. Use `scripts/icons.sh --macos` to regenerate just the macOS asset.

| Platform | Icon | Packaged with |
| --- | --- | --- |
| macOS | `rayde.icns`, with the source margin removed | `scripts/package-macos.sh [folder]` builds `RayDE.app`. |
| Linux | `hicolor/<n>x<n>/apps/rayde.png`, 16 to 1024 px | `scripts/package-linux.sh [prefix]` installs the launcher, desktop entry, MIME types and icons. |
| Windows | `rayde.ico`, 16 to 256 px | `packaging/windows/RayDE.cmd` and `install-shortcut.ps1`. |
| Window | `rayde-256.rgba`, embedded and passed as `WindowConfig.icon` | Every run. Windows and Linux windows use it; macOS uses the bundle's. |

- The macOS app bundles the AOT executable, shared Ash runtime and native libraries under `Contents/MacOS`. Running it does not need an installed `ash`. Building the package requires Ash. The Linux and Windows launchers use an external `ash`; `RAYDE_ASH` names it.
- Without an argument the macOS app offers recent projects, **Open Existing Project** and **New Project**. Existing entry points include `.hxml`, `haxelib.json`, `rayzor.toml`, `.rayext` and `.raytheme`. New Project creates a Haxe application, Haxe library or Rayzor application in a fresh folder and opens it immediately. It remembers up to 20 entry points in the user settings under `recentProjects.paths`. Linux and Windows launchers open a file dialog.
- File types registered: Linux `text/x-hxml`, `application/x-rayext`, `application/x-raytheme`.
- The Windows scripts have not been run on Windows.

## Built-in extensions

Packaging copies `extensions/` with the program. macOS places it in `RayDE.app/Contents/Resources/extensions`; Linux in `<prefix>/share/rayde/extensions`. The Windows distribution places it beside `rayde.hl` and `RayDE.cmd`. `rayscript.hdll` embeds the extension runtimes, shared syntax data and Markdown renderers beside the executable (or `rayde.hl` for hybrid packages); their third-party notices are staged under `notices/syntax-markdown`. `RAYDE_EXTENSIONS` overrides the built-in extensions folder.
