import rayde.settings.WorkspaceSession;

@:access(rayde.settings.WorkspaceSession)
class WorkspaceSessionChecks {
	public static function run():Void {
		var root = Sys.getCwd() + "bin/check-workspace-session";
		sys.FileSystem.createDirectory(root);
		var first = new WorkspaceSession(root, root + "/a.hxml"), other = new WorkspaceSession(root, root + "/b.hxml");
		first.close({files:[], active:""}); other.close({files:[], active:""});
		first = new WorkspaceSession(root, root + "/a.hxml");
		first.save({files:["src/Async.hx"], active:"src/Async.hx"});
		var deadline = haxe.Timer.stamp() + 5, delivered = false;
		while (!delivered && haxe.Timer.stamp() < deadline) {
			var current = first.read(); delivered = current != null && current.active == "src/Async.hx";
			if (!delivered) Sys.sleep(.005);
		}
		if (!delivered) throw "Worker did not checkpoint tabs during interaction";
		for (i in 0...50) first.save({files:["src/λ file.hx", 'src/File$i.hx'], active:'src/File$i.hx'});
		first.close({files:["src/λ file.hx", "src/Last.hx"], active:"src/Last.hx"});
		var next = new WorkspaceSession(root, root + "/a.hxml"), saved = next.read();
		if (saved == null || saved.files.join(",") != "src/λ file.hx,src/Last.hx" || saved.active != "src/Last.hx") throw "Session lost order, active tab or final checkpoint";
		if (other.read().files.length != 0) throw "Workspace build sessions were mixed";
		var moved = new WorkspaceSession(root + "/moved", root + "/moved/a.hxml");
		sys.FileSystem.createDirectory(haxe.io.Path.directory(moved.file));
		sys.io.File.copy(next.file, moved.file);
		if (moved.read() == null || moved.read().active != "src/Last.hx") throw "Moving a workspace lost its relative session metadata";
		moved.close(null);
		next.close({files:[], active:""});
		if (new WorkspaceSession(root, root + "/a.hxml").read().files.length != 0) throw "Explicitly closed tabs reopened";
		Sys.println("workspace session: ordered tabs, active tab, Unicode, coalesced writes, final checkpoint, empty sessions and project isolation");
	}
}
