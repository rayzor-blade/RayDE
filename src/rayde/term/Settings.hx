package rayde.term;

/**
 * What the terminal is set to, kept in the `terminal` section of `.rayde/settings.json`: the profile a
 * new terminal starts from, the shape of the cursor, and whether a selection is copied as it is made.
 */
class Settings {
	/** The name of the profile + starts, or null for the first the machine offers. */
	public var defaultProfile:Null<String> = null;

	/** block, bar or underline. */
	public var cursor = "block";

	public var copyOnSelect = false;

	public function new() {}

	/** The settings kept for the project at `root`, or the defaults when there are none or they cannot be read. */
	public static function read(root:String):Settings {
		var s = new Settings(), json = rayde.settings.Store.section(root, "terminal");
		if (json.defaultProfile != null)
			s.defaultProfile = Std.string(json.defaultProfile);
		if (json.cursor != null && ["block", "bar", "underline"].indexOf(Std.string(json.cursor)) >= 0)
			s.cursor = Std.string(json.cursor);
		s.copyOnSelect = json.copyOnSelect == true;
		return s;
	}

	public function save(root:String):Void
		rayde.settings.Store.save(root, "terminal", {defaultProfile: defaultProfile, cursor: cursor, copyOnSelect: copyOnSelect});
}
