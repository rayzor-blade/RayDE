package rayde.workspace;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
#end

/** Files compiled into the program, for a page that has no disk to find its built-in themes and extensions on. */
class Embed {
	/**
	 * Every file under `directory` (relative to the project, or absolute), as an array of `{path, directory, bytes}` entries
	 * under `mount`, ready for `MemoryWorkspace.load`. Files over `limit` bytes and names in `skip` (such as native libraries) are left out.
	 */
	public static macro function directory(directory:String, mount:String, ?skip:Array<String>, limit:Int = 1048576):Expr {
		var pos = Context.currentPos(), root = sys.FileSystem.fullPath(directory), items:Array<Expr> = [], skipping = skip == null ? [] : skip;
		function walk(path:String, target:String):Void {
			items.push(macro {path: $v{target}, directory: true, bytes: null});
			for (name in sys.FileSystem.readDirectory(path)) {
				var file = haxe.io.Path.join([path, name]), at = target + "/" + name;
				if (skipping.indexOf(name) >= 0 || StringTools.startsWith(name, ".")) continue;
				if (sys.FileSystem.isDirectory(file)) walk(file, at);
				else {
					var bytes = sys.io.File.getBytes(file);
					if (bytes.length > limit) continue;
					Context.registerModuleDependency(Context.getLocalModule(), file);
					items.push(macro {path: $v{at}, directory: false, bytes: haxe.crypto.Base64.decode($v{haxe.crypto.Base64.encode(bytes)})});
				}
			}
		}
		if (!sys.FileSystem.isDirectory(root)) Context.error("Not a directory: " + directory, pos);
		walk(root, mount);
		return macro $a{items};
	}
}
