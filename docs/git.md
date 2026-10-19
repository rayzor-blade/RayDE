# Git native backend

The Git backend is RayScript in `extensions/git/ext/gitNative.rays`. It calls libgit2 through the extension host's native FFI; repository scanning and diff generation run on the library's worker lane. It is a backend module, with no installed `.rayext` or SCM view of its own.

## Build and check

```sh
scripts/build-libgit2.sh           # build and stage the pinned shared library
scripts/check-git.sh               # C layouts and real-host integration
scripts/check-git.sh --benchmark   # also measure warm status on 10k changed files
```

Requires CMake, a C compiler, curl, shasum, Python 3 and Git. The check uses `RAYSCRIPT_HOST`, or the release host in the sibling RayScript checkout. Git commands create the fixtures; the operations under test execute through RayScript and libgit2, in a real host process with a verified native grant.

The source is [libgit2 v1.9.7](https://github.com/libgit2/libgit2/releases/tag/v1.9.7), pinned by its archive SHA-256 in `scripts/build-libgit2.sh`. The build uses shared libraries, `USE_SSH=exec`, bundled zlib and bundled regex, without libgit2's CLI, examples or tests. Experimental SHA-256 object IDs are disabled because they change the native struct ABI. SSH uses the system OpenSSH client. HTTPS uses libgit2's platform default provider.

The archive, source and single CMake build directory live under `.deps/`. The library and upstream notices are staged under `extensions/git/natives/`, excluded from source control. macOS and Linux packaging scripts build these assets before copying the extensions directory. The binding layouts and integration are checked on macOS arm64; other platforms need their own ABI validation.

## Module interface

The embedding manifest declares `native:git2` and a `git2` native with the staged library's path and SHA-256, as described in [Native libraries](extensions.md#native-libraries). Import the module from the extension's `ext` source folder:

```haxe
import gitNative.inspect;
var snapshot = inspect('/path/to/project');
```

`inspect(path)` discovers a repository at or above the path and returns its metadata directory, workdir, status records, staged diff and workdir diff. Repository, status-list, tree and diff handles are released before it returns. An unborn HEAD uses an empty tree for the staged comparison. Workdir diffs cover tracked changes; untracked files appear in status.

- `version()` returns `{major, minor, patch, features}`.
- `withRepository(path, action)` initializes libgit2, opens the repository, runs the action and closes it on return or exception. The action must not retain its repository or derived native views.
- `status(repository)` returns `{path, flags, index, workdir, conflicted, renamedFrom}` records. It includes nested untracked files and detects staged and workdir renames, excluding ignored files.
- `eachStatus(repository, visit)` calls `visit(path, flags)` through `git_status_foreach`. `statusFlags(repository)` collects these flags, excluding ignored entries. This simpler API uses libgit2's default status options and does not detect renames.
- `diff(repository, staged)` returns `{files, binaries, hunks, lines}` through all four `git_diff_foreach` callbacks. Files include old/new paths, sizes and delta status; hunks include old/new line ranges. Lines contain their origin byte, old/new line numbers and a copied `Bytes` buffer. Binary entries report binary data presence and inflated sizes.

Line content is length-delimited native data, not a C string. Copying it in the callback preserves embedded NULs and lets it outlive the diff and repository. A caller may decode a line's `bytes.toString()` when the text is UTF-8. Callback views stay inside their callback; records returned by the module contain only copied values. Callback exceptions return a failure value to C, then rethrow the original script exception after C returns.

The integration check covers parent discovery, staged and workdir modifications, deletion, nested untracked files, ignored files, rename detection, merge conflicts, binary diffs, UTF-8 lines, unborn HEAD, native errors, callback exceptions, GC and concurrent Krio script fibers. Its C probe validates struct sizes and field offsets against the pinned headers. Fixture repositories and the captured result are under `bin/git-native-checks/`.
