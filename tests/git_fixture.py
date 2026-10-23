"""Deterministic repository for the Git extension's graph and snapshot checks."""

import os
from pathlib import Path
import subprocess
import sys
import shutil


def create(root):
    root = Path(root)
    env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.test",
               GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.test",
               GIT_TERMINAL_PROMPT="0")
    counter = 0

    def git(*args, data=None):
        return subprocess.run(["git", "-C", str(root), *args], env=env, check=True,
                              input=data, text=True, capture_output=True).stdout.strip()

    def commit(subject, filename="history.txt", body=None):
        nonlocal counter
        counter += 1
        env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = f"{1720000000 + counter * 3600} +0000"
        (root / filename).write_text(subject + "\n")
        git("add", filename)
        git("commit", "-m", subject, *(["-m", body] if body else []))

    git("init", "-b", "main")
    git("config", "core.hooksPath", str(root / ".git/no-hooks"))
    git("config", "user.name", "Fixture")
    git("config", "user.email", "fixture@example.test")
    (root / ".gitignore").write_text(".rayde/\nsnapshot-home/\nmain.hl\n")
    git("add", ".gitignore")
    for filename in ["clean.txt", "src/modified.txt", "staged.txt", "renamed.txt", "conflict.txt"]:
        (root / filename).parent.mkdir(parents=True, exist_ok=True)
        (root / filename).write_text("Before\n")
        git("add", filename)
    for filename in ["build.hxml", "src"]:
        if (root / filename).exists():
            git("add", filename)
    for index in range(105):
        commit(f"Prepare extension runtime {index + 1}")
    git("tag", "v0.1.0")
    git("checkout", "-b", "ffi/callbacks")
    commit("Marshal callbacks to the VM", "callbacks.txt")
    commit("Run native calls on Krio lanes", "callbacks.txt")
    git("checkout", "main")
    commit("Keep extension hosts responsive")
    git("merge", "--no-ff", "ffi/callbacks", "-m", "Merge callback support")
    git("checkout", "-b", "ffi/trust")
    commit("Add native capability approvals", "trust.txt")
    commit("Verify library hashes before loading", "trust.txt")
    git("checkout", "main")
    commit("Polish extension settings")
    git("merge", "--no-ff", "ffi/trust", "-m", "Merge native library trust")
    commit("Add Git history graph", body="Full commit message with author details.\n\n" + "\n\n".join(f"Paragraph {i}: preserve the full description when hovering a commit, even when the graph shortens its title." for i in range(1, 9)))
    empty_tree = git("hash-object", "-t", "tree", "-w", "--stdin", data="")
    metadata = git("hash-object", "-t", "commit", "-w", "--stdin", data=f"tree {empty_tree}\nauthor Metadata <metadata@example.test> 1800000000 +0000\ncommitter Metadata <metadata@example.test> 1800000000 +0000\n\n")
    for name in ["refs/bugs/" + "a" * 64, "refs/remotes/issue-store/bugs/" + "a" * 64,
                 "refs/remotes/issue-store/identities/" + "b" * 64]:
        git("update-ref", name, metadata)
    if "--install" in sys.argv:
        (root / "src/modified.txt").write_text("Modified in the workdir\n")
        (root / "staged.txt").write_text("Staged change\n")
        git("add", "staged.txt")
        git("mv", "renamed.txt", "renamed-file.txt")
        (root / "untracked.txt").write_text("Untracked file\n")
        base = git("rev-parse", "HEAD:conflict.txt")
        ours = git("hash-object", "-w", "--stdin", data="Our version\n")
        theirs = git("hash-object", "-w", "--stdin", data="Their version\n")
        git("update-index", "--force-remove", "conflict.txt")
        git("update-index", "--index-info", data=f"100644 {base} 1\tconflict.txt\n100644 {ours} 2\tconflict.txt\n100644 {theirs} 3\tconflict.txt\n")
        (root / "conflict.txt").write_text("<<<<<<< ours\nOur version\n=======\nTheir version\n>>>>>>> theirs\n")
    return root


if __name__ == "__main__":
    root = create(sys.argv[1])
    if "--install" in sys.argv:
        source = Path(__file__).resolve().parents[1] / "extensions/git"
        target = root / ".rayde/extensions/git"
        for name in ["ext", "natives"]:
            shutil.copytree(source / name, target / name)
        shutil.copyfile(source / "git.rayext", target / "git.rayext")
