# Git

The built-in Git extension registers Ashui's git-branch icon in the activity bar. Selecting it opens **Source Control** in the sidebar, with the current branch, file counts and groups for merge conflicts, staged changes, workdir changes and untracked files. File rows show the filename first, followed by its parent directory in muted text.

![Source Control in the sidebar](images/git-scm.png)

The sidebar stacks **Changes**, **Graph** and **Commit files** in Ashui's native resizable panels, each with a collapsible header. Drag a divider or use its arrow keys to divide the height. The graph has dense commit rows, colored branch/merge lanes, reference badges, local hover and selection. Selecting a commit reveals its changed files, with filenames first, directory context, change badges and rename sources. Merge commits compare against their first parent; root commits show all added files. The sidebar loads the latest 60 commits; its maximize icon opens the paged graph in a separate tab, with changed files beside the selected commit's details.

The branch header has **Fetch**, **Pull** and **Push** icon actions with tooltips. Fetch updates remote references. Push publishes the current branch to its configured upstream, or to the default remote and same branch name when no upstream exists. It never forces a push. SSH uses the system OpenSSH client; private HTTPS credential helpers are not connected yet.

**Pull options** offers fast-forward only, merge and rebase for an individual pull. In Settings → Extensions → Git, **Pull strategy** sets the preferred default for the main Pull action. The initial default is fast-forward only. Pull requires a clean working tree and index; conflicting merges and rebases report the conflict without changing the branch, index or working files. Merge and rebase commits use the repository's configured Git identity.

Errors and completed remote operations appear as toasts and in the **Git** Output channel. **Show Output** on a toast opens the full message without occupying space in the SCM sidebar.

