package rayde.workspace;

import haxe.io.Bytes;

private enum Node {
	File(bytes:Bytes, mtime:Float);
	Dir(mtime:Float);
}

/** Files held in memory. A page keeps what a session has sent it in one, and a check runs RayDE against one. */
class MemoryWorkspace implements Workspace {
	final nodes = new Map<String, Node>();

	/** Called after every change, with the path and what happened: `write`, `mkdir`, `delete` or `rename` (of the destination). A page saves host storage from this. */
	public var onChange:Null<(String, String) -> Void>;

	public function new() {
		nodes.set("", Dir(Date.now().getTime()));
	}

	function changed(path:String, kind:String):Void if (onChange != null) onChange("/" + key(path), kind);

	/** Everything held, directories first, for saving. Paths are absolute. */
	public function entries():Array<{path:String, directory:Bool, bytes:Null<Bytes>}> {
		var names = [for (name in nodes.keys()) if (name != "") name];
		names.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		return [for (name in names) switch nodes.get(name) {
			case File(bytes, _): {path: "/" + name, directory: false, bytes: bytes};
			case Dir(_): {path: "/" + name, directory: true, bytes: null};
		}];
	}

	/** Puts entries from `entries` or from storage back, without telling `onChange`. */
	public function load(items:Array<{path:String, directory:Bool, bytes:Null<Bytes>}>):Void {
		var listener = onChange;
		onChange = null;
		for (item in items) if (item.directory) createDirectory(item.path) else saveBytes(item.path, item.bytes);
		onChange = listener;
	}

	/** `/`-separated, without trailing or doubled slashes and without `.` segments. */
	static function key(path:String):String {
		var parts:Array<String> = [];
		for (part in path.split("\\").join("/").split("/"))
			if (part == "..") parts.pop() else if (part != "" && part != ".") parts.push(part);
		return parts.join("/");
	}

	static function parent(key:String):String {
		var at = key.lastIndexOf("/");
		return at < 0 ? "" : key.substr(0, at);
	}

	public function exists(path:String):Bool return nodes.exists(key(path));

	public function isDirectory(path:String):Bool return switch nodes.get(key(path)) { case Dir(_): true; default: false; }

	public function readDirectory(path:String):Array<String> {
		var at = key(path);
		if (!isDirectory(at)) throw "Not a directory: " + path;
		var prefix = at == "" ? "" : at + "/", names = [];
		for (name in nodes.keys())
			if (name != at && name != "" && parent(name) == at) names.push(name.substr(prefix.length));
		names.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		return names;
	}

	public function stat(path:String):sys.FileStat {
		var node = nodes.get(key(path));
		if (node == null) throw "No such file: " + path;
		var time = switch node { case File(_, t): t; case Dir(t): t; }, size = switch node { case File(b, _): b.length; case Dir(_): 0; }, date = Date.fromTime(time);
		return {gid: 0, uid: 0, atime: date, mtime: date, ctime: date, size: size, dev: 0, ino: 0, nlink: 1, rdev: 0, mode: switch node { case File(_, _): 0x81a4; case Dir(_): 0x41ed; }};
	}

	public function fullPath(path:String):String return "/" + key(path);
	public function absolutePath(path:String):String return "/" + key(path);

	public function getBytes(path:String):Bytes
		return switch nodes.get(key(path)) {
			case File(bytes, _): bytes;
			case Dir(_): throw "Is a directory: " + path;
			case null: throw "No such file: " + path;
		}

	public function readFrom(path:String, offset:Int):Bytes {
		var bytes = getBytes(path);
		return offset >= bytes.length ? Bytes.alloc(0) : bytes.sub(offset, bytes.length - offset);
	}

	public function getContent(path:String):String return getBytes(path).toString();

	public function saveBytes(path:String, bytes:Bytes):Void {
		var at = key(path);
		if (isDirectory(at)) throw "Is a directory: " + path;
		createDirectory(parent(at));
		nodes.set(at, File(bytes, Date.now().getTime()));
		changed(at, "write");
	}

	public function saveContent(path:String, content:String):Void saveBytes(path, Bytes.ofString(content));

	public function createDirectory(path:String):Void {
		var at = key(path);
		if (nodes.exists(at)) {
			if (!isDirectory(at)) throw "Not a directory: " + path;
			return;
		}
		createDirectory(parent(at));
		nodes.set(at, Dir(Date.now().getTime()));
		changed(at, "mkdir");
	}

	public function deleteFile(path:String):Void {
		var at = key(path);
		switch nodes.get(at) {
			case File(_, _):
				nodes.remove(at);
				changed(at, "delete");
			case Dir(_): throw "Is a directory: " + path;
			case null: throw "No such file: " + path;
		}
	}

	public function deleteDirectory(path:String):Void {
		var at = key(path);
		if (at == "" || !isDirectory(at)) throw "Not a directory: " + path;
		if (readDirectory(at).length > 0) throw "Directory not empty: " + path;
		nodes.remove(at);
		changed(at, "delete");
	}

	public function rename(path:String, to:String):Void {
		var from = key(path), target = key(to);
		if (!nodes.exists(from)) throw "No such file: " + path;
		if (!isDirectory(parent(target))) throw "No such directory: " + to;
		for (name in [for (n in nodes.keys()) n])
			if (name == from || StringTools.startsWith(name, from + "/")) {
				var node = nodes.get(name);
				nodes.remove(name);
				nodes.set(target + name.substr(from.length), node);
				changed(name, "delete");
				changed(target + name.substr(from.length), "rename");
			}
	}

	public function copy(source:String, destination:String):Void saveBytes(destination, getBytes(source));
}
