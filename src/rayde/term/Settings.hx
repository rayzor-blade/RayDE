package rayde.term;

/**
 * What the terminal is set to, kept in `.rayde/terminal.json` beside the project's build file: the profile a
 * new terminal starts from, the shape of the cursor, and whether a selection is copied as it is made.
 */
class Settings {
	/** The name of the profile + starts, or null for the first the machine offers. */
	public var defaultProfile:Null<String> = null;

	/** block, bar or underline. */
	public var cursor = "block";

	public var copyOnSelect = false;

	public function new() {}

	static function file(root:String):String
		return haxe.io.Path.join([root, ".rayde", "terminal.json"]);

	/** The settings kept for the project at `root`, or the defaults when there are none or they cannot be read. */
	public static function read(root:String):Settings {
		var s = new Settings();
		try {
			if (sys.FileSystem.exists(file(root))) {
				var json:Dynamic = haxe.Json.parse(sys.io.File.getContent(file(root)));
				if (json.defaultProfile != null)
					s.defaultProfile = Std.string(json.defaultProfile);
				if (json.cursor != null && ["block", "bar", "underline"].indexOf(Std.string(json.cursor)) >= 0)
					s.cursor = Std.string(json.cursor);
				s.copyOnSelect = json.copyOnSelect == true;
			}
		} catch (_:Dynamic) {}
		return s;
	}

	public function save(root:String):Void
		try {
			var dir = haxe.io.Path.join([root, ".rayde"]);
			if (!sys.FileSystem.exists(dir))
				sys.FileSystem.createDirectory(dir);
			sys.io.File.saveContent(file(root), haxe.Json.stringify({defaultProfile: defaultProfile, cursor: cursor, copyOnSelect: copyOnSelect}, null, "\t") + "\n");
		} catch (_:Dynamic) {}
}
