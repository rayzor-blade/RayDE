package rayde.settings;

/** An extension folder as found: what its manifest says, where it is, and what is wrong with it. */
typedef Extension = {id:String, name:String, version:String, description:String, path:String, scope:String, ?problem:String};

/**
 * The extensions installed: a folder with an `extension.json` under `.rayde/extensions` in the workspace or
 * in the user's own `.rayde/extensions`. Nothing runs them yet; this is what the Settings page lists.
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
			var folder = haxe.io.Path.join([dir, name]), manifest = haxe.io.Path.join([folder, "extension.json"]);
			if (name.charAt(0) == "." || !sys.FileSystem.isDirectory(folder) || !sys.FileSystem.exists(manifest))
				continue;
			try {
				var json:Dynamic = haxe.Json.parse(sys.io.File.getContent(manifest));
				out.push({
					id: name,
					name: json.name != null ? Std.string(json.name) : name,
					version: json.version != null ? Std.string(json.version) : "",
					description: json.description != null ? Std.string(json.description) : "",
					path: folder,
					scope: scope
				});
			} catch (e:Dynamic)
				out.push({id: name, name: name, version: "", description: "", path: folder, scope: scope, problem: "extension.json cannot be read"});
		}
	}
}
