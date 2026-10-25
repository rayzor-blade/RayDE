package rayde.ext;

import rayde.workspace.Fs;
import rayde.ext.Manifest.NativeLibrary;
import rayde.settings.Extensions;
import rayde.settings.Store;

/** Native approvals belong to the user; workspace settings cannot grant execution. */
class NativeTrust {
	static function identity(value:Dynamic, manifest:Manifest, library:NativeLibrary):Bool
		return value != null && Reflect.isObject(value) && !Std.isOfType(value, Array) && !Std.isOfType(value, String)
			&& value.id == manifest.id && value.extension == Fs.fullPath(manifest.file)
			&& value.library == library.name;

	static function same(value:Dynamic, manifest:Manifest, library:NativeLibrary):Bool
		return identity(value, manifest, library) && value.path == library.path && value.sha256 == library.sha256;

	static function approvals(home:String):Array<Dynamic> {
		var value:Dynamic = Reflect.field(Store.section(home, "extensions"), "nativeApprovals");
		return Std.isOfType(value, Array) ? value : [];
	}

	public static function approved(manifest:Manifest, library:NativeLibrary, ?home:String):Bool
		return Lambda.exists(approvals(home ?? Extensions.home()), v -> same(v, manifest, library));

	public static function allApproved(manifest:Manifest, ?home:String):Bool
		return Lambda.foreach(manifest.natives, n -> approved(manifest, n, home));

	public static function set(manifest:Manifest, library:NativeLibrary, allow:Bool, ?home:String):Bool {
		var home = home ?? Extensions.home(), section = Store.section(home, "extensions");
		var values = [for (v in approvals(home)) if (!identity(v, manifest, library)) v];
		if (allow)
			values.push({id: manifest.id, extension: Fs.fullPath(manifest.file), library: library.name, path: library.path, sha256: library.sha256});
		Reflect.setField(section, "nativeApprovals", values);
		Store.save(home, "extensions", section);
		return approved(manifest, library, home) == allow;
	}
}
