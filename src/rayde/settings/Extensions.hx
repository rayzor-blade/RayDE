package rayde.settings;

import rayde.ext.Manifest;

/** An extension folder as found: what its manifest says, where it is, and what is wrong with it. */
typedef Extension = {id:String, name:String, version:String, description:String, path:String, scope:String, ?problem:String};

/**
 * The extensions installed: a folder under `.rayde/extensions` in the workspace or in the user's own
 * `.rayde/extensions` that holds a `.rayext` config file. Nothing runs them yet; this is what the Settings page lists.
 */
class Extensions {
	public static function list(root:String):Array<Extension> {
		var out = [];
		scan(haxe.io.Path.join([root, ".rayde", "extensions"]), "Workspace", out);
		var home = Sys.getEnv("HOME");
		if (home == null || home == "")
			home = Sys.getEnv("USERPROFILE");
		if (home != null && home != "")
			scan(haxe.io.Path.join([home, ".rayde", "extensions"]), "User", out);
		return out;
	}

	static function scan(dir:String, scope:String, out:Array<Extension>):Void {
		if (!sys.FileSystem.exists(dir) || !sys.FileSystem.isDirectory(dir))
			return;
		var names = sys.FileSystem.readDirectory(dir);
		names.sort(Reflect.compare);
		for (name in names) {
			var folder = haxe.io.Path.join([dir, name]);
			if (name.charAt(0) == "." || !sys.FileSystem.isDirectory(folder))
				continue;
			var configs = [for (f in sys.FileSystem.readDirectory(folder)) if (Manifest.isManifest(f)) f];
			if (configs.length == 0)
				continue;
			configs.sort(Reflect.compare);
			var m = Manifest.read(haxe.io.Path.join([folder, configs[0]]));
			out.push({
				id: name,
				name: m.name,
				version: m.version,
				description: m.description,
				path: folder,
				scope: scope,
				problem: m.problems.length == 0 ? null : m.problems[0]
			});
		}
	}
}
