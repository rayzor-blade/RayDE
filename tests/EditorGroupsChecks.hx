import ashui.reactive.Signal;
import rayde.ui.EditorGroups;
import rayde.keys.Chord;
import rayde.keys.KeyBindings;
import rayde.settings.WorkspaceSession;

class EditorGroupsChecks {
	static function check(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
	}

	public static function run():Void {
		var idleActive = Signal.make(""), idle = new EditorGroups(idleActive), reactions = 0;
		var watch = new ashui.reactive.Watch(() -> idleActive.get(), _ -> {
			reactions++;
			idle.sync([], idleActive.get());
		}, (_, _) -> false);
		for (_ in 0...4)
			ashui.reactive.Watch.runQueued();
		watch.stop();
		check(reactions == 1, "an empty group invalidated its own synchronization effect while idle");
		var active = Signal.make("c"),
			model = new EditorGroups(active),
			files = ["a", "b", "c"];
		model.sync(files, "c");
		model.split("horizontal");
		check(model.all().length == 2 && model.current().files.get().join(",") == "c" && model.all()[0].files.get().join(",") == "a,b",
			"split lost tab ownership or order");
		model.focusNext();
		check(active.get() == "b", "group focus lost its selected tab");
		model.split("vertical");
		check(model.all().length == 3 && active.get() == "b", "nested split did not select the moved tab");
		var saved = model.snapshot(path -> path),
			index = model.all().indexOf(model.current());
		var restored = new EditorGroups(active);
		restored.restore(saved, files, index, path -> path);
		check(haxe.Json.stringify(restored.snapshot(path -> path)) == haxe.Json.stringify(saved), "layout restoration changed group tabs or orientation");
		check(restored.current().active.get() == "b", "restored group did not own the selected file");
		restored.moveNext();
		check(restored.all().length == 2
			&& restored.current().files.get().join(",") == "c,b", "moving the last tab did not collapse its old group");
		restored.closeGroup();
		check(restored.all().length == 1 && restored.current().files.get().join(",") == "a,c,b", "closing a group dropped its documents");
		restored.split("horizontal");
		restored.join();
		check(restored.all().length == 1 && restored.all()[0].files.get().length == 3, "joining lost documents");
		active.set("a");
		restored.sync(files, "a");
		restored.split("vertical");
		var owner = restored.owner("a");
		restored.sync(["a", "b"], "a");
		check(restored.owner("a") == owner && Lambda.count(restored.all(), g -> g.files.get().indexOf("a") >= 0) == 1,
			"closing another file moved or duplicated the active tab");
		restored.remap(path -> path == "a" ? "renamed" : path);
		restored.sync(["renamed", "b"], "renamed");
		check(restored.owner("renamed") == owner, "renaming a file lost its group");
		var one = new EditorGroups(Signal.make("a"));
		one.sync(["a"], "a");
		one.split("horizontal");
		check(one.current().files.get().length == 0
			&& one.owner("a") != null, "splitting one tab duplicated its single-view document state");
		var emptyLayout = one.snapshot(path -> path);
		var emptyActive = Signal.make(""),
			emptyRestore = new EditorGroups(emptyActive);
		emptyRestore.restore(emptyLayout, ["a"], 1, path -> path);
		check(emptyActive.get() == ""
			&& emptyRestore.current().files.get().length == 0, "restoring an intentionally empty focused group selected another tab");
		one.sync(["a", "d"], "d");
		check(one.current().files.get()[0] == "d", "new files did not open in the empty focused group");
		one.sync(["a"], "a");
		check(one.all().length == 1, "closing a group's last tab left an orphan pane");
		var pruned = new EditorGroups(Signal.make("a"));
		pruned.restore(saved, ["a"], 0, path -> path);
		check(pruned.all().length == 1 && pruned.current().files.get().join(",") == "a", "missing files left empty restored groups");
		var root = Sys.getCwd() + "bin/check-editor-groups";
		sys.FileSystem.createDirectory(root);
		for (mac in [false, true]) {
			var keys = KeyBindings.read(root, mac);
			for (command in ["splitright", "splitdown", "focusnextgroup", "focuspreviousgroup"]) {
				var chord = keys.of(command);
				check(chord != null && keys.commandFor(chord) == command && keys.conflicts(command).length == 0,
					'missing or conflicting editor group shortcut $command');
			}
			check(keys.commandFor(Chord.parse("ctrl+shift+5", mac)) == "splitterminal", "editor splitting displaced the terminal split shortcut");
		}
		var store = new WorkspaceSession(root, root),
			session:rayde.settings.WorkspaceSession.TabSession = {
				files: files,
				active: "b",
				layout: saved,
				group: index
			};
		store.close(session);
		var read = new WorkspaceSession(root, root), snapshot = read.read();
		check(snapshot != null && haxe.Json.stringify(snapshot.layout) == haxe.Json.stringify(saved) && snapshot.group == index,
			"workspace storage lost the split tree or focused group");
		read.close(null);
		var empty = new WorkspaceSession(root, root + "/empty");
		empty.close({
			files: ["a"],
			active: "",
			layout: emptyLayout,
			group: 1
		});
		var reopened = new WorkspaceSession(root, root + "/empty");
		check(reopened.read().active == "" && reopened.read().group == 1, "session storage discarded empty group focus");
		reopened.close(null);
		Sys.println("Editor groups: nested splits, ownership, focus, moves, closure, rename, restoration and non-conflicting shortcuts passed");
	}
}
