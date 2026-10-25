#!/usr/bin/env python3
"""Finalize, validate and archive native RayDE distributions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import zipfile

SOURCE = Path(__file__).resolve().parent.parent
MAGIC = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\x7fELF", b"MZ")
COPIED = {}


def output(*args):
    return subprocess.check_output(list(map(str, args)), text=True, stderr=subprocess.STDOUT)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def binaries(root):
    for path in sorted(root.rglob("*")):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                if stream.read(4).startswith(MAGIC):
                    yield path


def search_dirs():
    paths = os.environ.get("RAYDE_LIBRARY_PATH", "").split(os.pathsep)
    llvm = os.environ.get("LLVM_SYS_211_PREFIX")
    if llvm:
        paths += [str(Path(llvm) / "bin"), str(Path(llvm) / "lib")]
    paths += os.environ.get("PATH", "").split(os.pathsep)
    redist = os.environ.get("VCToolsRedistDir")
    if redist:
        paths = [str(p) for p in Path(redist).glob("x64/Microsoft.VC*.CRT")] + paths
    return [Path(p) for p in paths if p]


def copy_dependency(source, dest):
    if source.resolve() == dest.resolve():
        return
    if COPIED.get(dest) == source.resolve():
        return
    if dest.exists() and digest(dest) != digest(source):
        raise RuntimeError(f"Conflicting native libraries named {dest.name}: {source} and {dest}")
    if not dest.exists():
        shutil.copy2(source, dest)
        dest.chmod(dest.stat().st_mode | 0o200)
    COPIED[dest] = source.resolve()


def mac_dependencies(path):
    identity = output("otool", "-D", path).splitlines()[1:]
    return [line.strip().split(" (", 1)[0] for line in output("otool", "-L", path).splitlines()[1:]
            if line.strip().split(" (", 1)[0] not in identity]


def mac_system(dep):
    return dep.startswith(("/usr/lib/", "/System/Library/"))


def bundle_macos(root, bindir):
    pending = list(binaries(root))
    seen = set()
    while pending:
        binary = pending.pop(0)
        if binary in seen:
            continue
        seen.add(binary)
        rpaths = re.findall(r"\bpath (.+?) \(offset", output("otool", "-l", binary))
        for dep in mac_dependencies(binary):
            if mac_system(dep):
                continue
            def expand(value):
                return Path(value.replace("@loader_path", str(binary.parent)).replace("@executable_path", str(bindir)))
            candidates = [expand(dep)]
            if dep.startswith("@rpath/"):
                candidates = [expand(p) / dep[7:] for p in rpaths]
            candidates += [binary.parent / Path(dep).name, bindir / Path(dep).name]
            candidates += [d / Path(dep).name for d in search_dirs()]
            found = next((p for p in candidates if p.is_file()), None)
            if found is None:
                raise RuntimeError(f"Unresolved dependency {dep} in {binary}")
            # All helpers and extension libraries share one directory of runtime dependencies.
            target = bindir / found.name
            if found.resolve().is_relative_to(root.resolve()):
                target = found
            else:
                copy_dependency(found, target)
                pending.append(target)
            relative = os.path.relpath(target, binary.parent)
            replacement = "@loader_path/" + relative
            if dep != replacement:
                subprocess.run(["install_name_tool", "-change", dep, replacement, str(binary)], check=True)
        if binary.suffix in (".dylib", ".hdll"):
            subprocess.run(["install_name_tool", "-id", "@loader_path/" + binary.name, str(binary)], check=True)
    for binary in binaries(root):
        if binary != bindir / "RayDE":
            subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=True)


def windows_dependencies(path):
    return re.findall(r"^\s+([\w.+-]+\.dll)\s*$", output("dumpbin", "/nologo", "/dependents", path), re.M | re.I)


def bundle_windows(root, bindir):
    pending = list(binaries(root))
    seen = set()
    system = Path(os.environ["SystemRoot"]) / "System32"
    while pending:
        binary = pending.pop(0)
        if binary in seen:
            continue
        seen.add(binary)
        for name in windows_dependencies(binary):
            if name.lower().startswith(("api-ms-", "ext-ms-")):
                continue
            dirs = [binary.parent, bindir] + search_dirs()
            found = next((d / name for d in dirs if (d / name).is_file()), None)
            if found is None and (system / name).is_file():
                continue
            if found is None:
                raise RuntimeError(f"Unresolved dependency {name} in {binary}")
            if found.resolve().is_relative_to(system.resolve()):
                continue
            target = bindir / name
            copy_dependency(found, target)
            if target not in seen:
                pending.append(target)


def linux_dependencies(path):
    text = output("ldd", path)
    if "not found" in text:
        raise RuntimeError(f"Unresolved native dependencies in {path}:\n{text}")
    return re.findall(r"\s*(\S+) => (/\S+) \(", text)


def bundle_linux(root, bindir):
    pending = list(binaries(root))
    seen = set()
    while pending:
        binary = pending.pop(0)
        if binary in seen:
            continue
        seen.add(binary)
        for name, source in linux_dependencies(binary):
            source = Path(source)
            # The desktop's graphics drivers, C library and distro libraries stay on the host.
            if source.resolve().is_relative_to(root.resolve()) or source.as_posix().startswith(("/usr/lib/", "/lib/", "/lib64/")):
                continue
            target = bindir / name
            copy_dependency(source, target)
            pending.append(target)
        relative = os.path.relpath(bindir, binary.parent)
        rpath = "$ORIGIN" if relative == "." else "$ORIGIN:$ORIGIN/" + relative
        subprocess.run(["patchelf", "--set-rpath", rpath, str(binary)], check=True)


def refresh_native_hashes(extensions):
    for file in extensions.rglob("*.rayext"):
        data = json.loads(file.read_text())
        for native in data.get("natives", {}).values():
            native["sha256"] = digest(file.parent / native["path"])
        file.write_text(json.dumps(data, indent=2) + "\n")


def layout(root, target):
    if target == "macos":
        return root / "Contents/MacOS", root / "Contents/Resources", root / "Contents/Resources/extensions", "RayDE", "rayzor"
    if target == "linux":
        return root / "lib/rayde", root / "lib/rayde", root / "share/rayde/extensions", "rayde", "rayzor"
    return root, root, root / "extensions", "RayDE.exe", "rayzor.exe"


def validate(root, target):
    bindir, data, extensions, program, rayzor = layout(root, target)
    host = "rayde-extension-host" + (".exe" if target == "windows" else "")
    required = [bindir / name for name in [program, host, "blinc_abi.hdll", "xgpu.hdll", "xwindow.hdll", "cterm.hdll", "rayscript.hdll"]]
    required += [data / rayzor, data / "haxe-std/Std.hx", data / "distribution.json", data / "notices/dependencies.json"]
    required += [extensions / name / (name + ".rayext") for name in ["git", "markdown", "rayzor"]]
    runtime = {"macos": "libhl.dylib", "linux": "libhl.so", "windows": "libhl.dll"}[target]
    required.append(bindir / runtime)
    for path in required:
        if not path.is_file() or not path.stat().st_size:
            raise RuntimeError(f"Missing distribution file: {path}")
    for manifest in extensions.rglob("*.rayext"):
        definition = json.loads(manifest.read_text())
        if not (manifest.parent / definition["main"]).is_file():
            raise RuntimeError(f"Missing extension entry point: {manifest}")
        for native in definition.get("natives", {}).values():
            if digest(manifest.parent / native["path"]) != native["sha256"]:
                raise RuntimeError(f"Native hash mismatch: {manifest}")
    if list(root.rglob("*.hl")):
        raise RuntimeError("AOT distributions must not contain development bytecode")
    for binary in binaries(root):
        if target == "macos":
            for dep in mac_dependencies(binary):
                if not mac_system(dep):
                    if not dep.startswith("@loader_path/") or not (binary.parent / dep[13:]).is_file():
                        raise RuntimeError(f"Non-relocatable dependency {dep} in {binary}")
            subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True)
        elif target == "linux":
            linux_dependencies(binary)
        else:
            for dep in windows_dependencies(binary):
                if not dep.lower().startswith(("api-ms-", "ext-ms-")) and not any((d / dep).is_file() for d in [binary.parent, bindir, Path(os.environ["SystemRoot"]) / "System32"]):
                    raise RuntimeError(f"Unbundled dependency {dep} in {binary}")


def finalize(root, target, version):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?", version):
        raise ValueError("RAYDE_VERSION must be a semantic version")
    bindir, data, extensions, _, _ = layout(root, target)
    {"macos": bundle_macos, "linux": bundle_linux, "windows": bundle_windows}[target](root, bindir)
    notices = data / "notices"
    lock = json.loads((SOURCE / "packaging/dependencies.json").read_text())
    shutil.copy2(SOURCE / "packaging/dependencies.json", notices / "dependencies.json")
    for name in lock["sources"]:
        source = SOURCE.parent / name
        destination = notices / name
        destination.mkdir(exist_ok=True)
        for license in source.glob("*LICENSE*"):
            if license.is_file():
                shutil.copy2(license, destination / license.name)
    for source, destination in [
        (SOURCE.parent / "rayzor/compiler/vendor/tinycc/COPYING", notices / "rayzor/tinycc.COPYING"),
        (SOURCE.parent / "hlwgpu/haxe/hlwgpu/hxsl/LICENSE.heaps", notices / "hlwgpu/LICENSE.heaps"),
    ]:
        if source.is_file():
            shutil.copy2(source, destination)
    ashui_revision = re.search(r"^ashui_rev=(\w+)$", (SOURCE / "scripts/deps.sh").read_text(), re.M)[1]
    ashui = Path(os.environ.get("ASHUI", SOURCE / ".deps" / ("ashui-" + ashui_revision)))
    for license in ashui.glob("*LICENSE*"):
        if license.is_file():
            (notices / "ashui").mkdir(exist_ok=True)
            shutil.copy2(license, notices / "ashui" / license.name)
    info = {"version": version, "platform": target, "architecture": platform.machine(),
            "commit": output("git", "-C", SOURCE, "rev-parse", "HEAD").strip(),
            "dirty": bool(output("git", "-C", SOURCE, "status", "--porcelain").strip()),
            "dependencies": {**lock["sources"], "ashui": ashui_revision},
            "haxe": output("haxe", "--version").strip(), "rust": output("rustc", "--version").strip()}
    (data / "distribution.json").write_text(json.dumps(info, indent=2) + "\n")
    refresh_native_hashes(extensions)
    if target == "macos":
        subprocess.run(["codesign", "--force", "--sign", "-", str(root)], check=True)
    validate(root, target)


def archive(root, target, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if target == "macos":
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(root), str(destination)], check=True)
    elif target == "windows":
        with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as package:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    package.write(path, root.name + "/" + path.relative_to(root).as_posix())
    else:
        with tarfile.open(destination, "w:gz") as package:
            package.add(root, arcname=root.name)
    destination.with_name(destination.name + ".sha256").write_text(f"{digest(destination)}  {destination.name}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--platform", choices=["macos", "linux", "windows"], required=True)
    parser.add_argument("--version", default=os.environ.get("RAYDE_VERSION", "0.1.0"))
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    if args.validate_only:
        validate(root, args.platform)
    else:
        finalize(root, args.platform, args.version)
    if args.archive:
        archive(root, args.platform, args.archive.resolve())
