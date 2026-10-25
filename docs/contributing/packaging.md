# Packaging

The icon is `assets/rayde-icon.png`, a rounded square on a transparent margin. `scripts/icons.sh` derives each platform's icon from it into `assets/icons`, which is committed. Only a change to the icon needs ImageMagick (`magick`), and on macOS `iconutil`. Use `scripts/icons.sh --macos` to regenerate just the macOS asset.

| Platform | Icon | Packaged with |
| --- | --- | --- |
| macOS | `rayde.icns`, with the source margin removed | `scripts/package-macos.sh [folder]` builds `RayDE.app`. |
| Linux | `hicolor/<n>x<n>/apps/rayde.png`, 16 to 1024 px | `scripts/package-linux.sh [empty folder]` builds the portable tree with launcher, desktop entry, MIME types and icons. |
| Windows | `rayde.ico`, 16 to 256 px | `scripts/package-windows.sh [folder]` builds a portable folder with `RayDE.exe` and `install-shortcut.ps1`. |
| Window | `rayde-256.rgba`, embedded and passed as `WindowConfig.icon` | Every run. Windows and Linux windows use it; macOS uses the bundle's. |

- All three packages contain an AOT executable, its matching Ash runtime, native libraries, built-in extensions, Rayzor and its standard library. Running the editor requires neither Ash nor Haxe to be installed. Building Haxe projects still requires the Haxe compiler and their libraries; HashLink bytecode projects also need the selected Ash or HashLink runner. Rayzor projects use the bundled compiler.
- Build scripts use `ASH` when set, otherwise the sibling workspace's `ash/target/release/ash`, falling back to Ash on PATH. The AOT compiler stages its matching shared runtime. Rebuild the bundle to adopt runtime fixes; replacing source files alone does not update a bundled runtime. Memory probes record runtime hashes for comparisons.
- Without an argument every launcher opens Welcome with Explorer collapsed. Welcome offers **Open Folder**, **Open Project**, **New Project** and recent workspaces. Existing entry points include arbitrary folders, `.hxml`, `haxelib.json`, `rayzor.toml`, `.rayext` and `.raytheme`. New Project creates a Haxe application, Haxe library or Rayzor application in a fresh folder and opens it immediately. Up to 20 folder and project paths are remembered under `recentProjects.paths`. Native path dialogs run only after an explicit action; Linux uses zenity or kdialog and Windows uses the system folder/file dialogs.
- File types registered: Linux `text/x-hxml`, `application/x-rayext`, `application/x-raytheme`.

Linux and Windows packagers require a new or empty output folder; they do not modify a system installation prefix. The Linux archive has `bin`, `lib` and `share` directories. Run `bin/rayde` from the extracted tree. Installing its desktop/MIME entries and refreshing desktop caches is a separate installation step.

## Built-in extensions

Packaging copies `extensions/` with the program. macOS places it in `RayDE.app/Contents/Resources/extensions`; Linux in `<prefix>/share/rayde/extensions`; Windows beside `RayDE.exe`. `rayscript.hdll` embeds the extension runtimes, shared syntax data and Markdown renderers beside the executable; their third-party notices are staged under `notices/syntax-markdown`. `RAYDE_EXTENSIONS` overrides the built-in extensions folder.

## CI distributions

`.github/workflows/distribution.yml` builds on pull requests, pushes to `main`, `v*` tags and manual dispatch. The native matrix covers macOS Apple Silicon and Intel, Linux x86-64 (Ubuntu 24.04), and Windows x86-64. CI builds each platform on its own runner; these are separate architecture downloads. Linux needs a compatible glibc (2.39 or later) and the desktop's graphics/window-system libraries. Windows ARM64 and Linux ARM64 packages are not included yet.

`packaging/dependencies.json` pins the Ash, RayScript, Rayzor, GPU and window source revisions, Rust toolchain and Haxe libraries. Ashui keeps its existing pin in `scripts/deps.sh`. `scripts/ci-deps.py --fetch` creates sibling checkouts and installs the exact Haxe libraries. Use a dedicated workspace: it refuses existing dirty or mismatched dependencies. `--build` builds the runtime, native libraries and Rayzor with its standard-library snapshot. LLVM 21 is installed through the pinned Ash checkout's composite action. Cargo builds and the CSS compiler use their lockfiles. On Windows, the build creates the native import library from Ash's own DLL so the editor and extensions share one runtime.

The workflow's Haxe, Rust and Python versions and Ashui cache path must follow their pins; `python3 tests/distribution_checks.py` checks that relationship. Before changing any dependency pin, make sure that commit and its locked Git dependencies are available on their public remotes. A local-only commit cannot be fetched by a hosted runner.

`scripts/distribution.py` resolves native dependencies, relocates macOS libraries, sets Linux runtime search paths and bundles Windows DLL dependencies. System libraries and graphics drivers remain provided by the OS. Git's native-library hash is refreshed after library relocation and signing. Missing files, unresolved imports and stale native hashes fail the package. Package metadata records versions and source revisions under `distribution.json`; notices and the dependency lock accompany it.

`scripts/ci-package.sh` archives the package and tests the extracted copy from an unrelated directory containing spaces, with a fresh home and development paths removed. It runs the AOT executable's `--check-install`, calls libgit2 through the isolated extension host with a verified native grant, and completes a real Rayzor LSP initialize/shutdown exchange. This does not replace interactive GUI testing on each OS. Artifacts include the archive and its SHA-256 file. Native job failures prevent a release draft from being created.

For a manual build, supply a semantic version through the workflow input. For a release, push a `vX.Y.Z` tag; the tag supplies the version and CI creates a **draft** GitHub release with all four archives and `SHA256SUMS`. Publishing remains a manual release step. The current macOS bundle uses ad-hoc signing; Developer ID signing and notarization require release credentials before normal Gatekeeper distribution. Windows signing is also a separate release step.
