import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.DocumentsPart)
@:access(rayde.ui.workbench.RunPart)
class EditorGroupsLayoutChecks {
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
		Sys.println("Editor split UI: both orientations, nested resize, shortcuts, independent editors, focus, previews, undo, restore and cleanup passed in both themes");
	}

	static function run(dark:Bool):Void {
		var root = Sys.getCwd() + "bin/editor-splits-" + Std.random(0x3fffffff);
		for (dir in [root + "/home", root + "/extensions/pane", root + "/workspace"])
			sys.FileSystem.createDirectory(dir);
		Sys.putEnv("HOME", root + "/home");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/extensions");
		sys.io.File.saveContent(root + "/extensions/pane/pane.rayext",
			'{"id":"pane","main":"main.rays","views":[],"activationEvents":["onCommand:preview"],"contributes":{"commands":[{"id":"preview","title":"Preview"}]}}');
		sys.io.File.saveContent(root + "/extensions/pane/main.rays",
			'registerCommand("preview", () -> mount(() -> <div class="flex flex-col gap-3 p-4"><h2>Split preview</h2><p>This view stays visible while another editor has focus.</p></div>, "tab:Split preview"));');
		var workspace = root + "/workspace",
			files = [for (name in ["A", "B", "C"]) workspace + '/$name.txt'];
		for (file in files)
			sys.io.File.saveContent(file, [for (i in 0...100) haxe.io.Path.withoutDirectory(file) + ' — line $i'].join("\n"));
		var svg = workspace + "/badge.svg";
		sys.io.File.saveContent(svg,
			'<svg xmlns="http://www.w3.org/2000/svg" width="200" height="150"><rect width="200" height="150" rx="16" fill="#2459a0"/><circle cx="100" cy="75" r="40" fill="#ffb020"/></svg>');
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
				return new Workbench({display: new Display(compiler, workspace, []), name: "Editor groups"});
			});
			bench.openProject();
		}
		function settle(frames = 8):Void {
			for (_ in 0...frames) {
				Offscreen.advance(1 / 60);
				Css.setViewport(1460, 960);
				Css.update();
				tree.flush();
				tree.computeLayout(bench.node, 1460, 960);
			}
			var pages = Css.query(tree,bench.node.id,".rayde-tab-page");
			for (id in Css.query(tree,bench.node.id,".rayde-code-editor")) {
				var minimaps = Css.query(tree,id,".ui-code-minimap"), headers = Css.query(tree,id,".rayde-crumbs");
				check(minimaps.length == 1,"Editor lost its minimap");
				var map = tree.getScrolledBounds(new Node(minimaps[0])), editor = tree.getScrolledBounds(new Node(id));
				var ancestors = tree.ancestors(id), page = Lambda.find(pages,id -> ancestors.indexOf(id) >= 0);
				check(page != null,"Editor has no page");
				var body = tree.getScrolledBounds(new Node(page));
				check(Math.abs(map.x+map.width-body.x-body.width)<.5,"Minimap leaves a right gap in its pane");
				check(Math.abs(map.y-editor.y)<.5 && Math.abs(map.y+map.height-editor.y-editor.height)<.5,"Minimap does not fill the editor height");
				if (headers.length > 0) {
					var header = tree.getScrolledBounds(new Node(headers[0]));
					check(Math.abs(map.y-body.y)<.5 && Math.abs(header.y-map.y)<.5,"Breadcrumb leaves a top gap above the minimap");
					check(header.x+header.width <= map.x+.5,"Breadcrumb overlaps the minimap");
				}
			}
		}
		function count(selector:String):Int
			return Css.query(tree, bench.node.id, selector).length;
		function bounds(selector:String):ashui.layout.Bounds {
			var found = Css.query(tree, bench.node.id, selector);
			check(found.length > 0, 'missing $selector');
			return tree.getScrolledBounds(new Node(found[0]));
		}
		function click(selector:String):Void {
			var box = bounds(selector);
			ashui.input.Pointer.move(tree, box.x + box.width / 2, box.y + box.height / 2);
			ashui.input.Pointer.press(tree);
			ashui.input.Pointer.release(tree);
			settle();
		}
		function key(key:window.Key, alt = false, shift = false, mod = true):Void {
			var mac = Sys.systemName() == "Mac";
			var modifiers = window.Modifiers.State(shift, mod && !mac, alt, mod && mac, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown);
			for (state in [window.MouseElementState.Pressed, window.MouseElementState.Released])
				ashui.input.Keyboard.input(tree, window.KeyEvent.Input(Unidentified(Unidentified), key, None, Standard, state, false, Unavailable), modifiers);
			settle();
		}
		function until(done:Void->Bool, message:String):Void {
			var deadline = haxe.Timer.stamp() + 12;
			while (!done() && haxe.Timer.stamp() < deadline) {
				settle(3);
				Sys.sleep(.01);
			}
			check(done(), message);
			settle();
		}
		function group(file:String):String
			return "#rayde-editor-group-" + bench.editorPart.groups.owner(file).id;
		function shot(name:String):Void
			Snapshot.capture('editor-splits-${dark ? "dark" : "light"}-$name', tree, bench.node, 1460, 960);
		start();
		try {
			for (file in files)
				bench.openFile(file);
			settle();
			var stateB = bench.documentsPart.documentState(files[1]);
			click("#rayde-split-right");
			check(ashui.input.Focus.of(tree) == bench.editorFor(files[2]).editing.interaction, "splitting did not focus the new editor after remounting");
			check(count(".rayde-editor-group") == 2 && bench.editorFor(files[1]) != null && bench.editorFor(files[2]) != null,
				"right split did not mount two independent editors");
			check(bounds(group(files[2])).x > bounds(group(files[1])).x, "vertical split did not put the new group on the right");
			click(group(files[1]) + " #rayde-editor-menu-trigger");
			check(bench.active.get() == files[1], "opening an unfocused group's menu did not select that group");
			bench.menusPart.showEditorMenu(false);
			settle();
			bench.openFile(files[2]);
			settle();
			bench.runCommand("find");
			settle();
			check(bench.documentsPart.documentState(files[2]).search.opened.get() && !stateB.search.opened.get(),
				"Find affected the unfocused pane: active="
				+ bench.active.get()
				+ " C="
				+ bench.documentsPart.documentState(files[2]).search.opened.get()
				+ " B="
				+ stateB.search.opened.get()
				+ " groups="
				+ haxe.Json.stringify(bench.editorPart.groups.snapshot(path -> path)));
			bench.editorFor(files[2]).hideFind();
			click(group(files[1]) + " .ui-code-viewport");
			check(bench.active.get() == files[1], "pointer focus did not activate its group");
			bench.editorFor(files[1]).focus();
			key(Character("\\"), true);
			check(count(".rayde-editor-group") == 3 && bounds(group(files[1])).y > bounds(group(files[0])).y,
				"horizontal split shortcut did not create a pane below");
			check(bench.documentsPart.documentState(files[1]) == stateB, "moving a tab replaced its document/undo state");
			key(Named(ArrowRight), true);
			check(bench.active.get() == files[2], "focus-next-group shortcut was consumed as caret movement");
			key(Named(ArrowLeft), true);
			check(bench.active.get() == files[1], "focus-previous-group shortcut failed");
			var original = stateB.value.get();
			bench.editorFor(files[1]).applyEdits([{from: 0, to: 0, text: "unsaved split edit\n"}]);
			settle();
			bench.editorFor(files[1]).undo();
			settle();
			check(stateB.value.get() == original, "split lost undo");
			bench.editorFor(files[1]).redo();
			settle();
			check(stateB.value.get().indexOf("unsaved split edit") == 0
				&& bench.documentsPart.buffer(files[2]).get().indexOf("unsaved split edit") < 0,
				"editing one pane changed another document");
			var editorB = bench.editorFor(files[1]);
			bench.openFile(files[2]);
			settle();
			bench.openFile(files[1]);
			settle();
			check(bench.editorFor(files[1]) == editorB, "focusing an existing pane remounted its editor");
			var handle = Css.query(tree, bench.node.id, '.rayde-editor-split[data-direction="horizontal"] > .ui-resizable-handle')[0];
			var beforeWidth = bounds(group(files[2])).width;
			ashui.input.Focus.set(ashui.input.Interaction.byId(tree, handle), true);
			key(Named(ArrowLeft), false, false, false);
			check(bounds(group(files[2])).width > beforeWidth,
				"split divider did not resize with its keyboard controls: before="
				+ beforeWidth
				+ " after="
				+ bounds(group(files[2])).width
				+ " layout="
				+ haxe.Json.stringify(bench.editorPart.groups.snapshot(path -> path)));
			shot("nested");
			bench.openFile(files[2]);
			bench.openFile(svg);
			settle();
			check(count("image-preview") == 1, "image preview did not open inside its group");
			bench.runCommand("ext.pane.preview");
			until(() -> Lambda.exists(bench.open.get(), f -> StringTools.startsWith(f, "rayde:tab:")), "extension preview did not open");
			var preview = bench.active.get();
			bench.runCommand("splitdown");
			settle();
			bench.openFile(files[1]);
			settle();
			check(count("studio-tab") == 1 && count("image-preview") == 1 && bench.editorFor(files[1]) != null,
				"unfocused extension/image previews stopped rendering: extension="
				+ count("studio-tab")
				+ " image="
				+ count("image-preview")
				+ " layout="
				+ haxe.Json.stringify(bench.editorPart.groups.snapshot(path -> path)));
			shot("previews");
			bench.closeFile(preview);
			settle();
			check(count(".rayde-editor-group") == 3 && count("studio-tab") == 0, "closing the final preview tab left an orphan group or mounted view");
			bench.openFile(files[2]);
			settle();
			bench.openFile(files[1]);
			settle();
			var expected = haxe.Json.stringify(bench.editorPart.groups.snapshot(path -> haxe.io.Path.withoutDirectory(path)));
			stop();
			tree.dispose();
			stop = null;
			start();
			settle();
			check(count(".rayde-editor-group") == 3 && bench.active.get() == files[1], "workspace reopen lost the layout or focused group");
			check(haxe.Json.stringify(bench.editorPart.groups.snapshot(path -> haxe.io.Path.withoutDirectory(path))) == expected,
				"workspace reopen changed group order or divider ratio");
			check(bench.documentsPart.buffer(files[1]).get().indexOf("unsaved split edit") == 0, "workspace reopen lost unsaved recovery");
			shot("restored");
			for (_ in 0...3) {
				bench.runCommand("joingroups");
				settle();
				bench.runCommand("splitright");
				settle();
			}
			bench.runCommand("closeeditorgroup");
			settle();
			check(count(".rayde-editor-group") == 1 && bench.open.get().length == 4, "closing a group lost tabs");
			bench.runPart.saveAll();
			bench.closeAll();
			settle();
			check(count(".rayde-editor-group") == 1
				&& count(".ui-code[data-mode=editor]") == 0
				&& Lambda.count(bench.documentsPart.documents) == 0,
				"closing all groups retained editor documents");
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
