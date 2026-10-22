package rayde.settings;

import rayde.run.Worker;

typedef TabSession = {files:Array<String>, active:String};
private typedef Write = {file:String, temporary:String, session:TabSession, mutex:sys.thread.Mutex};

/** Workspace tab metadata, independent of editor instances and document contents. */
class WorkspaceSession {
	final file:String;
	final temporary:String;
	final mutex = new sys.thread.Mutex();
	final worker = new Worker<Write, Bool>(write);

	public function new(root:String, project:String) {
		var prefix = haxe.io.Path.addTrailingSlash(root);
		var key = StringTools.startsWith(project, prefix) ? project.substr(prefix.length) : project == root ? "." : project;
		file = root + "/.rayde/sessions/" + haxe.crypto.Sha256.encode(key) + ".json";
		temporary = file + ".tmp-" + Std.random(0x3fffffff);
	}

	public function read():Null<TabSession> {
		try {
			if (!sys.FileSystem.exists(file) || sys.FileSystem.stat(file).size > 256 * 1024) return null;
			var data:Dynamic = haxe.Json.parse(sys.io.File.getContent(file));
			if (data.version != 1 || !Std.isOfType(data.files, Array) || !Std.isOfType(data.active, String)) return null;
			var files:Array<String> = [];
			for (entry in (data.files:Array<Dynamic>)) if (Std.isOfType(entry, String) && entry != "" && files.indexOf(entry) < 0) files.push(entry);
			return {files:files, active:files.indexOf(data.active) < 0 ? files.length == 0 ? "" : files[0] : data.active};
		} catch (_:Dynamic) return null;
	}

	public function save(session:TabSession):Void worker.submit("tabs", {file:file, temporary:temporary, session:session, mutex:mutex});

	/** The final checkpoint completes before the process exits; cancelled older writes cannot replace it. */
	public function close(session:Null<TabSession>):Void {
		worker.cancel("tabs");
		if (session != null) write({file:file, temporary:temporary, session:session, mutex:mutex}, () -> false);
		worker.dispose();
	}

	static function write(request:Write, cancelled:Void->Bool):Bool {
		request.mutex.acquire();
		try {
			if (!cancelled()) {
				sys.FileSystem.createDirectory(haxe.io.Path.directory(request.file));
				sys.io.File.saveContent(request.temporary, haxe.Json.stringify({version:1, files:request.session.files, active:request.session.active}));
				sys.FileSystem.rename(request.temporary, request.file);
			}
		} catch (_:Dynamic) { request.mutex.release(); return false; }
		request.mutex.release();
		return true;
	}
}
