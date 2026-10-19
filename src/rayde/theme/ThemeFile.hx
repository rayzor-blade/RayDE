package rayde.theme;

/** A colour as the theme file gives it: red, green, blue and alpha, each from 0 to 1. */
typedef Color = {r:Float, g:Float, b:Float, a:Float};

/** A stylesheet a theme brings: its text, or a file beside the theme file. */
typedef CssSource = {text:Null<String>, file:Null<String>};

/** What a theme file changes in one scheme, light or dark, over the theme it extends. */
typedef SchemeSpec = {
	colors:Map<String, Color>,
	/** Corner radii in pixels, by step (`xl`, `default`...). */
	radii:Map<String, Float>,
	/** Font family names by role (`sans`, `serif`, `mono`). */
	fonts:Map<String, String>,
	/** Text sizes in pixels, by step (`sm`, `base`, `2xl`...). */
	sizes:Map<String, Float>,
	/** How corners are smoothed into squircles: `smoothing`, `exponent` and `threshold`. */
	shape:Map<String, Float>,
	/** The unit the spacing ladder is a multiple of, in pixels, or null to leave it. */
	spacing:Null<Float>
};

/**
 * A theme bundle's file, `<name>.raytheme`: JSON that says how the theme differs from one of RayDE's own.
 *
 *     {
 *       "id": "midnight",
 *       "name": "Midnight",
 *       "version": "1.0.0",
 *       "author": "Someone",
 *       "description": "Deep blue surfaces and a violet accent",
 *       "extends": "restrained",
 *       "colors": {"primary": "#7c5cff", "accent": "#7c5cff"},
 *       "radii": {"xl": 16},
 *       "shape": {"smoothing": 0.8},
 *       "typography": {"mono": "JetBrains Mono", "sizes": {"sm": 13}},
 *       "light": {"colors": {"background": "#f7f6ff"}},
 *       "dark": {"colors": {"background": "#0d0b1f"}},
 *       "css": [".rayde-pill { border-color: var(--accent); }", {"file": "midnight.css"}]
 *     }
 *
 * `extends` is `restrained` (the default), `hybrid` or `expressive`. What is outside `light` and `dark` goes for both
 * schemes, and what is inside one goes for that scheme only. A colour is `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb(r, g, b)`,
 * `rgba(r, g, b, a)` or `transparent`; a token is named as in ashui (`surfaceElevated`) or with dashes (`surface-elevated`).
 * A scheme that sets `primary` and not `primaryHover` or `primaryActive` gets them from it, as `secondary`, and sets
 * `borderFocus` and `selection` from `primary` and `accentSubtle` from `accent` the same way; naming a token stops that.
 *
 * `css` is a text, a list, or `{"file": "x.css"}` for a file beside the theme file. Its rules apply only while the
 * theme is in use: each selector is placed under it, so write `.rayde-card { ... }`, not `#rayde .rayde-card`.
 */
class ThemeFile {
	/** The built-in themes a file can extend. */
	public static final BASES = ["restrained", "hybrid", "expressive"];

	/** The colours of a theme, named as ashui names them. */
	public static final COLORS = [
		"primary", "primaryHover", "primaryActive", "secondary", "secondaryHover", "secondaryActive", "success", "successBg", "warning", "warningBg", "error",
		"errorBg", "info", "infoBg", "background", "surface", "surfaceElevated", "surfaceOverlay", "textPrimary", "textSecondary", "textTertiary", "textInverse",
		"textLink", "border", "borderSecondary", "borderHover", "borderFocus", "borderError", "inputBg", "inputBgHover", "inputBgFocus", "inputBgDisabled",
		"selection", "selectionText", "accent", "accentSubtle", "tooltipBg", "tooltipText"
	];

	public static final RADII = ["none", "sm", "default", "md", "lg", "xl", "2xl", "3xl", "full"];
	public static final FONTS = ["sans", "serif", "mono"];
	public static final SIZES = ["xs", "sm", "base", "lg", "xl", "2xl", "3xl", "4xl", "5xl"];
	public static final SHAPE = ["smoothing", "exponent", "threshold"];
	public static inline var EXTENSION = ".raytheme";

	public final file:String;
	public final id:String;
	public final name:String;
	public final version:String;
	public final author:String;
	public final description:String;
	public final base:String;
	public final light:SchemeSpec;
	public final dark:SchemeSpec;
	public final css:Array<CssSource> = [];

	/** What is wrong with the file, as sentences; what could be read is used. */
	public final problems:Array<String> = [];

	public static function isThemeFile(path:String):Bool
		return StringTools.endsWith(path, EXTENSION);

