<p align="center"><img style="display: block;" src="assets/logo.svg" alt="RayDE" width="250"/></p>

<h2 align="center">Integrated Development Environment For The Haxe Programming Language</h2>
<p align="center">
  Built with Ashui and the Ash runtime.
</p>

<p align="center"><img  src="assets/rayde-welcome.png" width="800" alt="RayDE on a dark scheme, with the welcome page and the build file open in the Explorer" /></p>

RayDE is an IDE for Haxe projects. It is written in Haxe on [ashui](https://github.com/rayzor-blade/ashui) and runs on the ash runtime. [Rayzor](docs/languages.md) is its default Haxe language server, with the Haxe compiler's display service as a fallback.

## Features

- **Haxe projects.** Opens a `build.hxml`; the build file is edited as a form. Explorer, tabs, code editor with a minimap, hover types and documentation, go to definition, compiler problems underlined and listed. Run builds the project and runs it on ash.
- **Command center.** Files, commands and line numbers from one prompt. Key bindings follow VS Code and are editable.
- **Syntax and Markdown.** A shared Linguist-derived TextMate bundle highlights code files and fenced blocks. Markdown previews render LaTeX math and Mermaid diagrams with pan and zoom in editor tabs.
- **Terminal.** Integrated terminal panel with configurable profiles.
- **Libraries.** haxelib libraries are listed and managed from Settings.
- **Extensions.** Written in RayScript and described by a `.rayext` file: commands, menus, hooks, views in any part of the layout. Built-in, user and workspace extensions activate on events and run in embedded RayScript VMs. The Extension Studio reloads an extension as it is edited and has a console, an activity log, an element tree and a debugger.
- **Themes.** A `.raytheme` bundle sets colours, radii, type, custom fonts and CSS over a built-in theme. The Theme Studio edits one with the window as the live preview.
- **Window.** RayDE draws its own title bar, resize edges and window controls in the style of the platform.

## Getting started

```sh
scripts/rayde.sh path/to/build.hxml     # a Haxe project
scripts/rayde.sh path/to/name.rayext    # an extension
scripts/rayde.sh path/to/name.raytheme  # a theme
```

Requirements: `haxe`, `ash` on `PATH` (or `ASH=<path>`), and a Rust toolchain for the first build of the native libraries.

## Documentation

| Chapter | Contents |
| --- | --- |
| [Editor and keys](docs/editor.md) | Command center, shortcuts, hover, debugging keys. |
| [Syntax highlighting](docs/syntax.md) | Shared TextMate grammars, file detection and extension API. |
| [Markdown preview](docs/markdown.md) | GFM, mathematical LaTeX, Mermaid, images and live preview. |
| [Window](docs/window.md) | Title bar, controls, rounded corners. |
| [Writing an extension](docs/extensions.md) | Config, commands, menus, hooks, tabs, Extension Studio, debugger. |
| [Git](docs/git.md) | Interactive commit history, pinned libgit2 build and RayScript bindings. |
| [Theme bundles](docs/themes.md) | File format, fonts, CSS, installing, Theme Studio. |
| [Contributing](docs/contributing/README.md) | Building, checks and snapshots, packaging, issue tracking. |
