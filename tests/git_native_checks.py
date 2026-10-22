"""Real libgit2 integration through the editor's native-grant protocol."""

import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
import statistics
import time
import sys
from git_fixture import create as history_fixture

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "bin" / "git-native-checks"
EXTENSION = ROOT / "extensions" / "git"
HOST = os.environ.get("RAYSCRIPT_HOST", str(ROOT.parent / "rayscript/target/release/rayscript-host"))
LIBRARY = EXTENSION / "natives" / ("libgit2.dylib" if os.uname().sysname == "Darwin" else "libgit2.so")


def git(root, *args, ok=True):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, env=GIT_ENV)
    if ok and result.returncode:
        raise AssertionError(result.stderr.decode())
    return result


GIT_ENV = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.test",
               GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.test",
               GIT_TERMINAL_PROMPT="0")


class Host:
    def __enter__(self):
        self.errors = open(FIXTURE / "host.stderr", "a")
        self.process = subprocess.Popen([HOST, "--root", str(EXTENSION / "ext")],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.errors, text=True)
        self.messages = queue.Queue()

        def read():
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
            self.messages.put(None)

        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        self.send({"t": "natives", "root": str(EXTENSION), "capabilities": ["native:git2"],
                   "libraries": [{"name": "git2", "path": "natives/" + LIBRARY.name,
                                  "sha256": hashlib.sha256(LIBRARY.read_bytes()).hexdigest()}]})
        try:
            self.until("nativesReady")
        except BaseException:
            self.__exit__()
            raise
        return self

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def until(self, kind):
        while True:
            message = self.messages.get(timeout=30)
            if message is None:
                raise AssertionError("extension host ended before " + kind)
            if message["t"] == "error":
                raise AssertionError(message)
            if message["t"] == kind:
                return message

    def run(self, source):
        self.send({"t": "run", "name": "git-check.rays", "source": source})
        while True:
            message = self.until("log")
            if message["message"].startswith("@result:"):
                return json.loads(message["message"][8:])

    def __exit__(self, *error):
        try:
            self.send({"t": "shutdown"})
            self.process.stdin.close()
            self.process.wait(timeout=5)
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.process.stdout.close()
            self.errors.close()


PREAMBLE = """
import haxe.Json.stringify;
import gitNative.inspect;
import gitNative.version;
import gitNative.withRepository;
import gitNative.status;
import gitNative.statusFlags;
import gitNative.eachStatus;
import gitNative.diff;
import gitNative.openHistory;
import gitNative.repositoryStatus;
import gitNative.remoteOperation;
import gitNative.commitChanges;
import gitNative.openFileHistory;
import gitNative.blobText;
import gitNative.branchSummary;
function emit(value) { trace('@result:' + stringify(value)); }
function text(snapshot) {
  for (part in [snapshot.staged, snapshot.changes])
    for (line in part.lines) { line.text = line.bytes.toString(); line.bytes = null; }
  return snapshot;
}
"""


def write(root, name, content):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content if isinstance(content, bytes) else content.encode())


def init(name):
    root = FIXTURE / name
    root.mkdir()
    git(root, "init", "-b", "main")
    git(root, "config", "core.autocrlf", "false")
    git(root, "config", "core.hooksPath", str(FIXTURE / "no-hooks"))
    git(root, "config", "user.name", "Fixture")
    git(root, "config", "user.email", "fixture@example.test")
    return root


def inspect(root):
    with Host() as host:
        return host.run(PREAMBLE + """
var snapshot = inspect(REPO);
snapshot.flags = withRepository(REPO, repository -> statusFlags(repository));
emit(text(snapshot));
""".replace("REPO", json.dumps(str(root))))


