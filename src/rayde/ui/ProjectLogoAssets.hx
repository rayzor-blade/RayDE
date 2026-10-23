package rayde.ui;

/** Original raster artwork embedded without a process-wide decoded-image cache. */
class ProjectLogoAssets {
	public static macro function bytes(path:String):haxe.macro.Expr {
		var bytes = sys.io.File.getBytes(path), key = "rayde.project-logo:" + path;
		haxe.macro.Context.addResource(key, bytes);
		return macro haxe.Resource.getBytes($v{key});
	}
}
