package rayde.theme;

import ashui.theme.ColorScheme;
import ashui.theme.ColorTokens;
import ashui.theme.FontFamily;
import ashui.theme.RadiusTokens;
import ashui.theme.Rgba;
import ashui.theme.ShapeTokens;
import ashui.theme.SpacingTokens;
import ashui.theme.Theme;
import ashui.theme.ThemeBundle;
import ashui.theme.TypographyTokens;
import rayde.theme.ThemeFile.SchemeSpec;

/** Turns a theme file into the bundle ashui installs: the theme it extends, with what the file sets over it in each scheme. */
class ThemeBuilder {
	/** `builtin` gives a built-in theme's bundle by id. The theme's stylesheets and fonts are not part of the bundle; `Theming` puts them in force. */
	public static function build(t:ThemeFile, builtin:String->ThemeBundle):ThemeBundle {
		var base = builtin(t.base);
		return new ThemeBundle(t.name, scheme(t, base.light, t.light, false), scheme(t, base.dark, t.dark, true));
	}

	static function cap(name:String):String
		return name.charAt(0).toUpperCase() + name.substr(1);

	static function scheme(t:ThemeFile, base:Theme, spec:SchemeSpec, dark:Bool):Theme {
		var colors:Dynamic = Reflect.copy(base.colors);
		for (token => c in ThemeFile.derive(spec.colors, dark))
			Reflect.setField(colors, token, new Rgba(c.r, c.g, c.b, c.a));
		var radii:Dynamic = Reflect.copy(base.radii);
		for (step => px in spec.radii)
			Reflect.setField(radii, "radius" + cap(step), px);
		var type:Dynamic = Reflect.copy(base.typography);
		for (role => family in spec.fonts) {
			var field = "font" + cap(role);
			var old:FontFamily = Reflect.field(type, field);
			Reflect.setField(type, field, new FontFamily(family, old.fallbacks));
		}
		for (step => px in spec.sizes)
			Reflect.setField(type, "text" + cap(step), px);
		var shape = base.shape;
		if (spec.shape.keys().hasNext())
			shape = new ShapeTokens(pick(spec.shape, "smoothing", shape.cornerSmoothing), pick(spec.shape, "exponent", shape.cornerExponent),
				pick(spec.shape, "threshold", shape.smoothingThreshold));
		var spacing = spec.spacing == null ? base.spacing : SpacingTokens.withBase(spec.spacing);
		return new Theme(t.name, base.colorScheme, (colors : ColorTokens), (type : TypographyTokens), spacing, (radii : RadiusTokens), base.shadows, base.animations, shape);
	}

	static function pick(from:Map<String, Float>, key:String, fallback:Float):Float
		return from.exists(key) ? from.get(key) : fallback;
}
