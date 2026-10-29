package rayde.files;

import rayde.workspace.Fs;
import rayde.run.Worker;
import haxe.io.Path;

private typedef Scan = {directories:Array<String>, scope:Null<String>, limit:Int};
private typedef Snapshot = {paths:Array<String>, limited:Bool};

/** A workspace path snapshot; directory traversal belongs to its data-only worker. */
class FileIndex {
	static inline var MAX_ENTRIES = 50000;
	static inline var MAX_DEPTH = 128;
	final worker = new Worker<Scan, Snapshot>(scan);
	final limit:Int;
	public var paths(default, null):Array<String> = [];
	public var limited(default, null) = false;

	public function new(limit = MAX_ENTRIES) this.limit = Std.int(Math.max(1, Math.min(MAX_ENTRIES, limit)));
	public function refresh(directories:Array<String>, ?scope:String):Void worker.submit("files", {directories:directories.copy(),scope:scope,limit:limit});
	public function busy():Bool return worker.busy();
	public function dispose():Void { worker.dispose(); paths = []; limited = false; }

	/** Source folders precede the workspace; external class paths stay in Dependencies. */
	public static function directories(root:String, args:Array<String>):Array<String> {
		root = Path.removeTrailingSlashes(Path.normalize(root));
		var base = root, out:Array<String> = [], seen = new Map<String, Bool>();
		for (i in 0...args.length - 1) {
			var value = args[i + 1];
			if (args[i] == "--cwd") base = Path.normalize(Path.isAbsolute(value) ? value : Path.join([base,value]));
			else if (["-cp","-p","--class-path"].indexOf(args[i]) >= 0) {
				var dir = Path.removeTrailingSlashes(Path.normalize(Path.isAbsolute(value) ? value : Path.join([base,value])));
				if (FileOps.inside(root,dir) && !seen.exists(dir)) { out.push(dir); seen.set(dir,true); }
			}
		}
		if (!seen.exists(root)) out.push(root);
		return out;
	}

	/** Installs only changed snapshots on the caller's thread. */
	public function poll():Bool {
		var changed = false;
		for (result in worker.poll()) if (result.value != null) {
			var next = result.value.paths, same = paths.length == next.length;
			if (same) for (i in 0...paths.length) if (paths[i] != next[i]) { same = false; break; }
			if (!same) { paths = next; changed = true; }
			if (limited != result.value.limited) { limited = result.value.limited; changed = true; }
		}
		return changed;
	}

	static function scan(request:Scan, cancelled:Void->Bool):Snapshot {
		var paths:Array<String> = [], seen = new Map<String, Bool>(), ignore:Null<GitIgnore> = null, entries = 0, limited = false;
		var scope = try request.scope == null ? null : Fs.fullPath(request.scope) catch (_:Dynamic) return {paths:paths,limited:false};
		function walk(dir:String, depth:Int):Void {
			if (cancelled() || limited && entries >= request.limit) return;
			if (depth > MAX_DEPTH) { limited = true; return; }
			var real:String, names:Array<String>;
			try {
				real = Fs.fullPath(dir);
				if ((scope != null && !FileOps.inside(scope, real)) || seen.exists(real)) return;
				seen.set(real, true);
				names = Fs.readDirectory(dir);
			} catch (_:Dynamic) { return; }
			names.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
			for (name in names) {
				if (cancelled()) return;
				if (name == ".git" || name == ".haxelib" || name == ".rayde" || name == ".rayzor" || name == ".deps") continue;
				if (entries >= request.limit) { limited = true; return; }
				entries++;
				var path = Path.join([dir, name]), directory:Bool;
				try {
					if (scope != null && !FileOps.inside(scope,Fs.fullPath(path))) continue;
					directory = Fs.isDirectory(path);
					if (ignore != null && ignore.ignored(path)) continue;
				} catch (_:Dynamic) { continue; }
				if (directory) walk(path,depth + 1); else paths.push(path);
			}
		}
		for (dir in request.directories) {
			if (cancelled() || limited && entries >= request.limit) break;
			ignore = new GitIgnore(request.scope == null ? dir : request.scope); walk(dir,0);
		}
		return {paths:paths,limited:limited};
	}
}
