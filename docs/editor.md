# Editor

Open a file from [Explorer](explorer.md), or press **Cmd+P** to find it by name. On Windows and Linux, use **Ctrl** instead of Cmd unless a shortcut says otherwise.

## Everyday keys

| Key | Action |
| --- | --- |
| Cmd+P | Find a file. |
| Cmd+Shift+P | Find a command. |
| Ctrl+G | Go to a line. |
| Cmd+S | Save edited files. |
| Cmd+W | Close the current tab. |
| Cmd+F | Find in this file. |
| Cmd+Option+F (Ctrl+H elsewhere) | Find and replace. |
| F12 or Cmd-click (Ctrl-click elsewhere) | Go to a symbol's definition. |

See [all shortcuts and customization](keys.md) for completion, code actions, building and debugging keys.

## While editing

Hover a symbol for its type and documentation, or an underlined range for its diagnostic. Use completion and signature hints as you type; [language assistance](languages.md) covers their controls.

Use the minimap to navigate and fold controls to hide code regions. **Show Code Actions** (Cmd+.) offers actions for the current selection. Gutter icons run actions on their line; the configured main class has a **Run Project** action.

Right-click code, or press the context-menu key, for navigation, **Code Actions…**, clipboard commands, Find and Replace. **Shift+F10** also opens it unless your keymap assigns that key to another command. A right-click inside a selection keeps it. Language actions such as references, rename and formatting are enabled when the server supports them; edits remain unsaved and can be undone. The default keymap uses **Shift+F12** for references, **F2** for symbol rename and **Shift+Alt+F** for formatting.

Tabs retain their selection, scroll position, folds and undo history when you switch away. Reopening RayDE restores your previous [windows and tabs](window.md#restoring-a-session).

Right-click a tab for close, split and move actions, **Save**, or path commands. The menu targets that tab, including inactive tabs. Close Others, Left, Right, Saved and All affect only its split group; Save writes only that file.

Drag a tab along its strip to reorder it, or onto another split pane to move it. A thumbnail of its page follows the pointer. The insertion marker shows its position; dropping on a pane's content appends it. Crowded strips scroll when you hold the dragged tab near an edge. Press Escape or drop outside the editor to cancel. Tab order is restored with your workspace.

## Split view

Use the split buttons beside the tab menu to place editors **right** (vertical split) or **below** (horizontal split). Drag the divider to resize; splits can be nested. Each group has its own tabs, and editor commands follow the group you click.

Splitting moves the current tab when other tabs remain in its group; with one tab, it opens an empty group for another file. The tab menu also offers **Move Editor to Next Group**, **Close Editor Group** (keeps its tabs in a neighbor) and **Join All Editor Groups**. Opening an already open file focuses its group.

**Cmd+\\** splits right; **Cmd+Option+\\** splits down. **Cmd+Option+Right/Left** focuses the next/previous group. On Windows and Linux use Ctrl and Alt. These commands also appear in **View**, the command center and shortcut settings.

## Find and replace

Press Enter / Shift+Enter in Find to move to the next / previous match. Enter in Replace replaces one match; Cmd+Enter or Ctrl+Enter replaces all in one undo operation. Escape closes the panel.

Enable `.*` for regex and type a bare pattern such as `item(\d+)`. A `~/…/` wrapper is optional; Haxe literals such as `~/item(\d+)/i` can supply flags. In replacements, `$1` inserts a capture and `$$` a dollar sign. `Aa` toggles case sensitivity; underlined `Ab` toggles whole words. Invalid patterns show an error.

For other tasks, see [building and running](build.md), [panels](panels.md), [image previews](images.md), [Markdown](markdown.md), [Jam](jam.md) or [Settings](settings.md).
