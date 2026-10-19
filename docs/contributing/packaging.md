# Packaging

The icon is `assets/rayde-icon.png`, a rounded square on a transparent margin. `scripts/icons.sh` derives each platform's icon from it into `assets/icons`, which is committed. Only a change to the icon needs ImageMagick (`magick`), and on macOS `iconutil`.

| Platform | Icon | Packaged with |
| --- | --- | --- |
| macOS | `rayde.icns`, on the Big Sur grid with its shadow | `scripts/package-macos.sh [folder]` builds `RayDE.app`. |
| Linux | `hicolor/<n>x<n>/apps/rayde.png`, 16 to 1024 px | `scripts/package-linux.sh [prefix]` installs the launcher, desktop entry, MIME types and icons. |
| Windows | `rayde.ico`, 16 to 256 px | `packaging/windows/RayDE.cmd` and `install-shortcut.ps1`. |
| Window | `rayde-256.rgba`, embedded and passed as `WindowConfig.icon` | Every run. Windows and Linux windows use it; macOS uses the bundle's. |

- The launchers run the program with ash, which is not bundled. `RAYDE_ASH` names it; otherwise the usual places are searched.
- Without an argument a launcher opens a file dialog for a `.hxml`, `.rayext` or `.raytheme`.
- File types registered: Linux `text/x-hxml`, `application/x-rayext`, `application/x-raytheme`.
- The Windows scripts have not been run on Windows.
