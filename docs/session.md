# Workspace sessions

A browser workspace lets you edit files and run tools on a remote machine. Your browser provides the editor; the session host holds the files and runs builds, terminals, language servers and extensions.

## Opening a workspace

On `rayde.org`, the example opens with `Main.hx` ready to edit. Repository workspaces use `app.rayde.org/{session_id}` and require sign-in. An empty app entry opens Welcome.

In the browser, **Open Project** and **Open Folder** open the GitHub repository chooser. Sign in, choose a repository and wait for the workspace to start. Reloading its URL reconnects to that workspace. Keyboard shortcuts follow your browser's operating system.

**New Project** starts with the template grid. Select a starter, continue to **Create a repository**, and choose its name and visibility. GitHub sign-in opens a separate window so your editor and selected starter stay open. Repositories are private by default; after creation, RayDE prepares their remote workspace.

Your GitHub account appears at the top right of the editor. Click the GitHub icon and username for **Manage access** and **Sign out**. Manage access opens GitHub in another tab. RayDE asks you to save edited files before signing out and returning to Welcome. When signed out, use **Sign in** in the same place.

## Editing and saving

Text edits continue while disconnected and are kept in browser storage for reconnect and reload. Other connected editors receive your changes; Undo affects your own edits.

Hosted sessions record acknowledged edits in durable recovery. **Save** waits for pending edits to reach the host before writing the file. A failed save leaves the tab marked as changed and reports the error. Build and workspace switching wait for successful saves.

Ordinary session documents write through as edits settle. Cloud-bound documents keep edits in recovery until you choose **Save**, which writes the file on the host. Hosted sessions store a document recovery checkpoint before confirming Save. This checkpoint covers the saved document, rather than a backup of the whole workspace.

## Tools and extensions

Open **Cloud Sync** in the activity bar to see the provisioned workspace's CPU, memory, disk usage and VM uptime, alongside its resource and lifetime limits. Measurements refresh while the panel is open. An unavailable metric is labelled explicitly; the landing-page example has no personal resource allocation.

Build, Run, terminals and language servers use the session host's tools and environment. Extensions run there too, with their views displayed in the browser. The host must allow execution for these features.

For a browser-compatible Ashui project, choose **Preview App** from **Code Actions** or the eye button beside the tabs. RayDE saves your edits, builds the app and opens it in a preview tab. **Rebuild** applies later source changes. This requires [app preview tooling on the host](contributing/session.md#app-previews).

Unchanged previews reuse their compiled output. The status bar shows compiler activity and opens live Build output when clicked. Use **Rebuild App Preview from Scratch** in the command center to bypass the cache.

Hiding Terminal leaves commands running. Losing the session connection closes its terminals; start a new terminal after reconnecting. See [Problems, Output and Terminal](panels.md) for panel controls.

## Reconnecting and recovery

Reconnecting to the same workspace restores document synchronization. Active extensions and language servers restart as needed; a language server you explicitly stopped stays stopped. A loaded app preview stays visible during an interruption and recovers automatically after reconnecting. Recovery can reload the app.

Cloud Sync preserves saved edits and its merge base across session recovery. If publish access expires, choose **Reopen workspace** in Cloud Sync. Recovery errors pause saving to the cloud and keep your local files.

Supported open text files receive shared edits automatically. Incoming edits stay unsaved until you choose Save; a disconnected session keeps local edits for recovery.

If the workspace or signed-in account changes, RayDE pauses the old editor bindings and shows a warning. Choose **Reopen Workspace** to preserve local recovery data and reload the current workspace. If storage fails, the page stays open and reports the problem. Previous recovery data is kept separately from the new workspace.

Avoid clearing browser storage when recovering unsaved edits: it contains local drafts, personal history and tab layout.

## File limits

Shared text files must be UTF-8 and no larger than 8 MiB. If the session reaches its open-document limit, close unused tabs and retry.

Close shared documents before moving or deleting their file or containing folder. These operations are refused while shared documents remain open.

Save or reconcile recovered drafts before moving, deleting or replacing their files, even after closing their tabs. If RayDE asks you to reopen an older recovered draft, reopen it before retrying.

For self-hosting, environment settings, protocol details and tests, see the [session contributor reference](contributing/session.md). Account-gateway setup is in [the Cloudflare reference](../web/cloud/README.md).
