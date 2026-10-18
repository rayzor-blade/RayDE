package rayde.term;

/** A program a terminal can run: what it is called, where it is, and the arguments to give it (a login shell's when left out). */
typedef Profile = {
	name:String,
	program:String,
	?args:Array<String>,
	?isDefault:Bool
};

/**
 * The shells on this machine, as terminal profiles: the user's own (`$SHELL`) first and the default,
 * then the others `/etc/shells` lists, then a few that are often installed beside it (PowerShell,
 * Nushell). On Windows, PowerShell and the command prompt.
 */
class Profiles {
	public static function list():Array<Profile> {
		var out:Array<Profile> = [], seen = new Map<String, Bool>();
		function add(path:Null<String>, ?name:String):Void {
			if (path == null || path == "" || !sys.FileSystem.exists(path) || sys.FileSystem.isDirectory(path))
				return;
			var label = name != null ? name : StringTools.replace(haxe.io.Path.withoutDirectory(path), ".exe", "");
			if (seen.exists(label))
				return;
			seen.set(label, true);
			out.push({name: label, program: path});
		}
		if (Sys.systemName() == "Windows") {
			var root = Sys.getEnv("SystemRoot");
			if (root != null) {
				add(haxe.io.Path.join([root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"]), "PowerShell");
				add(haxe.io.Path.join([root, "System32", "cmd.exe"]), "Command Prompt");
			}
			add(onPath("pwsh.exe"), "pwsh");
		} else {
			add(Sys.getEnv("SHELL"));
			if (sys.FileSystem.exists("/etc/shells"))
				for (line in sys.io.File.getContent("/etc/shells").split("\n")) {
					var path = StringTools.trim(line);
					if (path == "" || StringTools.startsWith(path, "#") || path.indexOf("nologin") >= 0 || StringTools.endsWith(path, "/false"))
						continue;
					add(path);
				}
			for (extra in ["pwsh", "nu", "fish", "xonsh", "elvish"])
				add(onPath(extra));
		}
		if (out.length > 0)
			out[0].isDefault = true;
		return out;
	}

	/** Where `name` is on the search path, or null. */
	static function onPath(name:String):Null<String> {
		var path = Sys.getEnv("PATH");
		if (path == null)
			return null;
		for (dir in path.split(Sys.systemName() == "Windows" ? ";" : ":")) {
			var candidate = haxe.io.Path.join([dir, name]);
			if (dir != "" && sys.FileSystem.exists(candidate) && !sys.FileSystem.isDirectory(candidate))
				return candidate;
		}
		return null;
	}
}
