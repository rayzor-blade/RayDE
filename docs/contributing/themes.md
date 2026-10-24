# Theme implementation

Theme authoring is documented in [Theme bundles](../themes.md).

| Class | Role |
| --- | --- |
| `rayde.theme.ThemeFile` | Reads and checks a bundle, from a file or from text. Problems carry the path of the entry. |
| `rayde.theme.ThemeBuilder` | Builds the `ThemeBundle` ashui installs: the base theme's tokens with the file's over them, per scheme. |
| `rayde.theme.ThemeCss` | Places a stylesheet under the theme. |
| `rayde.theme.Themes` | Finds, installs and removes bundles. |
| `rayde.theme.FontName` | Reads family names from TrueType and OpenType files. |
| `rayde.theme.JsonLocator`, `ThemeEdit` | Find an entry by path in JSON text; edit it in place. |
| `rayde.theme.ThemeStudio` | Reads the editor text, puts the theme on the window, keeps the problems. |
| `rayde.ui.Theming` | Installs a bundle, loads and removes its sheets, registers its fonts. |
| `rayde.ui.ThemeStudioView`, `ThemePalette`, `ThemeTypography`, `ThemeGallery` | The Studio page. |

The window carries `data-theme="<id>"` and a theme's selectors begin `#rayde[data-theme="<id>"]`. `scripts/check.sh` covers the file, colours, scoping, installing, fonts and text edits. `SNAPSHOT_ONLY=themes scripts/snapshot.sh` and `SNAPSHOT_ONLY=themestudio scripts/snapshot.sh` drive the Settings page and the Studio and produce the theme guide illustrations.
