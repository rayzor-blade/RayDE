package rayde.settings;

import rayde.workspace.Fs;
import rayde.run.Worker;

typedef EditorLayoutSession = {
	?files:Array<String>, ?active:String,
	?direction:String, ?ratio:Float, ?first:EditorLayoutSession, ?second:EditorLayoutSession
};
typedef TabSession = {files:Array<String>, active:String, ?layout:EditorLayoutSession, ?group:Int};
private typedef Write = {file:String, temporary:String, session:TabSession, mutex:sys.thread.Mutex};

/** Workspace tab metadata, independent of editor instances and document contents. */
class WorkspaceSession {
	final file:String;
	final temporary:String;
	final mutex = new sys.thread.Mutex();
	final worker = new Worker<Write, Bool>(write);

	public function new(root:String, project:String, ?storageRoot:String) {
		var prefix = haxe.io.Path.addTrailingSlash(root);
		var key = StringTools.startsWith(project, prefix) ? project.substr(prefix.length) : project == root ? "." : project;
		file = (storageRoot ?? root) + "/.rayde/sessions/" + haxe.crypto.Sha256.encode(key) + ".json";
		temporary = file + ".tmp-" + Std.random(0x3fffffff);
	}

	public function read():Null<TabSession> {
		try {
			if (!Fs.exists(file) || Fs.stat(file).size > 256 * 1024) return null;
			var data:Dynamic = haxe.Json.parse(Fs.getContent(file));
			if (data.version != 1 || !Std.isOfType(data.files, Array) || !Std.isOfType(data.active, String)) return null;
			var files:Array<String> = [];
			for (entry in (data.files:Array<Dynamic>)) if (Std.isOfType(entry, String) && entry != "" && files.indexOf(entry) < 0) files.push(entry);
			var layout = readLayout(data.layout);
			var active = files.indexOf(data.active) >= 0 || data.active == "" && layout != null ? data.active : files.length == 0 ? "" : files[0];
			return {files:files, active:active, layout:layout, group:Std.isOfType(data.group, Int) ? data.group : 0};
		} catch (_:Dynamic) return null;
	}

	static function readLayout(value:Dynamic, depth = 0):Null<EditorLayoutSession> {
		if (value == null || depth > 8 || !Reflect.isObject(value) || Std.isOfType(value, Array)) return null;
		if (value.direction == "horizontal" || value.direction == "vertical") {
			var first = readLayout(value.first, depth + 1), second = readLayout(value.second, depth + 1);
			if (first == null || second == null) return null;
			var ratio:Float = Std.isOfType(value.ratio, Float) && Math.isFinite(value.ratio) ? value.ratio : .5;
			return {direction:value.direction, ratio:Math.max(.1, Math.min(.9, ratio)), first:first, second:second};
		}
		if (!Std.isOfType(value.files, Array) || !Std.isOfType(value.active, String)) return null;
		return {files:[for (entry in (value.files:Array<Dynamic>)) if (Std.isOfType(entry, String)) entry], active:value.active};
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
				Fs.createDirectory(haxe.io.Path.directory(request.file));
				Fs.saveContent(request.temporary, haxe.Json.stringify({version:1, files:request.session.files, active:request.session.active, layout:request.session.layout, group:request.session.group}));
				Fs.rename(request.temporary, request.file);
			}
		} catch (_:Dynamic) { request.mutex.release(); return false; }
		request.mutex.release();
		return true;
	}
}
