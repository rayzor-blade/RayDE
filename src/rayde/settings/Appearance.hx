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

	public function new() {}

	public static function read(root:String):Appearance {
		var a = new Appearance(), json = Store.section(root, "appearance");
		if (json.theme != null && Lambda.exists(themes, t -> t.id == Std.string(json.theme)))
			a.theme = Std.string(json.theme);
		if (json.scheme != null && ["system", "light", "dark"].indexOf(Std.string(json.scheme)) >= 0)
			a.scheme = Std.string(json.scheme);
		return a;
	}

	public function save(root:String):Void
		Store.save(root, "appearance", {theme: theme, scheme: scheme});

	public function choice():ThemeChoice
		return Lambda.find(themes, t -> t.id == theme);
}
