import rayde.settings.Store;
import rayde.settings.WindowSession;

class WindowSessionChecks {
	public static function run():Void {
		var root = Sys.getCwd() + "bin/check-window-session-" + Std.random(0x3fffffff), home = root + "/home", other = root + "/other";
		for (dir in [home, other, root + "/one", root + "/two"]) sys.FileSystem.createDirectory(dir);
		if (WindowSession.read(home) != null) throw "New user has a window session";
		Store.save(home, "appearance", {scheme:"light"});
		WindowSession.save([root + "/one", null, root + "/two", root + "/one"], home);
		var saved = WindowSession.read(home);
		if (saved.length != 4 || saved[0] != root + "/one" || saved[1] != null || saved[2] != root + "/two" || saved[3] != root + "/one") throw "Window session lost order, Welcome or duplicate workspaces";
		if (Store.section(home, "appearance").scheme != "light" || WindowSession.read(other) != null) throw "Window session overwrote settings or crossed users";
		Store.save(home, "windows", {version:1, entries:([root + "/one", "relative", 12, root + "/missing", null]:Array<Dynamic>)});
		saved = WindowSession.read(home);
		if (saved.length != 2 || saved[0] != root + "/one" || saved[1] != null) throw "Invalid or unavailable workspaces survived validation";
		Store.save(home, "windows", {version:2, entries:[]});
		if (WindowSession.read(home) != null) throw "Unsupported session version was accepted";
		Sys.println("window session: ordered workspaces, Welcome, duplicates, missing paths, settings preservation and user isolation");
	}
}
