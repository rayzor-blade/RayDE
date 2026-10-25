# Local Jam

The current editor preview shares one text document with up to eight participants. It runs locally; use an SSH tunnel for another machine. Accounts, hosted discovery, media and disk asset synchronization are not included in this preview.

## Start or join

1. Open a text file and run **Jam: Share Active Document…** from the command center.
2. Confirm your display name, then choose **Copy Invitation** in the Jam panel.
3. In another RayDE window, open the matching filename in a separate workspace copy and run **Jam: Join Shared Document…**. Save or discard existing edits before joining.
4. Paste the invitation. Joining updates the editor buffer; Save writes it to your local file.

Click the joystick in the status or activity bar to open the Jam panel. It shows participants, the shared document, connection status and recovery status. Closing the panel keeps the session running. **Leave** or **End** stops it; closing the host window ends the room.

## Edit and follow

Participants see each other's carets, selections and names. Undo and redo affect your own Jam edits. Closing the document's tab does not leave the session; leave before renaming or deleting the shared file.

Choose **Follow** beside a participant to follow their selection and viewport. Your own editing, navigation, tab switch or a disconnect stops following. **Stop Following** also stops it explicitly. Following does not take keyboard focus or publish the followed movements as your own.

To watch how the file changes, open [File History Diff](editor.md#file-history-diff), choose **Jam start**, and keep it in another split. It follows unsaved edits and shows participant names beside their changed lines.

## Recover a session

**Saved locally** means queued edits have reached the recovery files. **Save Recovery Checkpoint** compacts that recovery; it does not save the source file. A crash can lose edits still marked **saving locally**.

After restarting, open the same file. Choose **Jam: Resume Saved Document…** to host saved state with a new invitation, or **Jam: Rejoin Saved Document…** to merge offline edits into the original room. Save or discard buffer changes first. Sessions never reconnect automatically; undo history starts afresh after a process restart.

Starting or joining a fresh Jam replaces that file's previous Jam recovery. A different room is rejected when rejoining, preserving the saved data. To back it up, leave the session and copy the entire `.rayde/jam/<document-key>/` folder. Recovery is local and separate from saving your source file. Keep invitation tokens private.
