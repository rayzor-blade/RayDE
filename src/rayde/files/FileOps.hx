package rayde.files;

using StringTools;

/**
 * What the Explorer's menus do to files and folders. Each change says in a sentence why it could not be made, as an
 * exception, and none reaches outside the project's folder.
 */
class FileOps {
	/** Why `name` cannot be the name of a file or folder, or null when it can. */
	public static function invalid(name:String):Null<String> {
		if (name == "")
			return "Give it a name.";
		if (name == "." || name == "..")
			return "That is not a name.";
		if (name.indexOf("/") >= 0 || name.indexOf("\\") >= 0)
			return "A name cannot hold a slash.";
		if (name != name.trim())
			return "A name cannot start or end with a space.";
		if (name.length > 255)
			return "That name is too long.";
		for (i in 0...name.length)
			if (name.charCodeAt(i) < 32)
				return "A name cannot hold a control character.";
		return null;
	}

	/** Whether `path` is `root` or inside it, so nothing outside the project is touched. */
	public static function inside(root:String, path:String):Bool {
		var r = haxe.io.Path.removeTrailingSlashes(haxe.io.Path.normalize(root)), p = haxe.io.Path.removeTrailingSlashes(haxe.io.Path.normalize(path));
		return p == r || p.startsWith(r + "/");
	}

	static function guard(root:String, path:String):Void
		if (!inside(root, path))
			throw "That is outside the project.";

	static function check(name:String):Void {
		var why = invalid(name);
		if (why != null)
			throw why;
	}

	/** Makes an empty file called `name` in `dir`, and gives its path. */
	public static function createFile(root:String, dir:String, name:String):String {
		guard(root, dir);
		check(name);
		var path = haxe.io.Path.join([dir, name]);
		if (sys.FileSystem.exists(path))
			throw '$name is already there.';
		sys.io.File.saveContent(path, "");
		return path;
	}

	/** Makes a folder called `name` in `dir`, and gives its path. */
	public static function createFolder(root:String, dir:String, name:String):String {
		guard(root, dir);
		check(name);
		var path = haxe.io.Path.join([dir, name]);
		if (sys.FileSystem.exists(path))
			throw '$name is already there.';
		sys.FileSystem.createDirectory(path);
		return path;
	}

	/** Renames a file or folder within its folder, and gives the new path. A change of capitals alone is allowed. */
	public static function rename(root:String, path:String, name:String):String {
		guard(root, path);
		if (haxe.io.Path.removeTrailingSlashes(haxe.io.Path.normalize(path)) == haxe.io.Path.removeTrailingSlashes(haxe.io.Path.normalize(root)))
			throw "The project's own folder cannot be renamed here.";
		check(name);
		var dir = haxe.io.Path.directory(haxe.io.Path.removeTrailingSlashes(path)), target = haxe.io.Path.join([dir, name]);
		var same = haxe.io.Path.withoutDirectory(haxe.io.Path.removeTrailingSlashes(path)).toLowerCase() == name.toLowerCase();
		if (sys.FileSystem.exists(target) && !same)
			throw '$name is already there.';
		sys.FileSystem.rename(path, target);
		return target;
	}

	/** Deletes a file, or a folder and all it holds. */
	public static function delete(root:String, path:String):Void {
		guard(root, path);
		if (haxe.io.Path.removeTrailingSlashes(haxe.io.Path.normalize(path)) == haxe.io.Path.removeTrailingSlashes(haxe.io.Path.normalize(root)))
			throw "The project's own folder cannot be deleted here.";
		remove(path);
	}

	static function remove(path:String):Void {
		if (sys.FileSystem.isDirectory(path)) {
			for (entry in sys.FileSystem.readDirectory(path))
				remove(haxe.io.Path.join([path, entry]));
			sys.FileSystem.deleteDirectory(path);
		} else
			sys.FileSystem.deleteFile(path);
	}

	/** What deleting `path` would take, in a few words: the file, or the folder with the number of files in it. */
	public static function summary(path:String):String {
		var name = haxe.io.Path.withoutDirectory(haxe.io.Path.removeTrailingSlashes(path));
		if (!sys.FileSystem.isDirectory(path))
			return name;
		var files = 0;
		function walk(dir:String):Void
			for (entry in sys.FileSystem.readDirectory(dir)) {
				var p = haxe.io.Path.join([dir, entry]);
				if (sys.FileSystem.isDirectory(p))
					walk(p);
				else
					files++;
			}
		walk(path);
		return name + (files == 0 ? " (empty)" : files == 1 ? " (1 file)" : ' ($files files)');
	}

	/** Where each of `files` is once `from` has been moved to `to`: those that are `from` or inside it, with the new path. */
	public static function moved(files:Array<String>, from:String, to:String):Map<String, String> {
		var out = new Map<String, String>();
		var f = haxe.io.Path.removeTrailingSlashes(from);
		for (file in files)
			if (file == f)
				out.set(file, to);
			else if (file.startsWith(f + "/"))
				out.set(file, haxe.io.Path.removeTrailingSlashes(to) + file.substr(f.length));
		return out;
	}

	/** The files among `files` that are `path` or inside it. */
	public static function under(files:Array<String>, path:String):Array<String> {
		var p = haxe.io.Path.removeTrailingSlashes(path);
		return [for (f in files) if (f == p || f.startsWith(p + "/")) f];
	}

	/** `path` from `root`, as written in the project. */
	public static function relative(root:String, path:String):String {
		var r = haxe.io.Path.addTrailingSlash(root);
		return path.startsWith(r) ? path.substr(r.length) : path;
	}

	/** Shows `path` in the system's file manager. */
	public static function reveal(path:String):Void
		switch Sys.systemName() {
			case "Mac": Sys.command("open", ["-R", path]);
			case "Windows": Sys.command("explorer", ["/select," + StringTools.replace(path, "/", "\\")]);
			case _: Sys.command("xdg-open", [sys.FileSystem.isDirectory(path) ? path : haxe.io.Path.directory(path)]);
		}
}
