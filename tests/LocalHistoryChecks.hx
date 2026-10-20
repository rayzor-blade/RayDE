import rayde.history.LocalHistory;

class LocalHistoryChecks {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	public static function run():Void {
		var root = Sys.getCwd() + "bin/local-history-checks", file = root + "/never-staged.txt";
		sys.FileSystem.createDirectory(root);
		var history = new LocalHistory(root);
		if (sys.FileSystem.exists(history.path(file))) sys.FileSystem.deleteFile(history.path(file));
		require(history.recover(file, "original λ") == "original λ", "new file baseline");
		history.record(file, "original λ", "edited λ", {version:1, undo:[], redo:[]});
		history.record(file, "edited λ", "original λ", null, "Undo");
		history.record(file, "original λ", "other branch λ", null);
		history.dispose();
		history = new LocalHistory(root);
		require(history.recover(file, "original λ") == "other branch λ", "restart recovers never-staged edits");
		require(history.revision(file, "original λ", 1) == "edited λ", "edits undone before a branch remain recoverable");
		require(history.revision(file, "original λ", 2) == "original λ", "Undo state remains in Timeline");
		require(history.recover(file, "external change") == "external change", "recovery must not replace an external disk change");
		history.record(file, "external change", "external plus local", null); history.dispose();
		history = new LocalHistory(root);
		require(history.recover(file, "external change") == "external plus local", "new edits after an external change use the updated saved baseline");
		history.saved(file, "other branch λ", null); history.dispose();
		history = new LocalHistory(root);
		require(history.recover(file, "other branch λ") == "other branch λ", "saved baseline survives restart");
		for (i in 0...220) {
			var before = history.current(file, "other branch λ");
			history.record(file, before, "value " + i, null);
		}
		history.flush(file);
		require(history.entries(file, "other branch λ").length == LocalHistory.MAX_ENTRIES + 1, "revision retention is bounded");
		history.dispose(); history = new LocalHistory(root);
		require(history.recover(file, "other branch λ") == "value 219", "compacted patches reconstruct the latest text");
		history.dispose();
		var moved = root + "/renamed.txt";
		history = new LocalHistory(root); history.move(file, moved); history.dispose();
		history = new LocalHistory(root);
		require(history.recover(moved, "other branch λ") == "value 219" && !sys.FileSystem.exists(history.path(file)), "closed file rename preserves history");
		history.dispose(); sys.FileSystem.deleteFile(history.path(moved));
		sys.io.File.saveContent(history.path(file), "{broken");
		var errors = [];
		history = new LocalHistory(root); history.failed = message -> errors.push(message);
		require(history.recover(file, "disk") == "disk" && errors.length == 1, "corrupt history leaves disk text available");
		history.dispose(); sys.FileSystem.deleteFile(history.path(file));
		Sys.println("local history: never-staged recovery, abandoned edit branches, external changes, saved baseline, bounded patch compaction and malformed journal");
	}
}
