# Workspace sessions

A browser workspace lets you edit files and run tools on a remote machine. Your browser provides the editor; the session host holds the files and runs builds, terminals, language servers and extensions.

## Opening a workspace

On `rayde.org`, the example opens with `Main.hx` ready to edit. Repository workspaces use `app.rayde.org/{session_id}` and require sign-in. An empty app entry opens Welcome.

In the browser, **Open Project** and **Open Folder** open the GitHub repository chooser. Sign in, choose a repository and wait for the workspace to start. Reloading its URL reconnects to that workspace. Keyboard shortcuts follow your browser's operating system.

## Editing and saving

Text edits continue while disconnected and are kept in browser storage for reconnect and reload. Other connected editors receive your changes; Undo affects your own edits.

Hosted sessions record acknowledged edits in durable recovery. **Save** waits for pending edits to reach the host before writing the file. A failed save leaves the tab marked as changed and reports the error. Build and workspace switching wait for successful saves.

The host also writes shared edits as they settle. Hosted sessions store a document recovery checkpoint before confirming Save. This checkpoint covers the saved document, rather than a backup of the whole workspace.

## Tools and extensions

Build, Run, terminals and language servers use the session host's tools and environment. Extensions run there too, with their views displayed in the browser. The host must allow execution for these features.

Hiding Terminal leaves commands running. Losing the session connection closes its terminals; start a new terminal after reconnecting. See [Problems, Output and Terminal](panels.md) for panel controls.

## Reconnecting and recovery

Reconnecting to the same workspace restores document synchronization. Active extensions and language servers restart as needed; a language server you explicitly stopped stays stopped.

If the workspace or signed-in account changes, RayDE pauses the old editor bindings and shows a warning. Choose **Reopen Workspace** to preserve local recovery data and reload the current workspace. If storage fails, the page stays open and reports the problem. Previous recovery data is kept separately from the new workspace.

Avoid clearing browser storage when recovering unsaved edits: it contains local drafts, personal history and tab layout.

## File limits

Shared text files must be UTF-8 and no larger than 8 MiB. If the session reaches its open-document limit, close unused tabs and retry.

Close shared documents before moving or deleting their file or containing folder. These operations are refused while shared documents remain open.

For self-hosting, environment settings, protocol details and tests, see the [session contributor reference](contributing/session.md). Account-gateway setup is in [the Cloudflare reference](../web/cloud/README.md).
