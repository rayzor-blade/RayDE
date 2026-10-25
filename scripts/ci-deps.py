#!/usr/bin/env python3
"""Fetch and build the source dependencies of a distribution on its native host."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tomllib
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / "packaging/dependencies.json").read_text())
ASHUI_REV = re.search(r"^ashui_rev=([0-9a-f]{40})$", (ROOT / "scripts/deps.sh").read_text(), re.M)[1]


def run(*args, cwd=ROOT, **kwargs):
    print("+", *map(str, args), flush=True)
    return subprocess.run(list(map(str, args)), cwd=cwd, check=kwargs.pop("check", True), **kwargs)


def paths():
    dirs = {name: ROOT.parent / name for name in LOCK["sources"]}
    dirs["ashui"] = ROOT / ".deps" / ("ashui-" + ASHUI_REV)
    return dirs


def sources():
    return {**LOCK["sources"], "ashui": ASHUI_REV}


def github_text(url):
    headers = {"User-Agent": "RayDE-distribution"}
    token = os.environ.get("GITHUB_TOKEN")
    if token and urlsplit(url).netloc == "api.github.com":
        headers["Authorization"] = "Bearer " + token
    try:
        with urlopen(Request(url, headers=headers), timeout=30) as response:
            return response.read().decode("utf-8")
    except HTTPError as error:
        if error.code in (404, 422):
            raise RuntimeError(f"Not published or not accessible: {url}") from error
        raise RuntimeError(f"Dependency check failed with HTTP {error.code}: {url}") from error


def cargo_git_sources(text):
    revisions = set()
    for package in tomllib.loads(text).get("package", []):
        source = package.get("source", "")
        if not source.startswith("git+"):
            continue
        url = urlsplit(source[4:])
        if url.scheme != "https" or url.netloc != "github.com" or not re.fullmatch(r"[0-9a-f]{40}", url.fragment):
            raise ValueError(f"Unsupported locked Git source: {source}")
        revisions.add((url.path.strip("/").removesuffix(".git"), url.fragment))
    return revisions


def verify_remotes():
    """Check published pins and each pinned checkout's locked Git dependencies without building."""
    revisions = {(f"rayzor-blade/{name}", revision) for name, revision in sources().items()}
    failures = []
    def read_lock(item):
        repo, revision = item
        try:
            return cargo_git_sources(github_text(f"https://raw.githubusercontent.com/{repo}/{revision}/Cargo.lock")), None
        except Exception as error:
            return set(), str(error)
    with ThreadPoolExecutor(max_workers=4) as pool:
        for locked, error in pool.map(read_lock, sorted(revisions)):
            revisions.update(locked)
            if error:
                failures.append(error)
    for file in (ROOT / "native").glob("*/Cargo.lock"):
        revisions.update(cargo_git_sources(file.read_text()))
    def check(item):
        repo, revision = item
        try:
            value = json.loads(github_text(f"https://api.github.com/repos/{repo}/commits/{revision}"))
            if value.get("sha") != revision:
                raise RuntimeError(f"GitHub returned another revision for {repo}@{revision}")
            return None
        except Exception as error:
            return f"{repo}@{revision}: {error}"
    with ThreadPoolExecutor(max_workers=4) as pool:
        failures.extend(error for error in pool.map(check, sorted(revisions)) if error)
    if failures:
        raise SystemExit("Locked dependencies must be published before distribution builds:\n" + "\n".join("- " + error for error in failures))
    print(f"Verified {len(revisions)} published source and Cargo Git revisions", flush=True)


def checkout(name, revision, dest):
    if not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        run("git", "init", dest)
        run("git", "remote", "add", "origin", f"https://github.com/rayzor-blade/{name}.git", cwd=dest)
    head = run("git", "rev-parse", "--verify", "HEAD", cwd=dest, capture_output=True, text=True, check=False)
    dirty = run("git", "status", "--porcelain", "--untracked-files=no", cwd=dest, capture_output=True, text=True).stdout
    if dirty or head.returncode == 0 and head.stdout.strip() != revision:
        raise SystemExit(f"{dest} must be a clean checkout of {revision}; use a separate CI workspace")
    if head.returncode != 0:
        try:
            run("git", "fetch", "--depth=1", "origin", revision, cwd=dest)
        except subprocess.CalledProcessError as error:
            raise SystemExit(f"Cannot fetch locked dependency {name}@{revision}. Publish this commit and its Cargo Git dependencies before running distribution CI.") from error
        run("git", "checkout", "--detach", "FETCH_HEAD", cwd=dest)


