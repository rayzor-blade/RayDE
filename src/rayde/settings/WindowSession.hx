package rayde.settings;

/** The workspaces open together; each workspace stores its own tab session. */
class WindowSession {
	public static function read(?home:String):Null<Array<Null<String>>> {
		var data:Dynamic = Store.section(home ?? Extensions.home(), "windows");
		if (data.version != 1 || !Std.isOfType(data.entries, Array)) return null;
		var entries:Array<Null<String>> = [];
		for (entry in (data.entries:Array<Dynamic>)) {
			if (entry == null) entries.push(null);
			else if (Std.isOfType(entry, String) && haxe.io.Path.isAbsolute(entry))
				try { if (sys.FileSystem.exists(entry)) entries.push(entry); } catch (_:Dynamic) {}
		}
		return entries;
	}

	public static function save(entries:Array<Null<String>>, ?home:String):Void
		Store.save(home ?? Extensions.home(), "windows", {version:1, entries:entries});
}
