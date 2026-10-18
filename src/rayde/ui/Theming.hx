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

/** Puts an `Appearance` on the screen: the theme's bundle, and light, dark or the system's scheme. */
class Theming {
	/** The id of the theme installed now, so a change of scheme alone does not install it again. */
	static var installed:Null<String>;

	public static function bundle(id:String):ThemeBundle
		return switch id {
			case "hybrid": HybridTheme.bundle();
			case "expressive": ExpressiveTheme.bundle();
			case _: RestrainedTheme.bundle();
		}

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
			ThemeState.init(bundle(a.theme), wanted);
			installed = a.theme;
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
