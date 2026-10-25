package rayde.workspace;

import haxe.io.Bytes;

/**
 * Several workspaces under one tree: a path goes to the workspace mounted at its longest matching prefix.
 * In a page the session's folder is one mount and the browser's own storage, for settings, themes and built-in extensions, is the rest.
 * Mounts are given absolute paths and the workspaces they hold are called with the same absolute paths.
 */
class RoutedWorkspace implements Workspace {
	final mounts:Array<{prefix:String, workspace:Workspace}> = [];
	final fallback:Workspace;

	public function new(fallback:Workspace) {
		this.fallback = fallback;
	}

	/** Paths at or under `prefix` go to `workspace`. A later mount at a longer prefix takes what is under it. */
	public function mount(prefix:String, workspace:Workspace):Void {
		var at = normalize(prefix);
		mounts.push({prefix: at, workspace: workspace});
		mounts.sort((a, b) -> b.prefix.length - a.prefix.length);
	}

	static function normalize(path:String):String {
		var parts:Array<String> = [];
		for (part in path.split("\\").join("/").split("/"))
			if (part == "..") parts.pop() else if (part != "" && part != ".") parts.push(part);
		return "/" + parts.join("/");
	}

	function route(path:String):Workspace {
		var full = normalize(path);
		for (mount in mounts)
			if (full == mount.prefix || StringTools.startsWith(full, mount.prefix == "/" ? "/" : mount.prefix + "/")) return mount.workspace;
		return fallback;
	}

	public function exists(path:String):Bool return route(path).exists(path);
	public function isDirectory(path:String):Bool return route(path).isDirectory(path);
	public function readDirectory(path:String):Array<String> {
		var names = route(path).readDirectory(path), here = normalize(path);
		// A mount point inside this directory is an entry of it, whichever workspace holds the directory.
		for (mount in mounts) {
			var at = mount.prefix.lastIndexOf("/");
			if ((at == 0 ? "/" : mount.prefix.substr(0, at)) == here && mount.prefix != "/" && names.indexOf(mount.prefix.substr(at + 1)) < 0) names.push(mount.prefix.substr(at + 1));
		}
		return names;
	}
	public function stat(path:String):sys.FileStat return route(path).stat(path);
	public function fullPath(path:String):String return route(path).fullPath(path);
	public function absolutePath(path:String):String return route(path).absolutePath(path);
	public function getContent(path:String):String return route(path).getContent(path);
	public function getBytes(path:String):Bytes return route(path).getBytes(path);
	public function readFrom(path:String, offset:Int):Bytes return route(path).readFrom(path, offset);
	public function saveContent(path:String, content:String):Void route(path).saveContent(path, content);
	public function saveBytes(path:String, bytes:Bytes):Void route(path).saveBytes(path, bytes);
	public function createDirectory(path:String):Void route(path).createDirectory(path);
	public function deleteFile(path:String):Void route(path).deleteFile(path);
	public function deleteDirectory(path:String):Void route(path).deleteDirectory(path);

	public function rename(path:String, to:String):Void {
		var from = route(path), target = route(to);
		if (from != target) throw "A file cannot be renamed across workspaces: " + path;
		from.rename(path, to);
	}

	public function copy(source:String, destination:String):Void {
		var from = route(source), target = route(destination);
		if (from == target) from.copy(source, destination);
		else target.saveBytes(destination, from.getBytes(source));
	}
}
