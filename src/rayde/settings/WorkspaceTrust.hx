package rayde.settings;

import haxe.io.Path;
import rayde.workspace.Fs;
import rayde.workspace.PageHost;

/** Explicit workspace approvals belong to the user's private settings, never to project files. */
class WorkspaceTrust {
	public static function root(entry:String):String {
		var path = Fs.fullPath(entry);
		if (!Fs.exists(path)) throw "Workspace does not exist: " + entry;
		var folder = Path.normalize(Fs.isDirectory(path) ? path : Path.directory(path));
		var trimmed = Path.removeTrailingSlashes(folder);
		return trimmed == "" ? "/" : ~/^[A-Za-z]:$/.match(trimmed) ? trimmed + "/" : trimmed;
	}

	static function key(root:String, scope:String):String
		return haxe.crypto.Sha256.encode(scope + "\n" + root);

	static function privateHome(?home:String):String {
		var folder = home ?? Extensions.home();
		if (!Path.isAbsolute(folder)) throw "Set a user home directory before remembering workspace approval.";
		return folder;
	}

	static function identity(entry:String):String {
		var folder = root(entry), session = PageHost.session, bridge = PageHost.bridge;
		if (session != null) {
			var base = root(session.root);
			if (!rayde.files.FileOps.inside(base, folder)) throw "Choose a project in this workspace.";
			var scope = bridge != null && bridge.workspaceId != null ? "cloud\n" + bridge.workspaceId : "session\n" + session.storageKey;
			if ((bridge == null || bridge.workspaceId == null) && (session.storageKey == null || session.storageKey == ""))
				throw "Reconnect to this workspace before trusting its authors.";
			return key(folder == base ? "" : rayde.files.FileOps.relative(base, folder), scope);
		}
		return key(folder, PageHost.storage == null ? "local" : "page");
	}

	static function contains(id:String, home:String):Bool {
		var saved:Dynamic = Store.section(home, "workspaceTrust");
		if (saved.version != 1 || !Std.isOfType(saved.approved, Array)) return false;
		return Lambda.exists((saved.approved:Array<Dynamic>), item -> Std.isOfType(item, String) && item == id);
	}

	public static function trusted(entry:String, ?home:String):Bool {
		var folder = root(entry), bridge = PageHost.bridge;
		if (bridge != null && bridge.demo && rayde.files.FileOps.inside(PageHost.workspaceRoot(), folder)) return true;
		var folderHome = home ?? Extensions.home();
		return Path.isAbsolute(folderHome) && contains(identity(entry), folderHome);
	}

	static function approve(id:String, home:String):Void {
		var saved:Dynamic = Store.section(home, "workspaceTrust"), approved:Array<String> = [];
		if (saved.version == 1 && Std.isOfType(saved.approved, Array)) for (item in (saved.approved:Array<Dynamic>))
			if (Std.isOfType(item, String) && ~/^[0-9a-f]{64}$/.match(item) && approved.indexOf(item) < 0 && item != id) approved.push(item);
		approved.unshift(id);
		Store.saveChecked(home, "workspaceTrust", {version:1, approved:approved.slice(0, 4096)});
	}

	public static function remember(entry:String, ?home:String):Void
		approve(identity(entry), privateHome(home));

	/** A newly scaffolded repository is approved before navigating into its remote workspace. */
	public static function rememberCloud(workspace:String, project:Null<String>, ?home:String):Void {
		if (!~/^[\w-]{43}$/.match(workspace)) throw "Invalid workspace identity.";
		var file = Path.normalize(project ?? "build.hxml");
		if (Path.isAbsolute(file) || StringTools.startsWith(file, "../") || file == "..") throw "Invalid project path.";
		var folder = Path.directory(file);
		approve(key(folder, "cloud\n" + workspace), privateHome(home));
	}
}
