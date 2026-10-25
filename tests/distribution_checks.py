#!/usr/bin/env python3
"""Distribution contracts that run without native build dependencies."""
import importlib.util
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
        self.assertIn("ashui-" + pin, workflow)


if __name__ == "__main__":
    unittest.main()
