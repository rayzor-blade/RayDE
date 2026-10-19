package rayde.ui;

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
import rayde.theme.Themes;

/** Puts an `Appearance` on the screen: the theme's bundle, and light, dark or the system's scheme. */
class Theming {
	/** The id of the theme installed now, so a change of scheme alone does not install it again. */
	static var installed:Null<String>;

	/** The id of the theme in use, which the window carries as `data-theme` so a theme's own stylesheet applies only to it. */
	public static final current = ashui.reactive.Signal.make("restrained");

	/** The custom themes whose stylesheets have been given to the style system, which does not take one back. */
	static final sheeted = new Map<String, Bool>();

	static function builtin(id:String):ThemeBundle
		return switch id {
			case "hybrid": HybridTheme.bundle();
			case "expressive": ExpressiveTheme.bundle();
			case _: RestrainedTheme.bundle();
		}

	/**
	 * A theme's bundle by id: a built-in one, an installed one, or, for an id that is neither (a theme that was taken away),
	 * Restrained. `withCss` adds an installed theme's stylesheets, which only the bundle that is installed takes.
	 */
	public static function bundle(id:String, withCss = false):ThemeBundle {
		var custom = Themes.find(id);
		return custom == null ? builtin(id) : ThemeBuilder.build(custom.file, builtin, withCss);
	}

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
		if (installed == a.theme && ThemeState.tryGet() != null)
			ThemeState.get().setScheme(wanted);
		else {
			// A theme's stylesheets go in once; they are scoped to the theme, so they do nothing while another is chosen.
			var first = !sheeted.exists(a.theme);
			ThemeState.init(bundle(a.theme, first), wanted);
			sheeted.set(a.theme, true);
			installed = a.theme;
			current.set(Themes.find(a.theme) != null || Lambda.exists(Appearance.themes, t -> t.id == a.theme) ? a.theme : "restrained");
		}
		#if ashui_window
		var app = ashui.app.WindowedApp.current;
		if (app != null)
			app.window.setTheme(windowTheme(a));
		#end
	}

	#if ashui_window
	/** The window's own appearance for `a`, null to follow the system. */
	public static function windowTheme(a:Appearance):Null<window.Theme>
		return a.scheme == "light" ? window.Theme.Light : a.scheme == "dark" ? window.Theme.Dark : null;
	#end
}
