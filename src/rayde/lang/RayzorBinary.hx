package rayde.lang;

/** Finds the packaged server, an installed server, or the existing sibling development build. */
class RayzorBinary {
	static function existing(paths:Array<String>):Null<String> {
		for (path in paths) if (sys.FileSystem.exists(path) && !sys.FileSystem.isDirectory(path)) return sys.FileSystem.fullPath(path);
		return null;
	}

	public static function find():Null<String> {
		var named = Sys.getEnv("RAYZOR_LSP");
		if (named != null && named != "") return named;
		var name = Sys.systemName() == "Windows" ? "rayzor.exe" : "rayzor";
		var program = haxe.io.Path.directory(Sys.programPath());
		var bundled = existing([program + "/" + name, program + "/../Resources/" + name]);
		if (bundled != null) return bundled;
		var path = Sys.getEnv("PATH");
		if (path != null) {
			var installed = existing([for (dir in path.split(Sys.systemName() == "Windows" ? ";" : ":")) if (dir != "") dir + "/" + name]);
			if (installed != null) return installed;
		}
		return existing([for (root in [program + "/../../rayzor", Sys.getCwd() + "/../rayzor"]) for (profile in ["release", "debug"]) root + "/target/" + profile + "/" + name]);
	}

	public static function standardLibrary(executable:String):Null<String> {
		var dir = haxe.io.Path.directory(executable);
		if (dir == "") return null;
		for (_ in 0...6) {
			for (suffix in ["haxe-std", "compiler/haxe-std"]) {
				var path = haxe.io.Path.normalize(dir + "/" + suffix);
				if (sys.FileSystem.exists(path + "/Std.hx")) return sys.FileSystem.fullPath(path);
			}
			var parent = haxe.io.Path.directory(dir);
			if (parent == dir || parent == "") break;
			dir = parent;
		}
		return null;
	}
}
