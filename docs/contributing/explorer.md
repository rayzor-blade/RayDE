# Explorer implementation

User controls are in [Explorer](../explorer.md); project opening and starters are in [Projects](../projects.md).

## Tree and file catalog

The tree mounts only the rows in view, with a few above and below, from a flat list of what is shown; scrolling, opening and closing folders change that list and leave the cost of the screen as it was. A closed folder holds nothing, and its entries are read again when it opens. A file that comes forward is scrolled into view when its folders are open, and the arrow keys, Home, End, Page Up and Page Down move through the rows with Right and Left opening and closing folders and stepping in and out, as in any tree.

The Explorer lists every file type, including dotfiles, with folders first and Haxe files before other files. Configuration files and other languages open in the editor; supported images open in the previewer. Explorer and tab icons use Remix and a bundled MIT-licensed Devicon language subset; unknown types use the file-code icon.

Quick Open builds a path snapshot on a worker, scanning declared source folders before the workspace root. It excludes Git-ignored entries, internal cache folders and directory links outside the workspace. Traversal stops at 50,000 entries or 128 directory levels; a truncated catalog reports its limit in the palette footer. Only changed snapshots update the view, and superseded scans are cancelled. Remote mounts stop repository discovery at their filesystem boundary.

## Git ignore rules

Files and folders that git ignores are muted in the tree, as is everything inside an ignored folder. The rules come from the repository's `.git/info/exclude` and the `.gitignore` of each folder above the entry, the last matching pattern deciding, with `!` negation, anchored and directory-only patterns, `*`, `?`, `[...]` and `**`; a file inside an ignored folder cannot be re-included. The `.git` folder is always muted. Whether a file is tracked, and global excludes, are not considered. Outside a repository nothing is muted. An edited `.gitignore` applies to rows built after the edit.

## Outline

Outline uses the active language server's `textDocument/documentSymbol` request. Without a matching server, Haxe files fall back to the compiler module-symbols request on a worker. The active unsaved buffer is supplied to either route; superseded requests are cancelled. Source: [ExplorerOutline](../../src/rayde/ui/ExplorerOutline.hx).

## Local history

Timeline contains local history independently of source control. Selecting a local revision opens a read-only tab. Its Restore icon replaces the source's unsaved buffer as an undoable edit; saving remains a separate action. Local checkpoints preserve text patches and the bounded editor undo/redo stacks without retaining editor instances or render resources. They include edits that were never staged and intermediate states later abandoned after Undo.

Checkpoints are written atomically under `.rayde/history` after at most 350 ms of continuous editing, and flushed on close and workbench shutdown. Reopening a file restores unsaved work when its on-disk text still matches the last saved baseline. An external disk change is left in place; earlier local revisions remain available in Timeline. Explorer renames carry the history to the new path. Each file retains up to 200 changes plus its oldest retained baseline, within an 8 MiB checkpoint limit. Older patches are compacted into that baseline. Files beyond the size limit cannot be checkpointed and report the failure in the status bar. History is local to this workspace and should not be committed.

## Git history and dependencies

With the Git extension enabled and its native library approved, Timeline also shows commits for the active file on the current branch, follows renames along first-parent history, and reveals changed files when a commit is selected. It searches in bounded pages; **Load more history** continues from the cursor. Collapsing Timeline or switching sidebars closes the cursor and clears its rendered history. Local recovery remains available without Git.

Dependencies lists external class paths and the libraries declared by the current build, with selected versions or `dev` labels. External class paths appear here instead of under the workspace tree. Expand a folder or library to browse its sources, documentation and configuration files with the same icons as Explorer. Folder rows load on first expansion; selecting a file opens it in an editor tab, where Markdown's Open Preview action is also available. The header icons refresh the list or open Libraries settings. Resolution runs in background jobs from the workspace directory, including its local haxelib repository.


The Explorer snapshot and memory checks are described in [Checks and snapshots](checks.md).
