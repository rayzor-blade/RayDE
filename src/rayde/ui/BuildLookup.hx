package rayde.ui;

import rayde.workspace.Fs;

typedef BuildLookupRequest = {root:String, paths:Array<String>, main:String};
typedef BuildLookupResult = {main:String, found:Null<String>, folders:Map<String,Bool>, suggestions:Array<String>};

/** Filesystem suggestions are optional, bounded work; the build form does not wait for them. */
class BuildLookup {
	static final skipped = ["bin","dist","target","node_modules","vendor","build","out"];
	public static function scan(request:BuildLookupRequest, cancelled:Void->Bool):BuildLookupResult {
		var result:BuildLookupResult = {main:request.main, found:null, folders:new Map(), suggestions:[]};
		for (cp in request.paths) {
			if (cancelled()) return result;
			var path = haxe.io.Path.isAbsolute(cp) ? cp : haxe.io.Path.join([request.root,cp]);
			try result.folders.set(cp,Fs.exists(path) && Fs.isDirectory(path)) catch (_:Dynamic) result.folders.set(cp,false);
			if (request.main != "" && result.found == null) try {
				var file = haxe.io.Path.join([path,request.main.split(".").join("/") + ".hx"]);
				if (Fs.exists(file)) result.found = file;
			} catch (_:Dynamic) {}
		}
		var left = 512, seen = new Map<String,Bool>();
		function holdsHaxe(dir:String, depth:Int):Bool {
			if (depth == 0 || cancelled() || left <= 0) return false;
			var real = try Fs.fullPath(dir) catch (_:Dynamic) dir;
			if (seen.exists(real)) return false; seen.set(real,true);
			var names = try Fs.readDirectory(dir) catch (_:Dynamic) [];
			for (name in names) {
				if (cancelled() || --left < 0) return false;
				if (StringTools.startsWith(name,".") || skipped.indexOf(name) >= 0) continue;
				var path = haxe.io.Path.join([dir,name]);
				try { if (Fs.isDirectory(path) ? holdsHaxe(path,depth-1) : StringTools.endsWith(name.toLowerCase(),".hx")) return true; } catch (_:Dynamic) {}
			}
			return false;
		}
		var names = try Fs.readDirectory(request.root) catch (_:Dynamic) [];
		// The worker's comparator has an explicit call target.
		names.sort((a,b) -> a < b ? -1 : a > b ? 1 : 0);
		for (name in names) {
			if (cancelled() || --left < 0) break;
			if (StringTools.startsWith(name,".") || skipped.indexOf(name) >= 0 || request.paths.indexOf(name) >= 0) continue;
			var path = haxe.io.Path.join([request.root,name]);
			try { if (Fs.isDirectory(path) && holdsHaxe(path,3)) result.suggestions.push(name); } catch (_:Dynamic) {}
		}
		return result;
	}
}