def fetch():
    for name, revision in sources().items():
        checkout(name, revision, paths()[name])
    for name, version in LOCK["haxelibs"].items():
        run("haxelib", "install", name, version, "--skip-dependencies", "--always")
    for library in ("hashlink", "tink_hxx"):
        run("haxelib", "path", library)


def environment():
    dirs = paths()
    exe = ".exe" if os.name == "nt" else ""
    return {
        "RUSTUP_TOOLCHAIN": LOCK["rust"],
        "ASH": str(dirs["ash"] / "target/release" / ("ash" + exe)),
        "ASHUI": str(dirs["ashui"]),
        "ASHUI_REV": ASHUI_REV,
        "HLWGPU": str(dirs["hlwgpu"]),
        "HLWINDOW": str(dirs["hlwindow"]),
        "ASH_FUTURE": str(dirs["ash"] / "haxelib/ash-future"),
        "ASH_SIMD": str(dirs["ash"] / "haxelib/ash-simd"),
        "RAYZOR_LSP": str(dirs["rayzor"] / "target/release" / ("rayzor" + exe)),
        "RAYZOR_STD_PATH": str(dirs["rayzor"] / "compiler/haxe-std"),
        "RAYSCRIPT_TARGET_DIR": str(dirs["rayscript"] / "target"),
    }


def windows_imports():
    # Both the AOT executable and HDLLs import the same Ash runtime by this name.
    dest = ROOT / ".deps/ash-import"
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copy2(paths()["ash"] / "target/release/ash_std.dll", dest / "libhl.dll")
    exports = run("dumpbin", "/nologo", "/exports", dest / "libhl.dll", capture_output=True, text=True).stdout
    names = re.findall(r"^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)", exports, re.M)
    if "hl_alloc_bytes" not in names:
        raise SystemExit("Ash runtime exports were not found by dumpbin")
    definition = dest / "libhl.def"
    definition.write_text("LIBRARY libhl.dll\nEXPORTS\n" + "\n".join(names) + "\n")
    run("lib.exe", "/nologo", "/machine:x64", f"/def:{definition}", f"/out:{dest / 'libhl.lib'}")
    shutil.copy2(dest / "libhl.lib", dest / "libhl.dll.lib")
    return {"HL_LIB_DIR": str(dest), "ASH_RUNTIME": str(dest / "libhl.dll.lib")}


def build():
    os.environ.update(environment())
    dirs = paths()
    run("cargo", "build", "--locked", "--release", "-p", "ash_std", cwd=dirs["ash"])
    run("cargo", "build", "--locked", "--release", "-p", "ash", cwd=dirs["ash"])
    extra = windows_imports() if os.name == "nt" else {}
    os.environ.update(extra)
    if os.name == "nt":
        llvm_bin = Path(os.environ["LLVM_SYS_211_PREFIX"]) / "bin"
        for dll in llvm_bin.glob("*.dll"):
            shutil.copy2(dll, dirs["ash"] / "target/release" / dll.name)
    for name in ("hlwgpu", "hlwindow", "ashui"):
        args = ["-p", "hlwgpu"] if name == "hlwgpu" else []
        run("cargo", "build", "--locked", "--release", *args, cwd=dirs[name])
    run("cargo", "run", "--locked", "--release", "-p", "snapshot-gen", cwd=dirs["rayzor"])
    run("cargo", "build", "--locked", "--release", "-p", "rayzor", "--no-default-features", "--features", "llvm-static", cwd=dirs["rayzor"])
    return extra


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-remotes", action="store_true")
    parser.add_argument("--fetch", action="store_true")
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--env-file", type=Path)
    args = parser.parse_args()
    if args.verify_remotes:
        verify_remotes()
    if args.fetch:
        fetch()
    env = environment()
    if args.build:
        env.update(build())
    if args.env_file:
        with args.env_file.open("a", encoding="utf-8") as out:
            for key, value in env.items():
                out.write(f"{key}={value.replace(chr(92), '/')}\n")


if __name__ == "__main__":
    main()
