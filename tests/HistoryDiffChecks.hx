import rayde.history.LocalHistory;
import rayde.history.LineOwners;
import rayde.history.GitHistory;
import rayde.history.FileComparison;
import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

@:access(rayde.history.FileComparison)
@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.DocumentsPart)
@:access(rayde.ui.workbench.EditorPart)
class HistoryDiffChecks {
	static function check(ok:Bool, why:String):Void {
		if (!ok)
			throw why;
	}

	static function main():Void {
		LocalHistoryChecks.run();
		data();
		var home = Sys.getEnv("HOME"),
			extensions = Sys.getEnv("RAYDE_EXTENSIONS");
		try
			for (dark in [false, true])
				ui(dark)
		catch (error:Dynamic) {
			Sys.putEnv("HOME", home);
			Sys.putEnv("RAYDE_EXTENSIONS", extensions);
			throw error;
		}
		Sys.putEnv("HOME", home);
		Sys.putEnv("RAYDE_EXTENSIONS", extensions);
		Sys.println("History diff: Git blame, unsaved/local authors, journal recovery/compaction, stable Jam baseline, live split updates, source selection, tab reuse, hidden workers and cleanup passed in both themes");
	}

	static function data():Void {
		var root = Sys.getCwd() + "bin/history-data-" + Std.random(0x3fffffff),
			file = root + "/source file.txt";
		sys.FileSystem.createDirectory(root);
		function git(args:Array<String>)
			return StringTools.trim(GitHistory.command(root, args, () -> false));
		git(["init"]);
		var original = "one\nsame\nlast\n",
			head = "one\nsame\nbob\n",
			live = "one\npeer\nbob\nnew\n";
		sys.io.File.saveContent(file, original);
		git(["add", "--", "source file.txt"]);
		git([
			"-c",
			"user.name=Ada",
			"-c",
			"user.email=ada@example.test",
			"commit",
			"-m",
			"First"
		]);
		var first = git(["rev-parse", "HEAD"]);
		sys.io.File.saveContent(file, head);
		git(["add", "--", "source file.txt"]);
		git([
			"-c",
			"user.name=Bob",
			"-c",
			"user.email=bob@example.test",
			"commit",
			"-m",
			"Second"
		]);
		var repo = GitHistory.load(file, () -> false);
		check(repo.current.text == head && repo.current.owners[0] == "Ada" && repo.current.owners[2] == "Bob", "Git blame did not follow real line authors");
		var history = new LocalHistory(root);
		history.recover(file, head);
		history.record(file, head, live, null, "Edit", "raikage");
		var journal = history.snapshot(file, head);
		var point = LineOwners.latest(journal);
		check(LineOwners.latest(journal, point).value == point.value, "Unchanged history replayed all patches");
		var result = FileComparison.compare({
			file: file,
			text: live,
			journal: journal,
			jam: null,
			opened: live,
			catalog: null,
			base: null,
			selected: "git:" + first
		}, () -> false);
		check(result.base.text == original && result.text == live, "Selected commit and live buffer were not compared");
		check(Lambda.exists(result.hints, h -> h.side == "original" && h.line == 2 && h.text == "Ada"), "Deleted Git lines lost their committed author");
		check(Lambda.exists(result.hints, h -> h.side == "modified" && h.line == 2 && h.text == "Bob"),
			"Existing committed changes were blamed on the local editor");
		check(Lambda.exists(result.hints, h -> h.side == "modified" && h.line == 1 && h.text == "raikage"), "Jam author's edited line was not attributed");
		check(Lambda.exists(result.hints, h -> h.side == "modified" && h.line == 3 && h.text == "raikage"), "Jam author's inserted line was not attributed");
		check(!Lambda.exists(result.hints, h -> h.text.indexOf("@") >= 0), "Author hints leaked email addresses");
		history.saved(file, live, null);
		history.dispose();
		history = new LocalHistory(root);
		check(LineOwners.revision(history.snapshot(file, head)).owners[1] == "raikage", "Save or restart lost known author metadata");
		var before = live;
		for (i in 0...205) {
			var after = live + "tail " + i;
			history.record(file, before, after, null, "Edit", "amaterasu");
			before = after;
		}
		check(LineOwners.revision(history.snapshot(file, head)).owners[1] == "raikage", "Compaction discarded surviving line ownership");
		check(LineOwners.latest(history.snapshot(file, head), point).value.text == before, "Trimmed history did not rebuild a stale attribution checkpoint");
		history.dispose();
		// An inserted whole line must not steal the author of its untouched successor.
		var owners = LineOwners.patch({text: "a\nb\nc", owners: ["A", "B", "C"]}, {
			id: 1,
			parent: 0,
			time: 0.,
			kind: "Edit",
			from: 2,
			removed: "",
			inserted: "new\n",
			author: "N"
		});
		check(owners.owners.join(",") == "A,N,B,C", "Line insertion shifted blame incorrectly: " + owners.owners);
		owners = LineOwners.patch(owners, {
			id: 2,
			parent: 1,
			time: 0.,
			kind: "Edit",
			from: 2,
			removed: "new\n",
			inserted: "",
			author: "D"
		});
		check(owners.owners.join(",") == "A,B,C", "Whole-line deletion stole unchanged ownership");
		var old:rayde.history.LineOwners.HistoryJournal = {
			base: "a\nb",
			baseId: 0,
			owners: [],
			revisions: [
				{
					id: 1,
					parent: 0,
					time: 0.,
					kind: "Edit",
					from: 2,
					removed: "b",
					inserted: "B"
				}
			]
		};
		check(LineOwners.revision(old).owners[1] == null, "Old journals fabricated authors");
		var untracked = root + "/untracked.txt";
		sys.io.File.saveContent(untracked, "old");
		var local = new LocalHistory(root);
		local.recover(untracked, "old");
		local.record(untracked, "old", "new", null, "Edit", "Local edit");
		var jam = FileComparison.compare({
			file: untracked,
			text: "new",
			journal: local.snapshot(untracked, "old"),
			jam: {id: "jam", label: "Jam start", text: "old"},
			opened: "new",
			catalog: null,
			base: null,
			selected: ""
		}, () -> false);
		check(jam.selected == "jam" && jam.base.text == "old" && jam.hunks.length == 1, "Untracked Jam file could not compare with its session baseline");
		var cancelled = false;
		try
			GitHistory.command(root, ["status"], () -> true)
		catch (_:Dynamic)
			cancelled = true;
		check(cancelled, "Cancelled Git work still ran");
		local.dispose();
	}

