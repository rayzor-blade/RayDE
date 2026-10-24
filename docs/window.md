# Windows and sessions

**File > New Window** (Cmd+Shift+N, Ctrl+Shift+N elsewhere) opens Welcome in another window. Each project has its own tabs, language services, extensions and appearance. The **Window** menu lists open windows and offers minimize, maximize and full-screen actions.

Closing a window with edited files offers **Save and Close**, **Don't Save** and **Cancel**. Closing one window leaves the others running.

## Restoring a session

Launching without arguments reopens the previous session's windows, workspaces and tabs. A supplied workspace path takes precedence. Before a session has been saved, RayDE resumes the most recent workspace; a first launch opens Welcome with Explorer collapsed.

Each project remembers its tab order and active tab, including Settings and available extension view tabs. Unsaved text and undo history recover through local history. Closing all tabs keeps that project empty next time.

Quitting preserves all open windows. Closing one removes it from the next session; closing the last window preserves its workspace for the next launch.

## Menus and title bar

On macOS, menus appear in the system menu bar and follow the focused window. Windows and Linux show the same menus below the title bar.

Drag the title bar to move the window, double-click to maximize, and drag edges or corners to resize. RayDE's close, minimize and maximize controls follow the platform's style: macOS on the left; Windows, GNOME and KDE on the right.

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
