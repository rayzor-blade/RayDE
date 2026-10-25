package rayde.settings;

/** A theme RayDE offers, by the id kept in the settings, and what sets it apart. */
typedef ThemeChoice = {id:String, label:String, note:String};

/**
 * The colour scheme, kept in the `appearance` section of `.rayde/settings.json`: which theme, and whether it
 * is light, dark, or whichever the system is in. `rayde.ui.Theming` puts it on the screen.
 */
class Appearance {
	public static final themes:Array<ThemeChoice> = [
		{id: "restrained", label: "Restrained", note: "Quiet surfaces and the strongest squircle. RayDE's own."},
		{id: "hybrid", label: "Hybrid", note: "Between Restrained and Expressive. ashui's default."},
		{id: "expressive", label: "Expressive", note: "Bolder colour, and shadows tinted by the accent."}
	];

	public var theme = "restrained";

	/** system, light or dark. */
	public var scheme = "dark";

	/** How the window's controls look: auto (the platform's), macos, windows, gnome or kde. */
	public var windowControls = "auto";

	public function new() {}

	public static final controlStyles = ["auto", "macos", "icon", "windows", "gnome", "kde"];

	public static function read(root:String):Appearance {
		var a = new Appearance(), json = Store.section(root, "appearance");
		// A built-in theme's id, or an installed one's: the theme is looked up when it is used.
		if (json.theme != null && ~/^[A-Za-z0-9][A-Za-z0-9._-]*$/.match(Std.string(json.theme)))
			a.theme = Std.string(json.theme);
		if (json.scheme != null && ["system", "light", "dark"].indexOf(Std.string(json.scheme)) >= 0)
			a.scheme = Std.string(json.scheme);
		if (json.windowControls != null && controlStyles.indexOf(Std.string(json.windowControls)) >= 0)
			a.windowControls = Std.string(json.windowControls);
		return a;
	}

	public function save(root:String):Void
		Store.save(root, "appearance", {theme: theme, scheme: scheme, windowControls: windowControls});

	public function choice():ThemeChoice
		return Lambda.find(themes, t -> t.id == theme);
}
