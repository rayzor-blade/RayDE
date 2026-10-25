import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.input.Clipboard;
import ashui.input.Focus;
import ashui.input.Pointer;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.DocumentsPart)
@:access(rayde.ui.workbench.EditorPart)
@:access(rayde.ui.workbench.ExtensionsPart)
class TabContextMenuChecks {
	static function check(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static function main():Void {
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
		Sys.println("Tab context menus: inactive targets, focus/selection, lazy rows, save one file, scoped close variants, split/move, extension actions, previews and cleanup passed in both themes");
	}

	static function run(dark:Bool):Void {
		var root = Sys.getCwd() + "bin/tab-context-" + Std.random(0x3fffffff);
		for (directory in ["home", "workspace", "extensions/tabs"])
			sys.FileSystem.createDirectory(root + "/" + directory);
		Sys.putEnv("HOME", root + "/home");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/extensions");
		sys.io.File.saveContent(root + "/extensions/tabs/tabs.rayext",
			'{"id":"tabs","main":"main.rays","activationEvents":["onCommand:inspect","onCommand:preview"],"contributes":{"commands":[{"id":"inspect","title":"Inspect Tab"},{"id":"preview","title":"Preview"}],"menus":{"editor/title":[{"command":"inspect","when":{"ext":[".txt"]}}]}}}');
		sys.io.File.saveContent(root + "/extensions/tabs/main.rays",
			'import haxe.Json.stringify; registerCommand("inspect", args -> trace("TAB:"+stringify(args))); registerCommand("preview", _ -> mount(() -> <div id="tab-menu-preview"><text>Tab menu preview</text></div>, "tab:Preview"));');
		var files = [
			for (name in ["A", "B", "C", "D", "E", "F"])
				root + "/workspace/" + name + ".txt"
		];
		for (file in files)
			sys.io.File.saveContent(file, haxe.io.Path.withoutDirectory(file) + " original\n");
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light);
		rayde.ui.Style.use();
		var tree = new LayoutTree(),
			compiler = new CompilerServer(),
			dispose:Void->Void = null;
		var wb = Owner.root(tree, cleanup -> {
			dispose = cleanup;
			return new Workbench({display: new Display(compiler, root + "/workspace", []), name: "Tab menus"});
		});
		function settle(frames = 4):Void
			for (_ in 0...frames) {
				Offscreen.advance(.025);
				Css.setViewport(1200, 820);
				Css.update();
				tree.flush();
				tree.computeLayout(wb.node, 1200, 820);
			}
		function nodes(selector:String)
			return Css.query(tree, tree.root.id, selector);
		function until(done:Void->Bool, message:String):Void {
			var end = haxe.Timer.stamp() + 12;
			while (!done() && haxe.Timer.stamp() < end) {
				settle();
				Sys.sleep(.005);
			}
			check(done(), message + ": " + wb.notice.get());
			settle();
		}
		function click(selector:String):Void {
			var found = nodes(selector);
			check(found.length == 1, "Missing or duplicate " + selector);
			var box = tree.getScrolledBounds(new Node(found[0]));
			Pointer.move(tree, box.x + box.width / 2, box.y + box.height / 2);
			Pointer.press(tree);
			Pointer.release(tree);
			settle();
		}
		function menu(file:String, closeButton = false):Void {
			var selector = '.rayde-tab[data-tab-file="' + file + '"]' + (closeButton ? ' .rayde-close' : ' .rayde-tab-name');
			var found = nodes(selector);
			check(found.length == 1, "Missing tab " + file);
			var owner = wb.editorPart.groups.owner(file),
				scrollId = nodes('#rayde-editor-group-' + owner.id + ' #rayde-tab-scroll')[0];
			var scrollNode = ashui.input.Interaction.byId(tree, scrollId).node,
				scroll = ashui.input.Scroll.of(scrollNode);
			var box = tree.getScrolledBounds(new Node(found[0])),
				viewport = tree.getScrolledBounds(scrollNode);
			if (box.x < viewport.x)
				scroll.jumpTo(scroll.x.get() + box.x - viewport.x - 8, 0);
			else if (box.x + box.width > viewport.x + viewport.width)
				scroll.jumpTo(scroll.x.get() + box.x + box.width - viewport.x - viewport.width + 8, 0);
			settle();
			box = tree.getScrolledBounds(new Node(found[0]));
			Pointer.move(tree, box.x + box.width / 2, box.y + box.height / 2);
			Pointer.press(tree, Right);
			Pointer.release(tree, Right);
			settle();
			check(nodes("#rayde-tab-menu-close").length == 1, "Tab secondary press did not open its menu");
			check(wb.editorPart.tabDrag.file.get() == "", "Context menu started a tab drag");
		}
		function layout():Void {
			wb.closeAll();
			settle();
			for (file in files)
				wb.openFile(file);
			settle();
			wb.editorPart.splitEditor("horizontal");
			settle();
			check(wb.active.get() == files[5] && wb.editorPart.groups.all().length == 2, "Fixture did not create two split groups");
		}
		try {
			wb.openProject();
			layout();
			var front = wb.editorFor(files[5]), original = front.value.get();
			front.focus();
			front.select(0, 5);
			settle();
			var entry = wb.extensionsPart.extensionManager.extensions[0];
			check(!entry.connection.running(), "Fixture extension activated before use");
			check(nodes("#rayde-tab-menu-close").length == 0, "Closed tab menus allocated their rows");
			menu(files[0]);
			check(wb.active.get() == files[5], "Opening an inactive tab menu activated " + wb.active.get());
			check(wb.editorFor(files[0]) == null, "Opening an inactive tab menu loaded its editor");
			check(front.editing.selection() == original.substr(0, 5),
				"Opening a tab menu lost the current selection: "
				+ front.editing.anchor.get()
				+ ","
				+ front.editing.caret.get());
			check(!entry.connection.running(), "Listing extension title actions started its VM");
			check(nodes("#rayde-tab-menu-close-left:disabled").length == 1 && nodes("#rayde-tab-menu-close-right:disabled").length == 0,
				"Close directions ignored the clicked tab position");
			Snapshot.capture('tab-context-${dark ? "dark" : "light"}', tree, wb.node, 1200, 820);
			click("#rayde-tab-menu-copy-path");
			check(Clipboard.text() == files[0] && wb.active.get() == files[5], "Copy Path used the active tab");
			check(Focus.of(tree) == front.editing.interaction && front.editing.selection() == original.substr(0, 5),
				"Tab menu did not restore focus and selection");
			menu(files[1], true);
			click("#rayde-tab-menu-copy-relative");
			check(Clipboard.text() == "B.txt" && wb.open.get()
				.indexOf(files[1]) >= 0, "Right-clicking a close button closed its tab or copied the wrong path");
			for (index in [0, 1]) {
				wb.documentsPart.buffer(files[index]).set("unsaved " + index);
				wb.documentsPart.edited(files[index]);
			}
			settle();
			menu(files[0]);
			click("#rayde-tab-menu-save");
			check(sys.io.File.getContent(files[0]) == "unsaved 0"
				&& sys.io.File.getContent(files[1]) == "B.txt original\n"
				&& wb.dirty.get().indexOf(files[1]) >= 0
				&& wb.active.get() == files[5],
				"Save wrote another tab or activated its target");
			var supplied:Array<Dynamic> = [],
				previous = entry.connection.onEntry;
			entry.connection.onEntry = (owner, item) -> {
				if (previous != null)
					previous(owner, item);
				if (StringTools.startsWith(item.text, "TAB:"))
					supplied.push(haxe.Json.parse(item.text.substr(4)));
			};
			menu(files[0]);
			click("#rayde-menu-ext-tabs-inspect");
			until(() -> supplied.length == 1, "Extension title action did not run");
			check(supplied[0].path == files[0] && wb.active.get() == files[5], "Extension action used the active tab");
			menu(files[0]);
			click("#rayde-tab-menu-close");
			check(wb.open.get().indexOf(files[0]) < 0 && wb.open.get().indexOf(files[5]) >= 0, "Close Tab closed the active split instead of its target");
			layout();
			menu(files[2]);
			click("#rayde-tab-menu-close-left");
			check(wb.editorPart.groups.owner(files[2]).files.get().join("|") == files.slice(2, 5).join("|")
				&& wb.open.get().indexOf(files[5]) >= 0,
				"Close Left crossed a split or used the active index");
			layout();
			menu(files[2]);
			click("#rayde-tab-menu-close-right");
			check(wb.editorPart.groups.owner(files[2]).files.get().join("|") == files.slice(0, 3).join("|")
				&& wb.open.get().indexOf(files[5]) >= 0,
				"Close Right crossed a split or used the active index");
			layout();
			menu(files[2]);
			click("#rayde-tab-menu-close-others");
			check(wb.open.get().length == 2 && wb.open.get().indexOf(files[2]) >= 0 && wb.open.get().indexOf(files[5]) >= 0,
				"Close Others crossed the clicked split");
			layout();
			menu(files[2]);
			click("#rayde-tab-menu-close-saved");
			check(wb.open.get().length == 2 && wb.open.get().indexOf(files[1]) >= 0 && wb.open.get().indexOf(files[5]) >= 0,
				"Close Saved lost a dirty tab or closed another split");
			layout();
			menu(files[2]);
			click("#rayde-tab-menu-close-all");
			check(wb.open.get().length == 1 && wb.active.get() == files[5] && wb.editorPart.groups.all().length == 1, "Close All affected another split");
			layout();
			var before = wb.documentsPart.documentState(files[0]),
				left = wb.editorPart.groups.owner(files[0]);
			menu(files[0]);
			click("#rayde-tab-menu-move");
			check(wb.editorPart.groups.owner(files[0]) == wb.editorPart.groups.owner(files[5]), "Move used the wrong tab");
			check(wb.active.get() == files[0], "Move did not activate its target: " + wb.active.get());
			check(wb.documentsPart.documentState(files[0]) == before, "Move replaced document state");
			layout();
			left = wb.editorPart.groups.owner(files[0]);
			menu(files[0]);
			click("#rayde-tab-menu-split-down");
			check(wb.editorPart.groups.all().length == 3 && wb.editorPart.groups.owner(files[0]) != left && wb.active.get() == files[0],
				"Split did not move the clicked tab");
			wb.runCommand("ext.tabs.preview");
			until(() -> Lambda.exists(wb.open.get(), Workbench.isTab), "Preview did not open");
			var preview = Lambda.find(wb.open.get(), Workbench.isTab);
			menu(preview);
			check(nodes("#rayde-tab-menu-copy-path:disabled").length == 1 && nodes("#rayde-tab-menu-save:disabled").length == 1,
				"Virtual preview offered file operations");
			click("#rayde-tab-menu-close");
			until(() -> wb.open.get().indexOf(preview) < 0, "Preview context close failed");
			menu(files[0]);
			wb.closeFile(files[0]);
			settle();
			check(nodes("#rayde-tab-menu-close").length == 0, "Closing the target retained its popup");
			wb.closeAll();
			settle();
			check(nodes("#rayde-tab-menu-close").length == 0, "Closing all tabs retained menu rows");
		} catch (error:Dynamic) {
			dispose();
			tree.dispose();
			compiler.stop();
			throw error;
		}
		dispose();
		tree.dispose();
		compiler.stop();
	}
}
