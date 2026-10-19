# Theme bundles

RayDE ships three themes, Restrained, Hybrid and Expressive, each with a light and a dark scheme. A theme bundle is a JSON file that says how another theme differs: a few colours, a corner radius, a font, a stylesheet. Install one and it is in the list under the built-in themes in **Settings > Color scheme**. This chapter writes a bundle, installs it and switches to it; the two samples it uses are in [`themes/`](../themes).

![Midnight, a bundle that extends Restrained with a violet accent, in the editor](images/theme-midnight.png)

## A bundle

A bundle is a `.raytheme` file. The smallest changes one colour:

```json
{
  "name": "Rust",
  "colors": {"primary": "#b4532a"}
}
```

Everything it does not name comes from the theme it extends, Restrained unless `extends` says `hybrid` or `expressive`. A bundle with more to say looks like Midnight (abridged):

```json
{
  "id": "midnight",
  "name": "Midnight",
  "version": "1.0.0",
  "author": "RayDE",
  "description": "Deep indigo surfaces and a violet accent",
  "extends": "restrained",
  "shape": {"smoothing": 0.8, "threshold": 10},
  "radii": {"xl": 16},
  "light": {"colors": {"background": "#f3f1ff", "primary": "#6a4cf0"}},
  "dark":  {"colors": {"background": "#0b0a1a", "primary": "#8b6cff"}},
  "css": [{"file": "midnight.css"}]
}
```

- **Identity.** `id` names the theme in the settings file and defaults to the file's name; it uses letters, digits, dots, dashes and underscores, and is not one of the built-in names. `name`, `version`, `author` and `description` are what the Settings page shows.
- **Schemes.** What is outside `light` and `dark` is for both schemes; what is inside one is for that scheme only, and wins. A theme can leave a scheme alone and change the other.
- **Colours.** A colour is `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb(r, g, b)`, `rgba(r, g, b, a)` or `transparent`. A token is named as ashui names it (`surfaceElevated`) or with dashes (`surface-elevated`): `primary`, `secondary`, `success`, `warning`, `error`, `info` (each with a `Bg`, and the first two with `Hover` and `Active`), `background`, `surface`, `surfaceElevated`, `surfaceOverlay`, `textPrimary`, `textSecondary`, `textTertiary`, `textInverse`, `textLink`, `border`, `borderSecondary`, `borderHover`, `borderFocus`, `borderError`, `inputBg` (and `Hover`, `Focus`, `Disabled`), `selection`, `selectionText`, `accent`, `accentSubtle`, `tooltipBg` and `tooltipText`.
- **What follows from a colour.** Set `primary` and the hover and active shades, the focus border and the selection follow it; set `accent` and `accentSubtle` follows it; `secondary` gives its shades. Naming a token stops it following.
- **Shape and type.** `radii` takes `none`, `sm`, `default`, `md`, `lg`, `xl`, `2xl`, `3xl` and `full`, in pixels. `shape` sets how corners become squircles: `smoothing` (0 to 1), `exponent` and `threshold`, the radius from which a corner is smoothed. `typography` names `sans`, `serif` and `mono` families and gives `sizes` for `xs` to `5xl`. `spacing.base` is the unit the spacing ladder is a multiple of.
- **Stylesheets.** `css` is a text, a list, or `{"file": "x.css"}` for a file beside the bundle. Its rules apply only while the theme is in use: each selector is placed under the theme, so you write `.rayde-card { ... }`. `:root` is the theme itself, which is where custom properties go (`--ui-menu-bg`, `--ui-code-error`...). Rules inside `@media` are scoped too; `@keyframes` and `@font-face` are kept as written.

A mistake is said in a sentence, with where: an unknown token, a colour that is not one, a base that does not exist, a stylesheet that is not there, a field that means nothing. A bundle with a mistake is not installed.

## Installing and choosing

Open **Color scheme**. Under the three built-in themes, **Custom themes** has a field for a path: give it a `.raytheme` file, or a folder with one in it, and choose **Install**. A file is copied with the stylesheets it names; a folder is copied whole.

![The Custom themes card with Midnight chosen: its picture, its details, and the install field](images/theme-card.png)

The list above the field has **Built-in themes** first and then each installed theme; choosing one puts it on the window at once and keeps the choice in `.rayde/settings.json` (`appearance.theme`). It combines with the scheme above it, so a bundle's light and dark halves are each there when the scheme is. **Remove** takes the theme in use away, its files with it, and goes back to Restrained.

![Paper in the light scheme, with a dashed outline on the search pill from its stylesheet](images/theme-paper.png)

A bundle is installed in the user's `~/.rayde/themes`, which every project sees, or can be put by hand in `.rayde/themes` in a project. `RAYDE_THEMES=<folder>` names another folder for the user's. Each theme is a loose `.raytheme` file or a folder with one; the window finds them when it starts and when the Color scheme page is opened.

## How it is done

`rayde.theme.ThemeFile` reads and checks a bundle, `ThemeCss` places a stylesheet under the theme, and `ThemeBuilder` makes the `ThemeBundle` ashui installs: the base theme's tokens with the file's over them, in each scheme. The window carries `data-theme="<id>"`, and the stylesheet's selectors begin `#rayde[data-theme="<id>"]`, so a theme's rules stop applying when another is chosen. The checks (`scripts/check.sh`) cover the file, the colours, the scoping and installing; `SNAPSHOT_ONLY=themes scripts/snapshot.sh` installs both samples through the page, chooses each, changes scheme, and removes one, in both schemes.

## Limits

- Shadows and animation timings are not in the file: a bundle has the base theme's.
- The style system takes a stylesheet and does not give it back, so editing a theme's CSS and choosing it again in the same run adds rules to the old ones; restart RayDE to drop the old.
- A theme carries no images or fonts of its own, and a font family named in `typography` must be on the machine.
- Themes are chosen per project: the choice is in the workspace's settings file, while the bundle is installed once for the user.
