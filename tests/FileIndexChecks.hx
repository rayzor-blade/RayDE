import rayde.files.FileIndex;
import rayde.workspace.Fs;

private class ScopedFiles extends rayde.workspace.MemoryWorkspace {
	public var outside = 0;
	public var reads = 0;
	public function new() super();
	override public function exists(path:String):Bool {
		if (!rayde.files.FileOps.inside("/remote/workspace",path)) { outside++; throw "Outside mount"; }
		return super.exists(path);
	}
	override public function readDirectory(path:String):Array<String> { reads++; return super.readDirectory(path); }
}

class FileIndexChecks {
	static function settle(index:FileIndex):Bool {
		var changed = false, until = haxe.Timer.stamp() + 5;
		while (index.busy() && haxe.Timer.stamp() < until) { changed = index.poll() || changed; Sys.sleep(.002); }
		changed = index.poll() || changed;
		if (index.busy()) throw "File index did not finish";
		return changed;
	}

	public static function run():Void {
		var root = Sys.getCwd() + "bin/check-file-index-" + Std.random(0x3fffffff), outside = root + "-dependency";
		var wanted = ["src/A.hx", "src/readme.md", ".github/ci.yml", ".gitignore", ".hidden/Secret.hx", "README.md", "build.hxml", "data/tasks.json", "extensions/tools/ext/main.rays"];
		var excluded = [".git/config", ".haxelib/cache", ".rayde/settings.json", ".rayzor/cache", ".deps/library/A.hx", "generated/cache.txt"];
		for (file in wanted.concat(excluded).concat(["src/ignored.tmp"])) {
			sys.FileSystem.createDirectory(haxe.io.Path.directory(root + "/" + file));
			sys.io.File.saveContent(root + "/" + file, "fixture");
		}
		sys.io.File.saveContent(root + "/.gitignore", "generated/\n*.tmp\n");
		sys.FileSystem.createDirectory(outside);
		sys.io.File.saveContent(outside + "/External.hx", "class External {}");
		if (Sys.systemName() != "Windows") Sys.command("ln", ["-s",outside,root + "/linked"]);
		var dirs = FileIndex.directories(root,["-cp","src","-cp",outside,"--class-path","src","--cwd","data","-p","../extensions"]);
		if (dirs.join(",") != [root + "/src",root + "/extensions",root].join(",")) throw "Source priority or external class path filtering failed";
		var index = new FileIndex();
		var scan = () -> index.refresh(dirs.concat([root + "/missing",outside]),root);
		scan();
		if (index.paths.length != 0) throw "Worker mutated the UI snapshot";
		if (!settle(index) || index.limited || index.paths.length != wanted.length) throw "Catalog omitted files, duplicated roots or included ignored/external files: " + haxe.Json.stringify(index.paths);
		for (file in wanted) if (index.paths.indexOf(root + "/" + file) < 0) throw "Catalog omitted " + file;
		if (index.paths[0] != root + "/src/A.hx" || index.paths[2] != root + "/extensions/tools/ext/main.rays") throw "Source roots lost priority";
		var previous = index.paths;
		scan();
		if (settle(index) || index.paths != previous) throw "Unchanged scan replaced the snapshot";
		sys.io.File.saveContent(root + "/src/Later.hx", "class Later {}");
		scan();
		if (index.paths != previous || !settle(index) || index.paths.indexOf(root + "/src/Later.hx") < 0) throw "Asynchronous refresh lost a new file";
		scan(); index.refresh([root + "/missing"],root); settle(index);
		if (index.paths.length != 0) throw "Index delivered a superseded scan";
		index.dispose(); scan();
		if (index.busy() || index.paths.length != 0) throw "Disposed index retained paths or accepted work";

		var original = Fs.current, memory = new ScopedFiles();
		Fs.current = memory;
		try {
			for (file in ["README.md","config.json","src/Main.hx"]) memory.saveContent("/remote/workspace/" + file,"fixture");
			var remote = new FileIndex(); remote.refresh(["/remote/workspace"],"/remote/workspace"); settle(remote);
			if (remote.paths.length != 3 || memory.outside != 1) throw "Non-Git remote mount: paths=" + remote.paths.join(",") + ", boundary probes=" + memory.outside;
			remote.dispose();
			memory.reads = 0;
			var bounded = new FileIndex(1); bounded.refresh(["/remote/workspace","/remote/workspace/src"],"/remote/workspace"); settle(bounded);
			if (!bounded.limited || bounded.paths.length != 1 || memory.reads != 1) throw "Scan budget did not stop traversal";
			memory.deleteFile("/remote/workspace/config.json"); memory.deleteFile("/remote/workspace/src/Main.hx"); memory.deleteDirectory("/remote/workspace/src");
			bounded.refresh(["/remote/workspace"],"/remote/workspace");
			if (!settle(bounded) || bounded.limited) throw "Completed catalog retained truncation feedback";
			bounded.dispose();
			var deep = "/remote/workspace";
			for (_ in 0...140) deep += "/nested";
			memory.saveContent(deep + "/end.txt","fixture");
			var depth = new FileIndex(); depth.refresh(["/remote/workspace"],"/remote/workspace"); settle(depth);
			if (!depth.limited || depth.paths.indexOf(deep + "/end.txt") >= 0) throw "Scan depth was not bounded";
			depth.dispose();
		} catch (error:Dynamic) { Fs.current = original; throw error; }
		Fs.current = original;
		Sys.println("file index: workspace files, source priority, ignores, symlink scope, bounded traversal, remote mounts, refresh, supersession and disposal");
	}
}
