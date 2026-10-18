package rayde.ext;

/** Where the rayscript-host program is. */
class HostBinary {
	/**
	 * The program that runs an extension: the one `RAYSCRIPT_HOST` names, else `rayscript-host` on `PATH`, else
	 * the one a rayscript checkout beside RayDE has built. Null when there is none.
	 */
	public static function find():Null<String> {
		var named = Sys.getEnv("RAYSCRIPT_HOST");
		if (named != null && named != "")
			return sys.FileSystem.exists(named) ? named : null;
		var path = Sys.getEnv("PATH");
		if (path != null)
			for (dir in path.split(":"))
				if (dir != "" && sys.FileSystem.exists(dir + "/rayscript-host"))
					return dir + "/rayscript-host";
		var beside = haxe.io.Path.removeTrailingSlashes(Sys.getCwd()) + "/../rayscript/target";
		for (profile in ["release", "debug"])
			if (sys.FileSystem.exists('$beside/$profile/rayscript-host'))
				return '$beside/$profile/rayscript-host';
		return null;
	}
}
