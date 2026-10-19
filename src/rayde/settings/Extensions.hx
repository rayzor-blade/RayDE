package rayde.settings;

import rayde.ext.Manifest;

/** An extension folder as found: what its manifest says, where it is, and what is wrong with it. */
typedef Extension = {id:String, name:String, version:String, description:String, path:String, scope:String, ?problem:String, manifest:Manifest};

/** Finds extension manifests with workspace, user and built-in precedence. */
class Extensions {
	public static function home():String
		return Sys.getEnv("HOME") ?? Sys.getEnv("USERPROFILE") ?? ".";

	public static function builtins():String {
		var overridePath = Sys.getEnv("RAYDE_EXTENSIONS");
		if (overridePath != null && overridePath != "")
			return overridePath;
		var program = haxe.io.Path.directory(Sys.programPath());
		var candidates = [
			haxe.io.Path.join([program, "extensions"]),
			haxe.io.Path.join([program, "../../share/rayde/extensions"]),
			haxe.io.Path.join([Sys.getCwd(), "extensions"])
		];
		for (path in candidates)
			if (sys.FileSystem.exists(path))
				return haxe.io.Path.normalize(path);
		return candidates[0];
	}

	/** Workspace fields override user fields; saving a workspace toggle preserves the other settings. */
	public static function disabled(root:String, ?userHome:String):Array<String> {
		var user = Store.section(userHome ?? home(), "extensions"),
			workspace = Store.section(root, "extensions");
		var value:Dynamic = Reflect.hasField(workspace, "disabled") ? workspace.disabled : user.disabled;
		return Std.isOfType(value, Array) ? [for (id in (value : Array<Dynamic>)) if (Std.isOfType(id, String)) (id : String)] : [];
	}

	public static function setDisabled(root:String, id:String, disabled:Bool):Void {
		var section = Store.section(root, "extensions"),
			ids = Extensions.disabled(root);
		ids.remove(id);
		if (disabled)
			ids.push(id);
		Reflect.setField(section, "disabled", ids);
		Store.save(root, "extensions", section);
	}

	public static function list(root:String, ?builtins:String, ?user:String):Array<Extension> {
		var out = [];
		if (builtins != null)
			scan(builtins, "Built-in", out);
		if (user == null) {
			var home = Sys.getEnv("HOME") ?? Sys.getEnv("USERPROFILE");
			if (home != null && home != "")
				user = haxe.io.Path.join([home, ".rayde", "extensions"]);
		}
		if (user != null)
			scan(user, "User", out);
		scan(haxe.io.Path.join([root, ".rayde", "extensions"]), "Workspace", out);
		var chosen = new Map<String, Extension>();
		for (e in out)
			chosen.set(e.id, e);
		out = [for (e in chosen) e];
		out.sort((a, b) -> Reflect.compare(a.id, b.id));
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
				id: m.id,
				manifest: m,
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