def main():
    if FIXTURE.exists():
        shutil.rmtree(FIXTURE)
    FIXTURE.mkdir(parents=True)
    assert LIBRARY.is_file(), "run scripts/check-git.sh first"
    probe = FIXTURE / "layout"
    subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-I", str(ROOT / ".deps/libgit2-1.9.7/include"),
                    str(ROOT / "tests/fixtures/git-native/layout.c"), "-o", str(probe)], check=True)
    subprocess.run([str(probe)], check=True)
    root = init("repository")
    for name in ["clean.txt", "modified.txt", "staged.txt", "renamed.txt", "conflict.txt", "deleted.txt"]:
        write(root, name, "before\nsecond line\n")
    write(root, "binary.dat", b"\x00old binary\xff")
    write(root, ".gitignore", "ignored.txt\n")
    git(root, "add", ".")
    git(root, "commit", "-m", "base")
    git(root, "checkout", "-b", "other")
    write(root, "conflict.txt", "other\n")
    git(root, "commit", "-am", "other")
    git(root, "checkout", "main")
    write(root, "conflict.txt", "main\n")
    git(root, "commit", "-am", "main")
    assert git(root, "merge", "other", ok=False).returncode != 0
    write(root, "modified.txt", "after \u2603\nsecond line\n")
    write(root, "staged.txt", "staged change\nsecond line\n")
    git(root, "add", "staged.txt")
    git(root, "mv", "renamed.txt", "new name.txt")
    (root / "deleted.txt").unlink()
    write(root, "untracked.txt", "untracked\n")
    write(root, "nested/new.txt", "nested\n")
    write(root, "ignored.txt", "ignored\n")
    write(root, "binary.dat", b"\x00new binary\xfe")
    nested = root / "subfolder"
    nested.mkdir()
    with Host() as host:
        version = host.run(PREAMBLE + "emit(version());")
        assert [version[k] for k in ["major", "minor", "patch"]] == [1, 9, 7], version
        assert version["features"] & 4, version
    snapshot = inspect(nested)
    assert Path(snapshot["workdir"]) == root
    entries = {entry["path"]: entry for entry in snapshot["status"]}
    assert "clean.txt" not in entries and "ignored.txt" not in entries, entries
    assert entries["modified.txt"]["workdir"] & 256, entries
    assert entries["staged.txt"]["index"] & 2, entries
    assert entries["untracked.txt"]["workdir"] & 128, entries
    assert entries["nested/new.txt"]["workdir"] & 128, entries
    assert entries["deleted.txt"]["workdir"] & 512, entries
    assert entries["conflict.txt"]["conflicted"], entries
    assert entries["new name.txt"]["renamedFrom"] == "renamed.txt", entries
    flags = {entry["path"]: entry["flags"] for entry in snapshot["flags"]}
    assert flags["modified.txt"] & 256 and flags["conflict.txt"] & 32768, flags
    assert any(item["path"] == "binary.dat" for item in snapshot["changes"]["binaries"]), snapshot
    assert any(item["path"] == "modified.txt" for item in snapshot["changes"]["hunks"]), snapshot
    assert any(line["text"] == "after \u2603\n" and line["origin"] == ord("+") and line["newLine"] == 1
               for line in snapshot["changes"]["lines"]), snapshot
    assert any(line["text"] == "before\n" and line["origin"] == ord("-") and line["oldLine"] == 1
               for line in snapshot["changes"]["lines"]), snapshot
    assert any(line["text"] == "staged change\n" for line in snapshot["staged"]["lines"]), snapshot
    assert any(item["status"] == 4 and item["oldPath"] == "renamed.txt" for item in snapshot["staged"]["files"]), snapshot
    (FIXTURE / "snapshot.json").write_text(json.dumps(snapshot, indent=2))
    print("git native: version, parent discovery, status, rename, conflict, staged/workdir diff, four callbacks", flush=True)

    empty = init("unborn")
    write(empty, "first.txt", "first\n")
    git(empty, "add", "first.txt")
    result = inspect(empty)
    assert result["status"][0]["index"] & 1, result
    assert result["staged"]["lines"][0]["text"] == "first\n", result
    print("git native: unborn HEAD", flush=True)

    with Host() as host:
        result = host.run(PREAMBLE + """
var errors = [];
try { inspect(PATH); } catch (error) { errors.push(error); }
emit({errors: errors, good: text(inspect(GOOD))});
""".replace("PATH", json.dumps(str(FIXTURE / "missing"))).replace("GOOD", json.dumps(str(root))))
        assert "open repository:" in result["errors"][0], result
        assert result["good"]["status"], result
    print("git native: native errors and recovery", flush=True)

    with Host() as host:
        result = host.run(PREAMBLE + """
var errors = [], calls = 0;
try {
  withRepository(REPO, repository -> eachStatus(repository, (path, flags) -> {
    calls++; gc(); throw 'callback failure';
  }));
} catch (error) { errors.push(error); }
var count = withRepository(REPO, repository -> {
  var count = 0;
  eachStatus(repository, (path, flags) -> { gc(); count++; });
  return count;
});
var snapshot = inspect(REPO);
gc();
emit({errors: errors, calls: calls, count: count, snapshot: text(snapshot)});
""".replace("REPO", json.dumps(str(root))))
        assert result["errors"] == ["callback failure"] and result["calls"] == 1, result
        assert result["count"] >= len(entries), result
        assert any(line["text"] == "after \u2603\n" for line in result["snapshot"]["changes"]["lines"]), result
    print("git native: callback failure, GC, retained copies and recovery", flush=True)

    with Host() as host:
        result = host.run(PREAMBLE + """
var first = spawn(() -> inspect(FIRST));
var second = spawn(() -> inspect(SECOND));
emit({first: text(await first), second: text(await second)});
""".replace("FIRST", json.dumps(str(root))).replace("SECOND", json.dumps(str(empty))))
        assert result["first"]["status"] and result["second"]["status"], result
    print("git native: concurrent Krio script fibers", flush=True)

    git(root, "tag", "base-tag", "HEAD~1")
    with Host() as host:
        result = host.run(PREAMBLE + """
var cursor = openHistory(REPO), rows = [], done = false;
while (!done) { var page = cursor.next(1); rows = rows.concat(page.commits); done = page.done; }
var refs = cursor.refs;
cursor.close(); cursor.close(); gc();
var closed = false;
try { cursor.next(1); } catch (error) { closed = error == 'History cursor is closed'; }
var branch = openHistory(REPO, 'refs/heads/other');
var other = branch.next(500); branch.close();
var unborn = openHistory(EMPTY); var first = unborn.next(100); unborn.close();
emit({rows: rows, refs: refs, closed: closed, other: other, unborn: first});
""".replace("REPO", json.dumps(str(root))).replace("EMPTY", json.dumps(str(empty))))
        ids = [row["id"] for row in result["rows"]]
        expected = git(root, "rev-list", "--all").stdout.decode().splitlines()
        assert set(ids) == set(expected) and len(ids) == len(set(ids)), result
        positions = {oid: index for index, oid in enumerate(ids)}
        assert all(positions[parent] > positions[row["id"]] for row in result["rows"] for parent in row["parents"]), result
        assert all(row["author"] == "Fixture" for row in result["rows"]), result
        assert result["closed"] and result["unborn"] == {"commits": [], "done": True}, result
        other = git(root, "rev-list", "other").stdout.decode().splitlines()
        assert set(row["id"] for row in result["other"]["commits"]) == set(other), result
        assert any(ref["name"] == "refs/tags/base-tag" for ref in result["refs"]), result
    print("git native: paged topological history, references, branch filtering and cursor lifetime", flush=True)
    with Host() as host:
        result = host.run(PREAMBLE + "emit({normal:repositoryStatus(REPO),unborn:repositoryStatus(EMPTY)});".replace("REPO", json.dumps(str(root))).replace("EMPTY", json.dumps(str(empty))))
        assert result["normal"]["branch"] == "main" and len(result["normal"]["entries"]) == len(entries)
        assert result["unborn"]["branch"] == "No commits"

    history = FIXTURE / "history"
    history.mkdir()
    history_fixture(history)
    git(history, "tag", "-a", "release", "-m", "Annotated release")
    with Host() as host:
        result = host.run(PREAMBLE + """
import historyGraph.layout;
import historyGraph.scene;
import historyGraph.compactScene;
import historyGraph.timestamp;
var cursor = openHistory(REPO), first = cursor.next(6), second = cursor.next(500);
var rows = first.commits.concat(second.commits), refs = cursor.refs;
cursor.close(); gc();
emit({rows: rows, refs: refs, first: layout(first.commits), graph: layout(rows),
  scene: scene(rows, refs, rows[0].id), compact:compactScene(rows, refs, rows[0].id), dates: [timestamp(0), timestamp(951782400), timestamp(-1)]});
""".replace("REPO", json.dumps(str(history))))
        rows, graph = result["rows"], result["graph"]
        assert len(rows) == 114 and sum(len(row["parents"]) == 2 for row in rows) == 2, rows
        assert len({row["id"] for row in rows}) == 114
        assert result["first"]["rows"] == graph["rows"][:6], "page extension moved earlier nodes"
        assert result["first"]["edges"] == [edge for edge in graph["edges"] if edge["row"] < 6]
        positions = {row["id"]: index for index, row in enumerate(rows)}
        lanes = {row["commit"]["id"]: row["lane"] for row in graph["rows"]}
        for edge in graph["edges"]:
            assert positions[edge["target"]] > edge["row"], edge
            if positions[edge["target"]] == edge["row"] + 1:
                assert edge["to"] == lanes[edge["target"]], edge
        assert len(result["scene"]["regions"]) == len(rows)
        assert [r["id"] for r in result["compact"]["regions"]] == [r["id"] for r in result["scene"]["regions"]]
        assert any(ref["name"] == "refs/tags/release" and ref["target"] == rows[0]["id"] for ref in result["refs"])
        assert result["dates"] == ["1970-01-01 00:00 UTC", "2000-02-29 00:00 UTC", "1969-12-31 23:59 UTC"]
        assert all(row["author"] != "Metadata" for row in rows), rows
        assert not any("issue-store/" in ref["name"] or ref["name"].startswith("refs/bugs/") for ref in result["refs"])
        result = host.run(PREAMBLE + """
emit({latest:commitChanges(REPO,'HEAD'), merge:commitChanges(REPO,'HEAD~1'),
  root:commitChanges(REPO,ROOT_COMMIT)});
""".replace("REPO", json.dumps(str(history))).replace("ROOT_COMMIT", json.dumps(git(history,"rev-list","--max-parents=0","main").stdout.decode().strip())))
        assert result["latest"] == [{"path":"history.txt", "oldPath":"history.txt", "status":3}], result
        assert result["merge"] == [{"path":"trust.txt", "oldPath":"trust.txt", "status":1}], result
        assert result["root"] and all(item["status"] == 1 for item in result["root"]), result
        changes = init("commit-files")
        write(changes, "before.txt", "retained content\n" * 10)
        write(changes, "deleted.txt", "deleted\n")
        git(changes, "add", ".")
        git(changes, "commit", "-m", "root")
        git(changes, "mv", "before.txt", "after.txt")
        git(changes, "rm", "deleted.txt")
        write(changes, "nested/added.txt", "added\n")
        git(changes, "add", ".")
        git(changes, "commit", "-m", "rename and deletion")
        result = host.run(PREAMBLE + """
var error = '';
try { commitChanges(REPO,'missing-commit'); } catch (failure) { error = '' + failure; }
gc(); emit({files:commitChanges(REPO,'HEAD'),error:error});
""".replace("REPO", json.dumps(str(changes))))
        assert {item["path"]:item["status"] for item in result["files"]} == {"after.txt":4,"deleted.txt":2,"nested/added.txt":1}, result
        assert next(item["oldPath"] for item in result["files"] if item["status"] == 4) == "before.txt", result
        assert "resolve commit:" in result["error"], result
        result = host.run(PREAMBLE + """
var cursor = openFileHistory(REPO, ACTIVE_FILE), commits = [], done = false;
while (!done) { var page = cursor.next(1); commits = commits.concat(page.commits); done = page.done; }
cursor.close(); cursor.close();
var error = '';
try { cursor.next(1); } catch (failure) { error = '' + failure; }
var missing = openFileHistory(REPO, MISSING); var absent = missing.next(50); missing.close();
var unborn = openFileHistory(EMPTY, EMPTY_FILE); var empty = unborn.next(50); unborn.close();
emit({commits:commits, error:error, absent:absent, empty:empty});
""".replace("REPO", json.dumps(str(changes))).replace("ACTIVE_FILE", json.dumps(str(changes / "after.txt")))
            .replace("MISSING", json.dumps(str(changes / "absent.txt")))
            .replace("EMPTY_FILE", json.dumps(str(empty / "not-yet.txt"))).replace("EMPTY", json.dumps(str(empty))))
        assert [row["subject"] for row in result["commits"]] == ["rename and deletion", "root"], result
        assert result["absent"] == {"commits":[], "done":True}, result
        assert result["empty"] == {"commits":[], "done":True}, result
        assert "closed" in result["error"], result
        write(changes, "image.bin", b"\x00\x01\x02binary")
        git(changes, "add", "image.bin")
        write(changes, "after.txt", "retained content\n" * 10 + "edited in the index\n")
        git(changes, "add", "after.txt")
        result = host.run(PREAMBLE + """
emit({parent:blobText(REPO,'HEAD^1:before.txt'), head:blobText(REPO,'HEAD:after.txt'), index:blobText(REPO,':after.txt'),
  missing:blobText(REPO,'HEAD:no-such.txt'), binary:blobText(REPO,':image.bin'), empty:blobText(REPO,'HEAD^1:nested/added.txt')});
""".replace("REPO", json.dumps(str(changes))))
        assert result["parent"] == {"text":"retained content\n" * 10, "binary":False}, result
        assert result["head"]["text"] == "retained content\n" * 10, result
        assert result["index"]["text"].endswith("edited in the index\n"), result
        assert result["missing"] == {"text":"", "binary":False}, result
        assert result["binary"]["binary"] is True, result
    print("git commit files: root, modification, first-parent merge, rename, deletion, invalid revision recovery and metadata filtering", flush=True)
    git(history, "checkout", "--detach", "HEAD~2")
    with Host() as host:
        result = host.run(PREAMBLE + "var cursor = openHistory(REPO); emit({page:cursor.next(500),branch:repositoryStatus(REPO).branch}); cursor.close();".replace("REPO", json.dumps(str(history))))
        assert len(result["page"]["commits"]) == 114 and result["branch"] == "Detached HEAD", result
    print("git history: merge DAG, stable page lanes, edge routing, annotated tags, detached HEAD and UTC dates", flush=True)
    with Host() as host:
        result = host.run(PREAMBLE + """
var tasks=[];
for (i in 0...8) tasks.push(spawn(() -> {
  var cursor=openHistory(REPO); var page=cursor.next(100); cursor.close(); gc();
  return page.commits.length;
}));
var counts=[]; for (task in tasks) counts.push(await task); emit(counts);
""".replace("REPO", json.dumps(str(history))))
        assert result == [100] * 8, result
    print("git history: concurrent cached-object references retain independent ownership", flush=True)

    origin = FIXTURE / "origin.git"
    origin.mkdir()
    git(origin, "init", "--bare", "-b", "main")
    sender = init("sender")
    write(sender, "tracked.txt", "base\n")
    git(sender, "add", ".")
    git(sender, "commit", "-m", "remote base")
    git(sender, "remote", "add", "origin", str(origin))

    def remote(host, root, action, expected_error=None, strategy="ff-only"):
        result = host.run(PREAMBLE + """
try { emit({result:remoteOperation(REPO, ACTION, STRATEGY)}); }
catch (error) { emit({error:'' + error}); }
""".replace("REPO", json.dumps(str(root))).replace("ACTION", json.dumps(action)).replace("STRATEGY", json.dumps(strategy)))
        if expected_error is None:
            assert result.get("result", {}).get("remote") == "origin", result
        else:
            assert expected_error in result.get("error", ""), result
        return result

    with Host() as host:
        remote(host, sender, "push")
        assert git(sender, "config", "branch.main.remote").stdout.strip() == b"origin"
        assert git(origin, "rev-parse", "main").stdout == git(sender, "rev-parse", "HEAD").stdout
        receiver = init("receiver")
        git(receiver, "remote", "add", "origin", str(origin))
        remote(host, receiver, "fetch")
        git(receiver, "checkout", "-B", "main", "--track", "origin/main")
        before = git(receiver, "rev-parse", "HEAD").stdout
        write(sender, "tracked.txt", "remote update\n")
        git(sender, "commit", "-am", "remote update")
        remote(host, sender, "push")
        remote(host, receiver, "fetch")
        assert git(receiver, "rev-parse", "HEAD").stdout == before
        assert git(receiver, "rev-parse", "origin/main").stdout == git(sender, "rev-parse", "HEAD").stdout
        remote(host, receiver, "pull")
        assert git(receiver, "rev-parse", "HEAD").stdout == git(sender, "rev-parse", "HEAD").stdout
        assert (receiver / "tracked.txt").read_text() == "remote update\n"
        assert not git(receiver, "status", "--porcelain").stdout
        write(receiver, "tracked.txt", "uncommitted\n")
        remote(host, receiver, "pull", "Commit or stash")
        assert (receiver / "tracked.txt").read_text() == "uncommitted\n"
        git(receiver, "checkout", "--", "tracked.txt")
        write(receiver, "local.txt", "local\n")
        git(receiver, "add", ".")
        git(receiver, "commit", "-m", "local ahead")
        remote(host, receiver, "pull")
        local_head = git(receiver, "rev-parse", "HEAD").stdout
        write(sender, "tracked.txt", "divergent remote\n")
        git(sender, "commit", "-am", "divergent remote")
        remote(host, sender, "push")
        remote_head = git(origin, "rev-parse", "main").stdout
        remote(host, receiver, "push", "push to origin:")
        assert git(origin, "rev-parse", "main").stdout == remote_head
        remote(host, receiver, "pull", "diverged")
        assert git(receiver, "rev-parse", "HEAD").stdout == local_head
        counts = git(receiver, "rev-list", "--left-right", "--count", "HEAD...origin/main").stdout.split()
        summary = host.run(PREAMBLE + "emit(branchSummary(REPO));".replace("REPO", json.dumps(str(receiver))))
        assert summary["branch"] == "main" and summary["upstream"] is True, summary
        assert (summary["ahead"], summary["behind"]) == (int(counts[0]), int(counts[1])) and summary["ahead"] > 0 and summary["behind"] > 0, (summary, counts)
        level = host.run(PREAMBLE + "emit(branchSummary(REPO));".replace("REPO", json.dumps(str(sender))))
        assert level["upstream"] is True and level["ahead"] == 0 and level["behind"] == 0, level
        unborn = host.run(PREAMBLE + "emit(branchSummary(REPO));".replace("REPO", json.dumps(str(empty))))
        assert unborn == {"branch":"No commits", "head":"", "upstream":False, "ahead":0, "behind":0}, unborn
        assert not git(receiver, "status", "--porcelain").stdout
        for strategy in ["merge", "rebase"]:
            git(receiver, "reset", "--hard", local_head.decode().strip())
            remote(host, receiver, "pull", strategy=strategy)
            assert git(receiver, "merge-base", "--is-ancestor", remote_head.decode().strip(), "HEAD").returncode == 0
            assert (receiver / "local.txt").read_text() == "local\n"
            assert (receiver / "tracked.txt").read_text() == "divergent remote\n"
            assert not git(receiver, "status", "--porcelain").stdout
            parent_count = len(git(receiver,"rev-list","--parents","-n","1","HEAD").stdout.split()) - 1
            assert parent_count == (2 if strategy == "merge" else 1), strategy
        git(receiver, "reset", "--hard", remote_head.decode().strip())
        write(receiver, "tracked.txt", "local conflict\n")
        git(receiver, "commit", "-am", "local conflict")
        conflict_head = git(receiver,"rev-parse","HEAD").stdout
        write(sender, "tracked.txt", "remote conflict\n")
        git(sender, "commit", "-am", "remote conflict")
        remote(host, sender, "push")
        for strategy in ["merge", "rebase"]:
            before_index = (receiver / ".git/index").read_bytes()
            remote(host, receiver, "pull", "has conflicts; branch unchanged", strategy=strategy)
            assert git(receiver,"rev-parse","HEAD").stdout == conflict_head
            assert (receiver / ".git/index").read_bytes() == before_index
            assert (receiver / "tracked.txt").read_text() == "local conflict\n"
            assert not git(receiver,"status","--porcelain").stdout
            assert not any((receiver / ".git" / name).exists() for name in ["MERGE_HEAD","rebase-merge","rebase-apply"])
        remote(host, empty, "fetch", "No remote configured")
        git(receiver, "checkout", "--detach")
        remote(host, receiver, "push", "Check out a branch")
        source = PREAMBLE + "var cursor=openHistory(REPO, FOCUS); emit(cursor.next(500)); cursor.close();"
        focus = git(history, "rev-parse", "refs/tags/v0.1.0").stdout.decode().strip()
        result = host.run(source.replace("REPO", json.dumps(str(history))).replace("FOCUS", json.dumps(focus)))
        assert result["commits"][0]["id"] == focus and len(result["commits"]) == 105, result
    print("git remote: publish, upstream, fetch, fast-forward/merge/rebase pull, conflicts unchanged, ahead-only pull, dirty/diverged rejection, non-fast-forward push and commit focus", flush=True)

    if "--benchmark" in sys.argv:
        large = init("large")
        for index in range(10000):
            write(large, f"files/{index:05}.txt", "before\n")
        git(large, "add", ".")
        git(large, "commit", "-m", "ten thousand files")
        for index in range(10000):
            write(large, f"files/{index:05}.txt", "after\n")
        with Host() as host:
            source = PREAMBLE + "emit(withRepository(REPO, repository -> status(repository).length));"
            source = source.replace("REPO", json.dumps(str(large)))
            assert host.run(source) == 10000
            elapsed = []
            for _ in range(5):
                start = time.perf_counter()
                assert host.run(source) == 10000
                elapsed.append((time.perf_counter() - start) * 1000)
        print(f"git native: 10k changed files, median warm status {statistics.median(elapsed):.1f} ms", flush=True)


if __name__ == "__main__":
    main()
