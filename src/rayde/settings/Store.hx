package rayde.settings;

import rayde.workspace.Fs;

/**
 * The workspace's settings: `.rayde/settings.json`, one object with a section for each area of the Settings
 * page. A section is replaced whole when it is saved; sections this version does not know stay as they are.
 */
class Store {
	static function file(root:String):String
		return haxe.io.Path.join([root, ".rayde", "settings.json"]);

	/** The whole file as an object: empty when there is none or it cannot be read. */
	public static function read(root:String):Dynamic {
		try {
			if (Fs.exists(file(root))) {
				var json:Dynamic = haxe.Json.parse(Fs.getContent(file(root)));
				if (Reflect.isObject(json) && !Std.isOfType(json, Array))
					return json;
			}
		} catch (_:Dynamic) {}
		return {};
	}

	/** The section `name` as an object: empty when it is missing. */
	public static function section(root:String, name:String):Dynamic {
		var value = Reflect.field(read(root), name);
		return Reflect.isObject(value) && !Std.isOfType(value, Array) ? value : {};
	}

	/** Replaces the section `name`, reading the file again first so a change made elsewhere is kept. */
	public static function save(root:String, name:String, value:Dynamic):Void
		try {
			saveChecked(root,name,value);
		} catch (_:Dynamic) {}

    public static function saveChecked(root:String,name:String,value:Dynamic):Void {
			var all = read(root);
			Reflect.setField(all, name, value);
			var dir = haxe.io.Path.join([root, ".rayde"]);
			if (!Fs.exists(dir))
				Fs.createDirectory(dir);
			Fs.saveContent(file(root), haxe.Json.stringify(all, null, "\t") + "\n");
		}
}
