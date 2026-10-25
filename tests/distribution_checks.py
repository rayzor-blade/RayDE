#!/usr/bin/env python3
"""Distribution contracts that run without native build dependencies."""
import importlib.util
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("distribution", ROOT / "scripts/distribution.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class DistributionChecks(unittest.TestCase):
    def fixture(self, root, target):
        bindir, data, extensions, program, rayzor = package.layout(root, target)
        files = [bindir / p for p in [program, "rayde-extension-host" + (".exe" if target == "windows" else ""), "blinc_abi.hdll", "xgpu.hdll", "xwindow.hdll", "cterm.hdll", "rayscript.hdll"]]
        files += [data / rayzor, data / "haxe-std/Std.hx", data / "distribution.json", data / "notices/dependencies.json"]
        files.append(bindir / {"macos": "libhl.dylib", "linux": "libhl.so", "windows": "libhl.dll"}[target])
        for path in files:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture")
        for name in ["git", "markdown", "rayzor"]:
            folder = extensions / name
            folder.mkdir(parents=True)
            (folder / "main.rays").write_text("trace('fixture');")
            definition = {"id": name, "main": "main.rays"}
            if name == "git":
                (folder / "git2.native").write_text("native")
                definition["natives"] = {"git2": {"path": "git2.native", "sha256": package.digest(folder / "git2.native")}}
            (folder / (name + ".rayext")).write_text(json.dumps(definition))
        return bindir, extensions

    def test_layouts_and_required_files(self):
        for target in ["macos", "linux", "windows"]:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                bindir, _ = self.fixture(root, target)
                package.validate(root, target)
                (bindir / "rayscript.hdll").unlink()
                with self.assertRaisesRegex(RuntimeError, "Missing distribution file"):
                    package.validate(root, target)

    def test_native_hashes_follow_relocation_and_signing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            _, extensions = self.fixture(root, "linux")
            native = extensions / "git/git2.native"
            native.write_text("relocated and signed")
            with self.assertRaisesRegex(RuntimeError, "hash mismatch"):
                package.validate(root, "linux")
            package.refresh_native_hashes(extensions)
            package.validate(root, "linux")
            (extensions / "git/main.rays").unlink()
            with self.assertRaisesRegex(RuntimeError, "entry point"):
                package.validate(root, "linux")

    def test_archive_layout_checksum_and_permissions(self):
        for target, extension in [("linux", "tar.gz"), ("windows", "zip")]:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temp:
                root = Path(temp) / "RayDE with spaces"
                bindir, _ = self.fixture(root, target)
                executable = bindir / ("RayDE.exe" if target == "windows" else "rayde")
                executable.chmod(0o755)
                destination = Path(temp) / ("rayde." + extension)
                package.archive(root, target, destination)
                self.assertEqual(destination.with_name(destination.name + ".sha256").read_text(), f"{package.digest(destination)}  {destination.name}\n")
                if target == "linux":
                    with tarfile.open(destination) as archive:
                        member = archive.getmember("RayDE with spaces/lib/rayde/rayde")
                        self.assertEqual(member.mode & 0o777, 0o755)
                else:
                    with zipfile.ZipFile(destination) as archive:
                        self.assertIn("RayDE with spaces/RayDE.exe", archive.namelist())

    def test_macos_dependency_rewrite_and_shared_library_reuse(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "RayDE.app"
            bindir = root / "Contents/MacOS"
            bindir.mkdir(parents=True)
            (bindir / "RayDE").write_bytes(b"\xcf\xfa\xed\xfe")
            source = Path(temp) / "build/libextra.dylib"
            source.parent.mkdir()
            source.write_bytes(b"\xcf\xfa\xed\xfe")
            commands = []
            def tool(*args):
                if args[:2] == ("otool", "-D"):
                    return str(args[-1]) + ":\n"
                if args[:2] == ("otool", "-L"):
                    deps = str(source) if Path(args[-1]).name == "RayDE" else "/usr/lib/libSystem.B.dylib"
                    return str(args[-1]) + ":\n\t" + deps + " (compatibility version 1.0)\n"
                return ""
            with patch.object(package, "output", side_effect=tool), patch.object(package.subprocess, "run", side_effect=lambda args, **kw: commands.append(args)):
                package.bundle_macos(root, bindir)
            self.assertTrue((bindir / source.name).is_file())
            self.assertTrue(any("@loader_path/libextra.dylib" in args and "-change" in args for args in commands))
            self.assertTrue(any("codesign" in args for args in commands))

    def test_windows_import_library_names_the_shared_ash_runtime(self):
        spec = importlib.util.spec_from_file_location("ci_deps", ROOT / "scripts/ci-deps.py")
        deps = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(deps)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            runtime = root / "ash/target/release/ash_std.dll"
            runtime.parent.mkdir(parents=True)
            runtime.write_text("Ash runtime")
            commands = []
            def run(*args, **kwargs):
                commands.append(args)
                if args[0] == "dumpbin":
                    return SimpleNamespace(stdout="   1  0 00001000 hl_alloc_bytes\n   2  1 00001100 hl_gc_collect\n")
                (root / ".deps/ash-import/libhl.lib").write_text("Import library")
            with patch.object(deps, "ROOT", root), patch.object(deps, "paths", return_value={"ash": root / "ash"}), patch.object(deps, "run", side_effect=run):
                env = deps.windows_imports()
            self.assertIn("LIBRARY libhl.dll", (root / ".deps/ash-import/libhl.def").read_text())
            self.assertEqual(Path(env["ASH_RUNTIME"]).name, "libhl.dll.lib")
            self.assertEqual((Path(env["HL_LIB_DIR"]) / "libhl.dll").read_bytes(), runtime.read_bytes())
            self.assertTrue(any(args[0] == "lib.exe" for args in commands))

    def test_linux_custom_library_and_extension_search_path(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "distribution"
            bindir, _, extensions, _, _ = package.layout(root, "linux")
            bindir.mkdir(parents=True)
            binary = extensions / "git/natives/libgit2.so"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"\x7fELF")
            source = Path(temp) / "build/libcustom.so"
            source.parent.mkdir()
            source.write_bytes(b"\x7fELF")
            def dependencies(path):
                return [("libcustom.so", str(source)), ("libc.so.6", "/usr/lib/libc.so.6")] if path == binary else []
            commands = []
            with patch.object(package, "linux_dependencies", side_effect=dependencies), patch.object(package.subprocess, "run", side_effect=lambda args, **kwargs: commands.append(args)):
                package.bundle_linux(root, bindir)
            self.assertTrue((bindir / "libcustom.so").is_file())
            self.assertFalse((bindir / "libc.so.6").exists())
            self.assertIn(["patchelf", "--set-rpath", "$ORIGIN:$ORIGIN/../../../../../lib/rayde", str(binary)], commands)

    def test_version_input_is_data(self):
        script = ROOT / "scripts/release-version.py"
        env = {**os.environ, "GITHUB_REF": "refs/tags/v1.2.3-rc.1", "INPUT_VERSION": ""}
        self.assertEqual(subprocess.check_output([sys.executable, script], env=env, text=True), "RAYDE_VERSION=1.2.3-rc.1\n")
        env.update(GITHUB_REF="", INPUT_VERSION="$(touch /tmp/unwanted)")
        self.assertNotEqual(subprocess.run([sys.executable, script], env=env, capture_output=True).returncode, 0)

    def dependency_helper(self):
        spec = importlib.util.spec_from_file_location("ci_deps", ROOT / "scripts/ci-deps.py")
        deps = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(deps)
        return deps

    def test_cargo_git_checks_use_locked_commit_not_branch_or_rev_query(self):
        deps = self.dependency_helper()
        first, second = "a" * 40, "b" * 40
        lock = f'''version = 4
[[package]]
name = "a"
source = "git+https://github.com/owner/project.git?branch=main#{first}"
[[package]]
name = "b"
source = "git+https://github.com/owner/project.git?rev=abc#{second}"
[[package]]
name = "c"
source = "git+https://github.com/owner/project?branch=main#{first}"
[[package]]
name = "registry"
source = "registry+https://github.com/rust-lang/crates.io-index"
'''
        self.assertEqual(deps.cargo_git_sources(lock), {("owner/project", first), ("owner/project", second)})
        with self.assertRaisesRegex(ValueError, "Unsupported locked Git source"):
            deps.cargo_git_sources(lock.replace("https://github.com/owner/project.git", "file:///local/project"))

    def test_preflight_reports_unpublished_cargo_revision_before_builds(self):
        deps = self.dependency_helper()
        direct, nested = "a" * 40, "b" * 40
        lock = f'''[[package]]
name = "window-core"
source = "git+https://github.com/owner/window.git?rev={nested}#{nested}"
'''
        checked = []
        def lookup(url):
            checked.append(url)
            if url.endswith("/Cargo.lock"):
                return lock
            if "/owner/window/" in url:
                raise RuntimeError("Not published")
            return json.dumps({"sha": direct})
        with tempfile.TemporaryDirectory() as temp, patch.object(deps, "ROOT", Path(temp)), patch.object(deps, "sources", return_value={"hlwindow": direct}), patch.object(deps, "github_text", side_effect=lookup):
            with self.assertRaisesRegex(SystemExit, "owner/window@" + nested):
                deps.verify_remotes()
        self.assertTrue(any("/hlwindow/commits/" + direct in url for url in checked))
        self.assertEqual(sum("/owner/window/commits/" in url for url in checked), 1)
        def published(url):
            return lock if url.endswith("/Cargo.lock") else json.dumps({"sha": url.rsplit("/",1)[1]})
        with tempfile.TemporaryDirectory() as temp, patch.object(deps, "ROOT", Path(temp)), patch.object(deps, "sources", return_value={"hlwindow": direct}), patch.object(deps, "github_text", side_effect=published), redirect_stdout(io.StringIO()) as result:
            deps.verify_remotes()
        self.assertIn("Verified 2 published", result.getvalue())

    def test_failed_checkout_recovers_and_existing_work_is_protected(self):
        deps = self.dependency_helper()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            remote, seed, dest = [root / path for path in ("remote.git", "seed", "checkout with spaces")]
            def git(*args, cwd=root, check=True):
                return subprocess.run(["git", *map(str,args)], cwd=cwd, check=check, capture_output=True, text=True)
            git("init", "--bare", remote)
            git("init", seed)
            (seed / "file.txt").write_text("published")
            git("add", "file.txt", cwd=seed)
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-m", "Initial", cwd=seed)
            revision = git("rev-parse", "HEAD", cwd=seed).stdout.strip()
            git("push", str(remote), "HEAD:main", cwd=seed)
            def run(*args, **kwargs):
                args = list(args)
                if args[:4] == ["git", "remote", "add", "origin"]:
                    args[4] = str(remote)
                return subprocess.run(list(map(str,args)), cwd=kwargs.get("cwd", root), check=kwargs.get("check", True), capture_output=True, text=True)
            with patch.object(deps, "run", side_effect=run):
                with self.assertRaisesRegex(SystemExit, "Cannot fetch locked dependency"):
                    deps.checkout("fixture", "f" * 40, dest)
                self.assertTrue((dest / ".git").is_dir())
                deps.checkout("fixture", revision, dest)
                self.assertEqual(git("rev-parse", "HEAD", cwd=dest).stdout.strip(), revision)
                with self.assertRaisesRegex(SystemExit, "clean checkout"):
                    deps.checkout("fixture", "f" * 40, dest)
                (dest / "file.txt").write_text("local edits")
                with self.assertRaisesRegex(SystemExit, "clean checkout"):
                    deps.checkout("fixture", revision, dest)
                self.assertEqual((dest / "file.txt").read_text(), "local edits")

    def test_locked_toolchains_and_source_revisions(self):
        lock = json.loads((ROOT / "packaging/dependencies.json").read_text())
        workflow = (ROOT / ".github/workflows/distribution.yml").read_text()
        self.assertIn("RUSTUP_TOOLCHAIN: " + lock["rust"], workflow)
        self.assertIn("haxe-version: " + lock["haxe"], workflow)
        self.assertIn("python-version: '" + lock["python"] + "'", workflow)
        for revision in lock["sources"].values():
            self.assertRegex(revision, r"^[0-9a-f]{40}$")
        for action in re.findall(r"uses: ([^\s]+)", workflow):
            self.assertTrue(action.startswith("./") or re.search(r"@[0-9a-f]{40}$", action), action)
        pin = re.search(r"^ashui_rev=(\w+)$", (ROOT / "scripts/deps.sh").read_text(), re.M)[1]
        spec = importlib.util.spec_from_file_location("ci_deps", ROOT / "scripts/ci-deps.py")
        deps = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(deps)
        self.assertEqual(deps.environment()["ASHUI_REV"], pin)
        self.assertIn("RayDE/.deps/ashui-${{ env.ASHUI_REV }} -> target", workflow)
        self.assertIn("--verify-remotes", workflow)


if __name__ == "__main__":
    unittest.main()
