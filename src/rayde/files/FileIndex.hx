package rayde.files;

import rayde.workspace.Fs;
import rayde.run.Worker;

/** A workspace path snapshot; directory traversal belongs to its data-only worker. */
class FileIndex {
	final worker = new Worker<Array<String>, Array<String>>(scan);
	public var paths(default, null):Array<String> = [];

	public function new() {}
	public function refresh(directories:Array<String>):Void worker.submit("files", directories.copy());
	public function busy():Bool return worker.busy();
	public function dispose():Void { worker.dispose(); paths = []; }

	/** Installs only changed snapshots on the caller's thread. */
	public function poll():Bool {
		var changed = false;
		for (result in worker.poll()) if (result.value != null) {
			var next = result.value, same = paths.length == next.length;
			if (same) for (i in 0...paths.length) if (paths[i] != next[i]) { same = false; break; }
			if (!same) { paths = next; changed = true; }
		}
		return changed;
	}

	static function scan(directories:Array<String>, cancelled:Void->Bool):Array<String> {
		var paths:Array<String> = [], seen = new Map<String, Bool>();
		function walk(dir:String):Void {
			if (cancelled()) return;
			var real:String, names:Array<String>;
			try {
				real = Fs.fullPath(dir);
				names = Fs.readDirectory(dir);
			} catch (_:Dynamic) { return; }
			if (seen.exists(real)) return;
			seen.set(real, true);
			names.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
			for (name in names) {
				if (cancelled()) return;
				if (StringTools.startsWith(name, ".")) continue;
				var path = haxe.io.Path.join([dir, name]), directory:Bool;
				try directory = Fs.isDirectory(path) catch (_:Dynamic) { continue; }
				if (directory) walk(path); else paths.push(path);
			}
		}
		for (dir in directories) walk(dir);
		return paths;
	}
}