	function new(file:String, json:Dynamic) {
		this.file = file;
		var fallback = haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(file));
		var given = text(json, "id", "");
		id = given == "" ? fallback : given;
		if (!~/^[A-Za-z0-9][A-Za-z0-9._-]*$/.match(id))
			problems.push('Id "$id" must start with a letter or digit and use only letters, digits, dots, dashes and underscores.');
		name = text(json, "name", id);
		version = text(json, "version", "");
		author = text(json, "author", "");
		description = text(json, "description", "");
		var extended = text(json, "extends", "restrained");
		if (BASES.indexOf(extended) < 0) {
			problems.push('Unknown base theme "$extended"; expected ${BASES.join(", ")}.');
			extended = "restrained";
		}
		base = extended;
		if (BASES.indexOf(id) >= 0)
			problems.push('Id "$id" is one of the built-in themes; choose another.');
		light = scheme(json, "light");
		dark = scheme(json, "dark");
		sheets(Reflect.field(json, "css"));
		for (field in Reflect.fields(json))
			if (field.charAt(0) != "$" && ["id", "name", "version", "author", "description", "extends", "colors", "radii", "shape", "typography", "spacing", "light", "dark", "css"].indexOf(field) < 0)
				problems.push('Unknown field "$field".');
	}

	function text(object:Dynamic, field:String, fallback:String):String {
		var v:Dynamic = Reflect.field(object, field);
		return v == null ? fallback : Std.isOfType(v, String) ? v : {
			problems.push('"$field" must be text.');
			fallback;
		}
	}

	function objectOf(parent:Dynamic, field:String, where:String):Null<Dynamic> {
		var v:Dynamic = Reflect.field(parent, field);
		if (v == null)
			return null;
		if (Std.isOfType(v, String) || Std.isOfType(v, Array) || !Reflect.isObject(v)) {
			problems.push('"$where$field" must be an object.');
			return null;
		}
		return v;
	}

	static function key(name:String):String
		return StringTools.replace(StringTools.replace(name.toLowerCase(), "-", ""), "_", "");

	/** What the file says for one scheme: the shared sections, then those of `light` or `dark` over them. */
	function scheme(json:Dynamic, which:String):SchemeSpec {
		var spec:SchemeSpec = {colors: new Map(), radii: new Map(), fonts: new Map(), sizes: new Map(), shape: new Map(), spacing: null};
		var own = objectOf(json, which, "");
		var layers:Array<{from:Dynamic, where:String}> = [{from: json, where: ""}];
		if (own != null)
			layers.push({from: own, where: which + "."});
		for (layer in layers) {
			var from = layer.from, where = layer.where;
			var colors = objectOf(from, "colors", where);
			if (colors != null)
				for (token in Reflect.fields(colors)) {
					var canonical = Lambda.find(COLORS, c -> key(c) == key(token));
					if (canonical == null) {
						problems.push('Unknown colour "$token" in ${where}colors.');
						continue;
					}
					var c = parseColor(Reflect.field(colors, token));
					if (c == null)
						problems.push('${where}colors.$token: expected a colour such as #7c5cff or rgba(124, 92, 255, 0.5), not ${Std.string(Reflect.field(colors, token))}.');
					else
						spec.colors.set(canonical, c);
				}
			numbers(objectOf(from, "radii", where), RADII, where + "radii", spec.radii);
			numbers(objectOf(from, "shape", where), SHAPE, where + "shape", spec.shape);
			var typography = objectOf(from, "typography", where);
			if (typography != null) {
				for (role in FONTS) {
					var v:Dynamic = Reflect.field(typography, role);
					if (v != null)
						Std.isOfType(v, String) && v != "" ? spec.fonts.set(role, v) : problems.push('${where}typography.$role must be a font family name.');
				}
				numbers(objectOf(typography, "sizes", where + "typography."), SIZES, where + "typography.sizes", spec.sizes);
				for (field in Reflect.fields(typography))
					if (FONTS.indexOf(field) < 0 && field != "sizes")
						problems.push('Unknown field "$field" in ${where}typography.');
			}
			var spacing = objectOf(from, "spacing", where);
			if (spacing != null) {
				var base:Dynamic = Reflect.field(spacing, "base");
				if (Std.isOfType(base, Float) && base > 0)
					spec.spacing = base;
				else
					problems.push('${where}spacing.base must be a number above 0.');
				for (field in Reflect.fields(spacing))
					if (field != "base")
						problems.push('Unknown field "$field" in ${where}spacing.');
			}
		}
		return spec;
	}

	function numbers(from:Null<Dynamic>, names:Array<String>, where:String, into:Map<String, Float>):Void {
		if (from == null)
			return;
		for (n in Reflect.fields(from)) {
			var v:Dynamic = Reflect.field(from, n);
			var canonical = Lambda.find(names, c -> key(c) == key(n));
			if (canonical == null)
				problems.push('Unknown name "$n" in $where; expected ${names.join(", ")}.');
			else if (!Std.isOfType(v, Float))
				problems.push('$where.$n must be a number.');
			else
				into.set(canonical, v);
		}
	}

	function sheets(v:Dynamic):Void {
		if (v == null)
			return;
		var list:Array<Dynamic> = Std.isOfType(v, Array) ? v : [v];
		for (item in list) {
			if (Std.isOfType(item, String))
				css.push({text: item, file: null});
			else if (item != null && Reflect.isObject(item) && Std.isOfType(Reflect.field(item, "file"), String)) {
				var path:String = Reflect.field(item, "file");
				if (haxe.io.Path.isAbsolute(path) || path.split("/").indexOf("..") >= 0 || path.indexOf("\\") >= 0)
					problems.push('css file "$path" must be a path beside the theme file, without ".." or a drive.');
				else {
					css.push({text: null, file: path});
					if (!sys.FileSystem.exists(haxe.io.Path.join([haxe.io.Path.directory(file), path])))
						problems.push('css file "$path" not found.');
				}
			} else
				problems.push('Each "css" entry is text or {"file": "x.css"}.');
		}
	}

	/** A CSS-style colour, or null when it is none. */
	public static function parseColor(v:Dynamic):Null<Color> {
		if (!Std.isOfType(v, String))
			return null;
		var s = StringTools.trim(v).toLowerCase();
		if (s == "transparent")
			return {r: 0, g: 0, b: 0, a: 0};
		if (s.charAt(0) == "#") {
			var hex = s.substr(1);
			if (!~/^[0-9a-f]+$/.match(hex))
				return null;
			if (hex.length == 3 || hex.length == 4)
				hex = [for (i in 0...hex.length) hex.charAt(i) + hex.charAt(i)].join("");
			if (hex.length != 6 && hex.length != 8)
				return null;
			var byte = (i:Int) -> Std.parseInt("0x" + hex.substr(i * 2, 2)) / 255;
			return {r: byte(0), g: byte(1), b: byte(2), a: hex.length == 8 ? byte(3) : 1};
		}
		var rgb = ~/^rgba?\(\s*([0-9.]+)\s*[, ]\s*([0-9.]+)\s*[, ]\s*([0-9.]+)\s*(?:[,\/]\s*([0-9.]+%?)\s*)?\)$/;
		if (rgb.match(s)) {
			var channel = (i:Int) -> Math.min(255, Std.parseFloat(rgb.matched(i))) / 255;
			var a = rgb.matched(4);
			var alpha = a == null ? 1.0 : StringTools.endsWith(a, "%") ? Std.parseFloat(a) / 100 : Std.parseFloat(a);
			return {r: channel(1), g: channel(2), b: channel(3), a: Math.max(0, Math.min(1, alpha))};
		}
		return null;
	}

	/** `from` toward `to` by `t`, channel by channel, with `from`'s alpha. */
	public static function mix(from:Color, to:Color, t:Float):Color
		return {r: from.r + (to.r - from.r) * t, g: from.g + (to.g - from.g) * t, b: from.b + (to.b - from.b) * t, a: from.a};

	/**
	 * The colours of a scheme with those a theme sets and does not name filled in from the ones it sets: the hover and
	 * active shades of `primary` and `secondary`, the focus border and the selection from `primary`, the subtle accent from `accent`.
	 */
	public static function derive(set:Map<String, Color>, dark:Bool):Map<String, Color> {
		var out = [for (k => v in set) k => v];
		var white = {r: 1., g: 1., b: 1., a: 1.}, black = {r: 0., g: 0., b: 0., a: 1.};
		for (token in ["primary", "secondary"]) {
			var c = set.get(token);
			if (c == null)
				continue;
			if (!set.exists(token + "Hover"))
				out.set(token + "Hover", dark ? mix(c, white, .12) : mix(c, black, .1));
			if (!set.exists(token + "Active"))
				out.set(token + "Active", dark ? mix(c, black, .1) : mix(c, black, .2));
		}
		var primary = set.get("primary");
		if (primary != null) {
			if (!set.exists("borderFocus"))
				out.set("borderFocus", primary);
			if (!set.exists("selection"))
				out.set("selection", {r: primary.r, g: primary.g, b: primary.b, a: .3});
		}
		var accent = set.get("accent");
		if (accent != null && !set.exists("accentSubtle"))
			out.set("accentSubtle", {r: accent.r, g: accent.g, b: accent.b, a: dark ? .2 : .14});
		return out;
	}

	/** The text of each stylesheet the theme brings, files read from beside the theme file; one that cannot be read is skipped. */
	public function sheetTexts():Array<String> {
		var out = [];
		for (s in css) {
			if (s.text != null) {
				out.push(s.text);
				continue;
			}
			var path = haxe.io.Path.join([haxe.io.Path.directory(file), s.file]);
			if (sys.FileSystem.exists(path))
				out.push(sys.io.File.getContent(path));
		}
		return out;
	}

	/** Reads a theme file; one that cannot be read gives a theme that changes nothing, with the reason in `problems`. */
	public static function read(file:String):ThemeFile {
		var json:Dynamic = {};
		var why:Null<String> = null;
		try
			json = haxe.Json.parse(sys.io.File.getContent(file))
		catch (e:Dynamic)
			why = 'Invalid JSON: $e';
		if (why == null && (json == null || Std.isOfType(json, Array) || !Reflect.isObject(json))) {
			why = "The theme must be a JSON object.";
			json = {};
		}
		var t = new ThemeFile(file, json);
		if (why != null)
			t.problems.insert(0, why);
		return t;
	}
}
