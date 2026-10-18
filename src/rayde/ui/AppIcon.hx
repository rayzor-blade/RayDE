package rayde.ui;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
#end

/**
 * The window's icon, as the pixels `WindowConfig.icon` takes: RGBA, square. They are read at compile time from
 * `assets/icons/rayde-256.rgba` (made from `assets/rayde-icon.png` by `scripts/icons.sh`) and kept in the program, so
 * the icon is there wherever the program is run from. Windows and most Linux desktops show it on the window and the
 * taskbar; macOS takes its icon from the application bundle (`scripts/package-macos.sh`).
 */
class AppIcon {
	static inline var RESOURCE = "rayde.icon";

	/** The icon, embedded: `{pixels, width, height}`. */
	public static macro function window():Expr {
		var path = "assets/icons/rayde-256.rgba";
		var bytes = try sys.io.File.getBytes(path) catch (e:Dynamic) Context.error('app icon: cannot read $path; run scripts/icons.sh', Context.currentPos());
		var side = Std.int(Math.sqrt(bytes.length / 4));
		if (side * side * 4 != bytes.length)
			Context.error('app icon: $path is not square RGBA', Context.currentPos());
		Context.addResource(RESOURCE, bytes);
		return macro {pixels: haxe.Resource.getBytes($v{RESOURCE}), width: $v{side}, height: $v{side}};
	}
}
