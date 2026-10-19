# Window

RayDE opens without the system frame and draws its own title bar.

- The title bar moves the window; a double click maximizes it.
- The edges and corners resize it.
- Close, minimize and maximize are RayDE's controls, in the style of the platform: macOS controls on the left; Windows, GNOME and KDE controls on the right.

## Window controls

**Settings > Color scheme > Window controls** selects the style. It is stored as `appearance.windowControls` in `.rayde/settings.json`.

| Value | Style |
| --- | --- |
| `auto` | The platform's. |
| `macos` | Circles on the left. |
| `windows` | Square caption buttons. |
| `gnome` | Circular buttons. |
| `kde` | Flat buttons; close is tinted red when hovered. |

## Corners

The window is transparent so it can have rounded corners. The macOS, GNOME and KDE styles are rounded; the Windows style is square. `RAYDE_OPAQUE=1` fills the window instead, for a display where a transparent window misbehaves.

`rayde.ui.WindowChrome` is what the controls ask of the window. Without a window, as in the snapshots, it records the requests.
