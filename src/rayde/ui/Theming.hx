package rayde.ui;

import ashui.css.Css;
import ashui.css.Stylesheet;
import ashui.theme.ColorScheme;
import ashui.theme.ColorTokens;
import ashui.theme.Platform;
import ashui.theme.ThemeBundle;
import ashui.theme.ThemeState;
import ashui.theme.themes.ExpressiveTheme;
import ashui.theme.themes.HybridTheme;
import ashui.theme.themes.RestrainedTheme;
import rayde.settings.Appearance;
import rayde.theme.ThemeBuilder;
import rayde.theme.ThemeCss;
import rayde.theme.ThemeFile;
import rayde.theme.Themes;

/** What putting a theme file in force reported: font files that could not be registered, and the style system's warnings about its CSS. */
typedef Applied = {fonts:Array<String>, css:Array<String>};

/** Puts an `Appearance` on the screen: the theme's bundle, its stylesheets and fonts, and light, dark or the system's scheme. */
class Theming {
	/** The id of the theme installed now, so a change of scheme alone does not install it again. */
	static var installed:Null<String>;

	/** The id of the theme in use, which the window carries as `data-theme` so a theme's own stylesheet applies only to it. */
	public static final current = ashui.reactive.Signal.make("restrained");

	/** Whether the theme in use sets the `sans` role; the window carries it as `data-sans`, and then its text is set in that family. */
	public static final ownSans = ashui.reactive.Signal.make(false);

	/** The stylesheets of the theme in use. */
	static var sheets:Array<Stylesheet> = [];

	/** The font files registered, by path, with the modification time they had; a face cannot be taken back, so each is registered once per change. */
	static final registered = new Map<String, Float>();

	/** A theme file shown in place of the chosen theme, as in the Theme Studio: `apply` keeps showing it. */
	public static var pinned(default, null):Null<ThemeFile>;

	static function builtin(id:String):ThemeBundle
		return switch id {
			case "hybrid": HybridTheme.bundle();
			case "expressive": ExpressiveTheme.bundle();
			case _: RestrainedTheme.bundle();
		}

	/** A theme's bundle by id: a built-in one, an installed one, or, for an id that is neither (a theme that was taken away), Restrained. */
	public static function bundle(id:String):ThemeBundle {
		var custom = Themes.find(id);
		return custom == null ? builtin(id) : ThemeBuilder.build(custom.file, builtin);
	}

	/** The bundle of a theme file that need not be installed, for showing what it looks like. */
	public static function bundleOf(t:ThemeFile):ThemeBundle
		return ThemeBuilder.build(t, builtin);

	/** What the window opens with: the pinned theme's bundle, else the chosen theme's. */
	public static function shown(a:Appearance):ThemeBundle
		return pinned != null ? bundleOf(pinned) : bundle(a.theme);

	/** Whether `id` is a theme there is, built in or installed. */
	public static function exists(id:String):Bool
		return Lambda.exists(Appearance.themes, t -> t.id == id) || Themes.find(id) != null;

	/** The scheme in force: the system's own when the setting is system. */
	public static function resolved(a:Appearance):ColorScheme
		return a.scheme == "light" ? Light : a.scheme == "dark" ? Dark : Platform.detectSystemColorScheme();

	/** A theme's colours in a scheme, for showing what it looks like without installing it. */
	public static function colors(id:String, scheme:ColorScheme):ColorTokens
		return bundle(id).forScheme(scheme).colors;

	/** Makes `a` the look of the running program: installs its theme when that is not in use, otherwise only switches the scheme. */
	public static function apply(a:Appearance):Void {
		var wanted = resolved(a);
		if (pinned != null) {
			if (installed == pinned.id && ThemeState.tryGet() != null)
				ThemeState.get().setScheme(wanted);
			else
				put(pinned, wanted);
		} else if (installed == a.theme && ThemeState.tryGet() != null)
			ThemeState.get().setScheme(wanted);
		else {
			var custom = Themes.find(a.theme);
			if (custom != null)
				put(custom.file, wanted);
			else {
				var id = Lambda.exists(Appearance.themes, t -> t.id == a.theme) ? a.theme : "restrained";
				take(builtin(id), id, wanted, null, null);
			}
		}
		#if ashui_window
		var app = ashui.app.WindowedApp.current;
		if (app != null)
			app.window.setTheme(windowTheme(a));
		#end
	}

	/**
	 * Shows `t` in place of the chosen theme, from then on and again each time it is called: its bundle, stylesheets
	 * and fonts replace what was in force. What the style system and the font registration reported is returned.
	 */
	public static function pin(t:ThemeFile, a:Appearance):Applied {
		pinned = t;
		return put(t, resolved(a));
	}

	/** Goes back to the chosen theme. */
	public static function unpin(a:Appearance):Void {
		pinned = null;
		installed = null;
		apply(a);
	}

	/** Installs the bundle of `t`, with its fonts registered first and its stylesheets in force. */
	static function put(t:ThemeFile, scheme:ColorScheme):Applied {
		var applied:Applied = {fonts: registerFonts(t), css: []};
		take(ThemeBuilder.build(t, builtin), t.id, scheme, t, applied);
		return applied;
	}

	/** Installs `bundle` as theme `id`, with the stylesheets of `file` (a custom theme) in force in place of the last theme's. */
	static function take(bundle:ThemeBundle, id:String, scheme:ColorScheme, file:Null<ThemeFile>, applied:Null<Applied>):Void {
		// The bundle goes in first: the style system reads the theme's tokens (`--font-sans`...) when a sheet is added or removed.
		ThemeState.init(bundle, scheme);
		for (s in sheets)
			Css.remove(s);
		sheets = [];
		if (file != null) {
			var scope = '#rayde[data-theme="${file.id}"]';
			for (text in file.sheetTexts()) {
				var sheet = Css.load(ThemeCss.scope(text, scope), file.file);
				sheets.push(sheet);
				if (applied != null)
					for (d in sheet.diagnostics)
						applied.css.push(d.message);
			}
		}
		ownSans.set(file != null && (file.light.fonts.exists("sans") || file.dark.fonts.exists("sans")));
		installed = id;
		current.set(id);
	}

	/** Registers the font files of `t` that are new or changed; the files that could not be registered are returned as sentences. */
	static function registerFonts(t:ThemeFile):Array<String> {
		var failed = [];
		for (path in t.fontPaths()) {
			if (!sys.FileSystem.exists(path))
				continue;
			var stamp = sys.FileSystem.stat(path).mtime.getTime();
			if (registered.get(path) == stamp)
				continue;
			try {
				ashui.text.Fonts.register(sys.io.File.getBytes(path));
				registered.set(path, stamp);
			} catch (e:Dynamic)
				failed.push('${haxe.io.Path.withoutDirectory(path)}: $e');
		}
		return failed;
	}

	#if ashui_window
	/** The window's own appearance for `a`, null to follow the system. */
	public static function windowTheme(a:Appearance):Null<window.Theme>
		return a.scheme == "light" ? window.Theme.Light : a.scheme == "dark" ? window.Theme.Dark : null;
	#end
}
