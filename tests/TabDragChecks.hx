import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.input.Pointer;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.DocumentsPart)
@:access(rayde.ui.workbench.RunPart)
@:access(rayde.ui.EditorTabDrag)
@:access(rayde.ui.EditorTabSnapshot)
class TabDragChecks {
	static function check(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
	}

	public static function main():Void {
		var home = Sys.getEnv("HOME"),
			extensions = Sys.getEnv("RAYDE_EXTENSIONS");
		try
			for (dark in [false, true])
				run(dark)
		catch (error:Dynamic) {
			Sys.putEnv("HOME", home);
			Sys.putEnv("RAYDE_EXTENSIONS", extensions);
			throw error;
		}
		Sys.putEnv("HOME", home);
		Sys.putEnv("RAYDE_EXTENSIONS", extensions);
		Sys.println("Tab dragging: reorder, pane insertion/body/empty drops, feedback, cancellation, overflow scrolling, undo, previews, persistence and cleanup passed in both themes");
	}

	static function run(dark:Bool):Void {
		var root = Sys.getCwd() + "bin/tab-drag-" + Std.random(0x3fffffff);
		for (dir in [root + "/home", root + "/extensions/pane", root + "/workspace"])
			sys.FileSystem.createDirectory(dir);
		Sys.putEnv("HOME", root + "/home");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/extensions");
		sys.io.File.saveContent(root + "/extensions/pane/pane.rayext",
			'{"id":"pane","main":"main.rays","views":[],"activationEvents":["onCommand:preview"],"contributes":{"commands":[{"id":"preview","title":"Preview"}]}}');
		sys.io.File.saveContent(root + "/extensions/pane/main.rays",
			'registerCommand("preview", () -> mount(() -> <div class="p-4"><h2>Draggable preview</h2></div>, "tab:Draggable preview"));');
		var workspace = root + "/workspace",
			files = [for (name in ["A", "B", "C"]) workspace + '/$name.txt'];
		for (file in files)
			sys.io.File.saveContent(file, 'Document ${haxe.io.Path.withoutDirectory(file)}\nOne buffer and undo history across panes.\n');
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light);
		rayde.ui.Style.use();
		var tree:LayoutTree = null,
			bench:Workbench = null,
			stop:Void->Void = null,
			compiler = new CompilerServer();
		function start():Void {
			tree = new LayoutTree();
			bench = Owner.root(tree, cleanup -> {
				stop = cleanup;
				return new Workbench({display: new Display(compiler, workspace, []), name: "Tab dragging"});
			});
			bench.openProject();
		}
		function settle(frames = 5):Void
			for (_ in 0...frames) {
				Offscreen.advance(1 / 60);
				Css.setViewport(1280, 850);
				Css.update();
				tree.flush();
				tree.computeLayout(bench.node, 1280, 850);
			}
		function count(selector:String):Int
			return Css.query(tree, bench.node.id, selector).length;
		function box(selector:String):ashui.layout.Bounds {
			var nodes = Css.query(tree, bench.node.id, selector);
			check(nodes.length > 0, 'missing $selector');
			return tree.getScrolledBounds(new Node(nodes[0]));
		}
		function pane(file:String):String
			return "#rayde-editor-group-" + bench.editorPart.groups.owner(file).id;
		function tab(file:String):String {
			var ids = Css.query(tree, bench.node.id, pane(file) + " .rayde-tab");
			for (id in ids)
				if (ashui.css.Identity.of(tree, id).attribute("data-tab-file") == file)
					return "#" + ashui.css.Identity.of(tree, id).id;
			throw 'missing tab $file';
		}
		function press(file:String):Void {
			var at = box(pane(file) + " " + tab(file) + " .rayde-tab-name");
			Pointer.move(tree, at.x + at.width / 2, at.y + at.height / 2);
			Pointer.press(tree);
		}
		function to(x:Float, y:Float):Void {Pointer.move(tree, x, y); settle();}
		function release():Void {
			Pointer.release(tree);
			settle();
		}
		function drag(file:String, x:Float, y:Float):Void {
			press(file);
			to(x, y);
			release();
		}
		function body(selector:String):{x:Float, y:Float} {
			var at = box(selector);
			return {x: at.x + at.width / 2, y: at.y + at.height / 2};
		}
		function escape():Void {
			ashui.input.Keyboard.input(tree, window.KeyEvent.Input(Unidentified(Unidentified), Named(Escape), None, Standard, Pressed, false, Unavailable));
			settle();
		}
		function until(done:Void->Bool, message:String):Void {
			var end = haxe.Timer.stamp() + 10;
			while (!done() && haxe.Timer.stamp() < end) {
				settle(3);
				Sys.sleep(.01);
			}
			check(done(), message);
			settle();
		}
		function shot(name:String):Void
			Snapshot.capture('tab-drag-${dark ? "dark" : "light"}-$name', tree, bench.node, 1280, 850);
		start();
		try {
			for (file in files)
				bench.openFile(file);
			bench.openFile(files[1]);
			settle();
			var groups = bench.editorPart.groups,
				dragger = bench.editorPart.tabDrag,
				baseline = Pointer.hooks.length;
			var state = bench.documentsPart.documentState(files[1]),
				original = state.value.get();
			bench.editorFor(files[1]).applyEdits([{from: 0, to: 0, text: "unsaved drag edit\n"}]);
			settle();
			var editor = bench.editorFor(files[1]), last = box(tab(files[2]));
			press(files[1]);
			to(last.x + last.width - 2, last.y + last.height / 2);
			check(count("#rayde-tab-drag-preview") == 1
				&& count("#rayde-tab-drop-marker") == 1
				&& count(".rayde-editor-group[data-tab-drop]") == 1,
				"drag had no insertion feedback");
			var thumbnail = dragger.snapshot.get();
			check(thumbnail != null && thumbnail.width <= 320 && thumbnail.height <= 220 && count("#rayde-tab-drag-thumbnail") == 1,
				"drag did not capture a bounded page thumbnail");
			to(last.x + last.width - 3, last.y + last.height / 2);
			check(dragger.snapshot.get() == thumbnail, "pointer movement captured another page thumbnail");
			shot("reorder");
			release();
			check(thumbnail.disposed && thumbnail.texture == null && thumbnail.view == null && thumbnail.binding == null && dragger.snapshot.get() == null,
				"drop retained thumbnail GPU resources");
			check(groups.current().files.get().join(",") == [files[0], files[2], files[1]].join(",") && bench.active.get() == files[1],
				"dragging right used the wrong insertion slot or activated the release target");
			check(bench.editorFor(files[1]) == editor, "same-pane reordering remounted the code editor");
			var first = box(tab(files[0]));
			drag(files[1], first.x + 1, first.y + first.height / 2);
			check(groups.current().files.get().join(",") == [files[1], files[0], files[2]].join(","), "dragging left lost order");
			var a = box(tab(files[0]) + " .rayde-tab-name");
			press(files[0]);
			to(a.x + a.width / 2 + 2, a.y + a.height / 2);
			check(count("#rayde-tab-drag-preview") == 0, "a click's small movement started a drag");
			release();
			check(bench.active.get() == files[0], "small pointer movement broke normal tab activation");
			var before = groups.current().files.get().join(","),
				end = box(tab(files[2]));
			press(files[1]);
			to(end.x + end.width - 2, end.y + end.height / 2);
			escape();
			release();
			check(groups.current().files.get().join(",") == before
				&& count("#rayde-tab-drag-preview") == 0
				&& Pointer.hooks.length == baseline,
				"Escape moved a tab or retained drag hooks");
			drag(files[0], 10, 20);
			check(groups.current().files.get().join(",") == before, "dropping outside the editor changed tab order");
			press(files[0]);
			to(end.x, end.y + end.height / 2);
			Pointer.leave(tree);
			release();
			check(Pointer.hooks.length == baseline && dragger.file.get() == "", "leaving the window kept a drag active");
			bench.openFile(files[0]);
			bench.runCommand("splitright");
			settle();
			var into = groups.owner(files[0]), head = box(tab(files[0]));
			press(files[1]);
			to(head.x + 1, head.y + head.height / 2);
			shot("cross-pane");
			release();
			check(into.files.get().join(",") == [files[1], files[0]].join(",") && bench.active.get() == files[1],
				"cross-pane insertion did not target the chosen slot");
			check(bench.documentsPart.documentState(files[1]) == state && bench.dirty.get().indexOf(files[1]) >= 0,
				"moving panes replaced the buffer or lost dirty state");
			var point = body(pane(files[2]));
			drag(files[0], point.x, point.y);
			check(groups.owner(files[0]).files.get().join(",") == [files[2], files[0]].join(","), "body drop did not append");
			point = body(pane(files[2]));
			drag(files[1], point.x, point.y);
			check(groups.all().length == 1 && groups.current().files.get().join(",") == [files[2], files[0], files[1]].join(","),
				"moving a pane's final tab left an empty split");
			bench.editorFor(files[1]).undo();
			settle();
			check(state.value.get() == original, "moving tabs lost undo history");
			bench.editorFor(files[1]).redo();
			settle();
			bench.closeOthers();
			settle();
			bench.runCommand("splitright");
			settle();
			var empty = groups.current();
			point = body("#rayde-editor-group-" + empty.id);
			drag(files[1], point.x, point.y);
			check(groups.all().length == 1 && groups.owner(files[1]) == empty && bench.documentsPart.documentState(files[1]) == state,
				"drop into an empty pane lost document ownership");
			var d = workspace + "/D.txt";
			sys.io.File.saveContent(d, "close button");
			bench.openFile(d);
			settle();
			var close = box(tab(d) + " .rayde-close");
			Pointer.move(tree, close.x + close.width / 2, close.y + close.height / 2);
			Pointer.press(tree);
			release();
			check(bench.open.get().indexOf(d) < 0 && count("#rayde-tab-drag-preview") == 0, "close button started dragging or stopped closing tabs");
			bench.openFile(d);
			settle();
			press(d);
			to(box(tab(files[1])).x + 5, box(tab(files[1])).y + 15);
			thumbnail = dragger.snapshot.get();
			bench.closeFile(d);
			settle();
			release();
			check(dragger.file.get() == "" && Pointer.hooks.length == baseline && thumbnail.disposed, "closing the dragged tab retained gesture resources");
			for (i in 0...12) {
				var f = workspace + '/long-file-name-for-overflow-$i.txt';
				sys.io.File.saveContent(f, 'overflow $i');
				bench.openFile(f);
			}
			bench.openFile(files[1]);
			settle();
			var scrollId = Css.query(tree, bench.node.id, "#rayde-tab-scroll")[0],
				scroll = ashui.input.Scroll.at(scrollId, tree),
				viewport = box("#rayde-tab-scroll");
			press(files[1]);
			to(viewport.x + viewport.width - 3, viewport.y + viewport.height / 2);
			settle(20);
			check(scroll.x.get() > 50, "dragging at an overflowing strip's edge did not scroll it");
			release();
			check(groups.current().files.get().indexOf(files[1]) > 0 && dragger.scrollTimer == null && Pointer.hooks.length == baseline,
				"overflow drop did not reorder or retained gesture resources");
			var expected = groups.current().files.get().copy();
			stop();
			tree.dispose();
			stop = null;
			start();
			settle();
			groups = bench.editorPart.groups;
			dragger = bench.editorPart.tabDrag;
			check(groups.current().files.get().join(",") == expected.join(",")
				&& bench.documentsPart.buffer(files[1]).get().indexOf("unsaved drag edit") == 0,
				"reordered tabs or unsaved text did not survive restart");
			var svg = workspace + "/badge.svg";
			sys.io.File.saveContent(svg,
				'<svg xmlns="http://www.w3.org/2000/svg" width="150" height="100"><rect width="150" height="100" rx="12" fill="#255aa1"/></svg>');
			bench.openFile(svg);
			bench.runCommand("ext.pane.preview");
			until(() -> Lambda.exists(bench.open.get(), f -> StringTools.startsWith(f, "rayde:tab:")), "preview did not open");
			var preview = bench.active.get();
			bench.openFile(svg);
			bench.runCommand("splitright");
			settle();
			var imageHead = box(tab(svg));
			press(preview);
			to(imageHead.x + 1, imageHead.y + imageHead.height / 2);
			check(dragger.snapshot.get() != null, "extension page had no drag thumbnail");
			shot("extension-thumbnail");
			release();
			check(count("studio-tab") == 1
				&& groups.owner(preview) == groups.owner(svg), "extension preview could not move into another tab strip");
			var other = Lambda.find(groups.all(), g -> g != groups.owner(svg));
			point = body("#rayde-editor-group-" + other.id);
			press(svg);
			to(point.x, point.y);
			check(dragger.snapshot.get() != null, "image page had no drag thumbnail");
			shot("image-thumbnail");
			release();
			check(count("image-preview") == 1 && count("studio-tab") == 1, "moving image and extension previews lost their visible roots");
			shot("previews");
			bench.openFile(files[1]);
			settle();
			press(files[1]);
			to(point.x, point.y);
			ashui.input.WindowState.active.set(false);
			settle();
			check(dragger.file.get() == "" && Pointer.hooks.length == baseline, "window deactivation retained the drag");
			ashui.input.WindowState.active.set(true);
			release();
			bench.runPart.saveAll();
			bench.closeAll();
			settle();
			check(dragger.file.get() == ""
				&& dragger.scrollTimer == null
				&& count("#rayde-tab-drag-preview") == 0
				&& Lambda.count(bench.documentsPart.documents) == 0,
				"closing tabs retained drag state or editor documents");
			bench.openFile(files[1]);
			bench.openFile(svg);
			settle();
			press(files[1]);
			to(box(tab(svg)).x + 10, box(tab(svg)).y + 15);
			stop();
			stop = null;
			tree.dispose();
			check(Pointer.hooks.length == baseline && dragger.scrollTimer == null, "closing the window during a drag left input hooks");
		} catch (error:Dynamic) {
			if (stop != null)
				stop();
			tree.dispose();
			compiler.stop();
			throw error;
		}
		if (stop != null)
			stop();
		tree.dispose();
		compiler.stop();
	}
}
