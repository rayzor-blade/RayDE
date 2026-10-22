package rayde.settings;

/** User-wide project entry points, newest first; file contents are never cached. */
class RecentProjects {
	static inline var LIMIT = 20;

	public static function paths(?home:String):Array<String> {
		var saved:Dynamic = Store.section(home ?? Extensions.home(), "recentProjects").paths;
		var result:Array<String> = [];
		if (Std.isOfType(saved, Array)) for (entry in (saved:Array<Dynamic>)) {
			if (!Std.isOfType(entry, String)) continue;
			var file:String = entry;
			try {
				if (haxe.io.Path.isAbsolute(file) && sys.FileSystem.exists(file) && !sys.FileSystem.isDirectory(file) && result.indexOf(file) < 0)
					result.push(file);
			} catch (_:Dynamic) {}
			if (result.length == LIMIT) break;
		}
		return result;
	}

	public static function remember(file:String, ?home:String):Void {
		try {
			file = sys.FileSystem.fullPath(file);
			if (!sys.FileSystem.exists(file) || sys.FileSystem.isDirectory(file)) return;
			var previous = paths(home); previous.remove(file); previous.unshift(file);
			Store.save(home ?? Extensions.home(), "recentProjects", {paths:previous.slice(0, LIMIT)});
		} catch (_:Dynamic) {}
	}
}