A changed file in **Changes**, **Staged** or **Untracked** opens its diff in a tab: staged against HEAD, changes against the index, an untracked file against nothing; conflicts open the file. Each row's code icon opens the file itself. A file of a commit, in **Commit files** and in the Explorer's **Timeline**, opens that commit's change against its first parent. The diff is Ashui's `CodeDiff`: side by side or inline (the tab's layout button), changed words marked, long unchanged runs folded, F7 and Shift+F7 between changes. The tab is read-only and reuses itself for the same comparison; a binary file shows a note instead. Blobs are read through libgit2, the index through its entry for the path, because revparse does not implement `:path`.

The sidebar's **Refresh** action and **Git: Refresh** command reload status and history; saving a file also refreshes them. While the sidebar is visible it checks for external repository changes every 2.5 seconds. Tab switches do not refresh SCM; unchanged status and references preserve their existing views, and history is walked again only when HEAD, references or the chosen focus changes. The **History** toolbar action and **Git: History** command also open the expanded graph. Both views discover the repository at or above the project root through libgit2.

![Git history and selected merge commit](images/git-history.png)

Both graphs use a virtual viewport at a fixed scale, scrolling with the wheel, trackpad or scrollbars. A viewport-sized canvas draws only visible rows and edges; Ashui Scroll owns the full list extent. Dragging does not pan the graph and the wheel does not zoom. **Load more** appends 100 commits at a time, preserving earlier lane positions. The reference picker includes local branches, remote references and tags, excluding internal git-bug metadata. Choose **Current branch**, a named reference or **Focus on selected commit** to show only that revision's history. **Show all references** restores the expanded graph's full history. **Refresh** reopens the history cursor and reloads the first page. Closing the tab releases native resources.

The extension owns the graph layout and scene in RayScript. RayDE's generic [Ashui bridge](extensions.md#ashui-controls-and-interactive-drawing) renders retained CanvasKit paths, circles and text, with native Button and Select components. Painting and viewport gestures stay in the editor. Repository scanning and history reads run on libgit2's worker lane.

Stage/unstage actions and editor decorations are subsequent work. File diff tabs are waiting for Ashui's CodeDiff component; selected commit file lists are read only meanwhile.

## Build and check

```sh
scripts/build-libgit2.sh           # stage the library and generate git.rayext with its hash
scripts/check-git.sh               # C layouts and real-host integration
scripts/check-git.sh --benchmark   # also measure warm status on 10k changed files
SNAPSHOT_ONLY=git scripts/snapshot.sh  # graph and interaction checks in both schemes
```

Requires CMake, a C compiler, curl, shasum, Python 3 and Git. The check uses `RAYSCRIPT_HOST`, or the release host in the sibling RayScript checkout. Git commands create the fixtures; the operations under test execute through RayScript and libgit2, in a real host process with a verified native grant.

The source is [libgit2 v1.9.7](https://github.com/libgit2/libgit2/releases/tag/v1.9.7), pinned by its archive SHA-256 in `scripts/build-libgit2.sh`. The build uses shared libraries, `USE_SSH=exec`, bundled zlib and bundled regex, without libgit2's CLI, examples or tests. Experimental SHA-256 object IDs are disabled because they change the native struct ABI. SSH uses the system OpenSSH client. HTTPS uses libgit2's platform default provider.

The archive, source and single CMake build directory live under `.deps/`. The library and upstream notices are staged under `extensions/git/natives/`, excluded from source control. `git.rayext.in` is the tracked manifest template; the build generates `git.rayext` with the staged library's exact SHA-256. `scripts/rayde.sh`, Git snapshots and macOS/Linux packaging build these assets before loading or copying the extension. Activation occurs for `.git` at the project root, when the sidebar opens, or through either Git command. Nested projects can activate through the sidebar or commands. The binding layouts and integration are checked on macOS arm64; other platforms need their own ABI validation.

## Module interface

The embedding manifest declares `native:git2` and a `git2` native with the staged library's path and SHA-256, as described in [Native libraries](extensions.md#native-libraries). Import the module from the extension's `ext` source folder:

```haxe
import gitNative.inspect;
var snapshot = inspect('/path/to/project');
```

`inspect(path)` discovers a repository at or above the path and returns its metadata directory, workdir, status records, staged diff and workdir diff. Repository, status-list, tree and diff handles are released before it returns. An unborn HEAD uses an empty tree for the staged comparison. Workdir diffs cover tracked changes; untracked files appear in status.

- `version()` returns `{major, minor, patch, features}`.
- `repositoryStatus(path)` returns `{repository, workdir, branch, entries}`, including unborn and detached HEAD labels; entries use the same indexed status format below.
- `commitChanges(path, revision)` returns copied `{path, oldPath, status}` file deltas against the first parent, or an empty tree for a root commit, including rename detection.
- `remoteOperation(path, operation, strategy='ff-only')` performs `fetch`, `pull` or `push`; pull accepts `ff-only`, `merge` or `rebase`. All native handles close on return or failure.
- `withRepository(path, action)` initializes libgit2, opens the repository, runs the action and closes it on return or exception. The action must not retain its repository or derived native views.
- `status(repository)` returns `{path, flags, index, workdir, conflicted, renamedFrom}` records. It includes nested untracked files and detects staged and workdir renames, excluding ignored files.
- `eachStatus(repository, visit)` calls `visit(path, flags)` through `git_status_foreach`. `statusFlags(repository)` collects these flags, excluding ignored entries. This simpler API uses libgit2's default status options and does not detect renames.
- `diff(repository, staged)` returns `{files, binaries, hunks, lines}` through all four `git_diff_foreach` callbacks. Files include old/new paths, sizes and delta status; hunks include old/new line ranges. Lines contain their origin byte, old/new line numbers and a copied `Bytes` buffer. Binary entries report binary data presence and inflated sizes.
- `openHistory(path, ref='all')` returns a cursor with `next(limit=100)`, idempotent `close()`, `refs`, `repository` and `workdir`. Pages contain `{commits, done}` in topological/time order. Each copied commit contains `{id, subject, parents, author, email, time}`. Limits are 1–500; a full page may require one more read to detect the end. Close cursors explicitly, including on errors and view cleanup.
- `blobText(path, spec)` returns `{text, binary}` for a blob: `HEAD:path`, `<commit>:path` or `:path` for the index. A missing blob is an empty text.
- `references(repository)` returns `{name, label, target, kind}` records, peeling annotated tags to commit ids. All-reference history includes detached HEAD; unborn repositories return an empty page.

Line content is length-delimited native data, not a C string. Copying it in the callback preserves embedded NULs and lets it outlive the diff and repository. A caller may decode a line's `bytes.toString()` when the text is UTF-8. Callback views stay inside their callback; records returned by the module contain only copied values. Callback exceptions return a failure value to C, then rethrow the original script exception after C returns.

The integration check covers parent discovery, status/diff cases, unborn HEAD, native errors, callback exceptions, GC, concurrent Krio script fibers, paged merge history, annotated tags, detached HEAD, deterministic graph lanes and UTC dates. Its C probe validates struct sizes and field offsets against the pinned headers. Fixture repositories and the captured result are under `bin/git-native-checks/`.

The `git` snapshot scenario installs the real extension in an isolated workspace, verifies the activity icon and SCM status groups, opens a changed file and refreshes status from the toolbar. It then drives CanvasKit and component input, checks page/filter/selection behavior and owner cleanup, throws from a canvas event handler and verifies that the next event succeeds in the same host without restart. Snapshots cover both color schemes.
