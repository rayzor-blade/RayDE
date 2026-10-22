import rayde.files.FileIndex;

class FileIndexChecks {
	public static function run():Void {
		var root = Sys.getCwd() + "bin/check-file-index";
		for (dir in [root, root + "/src", root + "/.hidden"]) sys.FileSystem.createDirectory(dir);
		for (file in [root + "/src/Later.hx", root + "/src/B.hx"]) if (sys.FileSystem.exists(file)) sys.FileSystem.deleteFile(file);
		sys.io.File.saveContent(root + "/src/A.hx", "class A {}");
		sys.io.File.saveContent(root + "/src/readme.md", "# Example");
		sys.io.File.saveContent(root + "/.hidden/Secret.hx", "class Secret {}");
		var index = new FileIndex();
		function settle():Bool {
			var changed = false, until = haxe.Timer.stamp() + 5;
			while (index.busy() && haxe.Timer.stamp() < until) { changed = index.poll() || changed; Sys.sleep(.002); }
			changed = index.poll() || changed;
			if (index.busy()) throw "File index did not finish";
			return changed;
		}
		index.refresh([root, root + "/src", root + "/missing"]);
		if (index.paths.length != 0) throw "Worker mutated the UI snapshot";
		if (!settle() || index.paths.join(",") != root + "/src/A.hx," + root + "/src/readme.md") throw "Index lost order, duplicated overlapping roots or included hidden files: " + haxe.Json.stringify(index.paths);
		var previous = index.paths;
		index.refresh([root]);
		if (settle() || index.paths != previous) throw "Unchanged scan replaced the snapshot";
		sys.io.File.saveContent(root + "/src/Later.hx", "class Later {}");
		index.refresh([root]);
		if (index.paths != previous || !settle() || index.paths.indexOf(root + "/src/Later.hx") < 0) throw "Asynchronous refresh lost a new file";
		index.refresh([root]); index.refresh([root + "/missing"]);
		settle();
		if (index.paths.length != 0) throw "Index delivered a superseded scan";
		index.dispose(); index.refresh([root]);
		if (index.busy() || index.paths.length != 0) throw "Disposed index retained paths or accepted work";
		Sys.println("file index: asynchronous snapshots, sorted paths, overlapping roots, hidden files, refresh, supersession and disposal");
	}
}
