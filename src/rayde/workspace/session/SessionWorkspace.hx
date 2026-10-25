package rayde.workspace.session;

import haxe.crypto.Base64;
import haxe.io.Bytes;

/**
 * The files of a session, as `Workspace` calls. The session reports its root, and a path under it is a path in the session;
 * programs the session runs see the same paths, so a path RayDE builds is one they can use.
 */
class SessionWorkspace implements Workspace {
	final client:SessionClient;
	final mount:String;

	public function new(client:SessionClient) {
		this.client = client;
		mount = normalize(client.root);
	}

	/** `/`-separated, absolute, without `.` or `..` segments or a trailing slash. */
	static function normalize(path:String):String {
		var parts:Array<String> = [];
		for (part in path.split("\\").join("/").split("/"))
			if (part == "..") parts.pop() else if (part != "" && part != ".") parts.push(part);
		return "/" + parts.join("/");
	}

	/** The session's own name for `path`. */
	function inside(path:String):String {
		var full = normalize(path);
		if (full == mount) return "";
		if (StringTools.startsWith(full, mount + "/")) return full.substr(mount.length + 1);
		throw "Not in the session's workspace: " + path;
	}

	function entry(path:String):Null<Dynamic> return client.request("fs.stat", {path: inside(path)}).entry;

	public function exists(path:String):Bool return entry(path) != null;

	public function isDirectory(path:String):Bool {
		var found = entry(path);
		return found != null && found.kind == "dir";
	}

	public function readDirectory(path:String):Array<String> {
		var names:Array<String> = [for (item in (client.request("fs.list", {path: inside(path)}).entries : Array<Dynamic>)) item.name];
		return names;
	}

	public function stat(path:String):sys.FileStat {
		var found = entry(path);
		if (found == null) throw "No such file: " + path;
		var date = Date.fromTime(found.mtime);
		return {gid: 0, uid: 0, atime: date, mtime: date, ctime: date, size: found.size, dev: 0, ino: 0, nlink: 1, rdev: 0, mode: found.kind == "dir" ? 0x41ed : 0x81a4};
	}

	public function fullPath(path:String):String return normalize(path);
	public function absolutePath(path:String):String return normalize(path);

	public function getContent(path:String):String {
		var found = entry(path);
		if (found == null) throw "No such file: " + path;
		if (found.kind != "file") throw "Not a file: " + path;
		// The session decodes with replacement characters; bytes are exact, so text is decoded here.
		return getBytes(path).toString();
	}

	public function getBytes(path:String):Bytes return Base64.decode(client.request("fs.read", {path: inside(path), encoding: "base64"}).data);

	public function readFrom(path:String, offset:Int):Bytes return Base64.decode(client.request("fs.read", {path: inside(path), encoding: "base64", offset: offset}).data);

	public function saveContent(path:String, content:String):Void client.request("fs.write", {path: inside(path), data: content});

	public function saveBytes(path:String, bytes:Bytes):Void client.request("fs.write", {path: inside(path), data: Base64.encode(bytes), encoding: "base64"});

	public function createDirectory(path:String):Void client.request("fs.mkdir", {path: inside(path)});

	public function deleteFile(path:String):Void {
		if (isDirectory(path)) throw "Is a directory: " + path;
		client.request("fs.remove", {path: inside(path)});
	}

	public function deleteDirectory(path:String):Void {
		if (!isDirectory(path)) throw "Not a directory: " + path;
		client.request("fs.remove", {path: inside(path)});
	}

	public function rename(path:String, to:String):Void {
		// The session creates a missing destination directory; the contract does not.
		if (!isDirectory(haxe.io.Path.directory(normalize(to)))) throw "No such directory: " + to;
		client.request("fs.rename", {from: inside(path), to: inside(to)});
	}

	public function copy(source:String, destination:String):Void saveBytes(destination, getBytes(source));
}
