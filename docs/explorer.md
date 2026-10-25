# Explorer

Explorer lists every file type, including dotfiles, with folders first and Haxe files ahead of other files. Select a file to open it. Git-ignored entries are muted. Use the arrow keys to navigate; Right and Left expand or collapse folders.

Drag a file or folder onto a folder to move it. Hold over a closed folder to expand it; press Escape to cancel. Open tabs follow the move and keep unsaved edits.

Drag the horizontal dividers to resize the file tree, Outline, Timeline and Dependencies. The three lower panes can collapse; reopening a pane restores its height.

## Outline

Outline shows symbols in the active file, including unsaved changes. Select a type, method or field to jump to its declaration. Available symbols depend on the file's language support.

## Timeline

Timeline keeps local revisions, including changes never staged in Git. Select a revision to preview it; **Restore** replaces the editor buffer as an undoable change. Save separately to write it to disk.

Unsaved work can recover when you reopen the workspace. If the file changed externally, RayDE keeps that disk version and leaves earlier revisions available in Timeline. Local history belongs to this workspace.

With the [Git extension](git.md), Timeline also shows commits for the active file. **Load more history** fetches older entries.

## Dependencies

Dependencies contains external class paths and Haxelib libraries. Expand one to browse its sources, documentation and configuration. Selecting a file opens a tab; Markdown files also offer **Open Preview**.

The header buttons refresh dependencies or open Libraries settings. To open or create a workspace, see [Projects](projects.md).
