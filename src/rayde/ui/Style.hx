package rayde.ui;

/** ashui's components and RayDE's own rules, installed once; colours, type and motion come from the theme. */
class Style {
	static var installed = false;

	public static function use():Void {
		if (installed)
			return;
		ashui.components.Library.use();
		ashui.css.Css.add(ashui.css.CompiledCss.file("rayde.css"));
		installed = true;
	}
}