	static function ui(dark:Bool):Void {
		var root = Sys.getCwd() + "bin/history-ui-" + Std.random(0x3fffffff);
		for (name in ["home", "workspace", "extensions"])
			sys.FileSystem.createDirectory(root + "/" + name);
		Sys.putEnv("HOME", root + "/home");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/extensions");
		var file = root + "/workspace/Example.txt",
			other = root + "/workspace/Other.txt";
		sys.io.File.saveContent(file, "first\noriginal\nlast\n");
		sys.io.File.saveContent(other, "other");
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light);
		rayde.ui.Style.use();
		var tree = new LayoutTree(),
			compiler = new CompilerServer(),
			stop:Void->Void = null;
		var wb = Owner.root(tree, clean -> {
			stop = clean;
			return new Workbench({display: new Display(compiler, root + "/workspace", []), name: "History"});
		});
		function settle():Void
			for (_ in 0...4) {
				Offscreen.advance(.03);
				Css.setViewport(1100, 760);
				Css.update();
				tree.flush();
				tree.computeLayout(wb.node, 1100, 760);
			}
		function click(selector:String):Void {
			var found = Css.query(tree, wb.node.id, selector);
			check(found.length == 1, "Missing control " + selector);
			var bounds = tree.getScrolledBounds(new ashui.layout.Node(found[0]));
			ashui.input.Pointer.move(tree, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
			settle();
			ashui.input.Pointer.press(tree);
			ashui.input.Pointer.release(tree);
			settle();
		}
		function until(done:Void->Bool, why:String):Void {
			var end = haxe.Timer.stamp() + 20.;
			while (!done() && haxe.Timer.stamp() < end) {
				settle();
				Sys.sleep(.01);
			}
			check(done(), why);
			settle();
		}
		try {
			wb.openFile(file);
			settle();
			check(Css.query(tree, wb.node.id, "#rayde-open-history-diff").length == 1, "History icon missing beside split controls");
			wb.editorFor(file).applyEdits([{from: 6, to: 14, text: "updated"}]);
			settle();
			click("#rayde-open-history-diff");
			var id = Workbench.DIFF_TAB + file,
				model = wb.documentsPart.comparisonTabs.get(id);
			check(wb.active.get() == id && model != null, "Command did not open the native history tab");
			until(() -> !model.loading.get() && model.modified.get().indexOf("updated") >= 0, "Local diff did not load");
			check(model.error.get() == "" && model.original.get().indexOf("original") >= 0, "Timeline original baseline not available");
			check(Css.query(tree, wb.node.id, ".ui-code-diff-hint-text").length >= 2, "Inline authors missing");
			// Keep the live diff mounted in one group and type in the other.
			wb.editorPart.splitEditor("horizontal");
			settle();
			wb.openFile(file);
			settle();
			wb.editorFor(file).applyEdits([{from: 6, to: 13, text: "live peer edit"}]);
			settle();
			until(() -> model.modified.get().indexOf("live peer edit") >= 0
				&& !model.loading.get(), "Split diff failed to follow the live buffer");
			check(model.original.get().indexOf("original") >= 0, "Live edits moved the baseline");
			model.layout.set("split");
			settle();
			check(Css.query(tree, wb.node.id, ".ui-code-diff-viewport").length == 2, "Split layout did not create two panes");
			Snapshot.capture("history-diff-" + (dark ? "dark" : "light"), tree, wb.node, 1100, 760);
			wb.openFile(id);
			settle();
			var count = wb.open.get().length;
			wb.runCommand("filehistorydiff");
			settle();
			check(wb.open.get().length == count, "Repeated history action duplicated a tab");
			model.choose("opened");
			until(() -> !model.loading.get(), "Baseline selection stalled");
			check(model.original.get().indexOf("updated") >= 0, "Since-opening baseline changed after subsequent edits");
			var revision = wb.documentsPart.localHistory.entries(file, wb.documentsPart.buffer(file).get());
			var oldest = revision[revision.length - 1].id;
			wb.documentsPart.previewHistory(file, oldest);
			settle();
			click("#rayde-history-compare");
			until(() -> !model.loading.get()
				&& model.selected.get() == "local:" + oldest, "Timeline preview did not compare its chosen revision");
			check(model.original.get().indexOf("original") >= 0, "Timeline preview compared the wrong baseline");
			model.layout.set("inline");
			wb.editorPart.joinGroups();
			settle();
			Snapshot.capture("history-diff-inline-" + (dark ? "dark" : "light"), tree, wb.node, 1100, 760);
			wb.openFile(other);
			settle();
			check(model.worker == null, "Hidden comparison retained its worker");
			wb.closeFile(file);
			settle();
			check(wb.documentsPart.buffers.exists(file), "Open comparison lost its underlying buffer");
			wb.closeFile(id);
			settle();
			check(!wb.documentsPart.comparisonTabs.exists(id) && model.catalog == null && model.original.get() == "",
				"Closed comparison retained history data");
		} catch (error:Dynamic) {
			stop();
			tree.dispose();
			compiler.stop();
			throw error;
		}
		stop();
		tree.dispose();
		compiler.stop();
	}
}
