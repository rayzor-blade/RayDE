import ashui.components.CodeEditor;
import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.input.Clipboard;
import ashui.input.Focus;
import ashui.input.Keyboard;
import ashui.input.Pointer;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.lang.LspProtocol;
import rayde.lang.WorkspaceEdits;
import rayde.ui.EditorCommands;
import rayde.ui.Workbench;

@:access(rayde.ui.Workbench)
@:access(rayde.ui.EditorCommands)
@:access(rayde.ui.workbench.CodeActionsPart)
@:access(rayde.ui.workbench.DocumentsPart)
@:access(rayde.ui.workbench.EditorPart)
@:access(rayde.ui.workbench.ExtensionsPart)
@:access(rayde.ui.workbench.ExplorerPart)
@:access(rayde.ui.workbench.KeymapPart)
@:access(rayde.ui.workbench.LanguagesPart)
@:access(ashui.components.code.CodeEditorState)
class EditorContextMenuChecks {
	static function check(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static function main():Void {
		editChecks();
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
		Sys.println("Editor context menu: pointer/keyboard, split targeting, selection, clipboard/undo, read-only, Code Actions, extensions, LSP navigation/edits, stale results and cleanup passed in both themes");
	}

	static function editChecks():Void {
		var text = "λ😀 value\r\nnext",
			uri = LspProtocol.uri("/workspace/a b.hx");
		function edit(from:Int, to:Int, value:String):Dynamic
			return {range: {start: {line: 0, character: from}, end: {line: 0, character: to}}, newText: value};
		var edits = WorkspaceEdits.edits(text, [edit(4, 9, "name")]);
		check(WorkspaceEdits.text(text, edits) == "λ😀 name\r\nnext", "UTF-16 or CRLF edit offsets changed");
		check(WorkspaceEdits.text("x", WorkspaceEdits.edits("x", [edit(0, 0, "first"), edit(0, 0, "second")])) == "firstsecondx",
			"Same-position insertions lost the server's ordering");
		function refused(action:Void->Void):Bool {
			try
				action()
			catch (_:Dynamic)
				return true;
			return false;
		}
		check(refused(() -> WorkspaceEdits.edits(text, [edit(4, 10, "x"), edit(5, 6, "y")])), "Overlapping text edits were accepted");
		check(refused(() -> WorkspaceEdits.edits(text, [edit(90, 100, "x")])), "Out-of-range edits were clamped");
		check(refused(() -> WorkspaceEdits.documents({documentChanges: [{kind: "rename", oldUri: uri, newUri: uri + "x"}]})),
			"Resource operations were accepted as text edits");
		var changes:Dynamic = {};
		Reflect.setField(changes, uri, [edit(4, 9, "name")]);
		check(WorkspaceEdits.documents({changes: changes})[0].file == "/workspace/a b.hx", "Workspace edit URI did not round trip");
	}

	static function run(dark:Bool):Void {
		var root = Sys.getCwd() + "bin/editor-context-" + Std.random(0x3fffffff);
		for (directory in ["home", "extensions/actions", "workspace"])
			sys.FileSystem.createDirectory(root + "/" + directory);
		Sys.putEnv("HOME", root + "/home");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/extensions");
		var manifest:Dynamic = haxe.Json.parse(sys.io.File.getContent("tests/fixtures/codeactions/actions.rayext"));
		manifest.contributes = {
			commands: [{id: "inspect", title: "Inspect Selection", icon: "edit"}],
			menus: {
				"editor/context": [
					{
						command: "inspect",
						when: {ext: [".hx"]}
					}
				]
			}
		};
		sys.io.File.saveContent(root + "/extensions/actions/actions.rayext", haxe.Json.stringify(manifest));
		sys.io.File.saveContent(root + "/extensions/actions/main.rays",
			sys.io.File.getContent("tests/fixtures/codeactions/main.rays") +
			'\nimport haxe.Json.stringify; registerCommand("inspect", args -> trace("CONTEXT:" + stringify(args)));');
		var file = root + "/workspace/A.hx",
			other = root + "/workspace/B.hx",
			source = "class A {\n  var value = 0;\n}\n";
		sys.io.File.saveContent(file, source);
		sys.io.File.saveContent(other, "class B {}\n");
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light);
		rayde.ui.Style.use();
		var tree = new LayoutTree(),
			compiler = new CompilerServer(),
			dispose:Void->Void = null;
		var bench = Owner.root(tree, cleanup -> {
			dispose = cleanup;
			return new Workbench({display: new Display(compiler, root + "/workspace", []), name: "Context menus"});
		});
		var locked = ashui.reactive.Signal.make(false);
		bench.contributions.readOnlyWhen(path -> path == file && locked.get());
		var requests = root + "/requests.jsonl";
		bench.languagesPart.languageServers.register("context-checks", {
			id: "context",
			languages: ["haxe"],
			fileExtensions: [".hx"],
			transport: {kind: "stdio", command: "python3", args: [Sys.getCwd() + "tests/editor_context_lsp.py", requests]}
		}, (_, _) -> {});
		function settle(frames = 4):Void
			for (_ in 0...frames) {
				Offscreen.advance(.025);
				Css.setViewport(1200, 820);
				Css.update();
				tree.flush();
				tree.computeLayout(bench.node, 1200, 820);
			}
		function nodes(selector:String)
			return Css.query(tree, tree.root.id, selector);
		function until(done:Void->Bool, message:String):Void {
			var end = haxe.Timer.stamp() + 15;
			while (!done() && haxe.Timer.stamp() < end) {
				settle();
				Sys.sleep(.005);
			}
			check(done(), message + ": " + bench.notice.get());
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
		function key(value:window.Key, shift = false):Void {
			var mods = window.Modifiers.State(shift, false, false, false, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown);
			for (state in [window.MouseElementState.Pressed, window.MouseElementState.Released])
				Keyboard.input(tree, window.KeyEvent.Input(Unidentified(Unidentified), value, None, Standard, state, false, Unavailable), mods);
			settle();
		}
		function menu(editor:CodeEditor, at:Int):Void {
			var box = editor.rectAt(at);
			check(box != null, "Missing character geometry");
			Pointer.move(tree, box.x + 1, box.y + box.height / 2);
			Pointer.press(tree, Right);
			Pointer.release(tree, Right);
			settle();
			check(nodes("#rayde-code-menu-codeactions").length == 1, "Secondary press did not open the editor menu");
		}
		try {
			bench.openProject();
			bench.openFile(file);
			bench.openFile(other);
			settle();
			bench.editorPart.splitEditor("horizontal");
			settle();
			var editor = bench.editorFor(file), right = bench.editorFor(other);
			until(() -> EditorCommands.available(bench, file, "references"), "Fixture language server did not start");
			check(nodes("#rayde-code-menu-copy").length == 0, "Closed editors allocated menu rows");
			var from = source.indexOf("value");
			right.focus();
			settle();
			menu(editor, from + 2);
			check(bench.active.get() == file, "Right-click targeted another pane");
			key(Named(Escape));
			editor.focus();
			editor.select(from, from + 5);
			settle();
			menu(editor, from + 2);
			check(bench.active.get() == file && editor.editing.selection() == "value",
				"Right-click lost the selection or targeted another pane: "
				+ bench.active.get()
				+ " selection="
				+ editor.editing.selection()
				+ " range="
				+ haxe.Json.stringify(editor.editing.selectionRange()));
			check(nodes("#rayde-code-menu-references:disabled").length == 0, "Supported navigation was disabled");
			check(nodes("#rayde-code-menu-codeactions .ui-menu-item-label").length == 1, "Code Actions menu entry is missing");
			Snapshot.capture('editor-context-${dark ? "dark" : "light"}', tree, bench.node, 1200, 820);
			click("#rayde-code-menu-copy");
			check(Clipboard.text() == "value", "Copy read another pane's selection");
			check(Focus.of(tree) == editor.editing.interaction && nodes("#rayde-code-menu-copy").length == 0,
				"Closing the menu retained rows or lost editor focus");
			menu(editor, from + 1);
			click("#rayde-code-menu-cut");
			check(editor.value.get().indexOf("value") < 0 && right.value.get() == "class B {}\n", "Cut changed the wrong document");
			menu(editor, 0);
			click("#rayde-code-menu-undo");
			check(editor.value.get() == source, "Context cut was not undoable");
			editor.select(from, from + 5);
			Clipboard.setText("next");
			menu(editor, from + 1);
			click("#rayde-code-menu-paste");
			check(editor.value.get().indexOf("var next") >= 0, "Paste ignored the selection");
			editor.undo();
			settle();
			editor.focus();
			key(Named(F10), true);
			check(nodes("#rayde-code-menu-copy").length == 1, "Shift+F10 did not open the menu");
			key(Named(Escape));
			check(nodes("#rayde-code-menu-copy").length == 0
				&& Focus.of(tree) == editor.editing.interaction, "Escape did not restore editor focus");
			editor.select(from, from + 5);
			locked.set(true);
			settle();
			menu(editor, from + 1);
			check(nodes("#rayde-code-menu-cut:disabled").length == 1
				&& nodes("#rayde-code-menu-copy:disabled").length == 0
				&& nodes("#rayde-code-menu-formatdocument:disabled").length == 1,
				"Read-only editor offered mutation actions");
			key(Named(Escape));
			bench.codeActionsPart.showCodeActions();
			until(() -> Lambda.exists(bench.codeActionsPart.codeActions.list(), item -> item.action.kind == "quickfix"),
				"Read-only action provider did not respond");
			var fix = Lambda.find(bench.codeActionsPart.codeActions.list(), item -> item.action.kind == "quickfix");
			check(!bench.codeActionsPart.executeCodeAction(fix.key, bench.codeActionsPart.codeActionVersion)
				&& editor.value.get() == source,
				"A Code Action modified a read-only document");
			bench.quickOpen.set(false);
			settle();
			locked.set(false);
			settle();
			editor.select(from, from + 5);
			menu(editor, from + 1);
			click("#rayde-code-menu-codeactions");
			until(() -> bench.quickOpen.get()
				&& Lambda.exists(bench.centerRequest.get().picker.items, item -> item.label == "Set value to one"),
				"Code Actions did not use the provider picker");
			bench.quickOpen.set(false);
			settle();
			var supplied:Array<Dynamic> = [],
				entry = Lambda.find(bench.extensionsPart.extensionManager.extensions, e -> e.connection.manifest.id == "code-action-fixture");
			var onEntry = entry.connection.onEntry;
			entry.connection.onEntry = (owner, item) -> {
				if (onEntry != null)
					onEntry(owner, item);
				if (StringTools.startsWith(item.text, "CONTEXT:"))
					supplied.push(haxe.Json.parse(item.text.substr(8)));
			};
			editor.select(from, from + 5);
			menu(editor, from + 1);
			click("#rayde-code-menu-ext-code-action-fixture-inspect");
			until(() -> supplied.length == 1, "Extension context command did not run");
			check(supplied[0].path == file && supplied[0].kind == "file" && supplied[0].range.from == from && supplied[0].range.to == from + 5,
				"Extension command lost its file or selection range");
			menu(editor, from + 1);
			click("#rayde-code-menu-references");
			until(() -> bench.quickOpen.get()
				&& bench.centerRequest.get().picker.items.length == 2, "References did not open a location picker");
			bench.quickOpen.set(false);
			settle();
			for (command in ["definition", "typedefinition", "implementation"]) {
				editor.select(0, source.length);
				menu(editor, from + 1);
				click("#rayde-code-menu-" + command);
				until(() -> editor.editing.caret.get() == 6, command + " did not navigate");
			}
			var calls:Array<Dynamic> = [
				for (line in sys.io.File.getContent(requests).split("\n"))
					if (line != "") haxe.Json.parse(line)
			];
			for (method in ["definition", "typeDefinition", "implementation"]) {
				var call:Dynamic = Lambda.find(calls, (item:Dynamic) -> item.method == "textDocument/" + method);
				check(call != null && call.params.position.line == 1 && call.params.position.character == 7,
					"Navigation used the selection endpoint instead of the clicked symbol");
			}
			editor.focus();
			key(Named(F2));
			check(bench.prompt.get() != null && bench.prompt.get().title == "Rename Symbol", "F2 did not rename the editor symbol");
			bench.prompt.set(null);
			settle();
			settle(12);
			Focus.set(ashui.input.Interaction.byId(tree, nodes("#rayde-files .ui-tree-row[data-selected]")[0]), true);
			check(bench.explorerPart.explorerFocused(), "Explorer did not receive focus");
			key(Named(F2));
			check(bench.prompt.get() != null && bench.prompt.get().title != "Rename Symbol",
				"F2 in Explorer did not rename its file: title="
				+ (bench.prompt.get() == null ? "none" : bench.prompt.get().title)
				+ " focused="
				+ bench.explorerPart.explorerFocused()
				+ " selected="
				+ bench.explorerPart.selectedPath());
			bench.prompt.set(null);
			settle();
			bench.keymapPart.bindings.set("commands",rayde.keys.Chord.parse("f2",Sys.systemName()=="Mac"));
			Focus.set(ashui.input.Interaction.byId(tree,nodes("#rayde-files .ui-tree-row[data-selected]")[0]),true); key(Named(F2));
			check(bench.quickOpen.get() && bench.prompt.get()==null,"Explorer shadowed a user-assigned global key");
			bench.quickOpen.set(false); bench.keymapPart.bindings.reset("commands"); settle();
			editor.focus();
			editor.select(from, from);
			menu(editor, from);
			click("#rayde-code-menu-renamesymbol");
			until(() -> bench.prompt.get() != null, "Rename did not prompt");
			bench.prompt.get().accept("renamed");
			bench.prompt.set(null);
			until(() -> editor.value.get().indexOf("var renamed") >= 0, "Rename edits were not applied");
			editor.undo();
			settle();
			menu(editor, from);
			click("#rayde-code-menu-formatdocument");
			until(() -> StringTools.startsWith(editor.value.get(), "// formatted"), "Formatter did not apply edits");
			editor.undo();
			settle();
			check(editor.value.get() == source, "Formatting did not undo in one step");
			menu(editor, from);
			click("#rayde-code-menu-formatdocument");
			editor.applyEdits([{from: source.length, to: source.length, text: "// typed"}]);
			settle();
			var end = haxe.Timer.stamp() + .4;
			while (haxe.Timer.stamp() < end) {
				settle();
				Sys.sleep(.01);
			}
			check(!StringTools.startsWith(editor.value.get(), "// formatted"), "A stale formatter response overwrote newer edits");
			editor.undo();
			settle();
			menu(editor, from);
			click("#rayde-code-menu-find");
			check(editor.state.search.opened.get(), "Find did not open in the clicked editor");
			editor.hideFind();
			var cold = root + "/workspace/Cold.hx";
			sys.io.File.saveContent(cold, "class Cold {}\n");
			function change(line:Int, from:Int, to:Int, text:String):Dynamic
				return {range: {start: {line: line, character: from}, end: {line: line, character: to}}, newText: text};
			var snapshots = [file => source], rejected = false;
			try
				EditorCommands.apply(bench, file, [
					{file: file, version: null, edits: [change(0, 0, 0, "// renamed\n")]},
					{file: cold, version: null, edits: [change(0, 500, 501, "x")]}
				], snapshots)
			catch (_:Dynamic)
				rejected = true;
			check(rejected && editor.value.get() == source && !bench.documentsPart.buffers.exists(cold),
				"An invalid multi-file edit partially modified buffers");
			var coldState = bench.documentsPart.documentState(cold);
			coldState.caret = 10;
			coldState.anchor = 6;
			EditorCommands.apply(bench, file, [
				{file: file, version: null, edits: [change(0, 0, 0, "// renamed\n")]},
				{file: cold, version: null, edits: [change(0, 0, 0, "// renamed\n")]}
			], snapshots);
			settle();
			check(bench.documentsPart.buffer(cold).get() == "// renamed\nclass Cold {}\n" && bench.dirty.get().indexOf(cold) >= 0,
				"Multi-file edits lost an unmounted document");
			check(coldState.caret == 21 && coldState.anchor == 17, "Unmounted edits did not move the saved selection");
			bench.openFile(cold);
			settle();
			bench.editorFor(cold).undo();
			settle();
			check(bench.editorFor(cold).value.get() == "class Cold {}\n", "An unmounted document lost its rename undo step");
			bench.closeAll();
			settle();
			check(nodes(".rayde-code-context").length == 0
				&& nodes("#rayde-code-menu-copy").length == 0, "Closed tabs retained context menu views");
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
