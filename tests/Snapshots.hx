import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.theme.ThemeState;
import ashui.theme.themes.RestrainedTheme;
import rayde.ext.Manifest;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.run.Haxelib;
import rayde.settings.Appearance;
import rayde.settings.Store;
import rayde.ui.Theming;
import rayde.ui.Workbench;

/**
 * RayDE's workbench on the fixture projects, captured in both themes: as it
 * opens, with a file open and an edit the compiler finds wrong, after a run of
 * a program that works, and after a build that fails. Pictures go to
 * bin/snapshots, or ASHUI_SNAPSHOT_DIR. A run saves what is edited, so each
 * scenario works on a copy of its fixture, never the fixture itself.
 */
class Snapshots {
	static inline var WIDTH = 1280;
	static inline var HEIGHT = 800;

	static function main():Void {
		if (Sys.getEnv("SNAPSHOT_ONLY") == "toast") {
			ToastLayout.main();
			return;
		}
		if (Sys.getEnv("SNAPSHOT_ONLY") == "commandcenter") {
			CommandCenterLifecycle.main();
			return;
		}
		// haxelib is a stand-in with a few libraries, so the page and what it runs do not depend on the machine or the network; home is empty.
		var scratch = haxe.io.Path.join([Sys.getCwd(), "bin", "snapshot-tools"]);
		if (!sys.FileSystem.exists(scratch))
			sys.FileSystem.createDirectory(scratch);
		var stub = haxe.io.Path.join([scratch, "haxelib.sh"]), home = haxe.io.Path.join([scratch, "home"]);
		if (!sys.FileSystem.exists(home))
			sys.FileSystem.createDirectory(home);
		sys.io.File.saveContent(stub, "#!/bin/sh\nstate=\"$(dirname \"$0\")/libs.txt\"\ncase \"$1\" in\n list) cat \"$state\" 2>/dev/null ;;\n path) echo \"$RAYDE_SNAPSHOT_LIBRARY_PATH\" ;;\n --always) shift; case \"$1\" in install) echo \"$2: [${3:-1.0.0}]\" >> \"$state\"; echo \"Installed $2\" ;; update) echo \"Updated $2\" ;; esac ;;\n remove) grep -v \"^$2:\" \"$state\" > \"$state.new\"; mv \"$state.new\" \"$state\"; echo \"Removed $2\" ;;\nesac\n");
		Sys.command("chmod", ["+x", stub]);
		Sys.putEnv("RAYDE_HAXELIB", stub);
		Sys.putEnv("HOME", home);
		var builtins = scratch + "/empty-extensions";
		sys.FileSystem.createDirectory(builtins);
		Sys.putEnv("RAYDE_EXTENSIONS", builtins);
		for (dark in [true, false]) {
			sys.io.File.saveContent(haxe.io.Path.join([scratch, "libs.txt"]), "ash-simd: [0.1.0]\nformat: [3.7.0]\nhashlink: [1.14.0]\ntink_core: [2.1.1]\ntink_hxx: [0.25.1]\n");
			Haxelib.refresh();
			scenario(dark, "lsp", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				var root = bench.display().cwd;
				var installed = bench.extensionManager.find("rayzor");
				if (installed == null || installed.disabled || installed.installed.scope != "Built-in") throw "Rayzor must be a built-in default";
				until(() -> bench.languageServers.client(file) != null, "Rayzor extension registration");
				var client = bench.languageServers.client(file);
				bench.openFile(file);
				until(() -> client.state == "ready", "LSP initialization");
				bench.openFile(file); settle();
				var source = "class Main {\n\tstatic function main() {\n\t\tvar greeting = 'hello';\n\t\tgreeting.\n\t}\n}\n";
				bench.buffer(file).set(source); bench.edited(file); settle();
				var editor = bench.editorFor(file), caret = source.indexOf("greeting.") + "greeting.".length;
				editor.select(caret, caret); editor.focus();
				bench.runCommand("suggest");
				until(() -> editor.completionsOpen(), "LSP completion list");
				shot("completion"); press(Named(Enter));
				if (bench.buffer(file).get().indexOf("greeting.fixtureMember") < 0) throw "LSP completion was not applied";
				bench.goToDefinition();
				until(() -> bench.caret(file) == 6, "LSP definition navigation");
				click("#rayde-explorer-toggle-outline");
				until(() -> Lambda.exists(Css.query(bench.tree, bench.node.id, "#rayde-outline-tree text"), id -> ashui.ui.Text.at(id).text() == "LspMain"), "LSP Outline");
				shot("outline");
				var call = StringTools.replace(bench.buffer(file).get(), "greeting.fixtureMember", "greet(");
				bench.buffer(file).set(call); bench.edited(file); settle();
				var open = call.indexOf("greet(") + "greet(".length;
				editor.select(open, open); editor.focus();
				bench.runCommand("parameterhints");
				until(() -> Css.query(bench.tree, bench.node.id, ".ui-code-hint").length > 0, "LSP signature help");
				shot("signature"); editor.hideHint();
				var spot = editor.rectAt(6);
				ashui.input.Pointer.move(bench.tree, spot.x + spot.width / 2, spot.y + spot.height / 2);
				until(() -> Css.query(bench.tree, bench.node.id, ".ui-code-hint").length > 0, "asynchronous LSP hover");
				for (selector in [".rayde-hover-markdown .rayde-md-code", ".rayde-hover-markdown .rayde-md-em", ".rayde-hover-markdown .rayde-md-strong", ".rayde-hover-markdown .rayde-md-link", ".rayde-hover-markdown [data-token=keyword]"])
					if (Css.query(bench.tree, bench.node.id, selector).length == 0) throw "Missing rich hover content: " + selector;
				if (Css.query(bench.tree, bench.node.id, ".rayde-hover-markdown .ui-code-view").length > 0) throw "Compact hover constructed a CodeView";
				shot("hover"); editor.hideHint(); settle();
				if (Css.query(bench.tree, bench.node.id, ".rayde-hover-docs").length != 0) throw "Closed hover retained its Markdown view";
				editor.showHint({from:6, to:10, renderDocs:() -> rayde.ui.HoverDocumentation.render({kind:"plaintext", value:"*literal* ```haxe"})}, true);
				settle();
				if (Css.query(bench.tree, bench.node.id, ".rayde-md-em, .rayde-md-code").length > 0) throw "Plaintext hover was parsed as Markdown";
				shot("hover-plaintext"); editor.hideHint();
				editor.showHint({from:6, to:10, renderDocs:() -> rayde.ui.HoverDocumentation.render({kind:"markdown", value:"```unknown-language\nvisible fallback code\n```\n\n" + [for (i in 0...50) "Paragraph **" + i + "** with wrapped documentation."].join("\n\n")})}, true);
				settle();
				var docsId = Css.query(bench.tree, bench.node.id, ".rayde-hover-docs")[0];
				var bounds = bench.tree.getBounds(new ashui.layout.Node(docsId)), docsScroll = ashui.input.Scroll.at(docsId, bench.tree);
				if (bounds.height > 321 || docsScroll == null || docsScroll.limits().y <= 0) throw "Long hover documentation is not bounded and scrollable";
				if (!Lambda.exists(Css.query(bench.tree, bench.node.id, ".rayde-hover-docs text"), id -> ashui.ui.Text.at(id).text() == "visible fallback code")) throw "Unknown code language lost its text";
				shot("hover-scroll"); editor.hideHint();
				hover("#rayde-lsp-status"); settle(40);
				until(() -> Lambda.exists(Css.query(bench.tree, bench.node.id, ".ui-tooltip text"), id -> ashui.ui.Text.at(id).text() == "Rayzor — ready"), "ready server tooltip");
				shot("server-tooltip");
				click("#rayde-lsp-status"); shot("server-menu");
				click("#rayde-lsp-stop");
				until(() -> client.state == "stopped", "status menu to stop LSP");
				if (bench.languageServers.client(file) != null) throw "Stopped server still routes language requests";
				hover("#rayde-lsp-status"); settle(40);
				until(() -> Lambda.exists(Css.query(bench.tree, bench.node.id, ".ui-tooltip text"), id -> ashui.ui.Text.at(id).text() == "Rayzor — stopped"), "stopped server tooltip");
				shot("server-stopped-tooltip");
				click("#rayde-lsp-status"); shot("server-stopped");
				click("#rayde-lsp-start");
				until(() -> client.state == "ready", "status menu to start LSP");
				click("#rayde-lsp-status"); click("#rayde-lsp-restart");
				until(() -> client.state == "ready", "status menu to restart LSP");
				click("#rayde-lsp-status"); click("#rayde-lsp-output"); settle();
				if ((@:privateAccess bench.outputChannel.get()) != "ext:rayzor" || Css.query(bench.tree, bench.node.id, "#rayde-extension-output").length == 0) throw "LSP Show Output did not select its extension's channel";
				shot("server-output"); bench.closePanel(); settle();
				var gotPid = false, pid = 0;
				client.request("test/state", {}, result -> { pid = result.pid; gotPid = true; });
				until(() -> gotPid, "LSP process identity");
				bench.closeAll(); settle();
				bench.openFile(file); settle();
				gotPid = false;
				client.request("test/state", {}, result -> { if (result.pid != pid) throw "Tab lifecycle restarted the LSP"; gotPid = true; });
				until(() -> gotPid, "persistent LSP after close and reopen");
				if (bench.languageServers.client(file) != client) throw "Reopening replaced the LSP client";
				bench.openSettings("extensions"); settle();
				var prefix = "#rayde-extension-setting-rayzor-";
				for (name in ["command", "hxml", "stdlib", "macroBudgetMs"])
					if (Css.query(bench.tree, bench.node.id, prefix + name).length == 0) throw "Missing Rayzor setting: " + name;
				shot("settings");
			});
			scenario(dark, "explorer", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				var tree = bench.tree, root = haxe.io.Path.directory(haxe.io.Path.directory(file));
				function has(selector:String):Bool return Css.query(tree, bench.node.id, selector).length > 0;
				function label(word:String):Bool return Lambda.exists(Css.query(tree, bench.node.id, "#rayde-outline-tree text"), id -> ashui.ui.Text.at(id).text().indexOf(word) >= 0);
				bench.openFile(file); settle();
				if (has("#rayde-outline-scroll") || has("#rayde-dependencies-scroll") || has("#rayde-activity-ext-git-timeline")) throw "closed sections built their contents or added an activity icon";
				click("#rayde-explorer-toggle-outline");
				until(() -> label("Main"), "compiler Outline symbols");
				bench.editorFor(file).select(0, 0);
				click('#rayde-outline-tree [data-symbol-kind="method"] > .ui-tree-row');
				until(() -> bench.caretLine(file) == 1, "Outline click to navigate to the method declaration");
				var classIcon = bench.boundsOf('#rayde-outline-tree [data-symbol-kind="class"] > .ui-tree-row > .ui-tree-icon');
				var methodIcon = bench.boundsOf('#rayde-outline-tree [data-symbol-kind="method"] > .ui-tree-row > .ui-tree-icon');
				if (methodIcon.x - classIcon.x > 14) throw "Outline indentation is too wide";
				shot("outline");
				// Persistence contains only bounded undo data, including redo on the other side of an undo.
				var savedState = new ashui.components.code.CodeEditorState(ashui.reactive.Signal.make("ab"));
				savedState.history.record("a", "ab", {caret:1,anchor:1}, {caret:2,anchor:2});
				savedState.history.record("ab", "abc", {caret:2,anchor:2}, {caret:3,anchor:3});
				var undone = savedState.history.apply("abc", false);
				var json = haxe.Json.stringify(rayde.ui.DocumentHistory.snapshot(savedState));
				var recoveredState = new ashui.components.code.CodeEditorState(ashui.reactive.Signal.make(undone.text));
				rayde.ui.DocumentHistory.restore(recoveredState, haxe.Json.parse(json));
				if (recoveredState.history.apply("ab", true).text != "abc" || recoveredState.history.apply("abc", false).text != "ab" || recoveredState.history.apply("ab", false).text != "a") throw "persisted undo and redo did not round-trip";
				var source = bench.buffer(file).get();
				bench.buffer(file).set(StringTools.replace(source, "main()", "changed()"));
				until(() -> label("changed"), "Outline from the unsaved buffer");
				if (sys.io.File.getContent(file) != source) throw "Outline wrote the source file";
				bench.buffer(file).set(source);
				until(() -> label("main"), "restored Outline");
				var git = bench.extensionManager.find("git");
				bench.extensionManager.setNativeApproved("git", "git2", true);
				click("#rayde-explorer-toggle-timeline");
				var studio = bench.studioFor(git.connection.file);
				function says(word:String):Bool return studio.preview != null && Lambda.exists(studio.preview.outline(), o -> o.text.indexOf(word) >= 0);
				until(() -> { if (Lambda.exists(studio.console.get(), e -> e.kind == "error")) throw haxe.Json.stringify(studio.console.get()); return says("Prepare extension runtime 1"); }, "file Timeline to search bounded pages for the initial commit");
				shot("timeline");
				click("#rayde-explorer-toggle-dependencies");
				until(() -> has("#rayde-dependencies-tree"), "Dependencies empty build");
				// Resolve a declared library through the isolated haxelib command, with lazy source rows.
				var lib = root + "/library";
				sys.FileSystem.createDirectory(lib + "/sample");
				sys.io.File.saveContent(lib + "/sample/Widget.hx", "package sample; class Widget {}\n");
				Sys.putEnv("RAYDE_SNAPSHOT_LIBRARY_PATH", lib);
				bench.display().args.push("-lib"); bench.display().args.push("format");
				click("#rayde-dependencies-refresh");
				until(() -> has("#rayde-dependency-" + haxe.crypto.Md5.encode("format") + "-ready"), "resolved library source root");
				click("#rayde-dependency-" + haxe.crypto.Md5.encode("format") + "-ready > .ui-tree-row"); settle(25);
				shot("dependencies-root");
				var libraryRoot = "#rayde-library-" + haxe.crypto.Md5.encode(lib);
				click(libraryRoot + " > .ui-tree-row"); settle(25);
				var folder = "#rayde-library-" + haxe.crypto.Md5.encode(lib + "/sample");
				click(folder + " > .ui-tree-row"); settle(25);
				if (!Lambda.exists(Css.query(tree, bench.node.id, folder + " text"), id -> ashui.ui.Text.at(id).text() == "Widget.hx")) throw "library expansion did not lazily expose sources";
				bench.display().args.pop(); bench.display().args.pop();
				click(folder + " > .ui-tree-group > .ui-tree-item > .ui-tree-row");
				until(() -> bench.active.get() == lib + "/sample/Widget.hx" && bench.editorFor(lib + "/sample/Widget.hx") != null, "dependency source to open in an editor tab");
				shot("library-source");
				bench.openFile(file);
				until(() -> label("Main") && says("Prepare extension runtime 1"), "Outline and Timeline after library source navigation");
				var heights = [for (id in ["outline", "timeline", "dependencies"]) bench.boundsOf("#rayde-explorer-panel-" + id).height];
				var handles = Css.query(tree, bench.node.id, "#rayde-explorer-sections > .ui-resizable-handle");
				var divider = tree.getScrolledBounds(new ashui.layout.Node(handles[1]));
				ashui.input.Pointer.move(tree, divider.x + divider.width / 2, divider.y + divider.height / 2);
				ashui.input.Pointer.press(tree);
				ashui.input.Pointer.move(tree, divider.x + divider.width / 2, divider.y - 35); settle();
				ashui.input.Pointer.release(tree); settle();
				if (bench.boundsOf("#rayde-explorer-panel-timeline").height <= heights[1] + 20) throw "Explorer vertical splitter did not resize Timeline";
				var expanded = bench.boundsOf("#rayde-explorer-panel-outline").height;
				click("#rayde-explorer-toggle-outline"); settle(40);
				if (bench.boundsOf("#rayde-explorer-panel-outline").height > 29 || has("#rayde-outline-scroll")) throw "collapsed Outline kept its content";
				click("#rayde-explorer-toggle-outline"); settle(40);
				if (Math.abs(bench.boundsOf("#rayde-explorer-panel-outline").height - expanded) > 2) throw "Outline lost its expanded height";
				click("#rayde-explorer-toggle-timeline");
				until(() -> !says("Prepare extension runtime 1"), "Timeline visibility cleanup"); settle(40);
				click("#rayde-explorer-toggle-timeline"); settle(40);
				until(() -> says("Prepare extension runtime 1"), "Timeline reopening");
				var editor = bench.editorFor(file);
				editor.applyEdits([{from:source.length, to:source.length, text:"\n// never staged\n"}]); settle();
				click("#rayde-local-revision-0");
				if (!has("#rayde-history-preview") || sys.io.File.getContent(file) != source) throw "local revision should open read-only without writing the source";
				shot("local-revision");
				click("#rayde-history-restore");
				until(() -> bench.active.get() == file && bench.buffer(file).get() == source, "restore into the unsaved editor buffer");
				bench.editorFor(file).undo(); settle();
				if (bench.buffer(file).get().indexOf("never staged") < 0) throw "restoring a local revision was not undoable";
				@:privateAccess bench.localHistory.flush(file);
				var recovered = new rayde.history.LocalHistory(root);
				if (recovered.recover(file, source) != bench.buffer(file).get()) throw "unsaved work did not survive a new history instance";
				var restoredState = new ashui.components.code.CodeEditorState(ashui.reactive.Signal.make(bench.buffer(file).get()));
				rayde.ui.DocumentHistory.restore(restoredState, recovered.undo(file, restoredState.value.get()));
				if (restoredState.history.apply(restoredState.value.get(), true).text != source) throw "redo after restart did not restore the selected local revision";
				recovered.dispose();
				until(() -> label("Main") && says("Prepare extension runtime 1"), "settled Outline and Git Timeline after revision restore");
				shot("panels");
			});

			scenario(dark, "outline", (bench, _, shot, settle, scroll, click, type, hover, press, until) -> {
				var tree = bench.tree, root = bench.display().cwd, file = root + "/src/app/Main.hx";
				function has(word:String):Bool return Lambda.exists(Css.query(tree, bench.node.id, "#rayde-outline-scroll text"), id -> ashui.ui.Text.at(id).text().indexOf(word) >= 0);
				bench.openFile(file); click("#rayde-explorer-toggle-outline");
				until(() -> has("Main") && has("main"), "Outline with the full fixture's missing dependency");
				shot("missing-library");
				click('#rayde-outline-tree [data-symbol-kind="method"] > .ui-tree-row');
				until(() -> bench.caretLine(file) == 3, "full fixture Outline declaration navigation");
				var original = bench.buffer(file).get();
				bench.buffer(file).set("/* unterminated"); settle(1);
				if (!has("main")) throw "Outline cleared while waiting for an edited buffer";
				until(() -> has("Showing the last outline"), "last successful Outline during a syntax error");
				if (!has("main")) throw "syntax error discarded the last Outline";
				shot("syntax-error");
				bench.buffer(file).set(StringTools.replace(original, "function main", "function edited"));
				until(() -> has("edited") && !has("Showing the last outline"), "Outline recovery from an unsaved syntax error");
				if (sys.io.File.getContent(file) != original) throw "Outline saved an unsaved buffer";
				bench.openFile(root + "/lib/Util.hx");
				until(() -> has("Util") && has("twice") && !has("edited"), "Outline after switching to a library file");
				bench.openFile(root + "/tools/Gen.hx");
				until(() -> has("Gen") && !has("twice"), "Outline outside the configured source paths");
				shot("outside-classpath");
				var conditional = root + "/tools/Conditional.hx";
				sys.io.File.saveContent(conditional, "#if outline_enabled\nclass Enabled {}\n#else\nclass Disabled {}\n#end\n");
				bench.openFile(conditional); until(() -> has("Disabled"), "Outline conditional branch");
				sys.io.File.saveContent(root + "/build.hxml", sys.io.File.getContent(root + "/build.hxml") + "\n-D outline_enabled\n");
				bench.buildChanged();
				until(() -> has("Enabled") && !has("Disabled"), "Outline after a build configuration change");
				shot("changed-define");
			});

			scenario(dark, "find", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				bench.openFile(file); settle();
				var ed = bench.editorFor(file), original = bench.buffer(file).get(), state = ed.state;
				click(".ui-code-viewport"); press(Character("f"), false, Sys.systemName() != "Mac", false, Sys.systemName() == "Mac"); settle();
				if (!state.search.opened.get()) throw "Find shortcut did not open the component search bar";
				click(".ui-code-find-regex"); type(".ui-code-find-query", "item(12|34)"); click(".ui-code-find-query"); settle();
				if (ed.search.result.get().matches.length != 4) throw "Haxe regex did not find all captured items";
				var nextId = Css.query(bench.tree, bench.node.id, ".ui-code-find-next")[0];
				if (ashui.input.Interaction.byId(bench.tree,nextId).disabled.get()) throw "Next match button stayed disabled after finding results";
				var initialMatch = ed.editing.anchor.get();
				click(".ui-code-find-next"); settle(); if (ed.editing.anchor.get() <= initialMatch) throw "Next match button did not advance";
				click(".ui-code-find-previous"); settle(); if (ed.editing.anchor.get() != initialMatch) throw "Previous match button did not return";
				click(".ui-code-find-query");
				shot("haxe-regex");
				var first = ed.editing.anchor.get(); press(Named(Enter)); settle();
				if (ed.editing.anchor.get() <= first) throw "Enter did not advance the result";
				press(Named(Enter), true); settle(); if (ed.editing.anchor.get() != first) throw "Shift+Enter did not select the previous result";
				bench.runCommand("replace"); settle(); type(".ui-code-find-replacement", "entry$1"); settle();
				shot("replace-captures"); click(".ui-code-find-replace"); settle();
				if (ed.search.result.get().matches.length != 3 || bench.buffer(file).get().indexOf("entry12") < 0) throw "Replace did not change just the selected captured match";
				ed.undo(); settle(); if (bench.buffer(file).get() != original) throw "Replace did not undo";
				click(".ui-code-find-replace-all"); settle();
				if (bench.buffer(file).get().indexOf("item12") >= 0 || bench.buffer(file).get().indexOf("entry34") < 0 || bench.dirty.get().indexOf(file) < 0) throw "Replace All did not use captured text or mark the buffer dirty";
				shot("replaced"); ed.focus(); ed.undo(); settle(); if (bench.buffer(file).get() != original) throw "Replace All was not one undo step";
				var other = haxe.io.Path.directory(file) + "/Other.hx";
				bench.openFile(other); settle();
				if (state.mounted || Css.query(bench.tree, bench.node.id, ".ui-code-find").length > 0) throw "inactive search retained mounted controls";
				bench.active.set(file); settle(); ed = bench.editorFor(file);
				if (ed.state != state || state.search.query.get() != "item(12|34)" || ed.search.result.get().matches.length != 4) throw "search state did not survive an editor remount";
				click(".ui-code-find-query"); type(".ui-code-find-query", "["); settle();
				if (ed.search.result.get().error == null) throw "invalid regex had no recoverable error";
				shot("invalid-regex");
				type(".ui-code-find-query", "item(12|34)"); settle();
				if (ed.search.result.get().error != null || ed.search.result.get().matches.length != 4) throw "find did not recover after fixing the regex";
				press(Named(Escape)); settle(); if (state.search.opened.get() || ed.search.result.get().matches.length != 0) throw "closing find retained controls or result data";
				bench.closeAll(); settle(); if (state.mounted) throw "closed document retained an editor";
			});

			scenario(dark, "images", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				var tree = bench.tree, root = bench.display().cwd, png = root + "/Photo.PNG", svg = root + "/vector.svg";
				sys.io.File.copy("assets/rayde-welcome.png", png);
				sys.io.File.saveContent(root + "/broken.png", "not an image");
				sys.io.File.saveContent(root + "/broken.svg", "<svg><invalid");
				bench.refreshExplorer(); settle();
				function has(selector:String):Bool return Css.query(tree, bench.node.id, selector).length > 0;
				function viewer():rayde.ui.ImagePreview {
					for (component in (@:privateAccess ashui.ui.Component.hosts)) if (Std.isOfType(component, rayde.ui.ImagePreview)) return cast component;
					return null;
				}
				click('[data-path$="Photo.PNG"] > .ui-tree-row'); settle();
				if (!has("#rayde-image-canvas") || bench.editorFor(png) != null || (@:privateAccess bench.buffers.exists(png))) throw "raster image opened as a text document";
				shot("raster-fit");
				var raster = @:privateAccess viewer().bitmap, view = viewer().viewport, initialZoom = view.zoom.get();
				click("#rayde-image-in"); settle();
				if (view.zoom.get() <= initialZoom) throw "image zoom button did not zoom";
				var b = bench.boundsOf("#rayde-image-canvas");
				ashui.input.Pointer.move(tree,b.x+b.width/2,b.y+b.height/2); ashui.input.Pointer.wheel(tree,0,80); settle();
				var before = view.panX.get();
				ashui.input.Pointer.press(tree); ashui.input.Pointer.move(tree,b.x+b.width/2+60,b.y+b.height/2+30); ashui.input.Pointer.release(tree); settle();
				if (view.panX.get() == before) throw "image drag did not pan";
				shot("raster-zoom-pan");
				var zoom = view.zoom.get(), x = view.panX.get(), y = view.panY.get();
				bench.openFile(file); settle();
				if (raster.decoded() || viewer() != null) throw "inactive image retained decoded pixels or a viewer";
				bench.active.set(png); settle(); view = viewer().viewport;
				if (Math.abs(view.zoom.get()-zoom) > .001 || Math.abs(view.panX.get()-x) > .01 || Math.abs(view.panY.get()-y) > .01) throw "image navigation was lost on tab switch";
				click("#rayde-image-actual"); settle(); if (view.zoom.get() != 1) throw "actual image size did not restore 100 percent";
				click("#rayde-image-fit"); settle();
				click("#rayde-image-background"); settle(); if (!has("#rayde-image-surface[data-light]")) throw "image background control did not change contrast";
				shot("raster-light-background");
				var old = @:privateAccess viewer().bitmap;
				click("#rayde-image-reload"); settle(); if (old.decoded()) throw "image refresh retained the previous pixels";
				for (suffix in ["jpe", "jpeg"]) sys.io.File.copy(root + "/sample.jpg", root + "/sample." + suffix);
				for (name in ["sample.jpg", "sample.jpe", "sample.jpeg", "sample.webp", "sample.bmp", "sample.gif", "sample.ico", "sample-png.ico", "sample.avif"]) {
					bench.openFile(root + "/" + name); settle();
					until(() -> has("#rayde-image-canvas") || has("#rayde-image-error"), 'decode $name');
					if (!has("#rayde-image-canvas") || (@:privateAccess viewer().bitmap) == null) throw 'missing raster preview for $name';
					if (bench.editorFor(root + "/" + name) != null || (@:privateAccess bench.buffers.exists(root + "/" + name))) throw 'raster $name opened as text';
					shot("raster-" + StringTools.replace(name, ".", "-"));
				}
				bench.active.set(file); settle(); bench.active.set(root + "/sample.avif"); bench.active.set(file); settle(20);
				if (viewer() != null || has("#rayde-image-canvas")) throw "cancelled image decode mounted into another tab";
				sys.io.File.saveContent(root + "/broken.avif", "not an image");
				bench.openFile(root + "/broken.avif");
				until(() -> has("#rayde-image-error"), "invalid background image decode");
				var large = root + "/large.svg";
				sys.io.File.saveContent(large, '<svg xmlns="http://www.w3.org/2000/svg" width="16000" height="12000"><rect width="16000" height="12000" fill="#369cff"/><circle cx="8000" cy="6000" r="3000" fill="#ffce52"/></svg>');
				bench.openFile(large); settle();
				if (!has("#rayde-image-canvas") || viewer().viewport.zoom.get() >= .1) throw "oversized SVG was not fitted to the viewport";
				shot("large-svg");
				bench.openFile(svg); settle();
				if (!has("#rayde-image-edit") || bench.editorFor(svg) != null) throw "SVG did not open as a preview";
				shot("svg-preview");
				var original = bench.buffer(svg).get(), owned = @:privateAccess rayde.ui.SvgDocuments.owned;
				if ([for (_ in owned) 1].length != 1) throw "SVG preview is not owned";
				var shared = rayde.ui.SvgDocuments.acquire(original);
				click("#rayde-image-edit"); settle();
				if (bench.editorFor(svg) == null || has("#rayde-image-canvas") || ashui.svg.SvgDocument.get(shared.id) == null) throw "SVG editor switch released another view's document";
				rayde.ui.SvgDocuments.release(shared);
				if (owned.iterator().hasNext()) throw "SVG editor retained a preview document";
				var from = original.indexOf("SVG preview");
				bench.editorFor(svg).applyEdits([{from:from,to:from+11,text:"Edited vector"}]); settle();
				var edited = bench.buffer(svg).get();
				if (edited == original || bench.dirty.get().indexOf(svg) < 0) throw "SVG edit was not tracked";
				shot("svg-source");
				click("#rayde-image-show-preview"); settle();
				if (!has("#rayde-image-canvas") || sys.io.File.getContent(svg) != original) throw "preview failed to use the unsaved SVG";
				if (!Lambda.exists(owned, entry -> entry.document.markup.indexOf("Edited vector") >= 0)) throw "SVG preview used stale source";
				shot("svg-unsaved-preview");
				click("#rayde-image-edit"); settle(); bench.editorFor(svg).undo(); settle();
				if (bench.buffer(svg).get() != original) throw "SVG mode switch lost undo history";
				bench.buffer(svg).set("<svg><invalid"); click("#rayde-image-show-preview"); settle();
				if (!has("#rayde-image-error") || !has("#rayde-image-edit")) throw "invalid SVG cannot return to source";
				shot("invalid-svg");
				click("#rayde-image-edit"); settle(); bench.buffer(svg).set(original); click("#rayde-image-show-preview"); settle();
				if (!has("#rayde-image-canvas")) throw "SVG did not recover after correcting its source";
				bench.openFile(root + "/broken.png"); settle(); if (!has("#rayde-image-error")) throw "invalid raster image crashed or opened as text";
				shot("invalid-raster");
				bench.closeAll(); settle();
				if (viewer() != null || owned.iterator().hasNext() || raster.decoded()) throw "closed image tabs retained view resources";
			});

			scenario(dark, "basic", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				if (bench.panelOpen())
					throw "the bottom panel should start closed";
				shot("empty");
				// The guide lines of the Explorer's tree are hidden until the pointer is over it.
				bench.openFile(file);
				bench.closeAll();
				hover("#rayde-tree");
				shot("explorer-hover");
				hover("#rayde-bottom");
				shot("explorer-away");
				// A secondary press on a file and on a folder opens a menu for it; the items act on the files and the tabs.
				var tree = bench.tree;
				var rowOf = (path:String) -> {
					var found = ashui.css.Css.query(tree, bench.node.id, '[data-path$="$path"] > .ui-tree-row');
					if (found.length == 0)
						throw 'no row for $path';
					return tree.getScrolledBounds(new ashui.layout.Node(found[0]));
				};
				var menuOn = (path:String) -> {
					var b = rowOf(path);
					ashui.input.Pointer.move(tree, b.x + b.width / 2, b.y + b.height / 2);
					ashui.input.Pointer.press(tree, Right);
					ashui.input.Pointer.release(tree, Right);
					settle(8);
				};
				var folder = haxe.io.Path.directory(file);
				menuOn("src/Main.hx");
				shot("explorer-menu-file");
				press(Named(Escape));
				menuOn("/src");
				shot("explorer-menu-folder");
				click("#rayde-explorer-new-file");
				type("#rayde-prompt-input", "Fresh.hx");
				shot("explorer-prompt");
				click("#rayde-prompt-accept");
				if (!sys.FileSystem.exists(haxe.io.Path.join([folder, "Fresh.hx"])) || bench.active.get() != haxe.io.Path.join([folder, "Fresh.hx"]))
					throw "New File should make the file and open it";
				menuOn("src/Fresh.hx");
				click("#rayde-explorer-rename");
				type("#rayde-prompt-input", "Renamed.hx");
				click("#rayde-prompt-accept");
				var renamed = haxe.io.Path.join([folder, "Renamed.hx"]);
				if (!sys.FileSystem.exists(renamed) || sys.FileSystem.exists(haxe.io.Path.join([folder, "Fresh.hx"])) || bench.open.get().indexOf(renamed) < 0 || bench.active.get() != renamed)
					throw "Rename should move the file and its tab";
				// Duplicate, and copy then paste into the folder, give copies a free name; the menu shows each command's key.
				menuOn("src/Renamed.hx");
				shot("explorer-menu-keys");
				click("#rayde-explorer-duplicate");
				var copyOf = haxe.io.Path.join([folder, "Renamed copy.hx"]);
				if (!sys.FileSystem.exists(copyOf))
					throw "Duplicate should make Renamed copy.hx beside the file";
				menuOn("src/Main.hx");
				click("#rayde-explorer-copy");
				menuOn("/src");
				click("#rayde-explorer-paste");
				if (!sys.FileSystem.exists(haxe.io.Path.join([folder, "Main copy.hx"])))
					throw "Paste should put a copy of Main.hx in the folder under a free name";
				// What is cut moves, and the tab of a moved file follows it.
				sys.FileSystem.createDirectory(haxe.io.Path.join([folder, "sub"]));
				bench.refreshExplorer();
				settle();
				bench.openFile(copyOf);
				menuOn("src/Renamed copy.hx");
				click("#rayde-explorer-cut");
				menuOn("/sub");
				click("#rayde-explorer-paste");
				var cutTo = haxe.io.Path.join([folder, "sub", "Renamed copy.hx"]);
				if (sys.FileSystem.exists(copyOf) || !sys.FileSystem.exists(cutTo) || bench.active.get() != cutTo)
					throw "Cut and paste should move the file, and its tab with it";
				bench.folderState(folder + "/sub").set(false);
				bench.refreshExplorer();
				settle();
				if (Css.query(bench.tree, bench.node.id, '[data-path="$cutTo"]').length != 0)
					throw "a closed folder built its file rows before expansion";
				bench.folderState(folder + "/sub").set(true);
				settle();
				var loaded = Css.query(bench.tree, bench.node.id, '[data-path="$cutTo"]');
				if (loaded.length != 1 || bench.treeSelected.get() != cutTo)
					throw "expanding a folder did not load and select its active file";
				bench.folderState(folder + "/sub").set(false);
				settle();
				bench.folderState(folder + "/sub").set(true);
				settle();
				if (Css.query(bench.tree, bench.node.id, '[data-path="$cutTo"]')[0] != loaded[0])
					throw "reopening a folder rebuilt its file rows";
				menuOn("src/Renamed.hx");
				click("#rayde-explorer-delete");
				shot("explorer-delete");
				click("#rayde-prompt-accept");
				if (sys.FileSystem.exists(renamed) || bench.open.get().indexOf(renamed) >= 0)
					throw "Delete should remove the file and close its tab";
				bench.closeAll();
				settle();
				// Two files open, the first in front, so the strip shows the front tab beside another.
				bench.openFile(file);
				bench.openFile(haxe.io.Path.join([haxe.io.Path.directory(file), "Util.hx"]));
				bench.active.set(file);
				var buffer = bench.buffer(file), original = buffer.get();
				buffer.set(StringTools.replace(original, 'var greeting = "hello";', 'var greeting:Int = "hello";'));
				bench.edited(file);
				until(() -> bench.problems.get().length == 2, "background diagnostics for the edited file");
				if (bench.problems.get().length != 2)
					throw 'the edited file should show two problems, not ${bench.problems.get().length}';
				// The compiler's problems are underlined in the text where they are.
				var wavy = ashui.css.Css.query(bench.tree, bench.node.id, ".ui-code-squiggle-error").length;
				if (wavy < 2)
					throw 'each problem should be underlined in the editor, not $wavy';
				// Resting the pointer on a name shows what the compiler knows of it: its type, and its documentation.
				var text = buffer.get(), at = text.indexOf("greet(greeting") + 2;
				var hint = @:privateAccess bench.hintAt(file, at);
				if (hint == null || hint.signature.indexOf("times:Int") < 0 || hint.docs == null || hint.docs.indexOf("Says hello") < 0)
					throw 'the hint on greet should have its type and documentation: ${hint == null ? "none" : hint.signature + " / " + hint.docs}';
				if (@:privateAccess bench.hintAt(file, text.indexOf('"hello"') + 2) != null)
					throw "where a problem is underlined the problem is what shows, so there is no hint of the compiler's";
				var spot = @:privateAccess bench.editorOf(file).rectAt(at);
				ashui.input.Pointer.move(bench.tree, spot.x + spot.width / 2, spot.y + spot.height / 2);
				settle(60);
				shot("hover");
				ashui.input.Pointer.move(bench.tree, 5, 5);
				settle(30);
				bench.showPanel("problems");
				shot("problems");
				// Put the edit back; from the call on line 8, go to where it is defined.
				buffer.set(original);
				bench.check(file);
				bench.goTo(file, 7, 4);
				settle();
				if (bench.caretLine(file) != 7)
					throw 'go to should put the cursor on line 8, not ${bench.caretLine(file) + 1}';
				bench.goToDefinition();
				settle();
				if (bench.caretLine(file) != 2)
					throw 'go to definition should land on line 3, not ${bench.caretLine(file) + 1}';
				// Run the program.
				bench.run();
				wait(bench);
				settle();
				if (bench.runner.state != "finished" || bench.runner.console.indexOf("hello") < 0)
					throw 'the program did not run: ${bench.runner.state}: ${bench.runner.console}';
				shot("run");
				bench.openCenter();
				shot("command-center");
				bench.openCenter(">");
				shot("command-center-commands");
				bench.quickOpen.set(false);
				// The front tab as the last of three, then as the middle one: its feet go only where there is a neighbour.
				var folder = haxe.io.Path.directory(file);
				bench.openFile(haxe.io.Path.join([folder, "Names.hx"]));
				shot("tab-last");
				bench.showEditorMenu(true);
				shot("editor-menu");
				bench.showEditorMenu(false);
				bench.active.set(haxe.io.Path.join([folder, "Util.hx"]));
				shot("tab-middle");
				// Choosing a folder in the Explorer leaves the open files and the one in front alone, and the selection on that file.
				var front = bench.active.get();
				bench.treeSelected.set(folder);
				settle();
				if (front == "" || bench.open.get().length != 3 || bench.active.get() != front || bench.treeSelected.get() != front)
					throw 'choosing a folder changed what is open or selected: ${bench.open.get().length} files, in front "${bench.active.get()}", selected "${bench.treeSelected.get()}"';
				// With the folder above the file closed, the selection rests on the folder; opened again, it goes back to the file.
				bench.folderState(folder).set(false);
				settle();
				if (bench.treeSelected.get() != folder || bench.active.get() != front)
					throw 'a closed folder should carry the selection: selected "${bench.treeSelected.get()}"';
				shot("folder-closed");
				bench.folderState(folder).set(true);
				settle();
				if (bench.treeSelected.get() != front)
					throw 'the selection should return to the file: "${bench.treeSelected.get()}"';
				// Twelve more files, which do not fit the strip: it scrolls to keep the one in front in view.
				for (n in 1...13) {
					var more = haxe.io.Path.join([folder, 'Module$n.hx']);
					sys.io.File.saveContent(more, 'class Module$n {}\n');
					bench.openFile(more);
				}
				shot("tabs-many");
				bench.active.set(file);
				shot("tabs-many-first");
				bench.openBuild();
				shot("build-tab");
				// A terminal in the panel, running a script that prints in colour and then waits.
				bench.terminalProgram = "/bin/sh";
				bench.terminalArgs = [
					"-c",
					"printf '\\033[32mrayde\\033[0m on \\033[35mmain\\033[0m \\033[2m10:42\\033[0m\\n'; printf '\\033[1mls\\033[0m\\n'; printf '\\033[34msrc\\033[0m  \\033[34mbin\\033[0m  \\033[36mbuild.hxml\\033[0m  README.md\\n'; "
					+ "printf '\\033[31merror\\033[0m: \\033[4munderlined\\033[0m \\033[7minverse\\033[0m  box ┌─┬─┐ ╔═╦═╗ ┃ ▀▄█ ░▒▓ ▖▟ ✓\\n'; printf '\\033[38;5;208morange\\033[0m \\033[38;2;120;200;255mtruecolor\\033[0m \\033[1;33mbold yellow\\033[0m\\n'; printf '$ '; sleep 60"
				];
				bench.showPanel("terminal");
				var waiting = haxe.Timer.stamp() + 8;
				while ((bench.terminal() == null || bench.terminal().line(4).indexOf("orange") < 0) && haxe.Timer.stamp() < waiting) {
					Sys.sleep(.03);
					settle(1);
				}
				if (bench.terminal() == null || bench.terminal().line(0).indexOf("rayde on main") < 0)
					throw 'the terminal did not show what the program printed: "${bench.terminal() == null ? "no terminal" : bench.terminal().line(0)}"';
				settle(12);
				shot("terminal");
				// With the keyboard in it, and something typed: the cursor is a block behind the text, after it.
				bench.focusTerminal();
				bench.terminal().write("echo typed");
				var typing = haxe.Timer.stamp() + 4;
				while (bench.terminal().line(5).indexOf("typed") < 0 && haxe.Timer.stamp() < typing) {
					Sys.sleep(.03);
					settle(1);
				}
				settle(4);
				shot("terminal-typing");
				// A second terminal beside the first, which keeps running; the list of terminals, and the menu of profiles.
				var first = bench.terminal();
				bench.newTerminal();
				var second = bench.terminal();
				if (bench.terminalCount() != 2 || second == null || first == null || second.handle == first.handle || first.exitCode() != -1)
					throw 'a new terminal should start beside the first: ${bench.terminalCount()} running';
				var until = haxe.Timer.stamp() + 6;
				while (second.line(4).indexOf("orange") < 0 && haxe.Timer.stamp() < until) {
					Sys.sleep(.03);
					settle(1);
				}
				settle(8);
				shot("terminals");
				bench.showTerminalMenu(true);
				shot("terminal-profiles");
				bench.showTerminalMenu(false);
				// Split the screen of the second terminal, which sits beside it; the list shows both under one.
				var before = bench.terminalCount();
				bench.splitTerminal();
				if (bench.terminalCount() != before + 1)
					throw "splitting should start another terminal";
				var third = bench.terminal();
				until = haxe.Timer.stamp() + 6;
				while (third.line(4).indexOf("orange") < 0 && haxe.Timer.stamp() < until) {
					Sys.sleep(.03);
					settle(1);
				}
				settle(10);
				shot("terminal-split");
				bench.killTerminal();
				// The pickers of the menu, in the command center.
				bench.splitWithProfile();
				shot("terminal-split-profile");
				bench.quickOpen.set(false);
				bench.selectDefaultProfile();
				shot("terminal-default-profile");
				bench.quickOpen.set(false);
				// A task of the project's own, from .rayde/tasks.json, run in a terminal of its own that keeps its output after it ends.
				var taskFile = haxe.io.Path.join([haxe.io.Path.directory(haxe.io.Path.directory(file)), ".rayde", "tasks.json"]);
				sys.FileSystem.createDirectory(haxe.io.Path.directory(taskFile));
				sys.io.File.saveContent(taskFile, '{"tasks": [{"label": "Say hello", "command": "echo hello from a task"}, {"label": "Format source", "command": "echo formatting"}]}');
				var tasks = rayde.run.Tasks.list(bench.display());
				if (!Lambda.exists(tasks, t -> t.label == "Say hello") || !Lambda.exists(tasks, t -> t.label == "Build build.hxml") || !Lambda.exists(tasks, t -> StringTools.startsWith(t.label, "Run build.hxml")))
					throw 'the project should offer its own tasks and the hxml ones: ${[for (t in tasks) t.label]}';
				bench.runTaskPicker();
				shot("tasks");
				bench.quickOpen.set(false);
				bench.openCenter("task ");
				shot("center-tasks");
				bench.quickOpen.set(false);
				// Closed and opened again while it is part-way through closing, as a quick Esc and Cmd+P do.
				settle(3);
				bench.openCenter();
				settle(30);
				if (!bench.quickOpen.get())
					throw "the center asked for while it was closing should open once it has closed";
				bench.quickOpen.set(false);
				settle(40);
				var before = bench.terminalCount();
				bench.runTask(Lambda.find(tasks, t -> t.label == "Say hello"));
				if (bench.terminalCount() != before + 1)
					throw "a task should run in a terminal of its own";
				var ran = bench.terminal();
				until = haxe.Timer.stamp() + 6;
				while ((ran.line(0).indexOf("hello from a task") < 0 || ran.exitCode() == -1) && haxe.Timer.stamp() < until) {
					Sys.sleep(.03);
					settle(1);
				}
				if (ran.line(0).indexOf("hello from a task") < 0 || ran.exitCode() != 0)
					throw 'the task did not run: "${ran.line(0)}", exit ${ran.exitCode()}';
				settle(10);
				shot("terminal-task");
				bench.killTerminal();
				// The file the menu's Configure Tasks opens, as JSON.
				bench.configureTasks();
				shot("tasks-file");
				// The terminal's settings page, and a profile made the default is kept in the project.
				bench.openTerminalSettings();
				bench.setDefaultProfile("bash");
				shot("terminal-settings");
				if (sys.io.File.getContent(haxe.io.Path.join([haxe.io.Path.directory(haxe.io.Path.directory(file)), ".rayde", "settings.json"])).indexOf('"bash"') < 0)
					throw "the default profile was not kept";
				// Choosing the first brings it to the front, still running with what it printed; killing the one in front leaves the other.
				bench.selectTerminal(bench.terminalIds()[0]);
				if (bench.terminal() == null || bench.terminal().handle != first.handle)
					throw "choosing a terminal in the list should bring it to the front";
				settle(8);
				shot("terminals-first");
				bench.killTerminal();
				if (bench.terminalCount() != 1 || bench.terminal() == null || bench.terminal().handle != second.handle)
					throw 'killing a terminal should leave the other in front: ${bench.terminalCount()} running';
				bench.closeTerminals();
				if (bench.terminalCount() != 0)
					throw "every terminal should be ended";
				bench.closePanel();
				// The other sections of the Settings page, reached from its list, and the extensions folder empty.
				click("#rayde-activity-settings");
				if (bench.settingsSection() != "terminal" || bench.active.get() != Workbench.SETTINGS)
					throw "the gear should bring the Settings page forward on the section last in view";
				click("#rayde-settings-nav-extensions");
				if (bench.settingsSection() != "extensions")
					throw "a click on a section in the list should show it";
				shot("settings-extensions-empty");
				click("#rayde-settings-nav-libraries");
				shot("settings-libraries");
				// Every tab closed: the welcome page, now with recent files.
				bench.closeAll();
				shot("welcome-recent");
				// The tree fills the panel, and its scroll viewport stays inside it after a resize.
				bench.closeAll();
				for (i in 0...40)
					sys.io.File.saveContent(folder + '/NumberGaugeSizing${StringTools.lpad(Std.string(i), "0", 2)}.hx', "");
				bench.refreshExplorer();
				settle();
				function explorerViewport() {
					var panel = bench.boundsOf("#rayde-files"), viewport = bench.boundsOf("#rayde-explorer-scroll");
					if (viewport.x < panel.x || Math.abs(viewport.x + viewport.width - panel.x - panel.width) > 1)
						throw "the Explorer scroll viewport should fill its panel without extending beyond it";
					return viewport;
				}
				var wide = explorerViewport();
				var row = rowOf("src/NumberGaugeSizing00.hx");
				if (Math.abs(row.x + row.width - (wide.x + wide.width - 8)) > 1)
					throw "Explorer rows should fill the available width";
				hover("#rayde-explorer-scroll");
				shot("explorer-wide");
				var scrollNode = Css.query(tree, bench.node.id, "#rayde-explorer-scroll")[0];
				var scroller = ashui.input.Scroll.at(scrollNode, tree);
				scroller.scrollTo(0, 100);
				settle();
				var handle = bench.boundsOf("#rayde-columns > .ui-resizable-handle");
				ashui.input.Pointer.move(tree, handle.x + handle.width / 2, handle.y + handle.height / 2);
				ashui.input.Pointer.press(tree);
				ashui.input.Pointer.move(tree, handle.x + handle.width / 2 - 100, handle.y + handle.height / 2);
				ashui.input.Pointer.release(tree);
				settle();
				var narrow = explorerViewport();
				if (narrow.width > wide.width - 80)
					throw "dragging the divider should narrow the Explorer";
				if (Css.query(tree, bench.node.id, "#rayde-explorer-scroll")[0] != scrollNode || scroller.y.get() != 100)
					throw "resizing should preserve the Explorer and its scroll position";
				if (scroller.limits().y <= 0 || !scroller.scrollTo(0, 300))
					throw "the narrowed Explorer should still scroll";
				hover("#rayde-explorer-scroll");
				shot("explorer-narrow-scrolled");
			});
			// A build file with a target, libraries, defines and an argument the form does not manage, as the form shows it.
			scenario(dark, "full", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				bench.openBuild();
				shot("build-settings");
				scroll("#rayde-build", 520);
				shot("build-settings-middle");
				scroll("#rayde-build", 5000);
				shot("build-settings-end");
				scroll("#rayde-build", 0);
				var model = bench.buildFile();
				if (model == null || model.values("-cp").join(",") != "src,lib" || model.value("--main") != "app.Main")
					throw "the build form should open the build file as it is";
				// The form's own controls, driven as the pointer would: each writes the file, and the compiler is given the result.
				function written(what:String):String {
					var text = sys.io.File.getContent(model.path);
					return text;
				}
				var args = () -> bench.display().args;
				click("#rayde-build-folders-section .rayde-chip");
				if (written("class path").indexOf("-cp tools") < 0 || args().indexOf("tools") < 0)
					throw "choosing a suggested class path did not write it:\n" + written("");
				// Libraries: a name typed in and added goes into the build file and is installed when haxelib lacks it.
				bench.openSettings("libraries");
				shot("settings-libraries-full");
				type("#rayde-library-name", "tink_macro");
				click("#rayde-library-add");
				if (written("library").indexOf("-lib tink_macro") < 0 || args().indexOf("tink_macro") < 0)
					throw "adding a library did not write it:\n" + written("");
				until(() -> !bench.librariesBusy(), "haxelib to install tink_macro");
				if (!Lambda.exists(Haxelib.installed(), l -> l.name == "tink_macro"))
					throw "adding a library haxelib lacks did not install it";
				shot("settings-libraries-installed");
				// The column of libraries: a click switches an installed one into the build, and the same click out again.
				click("#rayde-lib-ash-simd");
				if (model.values("-lib").indexOf("ash-simd") < 0 || args().indexOf("ash-simd") < 0)
					throw "choosing an installed library in the column did not add it:\n" + written("");
				click("#rayde-lib-ash-simd");
				if (model.values("-lib").indexOf("ash-simd") >= 0)
					throw "choosing it again did not take it out:\n" + written("");
				click("#rayde-lib-tink_macro");
				if (model.values("-lib").indexOf("tink_macro") >= 0)
					throw "a library of the build did not come out with a click:\n" + written("");
				// An installed library is removed from the machine, and one the build names but haxelib lacks is installed from its row.
				click("#rayde-lib-remove-tink_macro");
				until(() -> !bench.librariesBusy(), "haxelib to remove tink_macro");
				if (Lambda.exists(Haxelib.installed(), l -> l.name == "tink_macro"))
					throw "removing a library did not remove it";
				shot("settings-libraries-removed");
				click("#rayde-lib-install-not_installed_yet");
				until(() -> !bench.librariesBusy(), "haxelib to install not_installed_yet");
				if (!Lambda.exists(Haxelib.installed(), l -> l.name == "not_installed_yet"))
					throw "installing from the row did not install it";
				bench.openSettings("build");
				settle();
				click("#rayde-build-debug");
				if (!model.has("--debug") || written("debug").indexOf("--debug") < 0)
					throw "the debug switch did not write the file:\n" + written("");
				var defines = model.values("-D").length;
				click("#rayde-build-defines-section .rayde-remove");
				if (model.values("-D").length != defines - 1 || written("define").indexOf("analyzer-optimize") >= 0)
					throw "removing a define did not write the file:\n" + written("");
				var text = written("");
				if (text.indexOf("# The app's build") < 0 || text.indexOf("--macro include('app')") < 0 || text.indexOf("not_installed_yet") < 0)
					throw "the form lost something it does not manage:\n" + text;
				// An input, a select and a button in a row of the form are one height.
				var input = bench.boundsOf("#rayde-build-define"), button = bench.boundsOf("#rayde-build-define-add"), select = bench.boundsOf("#rayde-build-dce");
				if (input == null || button == null || select == null || input.height != button.height || select.height != button.height)
					throw 'the form\'s controls should share a height: input ${input == null ? "?" : "" + input.height}, button ${button == null ? "?" : "" + button.height}, select ${select == null ? "?" : "" + select.height}';
				shot("build-settings-edited");
				// What the form writes is what the compiler is then given.
				model.add("-D", "from-the-form");
				model.save();
				bench.buildChanged();
				if (bench.display().args.indexOf("from-the-form") < 0)
					throw "the compiler's arguments did not follow the build file";
				var root = bench.display().cwd;
				// Color scheme: a theme is chosen from its picture, applied at once and written down; so is light or dark.
				bench.openSettings("appearance");
				shot("settings-appearance");
				click("#rayde-theme-hybrid");
				if (Store.section(root, "appearance").theme != "hybrid")
					throw "choosing a theme did not write it";
				shot("settings-appearance-hybrid");
				click(dark ? "#rayde-scheme-light" : "#rayde-scheme-dark");
				if (Store.section(root, "appearance").scheme != (dark ? "light" : "dark") || ThemeState.get().scheme() != (dark ? Light : Dark))
					throw 'choosing a scheme did not apply and write it: ${dark ? "dark" : "light"} run, file says ${Store.section(root, "appearance").scheme}, window is ${ThemeState.get().scheme()}';
				shot("settings-appearance-switched");
				// The landing page follows the scheme: its wordmark is the one drawn for the scheme in use.
				bench.closeAll();
				shot("welcome-switched");
				// What the rest of the snapshots expect: the theme and scheme they began with.
				var again = new Appearance();
				again.scheme = dark ? "dark" : "light";
				Theming.apply(again);
				settle();
				// Key bindings: a key is recorded for a command, a letter alone is refused, the new key runs the command, and a key on two commands is marked.
				var keysFile = haxe.io.Path.join([root, ".rayde", "keybindings.json"]);
				bench.openSettings("keys");
				shot("settings-keys");
				// A keymap of another editor: choosing it writes the choice, its keys run the commands and the default's no longer do.
				var mac = Sys.systemName() == "Mac";
				click("#rayde-keymap-intellij");
				if (Store.section(root, "keymap").preset != "intellij")
					throw "choosing a keymap did not write it";
				shot("settings-keymap-intellij");
				// The command center offers the same choice, and a keymap chosen there is shown on the page.
				bench.selectKeymap();
				shot("keymap-picker");
				bench.quickOpen.set(false);
				click("#rayde-keys-filter");
				press(Character(mac ? "o" : "n"), true, !mac, false, mac);
				until(() -> bench.quickOpen.get(), "the keymap's key for Go to File to open it");
				bench.quickOpen.set(false);
				press(Character("p"), false, !mac, false, mac);
				if (bench.quickOpen.get())
					throw "a key of the keymap left behind still did its command";
				bench.useKeymap("sublime");
				click("#rayde-keys-filter");
				shot("settings-keymap-sublime");
				if (Store.section(root, "keymap").preset != "sublime")
					throw "choosing a keymap from the center did not write it";
				click("#rayde-keymap-vscode");
				if (Store.section(root, "keymap").preset != "vscode")
					throw "going back to the default keymap did not write it";
				type("#rayde-keys-filter", "terminal");
				shot("settings-keys-filtered");
				type("#rayde-keys-filter", "toggle explorer");
				scroll("#rayde-keys", 5000);
				hover("#rayde-key-explorer");
				shot("settings-keys-hover");
				click("#rayde-key-edit-explorer");
				shot("settings-keys-recording");
				if (bench.boundsOf("#rayde-key-recorder") == null)
					throw "the pencil should show the recorder";
				if (!bench.hasKeyboard("#rayde-key-recorder"))
					throw "the recorder should have the keyboard";
				press(Character("a"));
				if (sys.FileSystem.exists(keysFile))
					throw "a letter alone should not become a key";
				shot("settings-keys-refused");
				press(Character("e"), false, false, true);
				if (!sys.FileSystem.exists(keysFile) || sys.io.File.getContent(keysFile).indexOf("alt+e") < 0)
					throw "the key pressed was not written:\n" + (sys.FileSystem.exists(keysFile) ? sys.io.File.getContent(keysFile) : "no file");
				shot("settings-keys-changed");
				click("#rayde-keys-filter");
				var before = bench.boundsOf("#rayde-files") != null;
				press(Character("e"), false, false, true);
				if ((bench.boundsOf("#rayde-files") != null) == before)
					throw "the key chosen for Toggle Explorer did not run it";
				press(Character("e"), false, false, true);
				press(Character("p"), false, false, false, true);
				until(() -> bench.quickOpen.get(), "Cmd+P to open the command center");
				bench.quickOpen.set(false);
				type("#rayde-keys-filter", "run");
				scroll("#rayde-keys", 5000);
				hover("#rayde-key-run");
				click("#rayde-key-edit-run");
				press(Character("p"), false, false, false, true);
				shot("settings-keys-conflict");
				click("#rayde-keys-reset-all");
				if (sys.FileSystem.exists(keysFile))
					throw "resetting every key should leave no file";
				shot("settings-keys-reset");
				// Extensions: a folder with a manifest is listed, and one whose manifest cannot be read says so.
				var extensions = haxe.io.Path.join([root, ".rayde", "extensions"]);
				if (!sys.FileSystem.exists(extensions))
					sys.FileSystem.createDirectory(extensions);
				for (name in ["hello", "broken"])
					sys.FileSystem.createDirectory(haxe.io.Path.join([extensions, name]));
				sys.io.File.saveContent(haxe.io.Path.join([extensions, "hello", "extension.json"]), '{"name": "Hello", "version": "0.1.0", "description": "Says hello in the status bar"}');
				sys.io.File.saveContent(haxe.io.Path.join([extensions, "broken", "extension.json"]), "{ nope");
				bench.openSettings("extensions");
				click("#rayde-settings-nav-keys");
				click("#rayde-settings-nav-extensions");
				shot("settings-extensions");
			});
			scenario(dark, "broken", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				bench.openFile(file);
				bench.run();
				wait(bench);
				settle();
				if (bench.runner.state != "failed" || bench.runner.problems.length != 1)
					throw 'the build should have failed with one problem: ${bench.runner.state}, ${bench.runner.problems.length}';
				shot("build-failed");
			});
		}
		for (dark in [true, false])
			scenario(dark, "extension", (bench, rays, shot, settle, scroll, click, type, hover, press, until) -> {
				settle();
				var studio = bench.studioFor(rays);
				if (studio == null)
					throw "opening an extension project should start its extension";
				var says = (text:String) -> studio.preview != null && Lambda.exists(studio.preview.outline(), o -> o.text == text);
				until(() -> says("ext/main.rays"), "the extension's view, with the file a mocked call answered with");
				// The view is in the sidebar in the Explorer's place, and its icon is in the activity bar; the Explorer's icon brings the Explorer back.
				shot("extension-sidebar");
				click("#rayde-activity-explorer");
				shot("extension-explorer");
				click("#rayde-activity-ext");
				bench.showPanel("extension");
				shot("extension-console");
				click("#rayde-studio-surface button");
				until(() -> says("1"), "the click to reach the extension and its change to come back");
				// The header is the extension's: a tool of its config runs its handler, and it can change the title.
				click("#rayde-tool-add");
				until(() -> says("A note 2") && studio.title.get() == "Notes (4)", "the tool to be answered, and the title changed");
				shot("extension-tool");
				click("#rayde-extension-activity");
				shot("extension-activity");
				click("#rayde-extension-elements");
				shot("extension-elements");
				// The config as a form: a change is written to the .rayext at once, and the heading follows.
				bench.openSettings("extension");
				settle(10);
				shot("extension-config");
				var config = haxe.io.Path.join([haxe.io.Path.directory(haxe.io.Path.directory(rays)), "notes.rayext"]);
				click("#rayde-ext-title");
				type("#rayde-ext-title", "Field notes");
				press(Named(Enter));
				until(() -> studio.title.get() == "Field notes" && sys.io.File.getContent(config).indexOf('"title": "Field notes"') > 0, "the heading to be written to the config and shown");
				click("#rayde-ext-cap-terminal");
				until(() -> sys.io.File.getContent(config).indexOf('"terminal"') > 0, "a capability to be written to the config");
				var text = sys.io.File.getContent(config);
				if (text.indexOf('"id": "reset"') < 0 || text.indexOf('"main": "ext/main.rays"') < 0)
					throw "the form should leave what it did not change as it was: " + text;
				shot("extension-config-edited");
				bench.openFile(rays);
				// A mistake as it is typed: the view stays as it was, the error lands in Problems, and the line opens from the Console.
				var buffer = bench.buffer(rays), good = buffer.get();
				buffer.set(StringTools.replace(good, "var count = signal(0);", "var = signal(0);"));
				bench.edited(rays);
				until(() -> bench.problems.get().length > 0, "the typed mistake to be found");
				if (!says("ext/main.rays"))
					throw "the last view that ran should stay while the source has a mistake";
				bench.showPanel("problems");
				shot("extension-error");
				buffer.set(good);
				bench.edited(rays);
				until(() -> bench.problems.get().length == 0 && !studio.stale.get() && says("ext/main.rays"), "the fixed extension to run again");
				shot("extension-fixed");
				var nextMain = haxe.io.Path.directory(rays) + "/other.rays";
				sys.io.File.saveContent(nextMain, good);
				bench.openSettings("extension");
				click("#rayde-ext-main");
				type("#rayde-ext-main", "ext/other.rays");
				press(Named(Enter));
				until(() -> studio.file == nextMain && studio.connection.file == nextMain && studio.running(), "changing the main script to retarget the managed host");
				if (bench.extensionManager.extensions.length != 1 || bench.studioFor(nextMain) != studio) throw "changing the main script should keep one managed connection and Studio";
			});
		for (dark in [true, false])
			scenario(dark, "markdown", (bench, rays, shot, settle, scroll, click, type, hover, press, until) -> {
				settle();
				var studio = bench.studioFor(rays);
				if (studio == null)
					throw "opening an extension project should start its extension";
				var root = haxe.io.Path.directory(haxe.io.Path.directory(rays)), readme = root + "/docs/README.md", tree = bench.tree;
				// Text is placed word by word, so the view is looked at for a word.
				var says = (word:String) -> studio.preview != null && Lambda.exists(studio.preview.outline(), o -> o.text != null && o.text.indexOf(word) >= 0);
				var has = (selector:String) -> ashui.css.Css.query(tree, bench.node.id, selector).length > 0;
				var menuOn = (path:String) -> {
					var found = ashui.css.Css.query(tree, bench.node.id, '[data-path$="$path"] > .ui-tree-row');
					if (found.length == 0)
						throw 'no row for $path';
					var b = tree.getScrolledBounds(new ashui.layout.Node(found[0]));
					ashui.input.Pointer.move(tree, b.x + b.width / 2, b.y + b.height / 2);
					ashui.input.Pointer.press(tree, Right);
					ashui.input.Pointer.release(tree, Right);
					settle(8);
				};
				var previews = () -> [for (f in bench.open.get()) if (StringTools.startsWith(f, Workbench.TAB)) f];
				// The extension declares no view: the Explorer keeps the sidebar and there is no icon for it in the activity bar. Its item is in the menu of a Markdown file only.
				until(() -> studio.state.get() == "running", "the extension to start");
				if (has("#rayde-activity-ext"))
					throw "an extension with no view should have no icon in the activity bar";
				menuOn("README.md");
				if (!has("#rayde-explorer-preview"))
					throw "a Markdown file should have the extension's Preview in its menu";
				shot("markdown-menu");
				press(Named(Escape));
				menuOn("ext/main.rays");
				if (has("#rayde-explorer-preview"))
					throw "a script should not have Preview in its menu";
				press(Named(Escape));
				// Choosing Preview runs the extension's command on the file, and what it mounts opens as a tab.
				menuOn("README.md");
				click("#rayde-explorer-preview");
				until(() -> previews().length == 1 && says("Markdown"), "the preview to open as a tab");
				if (bench.active.get() != previews()[0])
					throw "the new tab should be in front";
				shot("markdown-tab");
				// Preview again on the same file brings it up to date and opens nothing more.
				menuOn("README.md");
				click("#rayde-explorer-preview");
				settle(30);
				if (previews().length != 1 || studio.tabViews.length != 1)
					throw "a file should have one preview";
				// Saving the file brings the tab up to date, from the editor's text.
				var text = bench.buffer(readme);
				text.set("# Rewritten heading\n\nA line, with `code` and **weight**.\n");
				bench.edited(readme);
				bench.saveAll();
				until(() -> says("Rewritten") && !says("Markdown"), "the saved text to reach the tab");
				shot("markdown-saved");
				// Closing the tab tells the extension, which unmounts the view.
				bench.closeFile(previews()[0]);
				until(() -> studio.tabViews.length == 0 && !says("Rewritten"), "the extension to unmount the closed tab");
				shot("markdown-closed");
				// The editor's actions menu has the extension's item for the file in front, when its conditions hold.
				bench.openFile(readme);
				click("#rayde-editor-menu-trigger");
				if (!has("#rayde-menu-ext-preview"))
					throw "a Markdown file should have the extension's Preview in the editor's menu";
				shot("markdown-title-menu");
				press(Named(Escape));
				bench.openFile(rays);
				click("#rayde-editor-menu-trigger");
				if (has("#rayde-menu-ext-preview"))
					throw "a script should not have Preview in the editor's menu";
				press(Named(Escape));
				bench.openFile(readme);
				click("#rayde-editor-menu-trigger");
				click("#rayde-menu-ext-preview");
				until(() -> previews().length == 1 && says("Rewritten"), "the editor menu's Preview to open the tab");
				bench.closeFile(previews()[0]);
				until(() -> studio.tabViews.length == 0, "the closed tab to be unmounted");
				// The config form lists the extension's commands and menu items, and adds to both; each is written to the file at once.
				bench.openSettings("extension");
				settle(10);
				scroll("#rayde-extension-config", 760);
				shot("markdown-config");
				scroll("#rayde-extension-config", 1330);
				shot("markdown-hooks");
				var config = root + "/markdown.rayext";
				click("#rayde-ext-cmd-id");
				type("#rayde-ext-cmd-id", "refresh");
				type("#rayde-ext-cmd-title", "Refresh Preview");
				type("#rayde-ext-cmd-icon", "refresh");
				click("#rayde-ext-cmd-add");
				until(() -> sys.io.File.getContent(config).indexOf('"id": "refresh"') > 0, "the command to be written to the config");
				type("#rayde-ext-item-name", "README*");
				click("#rayde-ext-item-add");
				until(() -> sys.io.File.getContent(config).indexOf('"name": "README*"') > 0, "the menu item to be written to the config");
				var written = sys.io.File.getContent(config);
				if (written.indexOf('"icon": "ext/preview.svg"') < 0 || written.indexOf('"view"') >= 0)
					throw "the form should leave what it did not change as it was: " + written;
				shot("markdown-config-edited");
			});
		for (dark in [true, false])
			scenario(dark, "views", (bench, rays, shot, settle, scroll, click, type, hover, press, until) -> {
				settle();
				var studio = bench.studioFor(rays);
				if (studio == null)
					throw "opening an extension project should start its extension";
				var root = haxe.io.Path.directory(haxe.io.Path.directory(rays)), tree = bench.tree;
				var says = (word:String) -> studio.preview != null && Lambda.exists(studio.preview.outline(), o -> o.text != null && o.text.indexOf(word) >= 0);
				var has = (selector:String) -> ashui.css.Css.query(tree, bench.node.id, selector).length > 0;
				until(() -> says("Overview") && says("Inspector") && says("started"), "the three views to be drawn");
				// A view in each part of the layout: the sidebar, the right side bar and the bottom panel, each with its icon in the activity bar.
				for (selector in ["#rayde-activity-ext", "#rayde-activity-ext-inspector", "#rayde-activity-ext-log"])
					if (!has(selector))
						throw 'the activity bar should have $selector';
				for (selector in ["#rayde-view-ext #rayde-studio-surface", "#rayde-secondary #rayde-studio-surface", "#rayde-view-ext-log #rayde-studio-surface"])
					if (!has(selector))
						throw 'each view should be drawn in its own part: $selector';
				if (!has("#rayde-view-ext-log #rayde-studio-title"))
					throw "the panel view has its own header";
				shot("views");
				// An action of one view's header reaches the extension, and every view that shows the change follows it.
				click("#rayde-tool-refresh");
				until(() -> says("refresh 1") && Lambda.exists(studio.preview.outline(), o -> o.text == "2") && Lambda.exists(studio.preview.outline(), o -> o.text == "1"), "the action to be answered in the views");
				shot("views-refreshed");
				// The form lists each view with its own controls, and declares another. The right side bar and the panel are put away first, so the form has room.
				@:privateAccess bench.closePanel();
				@:privateAccess bench.secondaryWidth.set(0);
				settle(10);
				bench.openSettings("extension");
				settle(10);
				scroll("#rayde-extension-config", 520);
				shot("views-config");
				var config = root + "/dashboard.rayext";
				click("#rayde-ext-newview-id");
				type("#rayde-ext-newview-id", "extra");
				click("#rayde-ext-newview-add");
				until(() -> sys.io.File.getContent(config).indexOf('"id": "extra"') > 0 && has("#rayde-activity-ext-extra"), "the new view to be written to the config and given its icon");
				var written = sys.io.File.getContent(config);
				if (written.indexOf('"id": "inspector"') < 0 || written.indexOf('"refresh"') < 0)
					throw "the form should leave the other views as they were: " + written;
				shot("views-added");
			});
		for (dark in [true, false])
			scenario(dark, "chrome", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				settle();
				var chrome = bench.chrome, tree = bench.tree;
				var has = (selector:String) -> ashui.css.Css.query(tree, bench.node.id, selector).length > 0;
				var at = (x:Float, y:Float, ?times:Int) -> {
					ashui.input.Pointer.move(tree, x, y);
					for (_ in 0...(times == null ? 1 : times)) {
						ashui.input.Pointer.press(tree);
						ashui.input.Pointer.release(tree);
					}
					settle(3);
				};
				var asked = () -> chrome.calls.splice(0, chrome.calls.length).join(",");
				// The controls in the style of each platform; each asks the window for what it says.
				for (style in ["macos", "windows", "gnome", "kde"]) {
					@:privateAccess bench.windowStyle.set(style);
					settle(10);
					shot("bar-" + style);
					if (style == "macos") {
						hover("#rayde-win-close");
						settle(5);
						shot("bar-macos-hover");
					}
					// Over a bright colour, to see what the window leaves transparent at its corners.
					Snapshot.capture('rayde-${dark ? "dark" : "light"}-chrome-corners-$style', bench.tree, bench.node, WIDTH, HEIGHT, 0xff00ff);
					var middle = style == "macos" ? "#rayde-win-fullscreen" : "#rayde-win-maximize";
					click("#rayde-win-minimize");
					click(middle);
					click("#rayde-win-close");
					var expected = "minimize," + (style == "macos" ? "fullscreen" : "maximize") + ",close";
					var got = asked();
					if (got != expected)
						throw 'the $style controls should ask for $expected, not $got';
					// With no window the chrome keeps the state itself: the window now fills the screen, so it has no resize edges until it is restored.
					settle(5);
					if (style == "macos") {
						hover("#rayde-win-fullscreen");
						settle(5);
						shot("bar-macos-fullscreen-hover");
					}
					if (!(style == "macos" ? chrome.fullscreen.get() : chrome.maximized.get()) || has(".rayde-edge-w"))
						throw "a window that fills the screen has no resize edges";
					chrome.fullscreen.set(false);
					chrome.maximized.set(false);
					settle(5);
					if (!has(".rayde-edge-w"))
						throw "a window that does not fill the screen should have resize edges";
				}
				@:privateAccess bench.windowStyle.set("windows");
				settle(10);
				chrome.maximized.set(true);
				settle(5);
				if (has(".rayde-edge-w"))
					throw "a maximized window has no resize edges";
				shot("bar-windows-maximized");
				chrome.maximized.set(false);
				settle(5);
				// The bar moves the window, and a double click on it maximizes; the pill and the controls do not.
				at(250, 20);
				if (asked() != "drag")
					throw "a press on the bar should start a move";
				at(250, 20, 2);
				var twice = asked();
				if (twice.indexOf("maximize") < 0)
					throw 'a double click on the bar should maximize: $twice';
				chrome.maximized.set(false);
				settle(5);
				at(640, 20);
				if (asked() != "")
					throw "the pill is not a place to move the window from";
				bench.closeAll();
				// The edges and corners resize it from where they are.
				at(2, 400);
				at(1278, 400);
				at(640, 798);
				at(2, 2);
				at(1278, 798);
				var edges = asked();
				if (edges != "resize West,resize East,resize South,resize NorthWest,resize SouthEast")
					throw 'the edges should resize from where they are: $edges';
				shot("bar-after");
			});
		for (dark in [true, false])
			scenario(dark, "git", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				var manager = bench.extensionManager, git = manager.find("git"), tree = bench.tree;
				if (git == null) throw "Git fixture extension missing";
				manager.setNativeApproved("git", "git2", true);
				var studio = bench.studioFor(git.connection.file);
				function says(word:String):Bool
					return studio != null && studio.preview != null && Lambda.exists(studio.preview.outline(), o -> o.text.indexOf(word) >= 0);
				function within(id:String, word:String):Bool {
					var depth = -1;
					for (part in studio.preview.outline()) {
						if (part.props.indexOf("id=" + id) >= 0) { depth = part.depth; continue; }
						if (depth >= 0 && part.depth <= depth) return false;
						if (depth >= 0 && part.text.indexOf(word) >= 0) return true;
					}
					return false;
				}
				function control(id:String):rayde.ext.BridgeControl {
					var part = Lambda.find(studio.preview.outline(), p -> p.props.indexOf("id=" + id) >= 0);
					if (part == null) throw 'missing bridge $id';
					return @:privateAccess studio.preview.parts.get(part.id).control;
				}
				var icon = "#rayde-activity-ext-git-scm";
				if (Sys.getEnv("RAYDE_EXTENSION_PROBE") == "1") {
					if (!dark) return;
					ExtensionProbe.run(bench, file);
					return;
				}
				if (Sys.getEnv("RAYDE_INTERACTION_PROBE") == "1") {
					var scheme = Sys.getEnv("RAYDE_PROBE_SCHEME");
					if (scheme != null && scheme != (dark ? "dark" : "light")) return;
					InteractionProbe.run(bench, file, until);
					return;
				}
				if (Sys.getEnv("RAYDE_MEMORY_PROBE") == "1") {
					var probeRoot = haxe.io.Path.directory(haxe.io.Path.directory(file));
					var collected:Dynamic = null, previous = git.connection.onMessage;
					git.connection.onMessage = message -> {
						if (previous != null) previous(message);
						if (message.t == "collected") collected = message;
					};
					function sample(label:String):Void {
						settle(); shot("memory-" + label);
						hl.Gc.major(); Offscreen.advance(2.2); settle(5);
						collected = null; git.connection.collect();
						until(() -> collected != null, "memory probe collection");
						var count = 0, gpu = 0, cpu = 0;
						@:privateAccess for (canvas in ashui.ui.Canvas.bySlot) {
							count++;
							gpu += canvas.painter.rows * 2048 * 16;
							if (canvas.painter.bytes != null) cpu += canvas.painter.bytes.length;
						}
						var layers = 0, glyphs = 0, records = 0;
						@:privateAccess {
							var renderer = Snapshot.renderer().renderer;
							for (layer in renderer.layers) if (layer != null) layers += layer.width * layer.height * 4;
							for (target in [renderer.frameLayer, renderer.rows, renderer.shadow]) if (target != null) layers += target.width * target.height * 4;
							if (renderer.atlas != null) glyphs += renderer.atlas.textureWidth * renderer.atlas.textureHeight;
							if (renderer.colorAtlas != null) glyphs += renderer.colorAtlas.textureWidth * renderer.colorAtlas.textureHeight * 4;
							records = renderer.recordRows * 2048 * 16;
						}
						Sys.println("memory-probe:" + haxe.Json.stringify({phase:(dark ? "dark-" : "light-") + label,
							canvases:count, canvasGpuBytes:gpu, canvasCpuBytes:cpu, nodes:tree.order().length, vm:collected,
							haxe:hl.Gc.stats(), rendererLayers:layers, rendererGlyphs:glyphs, rendererRecords:records}));
						Sys.stdout().flush(); Sys.sleep(1);
					}
					sample("baseline");
					for (name in ["Main.hx", "Names.hx", "Util.hx"]) {
						if (name != "Main.hx") sys.io.File.copy("tests/fixtures/basic/src/" + name, probeRoot + "/src/" + name);
						bench.openFile(probeRoot + "/src/" + name); settle();
					}
					sample("three-editors");
					click(icon); until(() -> says("Add Git history graph"), "memory probe sidebar");
					sample("sidebar");
					var cycles = Std.parseInt(Sys.getEnv("RAYDE_MEMORY_CYCLES") ?? "5");
					for (iteration in 0...cycles) {
						git.connection.command("git.history", null);
						until(() -> studio.tabViews.length == 1 && says("100"), "memory probe history");
						var tab = bench.active.get();
						sample('history-$iteration');
						bench.openFile(file); settle();
						bench.closeFile(tab);
						until(() -> studio.tabViews.length == 0, "memory probe history close");
						sample('closed-$iteration');
					}
					click("#rayde-activity-explorer"); bench.closeAll(); sample("closed-all");
					return;
				}
				if (Css.query(tree, bench.node.id, icon).length == 0) throw "Git SCM activity icon missing";
				if (git.connection.manifest.views[0].icon != "branch") throw "Git SCM must use Ashui's git-branch icon";
				click(icon);
				until(() -> says("modified.txt") && says("staged.txt") && says("conflict.txt") && says("untracked.txt") && says("5 files"), "the SCM sidebar's native status groups");
				if (Lambda.exists(studio.console.get(), e -> e.kind == "error")) throw haxe.Json.stringify(studio.console.get());
				for (label in ["Merge conflicts", "Staged", "Changes", "Untracked", "renamed-file.txt", "main"])
					if (!says(label)) throw 'missing SCM content $label';
				shot("scm-ready");
				scroll("#git-scm-working-files", 150);
				click("#git-scm-changes .ui-button");
				until(() -> StringTools.endsWith(bench.active.get(), "/src/modified.txt"), "an SCM filename row to open its full path in the editor");
				var sourceDocument = bench.editorFor(bench.active.get()).document;
				var retainedHeader = Css.query(tree, bench.node.id, "#rayde-tab-modified-txt")[0];
				var sourcePath = bench.active.get();
				until(() -> says("Fixture"), "the sidebar history to finish loading");
				until(() -> within("git-scm-commit-files", "history.txt"), "the selected sidebar commit's changed files");
				var previousScene = @:privateAccess control("git-scm-canvas").scene.get();
				git.connection.hook("active.changed", {path:sourcePath}); settle(30);
				if ((@:privateAccess control("git-scm-canvas").scene.get()) != previousScene) throw "tab switches refreshed unchanged Git history";
				// Quiet polling still discovers worktree edits made outside the editor.
				var external = haxe.io.Path.directory(haxe.io.Path.directory(file)) + "/external-change.txt";
				sys.io.File.saveContent(external, "External edit\n");
				until(() -> says("external-change.txt"), "visible SCM to discover an external file");
				if ((@:privateAccess control("git-scm-canvas").scene.get()) != previousScene) throw "worktree-only changes rebuilt commit history";
				sys.FileSystem.deleteFile(external); git.connection.command("git.refresh", null);
				until(() -> !says("external-change.txt"), "explicit SCM refresh after deletion");

				var previousRight = 0.;
				for (id in ["git-fetch", "git-pull", "git-pull-options", "git-push"]) {
					var bounds = tree.getScrolledBounds(control(id).node);
					if (bounds.width < 30 || bounds.x < previousRight + 3) throw 'Git toolbar spacing collapsed at $id';
					previousRight = bounds.x + bounds.width;
				}
				for (id in ["git-fetch", "git-pull", "git-push"])
					if (Css.query(tree, control(id).node.id, ".ui-icon").length != 1) throw 'missing toolbar icon $id';
				hover("#git-fetch .ui-button"); settle(50); shot("fetch-tooltip");
				click("#git-pull-options .ui-button"); settle(30);
				if (Css.query(tree, bench.node.id, ".ui-menu-item").length < 3) throw "Pull strategy choices missing";
				shot("pull-options"); press(Named(Escape)); settle(30);
				shot("scm");
				var sideCanvas:ashui.canvaskit.CanvasKit = @:privateAccess control("git-scm-canvas").kit;
				var sideControl = control("git-scm-canvas"), sideBounds = tree.getScrolledBounds(sideControl.node);
				// Every resize frame lays out the canvas at its viewport's current size.
				var sideDivider = bench.boundsOf("#rayde-columns > .ui-resizable-handle");
				var dividerX = sideDivider.x + sideDivider.width / 2, dividerY = sideDivider.y + sideDivider.height / 2;
				ashui.input.Pointer.move(tree, dividerX, dividerY);
				ashui.input.Pointer.press(tree);
				for (dx in [-16, -32, -48, -32, -16, 0]) {
					ashui.input.Pointer.move(tree, dividerX + dx, dividerY);
					settle(1);
					if (control("git-scm-canvas") != sideControl || sideControl.node == null)
						throw "resizing the sidebar remounted the Git view";
					var viewportBounds = tree.getBounds(sideControl.node), canvasBounds = tree.getBounds(sideCanvas.node);
					if (Math.abs(canvasBounds.width - viewportBounds.width) > 1 || Math.abs(canvasBounds.height - viewportBounds.height) > 1)
						throw "the Git canvas lags behind its viewport during resize";
					if (dx == -48)
						Snapshot.capture('rayde-${dark ? "dark" : "light"}-git-scm-resize-frame', tree, bench.node, WIDTH, HEIGHT, ThemeState.get().color(Background).rgb());
				}
				ashui.input.Pointer.release(tree);
				settle();
				if (Sys.getEnv("RAYDE_RESIZE_PROBE") == "1") {
					Sys.println("Git sidebar resize: mounted view and viewport size preserved through every drag frame");
					return;
				}
				var pixels = Snapshot.renderer().renderToRgba8(bench, WIDTH, HEIGHT);
				var highlight = ThemeState.get().color(Selection);
				var px = Std.int(sideBounds.x + 200), py = Std.int(sideBounds.y + 21), base = Std.int(sideBounds.x + 1);
				var rgb = [highlight.byte(highlight.r), highlight.byte(highlight.g), highlight.byte(highlight.b)];
				for (channel in 0...3) {
					var expected = Math.round(pixels.get((py * WIDTH + base) * 4 + channel) * (1 - highlight.a) + rgb[channel] * highlight.a);
					var actual = pixels.get((py * WIDTH + px) * 4 + channel);
					if (Math.abs(actual - expected) > 3) throw 'selected row lost theme alpha: channel $channel expected $expected got $actual';
				}
				ashui.input.Pointer.move(tree, sideBounds.x + 90, sideBounds.y + 36);
				ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree);
				until(() -> sideCanvas.selection.ids.get().length == 1, "sidebar graph selection");
				var selected = sideCanvas.selection.ids.get()[0];
				until(() -> says(selected.substr(0,7)), "sidebar graph selection to reach RayScript");
				until(() -> within("git-scm-commit-files", "trust.txt"), "selecting a merge commit to reveal its first-parent changed files");
				shot("scm-commit-files");
				click("#git-scm-focus-commit .ui-button");
				until(() -> (@:privateAccess control("git-scm-focus").value.get()) == selected && !(@:privateAccess control("git-scm-focus").disabled.get()), "sidebar focus on the selected commit");
				click("#git-scm-focus .ui-select"); press(Named(Home)); press(Named(Enter));
				until(() -> (@:privateAccess control("git-scm-focus").value.get()) == "all" && !(@:privateAccess control("git-scm-focus").disabled.get()), "restore all sidebar references");
				var sideScroll = ashui.input.Scroll.at(sideControl.node.id, tree);
				ashui.input.Pointer.move(tree, sideBounds.x + 90, sideBounds.y + 36);
				ashui.input.Pointer.wheel(tree, 0, -115); settle();
				if (sideScroll == null || sideScroll.y.get() <= 0 || sideCanvas.viewport.zoom.get() != 1) throw "sidebar graph must scroll at a fixed scale";
				var scrolledHit = sideCanvas.index.hitTest(90, sideScroll.y.get() + 36);
				ashui.input.Pointer.move(tree, sideBounds.x + 90, sideBounds.y + 36);
				ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree);
				until(() -> scrolledHit != null && sideCanvas.selection.has(scrolledHit.id) && says(scrolledHit.id.substr(0,7)), "selection after scrolling to use content coordinates");
				shot("scm-scrolled");
				sideScroll.scrollTo(0, 0); settle();
				var splitter = Css.query(tree, bench.node.id, "#git-scm-panels .ui-resizable-handle")[0];
				var splitBounds = tree.getScrolledBounds(new ashui.layout.Node(splitter));
				ashui.input.Pointer.move(tree, splitBounds.x + splitBounds.width/2, splitBounds.y + splitBounds.height/2);
				ashui.input.Pointer.press(tree);
				ashui.input.Pointer.move(tree, splitBounds.x + splitBounds.width/2, splitBounds.y - 65); settle();
				ashui.input.Pointer.release(tree); settle();
				if (tree.getScrolledBounds(sideControl.node).height <= sideBounds.height + 40) throw "native resizable panels did not resize the graph";
				var resizedHeight = tree.getScrolledBounds(sideControl.node).height;
				press(Named(ArrowUp));
				if (tree.getScrolledBounds(sideControl.node).height <= resizedHeight) throw "native resize keyboard handling failed";
				shot("scm-resized");
				click("#rayde-panel-toggle-graph"); settle(40);
				if (tree.getScrolledBounds(sideControl.node).height > 1) throw "native collapsible did not close the graph";
				shot("scm-collapsed");
				press(Named(Enter)); settle(40);
				if (tree.getScrolledBounds(sideControl.node).height <= sideBounds.height + 40) throw "native collapsible lost the expanded size";
				var root = haxe.io.Path.directory(haxe.io.Path.directory(file));
				sys.io.File.saveContent(root + "/clean.txt", "Changed after initial status\n");
				click('#rayde-tool-git-refresh');
				until(() -> says("clean.txt") && says("6 files"), "the sidebar toolbar to refresh native status");
				shot("scm-refreshed");
				click('#git-scm-expand .ui-button');
				until(() -> says("100") && says("Add Git history graph"), "the native history page and selected commit details");
				until(() -> within("git-history-files", "history.txt"), "the expanded graph's selected commit files");
				if (Lambda.exists(studio.console.get(), e -> e.kind == "error")) throw haxe.Json.stringify(studio.console.get());
				function canvas():ashui.canvaskit.CanvasKit return @:privateAccess control("git-history-canvas").kit;
				shot("history");
				click("#rayde-tab-Git-history-close");
				until(() -> studio.tabViews.length == 0, "history tab close button");
				click("#git-scm-expand .ui-button");
				until(() -> studio.tabViews.length == 1 && within("git-history-files", "history.txt"), "sidebar maximize after the tab close button");
				shot("history-close-button-reopened");
				var kit = canvas(), viewport = kit.viewport, bounds = tree.getScrolledBounds(kit.node);
				var point = viewport.contentToScreen(130, 66);
				ashui.input.Pointer.move(tree, bounds.x + point.x, bounds.y + point.y); settle();
				if ((@:privateAccess control("git-history-canvas").hovered.get()) == "") throw "canvas hover region missing";
				ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree);
				until(() -> says("Merge native library trust"), "canvas click to select a commit through RayScript");
				until(() -> within("git-history-files", "trust.txt"), "a selected merge commit's changed files in the expanded view");
				shot("selected");
				var revision = studio.preview.revision;
				var scrollGraph = ashui.input.Scroll.at(control("git-history-canvas").node.id, tree);
				ashui.input.Pointer.move(tree, bounds.x + 120, bounds.y + 120);
				ashui.input.Pointer.wheel(tree, 0, -240); settle();
				if (scrollGraph == null || scrollGraph.y.get() <= 0) throw "expanded history did not scroll";
				var scrollY = scrollGraph.y.get();
				ashui.input.Pointer.press(tree, Middle);
				ashui.input.Pointer.move(tree, bounds.x + 160, bounds.y + 140); settle();
				ashui.input.Pointer.release(tree, Middle); settle();
				if (viewport.zoom.get() != 1 || viewport.panX.get() != -scrollGraph.x.get() || viewport.panY.get() != -scrollGraph.y.get() || scrollGraph.y.get() != scrollY)
					throw "linear history accepted a pan or zoom gesture";
				if (studio.preview.revision != revision) throw "scrolling sent drawing operations through the host";
				shot("scrolled");
				var drawing = Lambda.find(studio.preview.outline(), p -> p.props.indexOf("id=git-history-canvas") >= 0);
				var accepted = @:privateAccess control("git-history-canvas").scene.get();
				studio.preview.apply([["set", drawing.id, "scene", {commands: [{type: "circle", radius: -1}]}]]);
				if ((@:privateAccess control("git-history-canvas").scene.get()) != accepted) throw "invalid scene replaced the last accepted drawing";
				if (git.output.join("\n").indexOf("Canvas radius is out of range") < 0) throw "invalid scene was not reported in the extension Output";
				var saved = control("git-history-canvas").state(), hooks = LayoutTree.settledHooks.length;
				var panelSizes = haxe.Json.stringify(control("git-scm-panels").state());
				studio.preview.hide();
				if (LayoutTree.settledHooks.length != hooks - 4) throw "hidden canvases retained their layout hooks";
				studio.preview.show(); settle();
				if (haxe.Json.stringify(control("git-scm-panels").state()) != panelSizes) throw "panel sizes did not survive presentation rebuild";
				// Reattach the remounted roots to the workbench's tab surface.
				@:privateAccess for (surface in studio.surfaces) surface.attached = [];
				@:privateAccess studio.adopt();
				settle();
				var restored = control("git-history-canvas").state();
				if (restored.scrollX != saved.scrollX || restored.scrollY != saved.scrollY) throw "hidden history lost its scroll position";
				click("#git-history-more .ui-button");
				until(() -> says("114"), "the next native history page");
				revision = studio.preview.revision;
				click("#git-history-more .ui-button");
				if (studio.preview.revision != revision) throw "disabled load-more button dispatched an event";
				click("#git-history-branch .ui-select"); press(Named(End)); press(Named(Enter));
				until(() -> says("Prepare extension runtime 105"), "the tag's first history page");
				click("#git-history-more .ui-button");
				until(() -> within("git-history-count", "105") && !(@:privateAccess control("git-history-branch").disabled.get()), "tag filtering through the native select component");
				shot("filtered");
				var focusedCommit = canvas().selection.ids.get()[0];
				click("#git-history-focus .ui-button");
				until(() -> (@:privateAccess control("git-history-branch").value.get()) == focusedCommit && !(@:privateAccess control("git-history-branch").disabled.get()), "expanded graph focus on a commit");
				click("#git-history-all .ui-button");
				until(() -> (@:privateAccess control("git-history-branch").value.get()) == "all" && !(@:privateAccess control("git-history-branch").disabled.get()) && within("git-history-files", "history.txt"), "restore all references and latest commit files");
				var tab = bench.active.get();
				bench.closeFile(tab);
				until(() -> studio.tabViews.length == 0, "Git view and native cursor cleanup");
				settle();
				if (bench.editorFor(sourcePath) == null || bench.editorFor(sourcePath).document != sourceDocument) throw "opening and closing history discarded another tab's document";
				if (Css.query(tree, bench.node.id, "#rayde-tab-modified-txt")[0] != retainedHeader) throw "opening and closing history rebuilt another tab's header";
				// The graph's sketch loses two hooks; the remounted minimap adds its one size hook.
				if (LayoutTree.settledHooks.length != hooks - 1) throw 'closing history leaked canvas layout hooks: $hooks -> ${LayoutTree.settledHooks.length}';
				for (cycle in 0...2) {
					click("#git-scm-expand .ui-button");
					until(() -> studio.tabViews.length == 1 && within("git-history-files", "history.txt"), "sidebar maximize to reopen the closed history");
					shot('history-reopened-$cycle');
					click("#rayde-tab-Git-history-close");
					until(() -> studio.tabViews.length == 0, "reopened history cleanup");
					settle();
					if (LayoutTree.settledHooks.length != hooks - 1) throw "reopening history leaked canvas layout hooks";
				}
				for (action in ["others", "saved", "all"]) {
					click("#git-scm-expand .ui-button");
					until(() -> studio.tabViews.length == 1 && within("git-history-files", "history.txt"), 'history before Close $action');
					if (action == "others") { bench.openFile(sourcePath); settle(); }
					click("#rayde-editor-menu-trigger");
					click("#rayde-menu-close-" + action);
					until(() -> studio.tabViews.length == 0, 'Close $action to unmount history');
					click("#git-scm-expand .ui-button");
					until(() -> studio.tabViews.length == 1 && within("git-history-files", "history.txt"), 'sidebar maximize after Close $action');
					shot('history-reopened-after-close-$action');
					click("#rayde-tab-Git-history-close");
					until(() -> studio.tabViews.length == 0, "bulk-close regression cleanup");
				}
				git.connection.send({t:"run", name:"virtual-graph.rays", source:"var commands = [], regions = []; for (i in 0...1000) { var y = i * 24; commands.push({type:'path',path:[['M',20,y],['L',20,y+24]],stroke:2,color:'accent'}); commands.push({type:'circle',x:20,y:y+12,radius:4,color:'accent'}); commands.push({type:'text',x:40,y:y+16,text:'Commit ' + i,color:'textPrimary'}); regions.push({id:'row' + i,x:0,y:y,width:640,height:24}); } var full = {bounds:{x:0,y:0,width:640,height:24000},commands:commands,regions:regions}; var drawing = signal(full); registerCommand('test.virtualShort', () -> drawing.value = {bounds:{x:0,y:0,width:640,height:24},commands:[],regions:[]}); mount(() -> <canvas-kit id='virtual-graph' class='flex-1 min-h-0' navigation='scroll' textRendering='native' scene={drawing} onClick={e -> trace('virtual row ' + e.region + ' y=' + e.y)}/>, 'tab:Virtual graph');"});
				until(() -> studio.tabViews.length == 1, "a large virtual history scene"); settle();
				var virtualControl = control("virtual-graph"), virtualKit:ashui.canvaskit.CanvasKit = @:privateAccess virtualControl.kit;
				var virtualBounds = tree.getScrolledBounds(virtualKit.node), virtualScroll = ashui.input.Scroll.at(virtualControl.node.id, tree);
				if (virtualBounds.height > HEIGHT || virtualBounds.width > WIDTH) throw "virtual graph allocated a canvas larger than the viewport";
				if (virtualKit.index.get("row0") == null || virtualKit.index.get("row999") != null) throw "virtual graph indexed offscreen rows";
				function labelsVisible():Void {
					var rgba = Snapshot.renderer().renderToRgba8(bench, WIDTH, HEIGHT), b = tree.getScrolledBounds(virtualKit.node);
					var ink = ThemeState.get().color(TextPrimary), count = 0;
					for (y in Std.int(b.y + 20)...Std.int(b.y + b.height - 20))
						for (x in Std.int(b.x + 50)...Std.int(b.x + 180)) {
							var at = (y * WIDTH + x) * 4;
							if (Math.abs(rgba.get(at) - ink.byte(ink.r)) < 8 && Math.abs(rgba.get(at+1) - ink.byte(ink.g)) < 8 && Math.abs(rgba.get(at+2) - ink.byte(ink.b)) < 8) count++;
						}
					if (count < 80) throw 'virtual text disappeared after scrolling: $count text pixels';
					if (Css.query(tree, virtualControl.node.id, ".rayde-canvas-label").length > 80) throw "virtual canvas retained offscreen label nodes";
				}
				for (offset in [600., 2400.5, 18000.25, 900., 0., 23800.]) {
					virtualScroll.scrollTo(0, offset); settle(3); labelsVisible();
					hl.Gc.major(); Offscreen.advance(2.2); settle(3); labelsVisible();
				}
				virtualScroll.scrollTo(0, 24000); settle();
				var bottomBounds = tree.getScrolledBounds(virtualKit.node);
				if (bottomBounds.y != virtualBounds.y || bottomBounds.height != virtualBounds.height || virtualScroll.y.get() < 23000)
					throw "virtual graph did not keep its canvas anchored to the viewport";
				if (virtualKit.index.get("row999") == null || virtualKit.index.get("row0") != null || virtualKit.index.query(0,0,640,24000).length > 40)
					throw "virtual graph did not restrict hit regions to visible rows";
				shot("virtual-long");
				ashui.input.Pointer.move(tree, bottomBounds.x + 80, bottomBounds.y + 999*24 + 12 - virtualScroll.y.get());
				ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree);
				until(() -> git.output.join("\n").indexOf("virtual row row999 y=23988") >= 0, "virtual row hit testing after a deep scroll");
				git.connection.command("test.virtualShort", null);
				until(() -> (@:privateAccess virtualControl.scene.get().bounds.height) == 24, "a shorter virtual scene"); settle();
				if (virtualScroll.y.get() != 0) throw "virtual graph retained an out-of-range scroll offset after filtering";
				bench.closeFile(bench.active.get());
				until(() -> studio.tabViews.length == 0, "virtual scene cleanup");
				git.connection.send({t: "run", name: "fiber-check.rays", source: "var failed = false; mount(() -> <canvas-kit id='fiber-canvas' class='flex-1' scene={{bounds:{x:0,y:0,width:100,height:100},commands:[{type:'circle',x:50,y:50,radius:25,color:'accent'}],regions:[{id:'target',x:0,y:0,width:100,height:100}]}} onClick={e -> { if (!failed) { failed = true; throw 'fiber event aborted'; } trace('fiber event recovered'); }}/>, 'tab:Fiber check');"});
				until(() -> studio.tabViews.length == 1, "fiber recovery test view");
				settle(); shot("fiber-check");
				var c = control("fiber-canvas"), native:ashui.canvaskit.CanvasKit = @:privateAccess c.kit;
				var b = tree.getScrolledBounds(native.node);
				function hit():Void {
					ashui.input.Pointer.move(tree, b.x + 50, b.y + 50);
					ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree);
				}
				hit();
				until(() -> git.output.join("\n").indexOf("fiber event aborted") >= 0, "the handler exception to be reported");
				if (!git.connection.running() || git.restarts.length != 0) throw "handler failure restarted the extension host";
				hit();
				until(() -> git.output.join("\n").indexOf("fiber event recovered") >= 0, "another canvas event in the same host after the exception");
				bench.closeFile(bench.active.get());
				until(() -> studio.tabViews.length == 0, "fiber test view cleanup");
				bench.openCenter(">Git: History"); settle(5); press(Named(Enter));
				until(() -> says("Add Git history graph"), "Git history to reopen after cursor cleanup");
				bench.openSettings("extensions"); settle(10);
				click("#rayde-extension-setting-git-git-pullStrategy"); press(Named(End)); press(Named(Enter));
				if (Reflect.field(Store.section(root, "extension.git"), "git.pullStrategy") != "rebase") throw "Git pull preference was not saved";
				shot("pull-preference");
				until(() -> !(@:privateAccess control("git-fetch").disabled.get()), "Git refresh after the settings change");
				click("#git-fetch .ui-button");
				until(() -> git.output.join("\n").indexOf("No remote configured") >= 0 && Css.query(tree, bench.node.id, ".ui-toast").length > 0, "Git failure toast and Git Output entry");
				if (Css.query(tree, bench.node.id, "#git-scm-error").length != 0) throw "Git error was embedded in the sidebar";
				shot("error-toast");
				click(".ui-toast .ui-button");
				if ((@:privateAccess bench.outputChannel.get()) != "ext:git" || !bench.panelOpen()) throw "notification action did not open Git Output";
				until(() -> (@:privateAccess bench.extensionOutputView.get()) != null && (@:privateAccess bench.extensionOutputView.get()).scroll.y.get() > 0, "notification Output to reveal its latest message");
				var log = @:privateAccess bench.extensionOutputView.get();
				var failure = Lambda.find(log.document.lines, line -> line.text.indexOf("No remote configured") >= 0);
				if (failure == null || failure.tokens[0].kind != "keyword") throw "Git error lost its severity in Output: " + haxe.Json.stringify({
					lines: [for (line in log.document.lines) if (line.text.indexOf("No remote configured") >= 0) {text:line.text, tokens:line.tokens}],
					entries: [for (i in 0...git.output.length) if (git.output[i].indexOf("No remote configured") >= 0) {text:git.output[i], kind:git.outputKinds[i]}]
				});
				if (Css.query(tree, log.node.id, '[data-token="keyword"]').length == 0) throw "error text was not rendered as an error token";
				shot("error-output");
				log.select(failure.start, failure.start + failure.text.length);
				git.log("Fetch completed.", "success");
				git.log("Upstream changed.\r\nFetch again before pushing.", "warning");
				@:privateAccess bench.refreshExtensionOutput();
				settle();
				if ((@:privateAccess bench.extensionOutputView.get()) != log || log.editing.anchor.get() != failure.start) throw "appending Output replaced its view or selection";
				for (expected in [{text:"Fetch completed.", kind:"string"}, {text:"Upstream changed.", kind:"number"}, {text:"Fetch again before pushing.", kind:"number"}]) {
					var line = Lambda.find(log.document.lines, line -> line.text == expected.text);
					if (line == null || line.tokens[0].kind != expected.kind) throw "multiline Output severity: " + expected.text + ": " + haxe.Json.stringify([for (line in log.document.lines.slice(-8)) {text:line.text, tokens:line.tokens}]);
				}
				@:privateAccess bench.revealExtensionOutput(); settle();
				shot("output-severities");
				// The bounded log can replace text with identical text of another severity.
				for (_ in 0...1000) git.log("Repeated message", "error");
				@:privateAccess bench.refreshExtensionOutput(); settle();
				for (_ in 0...1000) git.log("Repeated message", "warning");
				@:privateAccess bench.refreshExtensionOutput(); settle();
				if (git.output.length != 1000 || git.outputKinds.length != 1000 || log.document.lines[0].tokens[0].kind != "number") throw "retained Output severities were stale after eviction";
				var build = new ashui.components.code.CodeDocument("Main.hx:2: characters 1-4 : Unknown identifier\n  additional detail\nMain.hx:3: characters 1-4 : Warning : Deprecated\nBuilding…\nExited with 1.\nExited with 0.", new rayde.ui.OutputHighlighter());
				var expected = ["keyword", "keyword", "number", "plain", "keyword", "string"];
				for (i in 0...expected.length) if (build.lines[i].tokens[0].kind != expected[i]) throw 'wrong build Output severity on line $i';
				Sys.println("git snapshots: history pages, references, selection, theme alpha, fixed-scale scrolling, cleanup and fiber exception recovery");
			});
		for (dark in [true, false])
			scenario(dark, "extensions", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				var manager = bench.extensionManager, markdown = manager.find("markdown"), dashboard = manager.find("dashboard");
				if (markdown == null || dashboard == null) throw "both workspace extensions should be discovered";
				var root = haxe.io.Path.directory(haxe.io.Path.directory(file));
				var has = (selector:String) -> Css.query(bench.tree, bench.node.id, selector).length > 0;
				until(() -> markdown.connection.listening().indexOf("file.saved") >= 0 && dashboard.connection.running(), "two installed extensions to start");
				for (selector in ["#rayde-activity-ext-markdown-preview", "#rayde-activity-ext-dashboard-main"])
					if (!has(selector)) throw 'installed view should have an activity icon: $selector';
				bench.openFile(file);
				click("#rayde-activity-ext-dashboard-main");
				shot("workspace");
				bench.openFile(root + "/README.md");
				bench.openCenter(">Preview");
				settle(5);
				press(Named(Enter));
				until(() -> Lambda.exists(bench.open.get(), f -> StringTools.startsWith(f, Workbench.TAB)), "the installed Markdown command to open its preview");
				shot("markdown");
				bench.openCenter(">Describe dashboard");
				settle(5);
				press(Named(Enter));
				until(() -> dashboard.output.indexOf("dashboard ready") >= 0, "the other extension's command to run");
				bench.openCenter(">Fail dashboard");
				settle(5);
				press(Named(Enter));
				until(() -> dashboard.output.join("\n").indexOf("dashboard failure") >= 0, "a script error to reach its Output channel");
				// Ending the embedded VM exercises restart supervision and its Output channel.
				dashboard.connection.send({t: "shutdown"});
				until(() -> dashboard.restarts.length == 1 && dashboard.connection.running(), "the exited extension to restart");
				bench.showPanel("console");
				bench.setPanelHeight(260);
				@:privateAccess bench.outputChannel.set("ext:dashboard");
				@:privateAccess bench.refreshExtensionOutput();
				if (dashboard.output.join("\n").indexOf("Restarting extension") < 0) throw "restart should be reported in the extension's Output channel";
				shot("restart-output");
				bench.openSettings("extensions");
				bench.setPanelHeight(0);
				settle(10);
				click("#rayde-extension-setting-dashboard-dashboard-compact");
				if (Reflect.field(Store.section(root, "extension.dashboard"), "dashboard.compact") != true) throw "a contributed setting should be saved in its extension's section";
				shot("settings");
				click("#rayde-extension-toggle-dashboard");
				until(() -> dashboard.disabled && !dashboard.connection.running(), "the Settings toggle to stop an installed extension");
				if (has("#rayde-activity-ext-dashboard-main")) throw "a disabled extension's icon should be removed";
				if (rayde.settings.Extensions.disabled(root).indexOf("dashboard") < 0) throw "the disabled extension should be persisted in workspace settings";
				shot("disabled");
				click("#rayde-extension-toggle-dashboard");
				until(() -> !dashboard.disabled && dashboard.connection.running() && has("#rayde-activity-ext-dashboard-main"), "enabling to restore the host and its contributions");
				var native = manager.find("native-example");
				if (native == null || native.state != "blocked" || native.connection.running()) throw "native extension should wait for approval";
				scroll("#rayde-extensions", 10000);
				shot("native-unapproved");
				click("#rayde-native-approve-native-example-example");
				until(() -> native.output.indexOf("native example ready") >= 0, "native approval to start the extension");
				shot("native-approved");
				click("#rayde-native-approve-native-example-example");
				until(() -> native.state == "blocked" && !native.connection.running(), "native revocation to stop the extension");
				shot("native-revoked");
			});

		for (dark in [true, false])
			scenario(dark, "debug", (bench, rays, shot, settle, scroll, click, type, hover, press, until) -> {
				settle();
				var studio = bench.studioFor(rays);
				if (studio == null)
					throw "opening an extension project should start its extension";
				var d = studio.debug, root = haxe.io.Path.directory(haxe.io.Path.directory(rays)), tree = bench.tree;
				var has = (selector:String) -> ashui.css.Css.query(tree, bench.node.id, selector).length > 0;
				var says = (word:String) -> studio.preview != null && Lambda.exists(studio.preview.outline(), o -> o.text != null && o.text.indexOf(word) >= 0);
				var stoppedAt = (line:Int) -> () -> d.stopped.get() != null && d.stopped.get().frames[0].line == line;
				until(() -> studio.state.get() == "running" && says("Total"), "the extension to start");
				// A breakpoint from the editor: the command puts one on the line the cursor is on, and keeps it in the project.
				bench.openFile(rays);
				bench.goTo(rays, 6, 0);
				settle(5);
				@:privateAccess bench.toggleBreakpoint();
				if (d.linesOf(rays).join(",") != "7")
					throw 'the breakpoint should be on line 7: ${d.linesOf(rays)}';
				settle(5);
				var editor = @:privateAccess bench.editorOf(rays);
				if (editor.markerLinesOf("breakpoints").join(",") != "6" || !has(".ui-code-marker-breakpoint"))
					throw "the breakpoint should be a dot in the gutter, on the line";
				shot("debug-gutter");
				// A press in the gutter puts one on a line and takes it off again.
				var gutter = ashui.css.Css.query(tree, bench.node.id, ".ui-code-gutter")[0], viewport = ashui.css.Css.query(tree, bench.node.id, ".ui-code-viewport")[0];
				var g = tree.getScrolledBounds(new ashui.layout.Node(gutter)), v = tree.getScrolledBounds(new ashui.layout.Node(viewport));
				var pressGutter = (line:Int) -> {
					ashui.input.Pointer.move(tree, g.x + 9, v.y + 8 + line * editor.metrics.lineHeight + editor.metrics.lineHeight / 2);
					ashui.input.Pointer.press(tree);
					ashui.input.Pointer.release(tree);
					settle(5);
				};
				pressGutter(12);
				if (d.linesOf(rays).join(",") != "7,13")
					throw 'a press in the gutter on line 13 should add a breakpoint: ${d.linesOf(rays)}';
				pressGutter(12);
				if (d.linesOf(rays).join(",") != "7")
					throw 'a second press should take it off: ${d.linesOf(rays)}';
				if (sys.io.File.getContent(root + "/.rayde/settings.json").indexOf('"ext/main.rays"') < 0)
					throw "the breakpoint should be kept in the project's settings";
				// An action runs the handler, which calls the function with the breakpoint, and the extension stops there.
				click("#rayde-tool-add");
				until(stoppedAt(7), "the extension to stop at the breakpoint");
				var stop = d.stopped.get();
				if (stop.frames.length != 2 || stop.frames[0].name != "record" || stop.frames[0].file != rays || stop.reason != "breakpoint")
					throw 'the stack should be record and its caller: ${stop.frames}';
				settle(20);
				until(() -> d.locals.get().length == 3, "the locals of the frame");
				var locals = [for (v in d.locals.get()) v.name + "=" + v.value].join(",");
				if (locals != "amount=5,before=0,entry={amount: 5, before: 0}")
					throw 'the locals of record: $locals';
				settle(5);
				if (!has(".ui-code-line-current"))
					throw "the line the extension is stopped on should be marked";
				// The editor goes to the line and the panel shows the stop.
				if (bench.active.get() != rays || bench.caretLine(rays) != 6 || bench.bottom.get() != "extension" || studio.panel.get() != "debug")
					throw "a stop should show its line in the editor and open the Debug panel";
				if (!has("#rayde-debug-continue") || has("#rayde-debug-pause"))
					throw "while stopped the toolbar offers Continue, not Pause";
				shot("debug-stopped");
				// An expression in the frame, and the members of a variable.
				click("#rayde-debug-evaluate");
				type("#rayde-debug-evaluate", "entry.amount");
				press(Named(Enter));
				until(() -> d.evaluation.get() != null && d.evaluation.get().ok && d.evaluation.get().text == "5", "the expression to be evaluated");
				var entry = Lambda.find(d.locals.get(), v -> v.name == "entry");
				d.toggleOpen(entry.ref);
				until(() -> d.membersOf(entry.ref).length == 2, "the members of entry");
				settle(5);
				shot("debug-variables");
				// The caller's frame has its own variables.
				click("#rayde-frame-1");
				until(() -> d.frame.get() == 1 && d.locals.get().length == 0, "the caller's variables");
				d.select(0);
				until(() -> d.locals.get().length == 3, "the variables of the top frame again");
				// Stepping: over to the next line, and out to the caller.
				click("#rayde-debug-over");
				until(stoppedAt(8), "the step to the next line");
				if (d.stopped.get().reason != "step")
					throw "a step stops because of the step";
				if (says("5"))
					throw "line 7 has run, so the signal has changed, but the view has not been flushed while stopped";
				click("#rayde-debug-out");
				until(stoppedAt(14), "the step out to the caller");
				shot("debug-stepped-out");
				// Going on: the extension runs, the view shows the change, and nothing is stopped.
				click("#rayde-debug-continue");
				until(() -> d.stopped.get() == null && says("5"), "the extension to go on and show the total");
				settle(5);
				if (has(".ui-code-line-current"))
					throw "the mark on the line goes when the extension goes on";
				// A breakpoint comes off with the same command and is not kept.
				bench.goTo(rays, 6, 0);
				settle(5);
				@:privateAccess bench.toggleBreakpoint();
				if (d.linesOf(rays).length != 0 || sys.io.File.getContent(root + "/.rayde/settings.json").indexOf('"ext/main.rays"') >= 0)
					throw "removing the breakpoint should remove it from the project's settings";
				click("#rayde-tool-add");
				settle(30);
				if (d.stopped.get() != null)
					throw "without a breakpoint the action does not stop";
				// A breakpoint moves with the text: a line put in above it moves it down, in the editor and for the host.
				bench.goTo(rays, 6, 0);
				settle(5);
				@:privateAccess bench.toggleBreakpoint();
				settle(5);
				var typing = @:privateAccess bench.editorOf(rays);
				typing.select(0, 0);
				typing.editing.replace("// A line above.\n");
				settle(5);
				if (d.linesOf(rays).join(",") != "8")
					throw 'the breakpoint should have moved down to line 8 with the text: ${d.linesOf(rays)}';
				typing.undo();
				settle(5);
				if (d.linesOf(rays).join(",") != "7")
					throw 'and back up to line 7 when the line goes: ${d.linesOf(rays)}';
			});
		for (dark in [true, false])
			scenario(dark, "themes", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				settle();
				var tree = bench.tree, home = Sys.getCwd() + "bin/fixtures/themes-home";
				if (sys.FileSystem.exists(home))
					for (f in sys.FileSystem.readDirectory(home))
						deleteTree(haxe.io.Path.join([home, f]));
				else
					sys.FileSystem.createDirectory(home);
				Sys.putEnv("RAYDE_THEMES", home);
				var has = (selector:String) -> ashui.css.Css.query(tree, bench.node.id, selector).length > 0;
				var primary = () -> ashui.theme.ThemeState.get().color(ashui.theme.ColorToken.Primary).rgb();
				var clickNth = (selector:String, n:Int) -> {
					var found = ashui.css.Css.query(tree, bench.node.id, selector);
					if (found.length <= n)
						throw 'there is no $n-th element for $selector';
					var at = tree.getScrolledBounds(new ashui.layout.Node(found[n]));
					ashui.input.Pointer.move(tree, at.x + at.width / 2, at.y + at.height / 2);
					ashui.input.Pointer.press(tree);
					ashui.input.Pointer.release(tree);
					settle(6);
				};
				// The scheme is the one this run is for, so what a theme gives is known.
				bench.openSettings("appearance");
				settle(10);
				click(dark ? "#rayde-scheme-dark" : "#rayde-scheme-light");
				if (!has("#rayde-custom-theme-empty") || has("#rayde-custom-theme"))
					throw "with no custom theme installed the card says so and has no list";
				shot("themes-none");
				// Installing a theme from its folder, then choosing it from the list under the built-in ones.
				var root = Sys.getCwd();
				// The card is below the schemes and the built-in themes: the page is scrolled to it.
				scroll("#rayde-appearance", 900);
				click("#rayde-theme-path");
				type("#rayde-theme-path", root + "themes/midnight");
				click("#rayde-theme-install");
				if (!sys.FileSystem.exists(home + "/midnight/midnight.raytheme") || !sys.FileSystem.exists(home + "/midnight/midnight.css"))
					throw "the theme and its stylesheet should be in the themes folder";
				if (!has("#rayde-custom-theme") || has("#rayde-custom-theme-empty"))
					throw "once a theme is installed the card has a list of them";
				shot("themes-installed");
				var before = primary();
				click("#rayde-custom-theme");
				clickNth(".ui-select-item", 1);
				if (rayde.ui.Theming.current.get() != "midnight")
					throw 'Midnight should be in use, not ${rayde.ui.Theming.current.get()}';
				if (primary() != (dark ? 0x8b6cff : 0x6a4cf0) || primary() == before)
					throw 'Midnight\'s primary colour should be in use: ${StringTools.hex(primary(), 6)}';
				if (sys.io.File.getContent(bench.display().cwd + "/.rayde/settings.json").indexOf('"theme": "midnight"') < 0)
					throw "the choice should be kept in the settings";
				if (!has("#rayde-custom-details"))
					throw "the theme in use has its details under the list";
				settle(10);
				sameHeight(bench, ["#rayde-theme-path", "#rayde-theme-install", "#rayde-theme-remove"]);
				shot("themes-midnight");
				bench.openFile(file);
				settle(10);
				shot("themes-midnight-editor");
				// A second theme, from a single file: it takes the place of the first, and the first's rules stop applying with it.
				bench.openSettings("appearance");
				settle(10);
				scroll("#rayde-appearance", 900);
				click("#rayde-theme-path");
				type("#rayde-theme-path", root + "themes/paper/paper.raytheme");
				click("#rayde-theme-install");
				click("#rayde-custom-theme");
				clickNth(".ui-select-item", 2);
				if (rayde.ui.Theming.current.get() != "paper" || primary() != (dark ? 0xe08a5c : 0xb4532a))
					throw 'Paper should be in use with its own primary colour: ${rayde.ui.Theming.current.get()} ${StringTools.hex(primary(), 6)}';
				var shown = ashui.css.Identity.of(tree, bench.node.id).attribute("data-theme");
				if (shown != "paper")
					throw 'the window should carry the theme it is in: $shown';
				shot("themes-paper");
				// The scheme changes within a theme.
				scroll("#rayde-appearance", 0);
				click(dark ? "#rayde-scheme-light" : "#rayde-scheme-dark");
				if (primary() != (dark ? 0xb4532a : 0xe08a5c))
					throw "the other scheme of Paper should be in use";
				click(dark ? "#rayde-scheme-dark" : "#rayde-scheme-light");
				scroll("#rayde-appearance", 900);
				// A theme is taken away, and the window goes back to a built-in one.
				click("#rayde-theme-remove");
				if (sys.FileSystem.exists(home + "/paper") || sys.FileSystem.exists(home + "/paper.raytheme") || rayde.ui.Theming.current.get() != "restrained")
					throw "removing the theme in use removes its files and returns to a built-in theme";
				shot("themes-removed");
				click("#rayde-custom-theme");
				clickNth(".ui-select-item", 1);
				click("#rayde-custom-theme");
				clickNth(".ui-select-item", 0);
				if (rayde.ui.Theming.current.get() != "restrained")
					throw "choosing Built-in themes goes back to a built-in theme";
				Sys.putEnv("RAYDE_THEMES", "");
			});
		for (dark in [true, false])
			scenario(dark, "themestudio", (bench, theme, shot, settle, scroll, click, type, hover, press, until) -> {
				settle(10);
				var studio = bench.themeModel();
				if (studio == null)
					throw "opening a .raytheme should start the Theme Studio";
				var root = haxe.io.Path.directory(theme), read = () -> sys.io.File.getContent(theme);
				var primary = () -> ashui.theme.ThemeState.get().color(ashui.theme.ColorToken.Primary).rgb();
				var has = (selector:String) -> ashui.css.Css.query(bench.tree, bench.node.id, selector).length > 0;
				// Scrolls the page until the element `selector` finds is near the top.
				var reveal = (selector:String) -> {
					var card = ashui.css.Css.query(bench.tree, bench.node.id, selector)[0], area = ashui.css.Css.query(bench.tree, bench.node.id, "#rayde-theme-studio")[0];
					var scroller = ashui.input.Scroll.at(area, bench.tree);
					scroller.scrollTo(0, scroller.y.get() + bench.tree.getScrolledBounds(new ashui.layout.Node(card)).y - 140);
					settle(4);
				};
				if (studio.problems.get().length > 0)
					throw "the fixture theme should read cleanly: " + studio.problems.get().map(p -> p.message).join("; ");
				if (rayde.ui.Theming.current.get() != "studio" || primary() != (dark ? 0x4cc2a8 : 0x12806b))
					throw 'the theme in the file should be on the window: ${rayde.ui.Theming.current.get()} ${StringTools.hex(primary(), 6)}';
				sameHeight(bench, ["#rayde-theme-light", "#rayde-theme-text", "#rayde-theme-install"]);
				sameHeight(bench, ["#rayde-font-path", "#rayde-font-add"]);
				sameHeight(bench, ["#rayde-theme-css-new", "#rayde-theme-css-add"]);
				shot("page");
				// A colour typed into its input is written where the file has it, and the window changes with it.
				click("#rayde-token-input-primary");
				type("#rayde-token-input-primary", "#ff5533");
				press(Named(Enter));
				until(() -> read().indexOf("#ff5533") > 0, "the colour to be written to the theme file");
				if (primary() != 0xff5533 || read().indexOf('"extends": "restrained"') < 0 || read().indexOf('"fonts": [{"family"') < 0)
					throw "the colour should be in use and the rest of the file left as written: " + read();
				if (bench.buffer(theme).get() != read())
					throw "the editor should hold what was written";
				shot("palette-edited");
				click("#rayde-token-reset-primary");
				until(() -> read().indexOf("#ff5533") < 0, "the colour to be taken out of the theme file");
				var base = primary();
				if (base == 0xff5533 || base == (dark ? 0x4cc2a8 : 0x12806b))
					throw "a reset colour goes back to the base theme's";
				// A font file from outside is copied beside the theme and listed under its family.
				var extra = Sys.getCwd() + "tests/fixtures/themestudio-extra/Lora-Italic.ttf";
				click("#rayde-font-path");
				type("#rayde-font-path", extra);
				click("#rayde-font-add");
				until(() -> read().indexOf("fonts/Lora-Italic.ttf") > 0, "the font file to be listed in the theme, under the family the file carries");
				if (!sys.FileSystem.exists(root + "/fonts/Lora-Italic.ttf") || studio.problems.get().length > 0)
					throw "the file should be copied beside the theme without problems: " + studio.problems.get().map(p -> p.message).join("; ");
				reveal("#rayde-theme-typography");
				shot("fonts-added");
				click("#rayde-font-remove-Lora-Italic-ttf");
				until(() -> read().indexOf("fonts/Lora-Italic.ttf") < 0, "the font file to be taken out of the theme");
				// A family chosen for a role is set in that face on the window.
				click("#rayde-font-use-sans-Lora");
				until(() -> read().indexOf('"sans": "Lora"') > 0, "the family to be set for sans");
				settle(20);
				// The sans role is the interface's font: a label that was there before the change resolves to it.
				var label = ashui.css.Css.query(bench.tree, bench.node.id, "#rayde-files .ui-tree-row")[0];
				var family = ashui.css.Css.resolved(ashui.css.Identity.of(bench.tree, label), "font-family");
				if (family == null || family.indexOf("Lora") != 0)
					throw "the window's text should be set in the sans family: " + family;
				// The type card at the top of the view, to see the specimens and the window in the new face.
				reveal("#rayde-theme-typography");
				shot("fonts-sans");
				click("#rayde-font-sans");
				type("#rayde-font-sans", "");
				press(Named(Enter));
				until(() -> read().indexOf('"sans"') < 0, "the sans family to be taken out");
				// The scheme changes within the theme.
				scroll("#rayde-theme-studio", 0);
				click(dark ? "#rayde-theme-light" : "#rayde-theme-dark");
				until(() -> primary() == (dark ? 0x12806b : 0x4cc2a8), "the other scheme of the theme to be in use");
				shot("other-scheme");
				click(dark ? "#rayde-theme-dark" : "#rayde-theme-light");
				until(() -> primary() == base, "the scheme to come back");
				// A stylesheet added beside the theme, and what the style system says of its rules.
				click("#rayde-theme-css-new");
				type("#rayde-theme-css-new", "extra.css");
				click("#rayde-theme-css-add");
				until(() -> read().indexOf('"file": "extra.css"') > 0 && sys.FileSystem.exists(root + "/extra.css"), "the stylesheet to be created and listed");
				sys.io.File.saveContent(root + "/extra.css", ".rayde-card { not-a-property: 1; }");
				studio.refresh();
				if (!Lambda.exists(studio.problems.get(), p -> p.message.indexOf("not-a-property") >= 0))
					throw "the style system's warning should be among the problems: " + studio.problems.get().map(p -> p.message).join("; ");
				shot("css-warning");
				// Installing the theme puts it, with its stylesheets and fonts, in the user's themes.
				var home = Sys.getCwd() + "bin/fixtures/themestudio-home";
				if (sys.FileSystem.exists(home))
					deleteTree(home);
				Sys.putEnv("RAYDE_THEMES", home);
				scroll("#rayde-theme-studio", 0);
				click("#rayde-theme-install");
				for (installed in ["studio/studio.raytheme", "studio/studio.css", "studio/extra.css", "studio/fonts/Lora-Regular.ttf"])
					if (!sys.FileSystem.exists(home + "/" + installed))
						throw 'installing the theme should bring $installed';
				if (!has("#rayde-theme-install-note"))
					throw "installing says where the theme went";
				shot("installed");
				Sys.putEnv("RAYDE_THEMES", "");
				// Typing in the editor: broken text keeps the last theme in force, and a mistake in the content is a problem on its line.
				bench.openFile(theme);
				var buffer = bench.buffer(theme), good = buffer.get();
				buffer.set("{nope");
				bench.edited(theme);
				until(() -> studio.stale.get(), "the broken text to be seen");
				if (primary() != base)
					throw "the last readable theme should stay on the window";
				if (!Lambda.exists(bench.problems.get(), p -> p.file == theme && p.severity == 1 && p.message.indexOf("Invalid JSON") == 0))
					throw "text that is not JSON is an error of the theme file";
				shot("text-broken");
				buffer.set(StringTools.replace(good, '"extends": "restrained"', '"extends": "gothic", "tint": 1'));
				bench.edited(theme);
				until(() -> !studio.stale.get() && studio.problems.get().length >= 2, "the mistakes in the content to be found");
				if (!Lambda.exists(bench.problems.get(), p -> p.file == theme && p.message.indexOf("gothic") >= 0 && p.range.start.line == 6))
					throw "a problem is on the line of the entry it names: " + bench.problems.get().map(p -> p.message + "@" + p.range.start.line).join("; ");
				shot("problems-text");
				bench.openThemeStudio();
				settle(10);
				shot("problems");
				click("#rayde-theme-problems .rayde-entry");
				if (bench.active.get() != theme)
					throw "a problem opens the theme as text";
				buffer.set(good);
				bench.edited(theme);
				until(() -> studio.problems.get().length == 0 || Lambda.foreach(studio.problems.get(), p -> p.message.indexOf("not-a-property") >= 0), "the fixed text to read again");
				bench.openThemeStudio();
				settle(20);
				reveal("#rayde-theme-gallery");
				shot("gallery");
				scroll("#rayde-theme-studio", 5000);
				shot("gallery-end");
			});
		for (dark in [true, false])
			scenario(dark, "markdownpreview", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				var root = haxe.io.Path.directory(haxe.io.Path.directory(file)), readme = root + "/README.md";
				var manager = bench.extensionManager, entry = manager.find("markdown"), tree = bench.tree;
				function row(path:String):String return '[data-path="$path"] > .ui-tree-row';
				for (path in [readme, root + "/other.md", root + "/src/notes.MD"])
					if (Css.query(tree, bench.node.id, row(path)).length != 1) throw 'Explorer skipped Markdown file $path';
				var guide = root + "/docs/guide.md";
				if (Css.query(tree, bench.node.id, row(guide)).length != 0) throw "Explorer loaded a closed docs folder eagerly";
				click(row(root + "/docs")); settle();
				if (Css.query(tree, bench.node.id, row(guide)).length != 1) throw "Explorer skipped a Markdown file outside the class path";
				click(row(guide));
				if (bench.active.get() != guide) throw "clicking Markdown in Explorer did not open its editor";
				click(row(readme));
				if (bench.active.get() != readme) throw "clicking root Markdown in Explorer did not open its editor";
				shot("explorer-markdown");
				if (entry == null || entry.connection.running()) throw "Markdown should activate on command";
				if (rayde.ui.ViewIcons.of(entry.connection.manifest) != rayde.ui.Icons.MARKDOWN_LINE) throw "Markdown must use the Remix Markdown icon";
				if (Css.query(tree, bench.node.id, "#rayde-activity-ext-markdown").length != 0) throw "Markdown preview must not add an activity icon";
				click("#rayde-editor-menu-trigger"); shot("editor-preview-menu"); press(Named(Escape));
				var menuBounds = tree.getScrolledBounds(new ashui.layout.Node(Css.query(tree, bench.node.id, row(readme))[0]));
				ashui.input.Pointer.move(tree, menuBounds.x + menuBounds.width/2, menuBounds.y + menuBounds.height/2);
				ashui.input.Pointer.press(tree, Right); ashui.input.Pointer.release(tree, Right); settle();
				var openBounds = tree.getBounds(new ashui.layout.Node(Css.query(tree, bench.node.id, "#rayde-explorer-open")[0]));
				var previewBounds = tree.getBounds(new ashui.layout.Node(Css.query(tree, bench.node.id, "#rayde-explorer-open-preview")[0]));
				if (Math.abs(openBounds.height - previewBounds.height) > 1) throw "Explorer menu icon added extra row height";
				hover("#rayde-explorer-open-preview"); settle();
				shot("context-preview-menu"); click("#rayde-explorer-open-preview");
				var studio = bench.studioFor(entry.connection.file);
				function ready():Bool return Css.query(tree, bench.node.id, ".rayde-markdown").length > 0;
				until(() -> {
					if (Lambda.exists(studio.console.get(), e -> e.kind == "error")) throw haxe.Json.stringify(studio.console.get());
					return ready();
				}, "the production Markdown preview"); settle();
				if (Lambda.exists(studio.console.get(), e -> e.kind == "error")) throw haxe.Json.stringify(studio.console.get());
				var firstScroll = ashui.input.Scroll.at(Css.query(tree, bench.node.id, "#markdown-scroll")[0], tree);
				if (firstScroll.y.get() != 0) throw "Markdown preview did not start at the document's beginning";
				var heading = tree.getScrolledBounds(new ashui.layout.Node(Css.query(tree, bench.node.id, ".rayde-md-h1")[0]));
				if (heading.y < tree.getScrolledBounds(firstScroll.node).y) throw "Markdown heading was laid out above the viewport";
				var part = Lambda.find(studio.preview.outline(), p -> p.props.indexOf("id=markdown-document") >= 0);
				var control:rayde.ext.BridgeControl = @:privateAccess studio.preview.parts.get(part.id).control;
				function mountWhere(predicate:Dynamic->Bool):Void {
					var view = @:privateAccess control.markdown;
					var data:Dynamic = @:privateAccess view.document.get();
					function matches(part:Dynamic):Bool {
						if (predicate(part)) return true;
						var children:Array<Dynamic> = part.children == null ? [] : part.children;
						return Lambda.exists(children, matches);
					}
					var items:Array<Dynamic> = data.children;
					for (i in 0...items.length) if (matches(items[i])) {
						@:privateAccess view.blocks.reveal(i, () -> true); settle(); return;
					}
					throw "missing Markdown fixture block";
				}
				function kind(name:String):Void mountWhere(p -> p.kind == name);
				for (name in ["math", "diagram", "code", "table", "list", "footnote"]) {
					kind(name);
					var selector = name == "math" || name == "diagram" ? '[data-md-render="$name"]' : '.rayde-md-$name';
					if (Css.query(tree, bench.node.id, selector).length == 0) throw 'missing Markdown renderer $selector';
				}
				scroll("#markdown-scroll", 0);

				function watches():Int return [for (watch in (@:privateAccess ashui.reactive.Watch.bySlot)) if (watch != null) 1].length;
				function texts():Int return [for (_ in (@:privateAccess ashui.ui.Text.byNode)) 1].length;
				var watchCount = watches();
				var textCount = texts();
				var previousDocument = @:privateAccess control.markdownDocument.get();
				var source = bench.buffer(readme).get();
				bench.buffer(readme).set(StringTools.replace(source, "Markdown, rendered", "Markdown, refreshed")); bench.edited(readme);
				until(() -> (@:privateAccess control.markdownDocument.get()) != previousDocument, "an edit to replace the document"); settle();
				if (watches() != watchCount) throw 'Markdown refresh retained text layout watches: $watchCount -> ${watches()}';
				if (texts() != textCount) throw 'Markdown refresh retained text layout entries: $textCount -> ${texts()}';
				function follow(href:String):Void {
					mountWhere(p -> p.href == href);
					var links = Css.query(tree, bench.node.id, '[data-md-link="$href"]');
					if (links.length == 0) throw 'missing Markdown link $href';
					var target:ashui.layout.Node = null;
					function find(id:haxe.Int64):Void {
						var text = ashui.ui.Text.at(id), bounds = tree.getScrolledBounds(new ashui.layout.Node(id));
						if (text != null && bounds != null && bounds.width > 0 && bounds.height > 0) target = new ashui.layout.Node(id);
						for (child in tree.children(id)) find(child);
					}
					find(links[0]);
					if (target == null) throw 'Markdown link has no visible text: $href';
					var bounds = tree.getScrolledBounds(target), frame = tree.getScrolledBounds(firstScroll.node);
					firstScroll.scrollTo(0, firstScroll.y.get() + bounds.y - frame.y - 100); settle();
					bounds = tree.getScrolledBounds(target);
					ashui.input.Pointer.move(tree, bounds.x+bounds.width/2, bounds.y+bounds.height/2);
					ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree); settle();
				}
				follow("#mathematics");
				if (firstScroll.y.get() == 0) throw "Markdown heading link did not scroll to its anchor";
				kind("table");
				var cells = Css.query(tree, bench.node.id, ".rayde-md-table-head .rayde-md-table-cell");
				if (tree.textAlign(cells[1]) != 2) throw "Markdown table column alignment was lost";
				kind("list");
				var tasks = Css.query(tree, bench.node.id, ".rayde-md-task .ui-checkbox");
				if (tasks.length != 2) throw "Markdown task lists must use Ashui checkboxes";
				for (task in tasks) {
					var size = tree.getBounds(new ashui.layout.Node(task));
					if (size.width != 14 || size.height != 14) throw "checked and unchecked task boxes must both be 14 by 14";
				}
				scroll("#markdown-scroll", 0); shot("math");
				scroll("#markdown-scroll", 390); shot("mermaid");
				var diagram = @:privateAccess control.markdown.diagrams[0];
				var viewport = diagram.viewport, bounds = tree.getScrolledBounds(diagram.node);
				var zoom = viewport.zoom.get(), documentY = firstScroll.y.get();
				ashui.input.Pointer.move(tree, bounds.x+bounds.width/2, bounds.y+bounds.height/2);
				ashui.input.Pointer.wheel(tree, 0, -120); settle();
				if (viewport.zoom.get() == zoom) throw "Mermaid wheel input did not zoom";
				if (firstScroll.y.get() != documentY) throw "Mermaid zoom also scrolled the document";
				var pan = viewport.panX.get(), panY = viewport.panY.get();
				ashui.input.Pointer.press(tree);
				ashui.input.Pointer.move(tree, bounds.x+bounds.width/2+60, bounds.y+bounds.height/2+30); settle();
				ashui.input.Pointer.release(tree); settle();
				if (viewport.panX.get() == pan) throw "Mermaid drag input did not pan";
				if (Math.abs((viewport.panY.get()-panY)*viewport.zoom.get() - 30) > 1) throw "Mermaid pan jumped by the document scroll offset";
				shot("mermaid-zoomed");
				click(".rayde-md-diagram-fit");
				if (Math.abs(viewport.zoom.get() - zoom) > .001) throw "Mermaid fit did not restore the fitted viewport";
				kind("code");
				var code = tree.getScrolledBounds(new ashui.layout.Node(Css.query(tree, bench.node.id, ".rayde-md-code")[0]));
				firstScroll.scrollTo(0, firstScroll.y.get() + code.y - tree.getScrolledBounds(firstScroll.node).y - 80); settle(); shot("highlighted-code");
				scroll("#markdown-scroll", 1600); shot("gfm-images");
				var tab = bench.active.get();
				var originalSvgCount = [for (_ in (@:privateAccess rayde.ui.SvgDocuments.owned)) 1].length;
				bench.buffer(readme).set(source + "\nAn update.\n"); bench.edited(readme);
				until(() -> Css.query(tree, bench.node.id, ".rayde-md-word").length > 0 && (@:privateAccess control.markdownDocument.get()) != null
					&& haxe.Json.stringify(@:privateAccess control.markdownDocument.get()).indexOf("An update.") >= 0, "a document replacement"); settle();
				if ([for (_ in (@:privateAccess rayde.ui.SvgDocuments.owned)) 1].length != originalSvgCount) throw "document refresh retained old vector images";
				follow("other.md");
				until(() -> studio.tabViews.length == 2 && Css.query(tree, bench.node.id, '[data-md-heading="another-document"]').length > 0, "relative Markdown link to open a second preview");
				bench.closeFile(bench.active.get()); settle();
				if (bench.active.get() != tab) throw "closing the linked preview did not return to its source preview";
				bench.openFile(readme); settle();
				manager.command("markdown", "markdown.preview", {path:readme});
				until(() -> bench.active.get() == tab, "reuse and focus an existing preview tab");
				if (studio.tabViews.length != 1) throw "duplicate Markdown preview";
				var buffer = bench.buffer(readme);
				buffer.set("# Unsaved live preview\n\n$\\frac{1}{2}$\n\n```mermaid\nsequenceDiagram\n A->>B: Hello\n```\n");
				bench.edited(readme);
				until(() -> Css.query(tree, bench.node.id, '[data-md-heading="unsaved-live-preview"]').length > 0, "unsaved Markdown edits in the preview");
				scroll("#markdown-scroll", 0); shot("live-sequence");
				buffer.set("# Recoverable errors\n\n$\\invalidMathCommand{x}$\n\n```mermaid\nnot-a-diagram\n```\n\nStill readable\n");
				bench.edited(readme);
				until(() -> Css.query(tree, bench.node.id, ".rayde-md-error").length == 2, "malformed blocks to show errors without losing the document");
				shot("invalid-blocks");
				bench.closeAll();
				until(() -> studio.tabViews.length == 0, "bulk close to unmount Markdown"); settle();
				if ((@:privateAccess rayde.ui.SvgDocuments.owned).iterator().hasNext()) throw "Markdown retained generated SVGs after close";
				manager.command("markdown", "markdown.preview", {path:readme});
				until(ready, "Markdown preview after bulk close"); shot("reopened");
				bench.openFile(root + "/example.rs"); settle();
				var editor = bench.editorFor(root + "/example.rs");
				if (!Lambda.exists(editor.document.lines[0].tokens, t -> t.kind == ashui.components.code.CodeHighlighter.CodeTokenKind.Keyword))
					throw "ordinary Rust files did not receive TextMate highlighting";
				shot("editor-textmate");
				var syntax = @:privateAccess bench.nativeSyntax.get(root + "/example.rs");
				bench.closeFile(root + "/example.rs"); settle();
				if ((@:privateAccess syntax.handle) != -1) throw "closing a saved document retained its native lexical session";
				bench.closeAll(); until(() -> studio.tabViews.length == 0, "old previews to close");
				var disposed:Array<Int> = [];
				var onDispose = (bitmap:ashui.types.Bitmap) -> { disposed.push(bitmap.id); };
				ashui.types.Bitmap.disposing.push(onDispose);
				function activeMarkdown():rayde.ext.MarkdownView {
					for (part in (@:privateAccess studio.preview.parts)) if (part.control != null) {
						var c = part.control;
						if ((@:privateAccess c.markdown) != null && (@:privateAccess c.markdownVisible.get())) return @:privateAccess c.markdown;
					}
					return null;
				}
				function hasBitmap():Bool {
					var view = activeMarkdown(); return view != null && (@:privateAccess view.bitmaps.length) == 1;
				}
				manager.command("markdown", "markdown.preview", {path:root + "/html.md"});
				until(hasBitmap, "HTML preview with raster image"); settle();
				var htmlTab = bench.active.get(), htmlView = activeMarkdown();
				var bitmap = @:privateAccess htmlView.bitmaps[0];
				var model = haxe.Json.stringify(@:privateAccess htmlView.document.get());
				if (model.indexOf("imageBytes") >= 0 || model.indexOf("svgBytes") >= 0 || model.length > 16000) throw "preview cached image payloads instead of file references";
				if (bitmap.width > 800 || bitmap.height > 800) throw "preview retained raster pixels larger than twice its display size";
				var htmlHeading = Css.query(tree, bench.node.id, '[data-md-html="h2"]')[0];
				if (tree.textAlign(htmlHeading) != 1) throw "HTML align=center was not applied";
				var logo = tree.getScrolledBounds(new ashui.layout.Node(Css.query(tree, bench.node.id, '[data-md-html="img"]')[0]));
				var parent = tree.getScrolledBounds(new ashui.layout.Node(tree.ancestors(Css.query(tree, bench.node.id, '[data-md-html="img"]')[0])[0]));
				shot("html");
				if (Math.abs(logo.width-250) > 1 || Math.abs(logo.x+logo.width/2-parent.x-parent.width/2) > 1) throw "HTML image width/centering is incorrect: " + haxe.Json.stringify({image:logo, parent:parent});
				scroll("#markdown-scroll", 450); shot("html-details");
				click(".rayde-markdown summary"); settle(); shot("html-details-open");
				var htmlY:Float = htmlView.state().y, decodedBytes = bitmap.width * bitmap.height * 4;
				manager.command("markdown", "markdown.preview", {path:root + "/html-second.md"});
				until(() -> bench.active.get() != htmlTab && hasBitmap(), "second HTML image preview"); settle();
				var secondTab = bench.active.get();
				if (disposed.indexOf(bitmap.id) < 0 || (@:privateAccess htmlView.bitmaps.length) != 0) throw "inactive preview retained decoded raster images";
				for (_ in 0...3) {
					bench.active.set(htmlTab); settle(); until(hasBitmap, "first cached preview to resume");
					if (Math.abs(activeMarkdown().state().y - htmlY) > 1) throw 'preview scroll position was lost while releasing images: $htmlY -> ${activeMarkdown().state().y}';
					bitmap = @:privateAccess activeMarkdown().bitmaps[0];
					bench.active.set(secondTab); settle(); until(hasBitmap, "second cached preview to resume");
					if (disposed.indexOf(bitmap.id) < 0) throw "switching image previews did not release the previous pixels";
				}
				var activeView = activeMarkdown(); bitmap = @:privateAccess activeView.bitmaps[0];
				bench.openFile(file); settle();
				if (disposed.indexOf(bitmap.id) < 0 || (@:privateAccess activeView.bitmaps.length) != 0 || (@:privateAccess rayde.ui.SvgDocuments.owned).iterator().hasNext()) throw "inactive image previews retained render resources";
				if (studio.tabViews.length != 2) throw "hiding previews closed their document tabs";
				Sys.println('[markdown-images] active decoded bytes=$decodedBytes; inactive decoded images=0; disposed images=${disposed.length}; cached document chars=${model.length}');
				shot("inactive-images-released");
				bench.active.set(htmlTab); until(hasBitmap, "HTML preview after code tab"); shot("html-reopened");
				bench.closeAll(); until(() -> studio.tabViews.length == 0, "image previews to close"); settle();
				ashui.types.Bitmap.disposing.remove(onDispose);
				var residencyFile = root + "/viewport-images.md";
				sys.io.File.saveContent(residencyFile, '<img src="welcome.png" width="400"/>\n\n' + [for (i in 0...60) 'Paragraph $i between the two images.\n\n'].join("") + '<img src="welcome.png" width="200"/>\n');
				manager.command("markdown", "markdown.preview", {path:residencyFile});
				until(hasBitmap, "scrollable image document"); settle();
				var image = @:privateAccess activeMarkdown().bitmaps[0];
				shot("viewport-images-top");
				if (!image.decoded() || (@:privateAccess activeMarkdown().bitmaps.length) != 1) throw "offscreen Markdown image was mounted";
				for (_ in 0...3) {
					scroll("#markdown-scroll", 100000); until(hasBitmap, "bottom image to mount"); shot("viewport-images-bottom");
					if (image.decoded()) throw "departed Markdown image retained decoded pixels";
					image = @:privateAccess activeMarkdown().bitmaps[0];
					if (!image.decoded() || image.width > 400 || Css.query(tree, bench.node.id, "[data-md-block]").length > 25) throw "bottom image or bounded block range was lost";
					scroll("#markdown-scroll", 0); until(hasBitmap, "top image to remount"); shot("viewport-images-returned");
					if (image.decoded()) throw "bottom image stayed resident after return";
					image = @:privateAccess activeMarkdown().bitmaps[0];
					if (!image.decoded() || image.width <= 400) throw "top image did not remount";
				}
				bench.closeAll(); until(() -> studio.tabViews.length == 0, "viewport image preview to close"); settle();
				if (image.decoded()) throw "closed viewport image document retained pixels";
				var longFile = root + "/virtual-blocks.md";
				sys.io.File.saveContent(longFile, "# Virtual document\n\n[Jump to end](#destination)\n\n" + [for (i in 0...160) 'Paragraph $i. A block that should leave no native views outside the viewport.\n\n'].join("") + "## Destination\n\nFinal paragraph.\n");
				manager.command("markdown", "markdown.preview", {path:longFile});
				until(() -> Css.query(tree, bench.node.id, '[data-md-heading="virtual-document"]').length > 0, "virtual document"); settle();
				if (Css.query(tree, bench.node.id, "[data-md-block]").length > 25 || Css.query(tree, bench.node.id, '[data-md-heading="destination"]').length > 0) throw "document mounted distant blocks eagerly";
				shot("virtual-blocks-top");
				activeMarkdown().reveal("destination"); settle();
				until(() -> Css.query(tree, bench.node.id, '[data-md-heading="destination"]').length > 0, "offscreen heading anchor");
				var position:Float = activeMarkdown().state().y, virtualTab = bench.active.get();
				if (position < 1000 || Css.query(tree, bench.node.id, "[data-md-block]").length > 25 || Css.query(tree, bench.node.id, '[data-md-heading="virtual-document"]').length > 0) throw "anchor failed to move the virtual range";
				shot("virtual-blocks-end");
				bench.openFile(file); settle(); bench.active.set(virtualTab); settle();
				if (Math.abs(activeMarkdown().state().y-position) > 1 || Css.query(tree, bench.node.id, "[data-md-block]").length > 25) throw "cached virtual position was not restored";
				shot("virtual-blocks-restored");
				bench.closeAll(); until(() -> studio.tabViews.length == 0, "virtual document close");

			});
		for (dark in [true, false])
			scenario(dark, "documents", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				var folder = haxe.io.Path.directory(file), a = folder + "/DocumentA.hx", b = folder + "/DocumentB.hx";
				var source = 'class DocumentA {\n\tfunction test() {\n\t\treturn 1;\n\t}\n}\n' + [for (i in 0...100) '// line $i\n'].join("");
				sys.io.File.saveContent(a, source);
				sys.io.File.saveContent(b, "class DocumentB {}\n");
				bench.openFile(a); settle();
				var editor = bench.editorFor(a), document = editor.document;
				editor.applyEdits([{from: source.length, to: source.length, text: "// edit\n"}]);
				editor.select(1, 7); editor.toggleFold(1); settle();
				editor.scroll.jumpTo(0, 360); settle();
				var y = editor.scroll.y.get();
				bench.openFile(b); settle();
				var state = @:privateAccess bench.documents.get(a);
				if (bench.editorFor(a) != null || state.mounted || state.document != document || state.caret != 7 || state.anchor != 1 || state.scrollY != y)
					throw "inactive tabs must retain document/navigation data without an editor view";
				if (Css.query(bench.tree, bench.node.id, '.ui-code[data-mode="editor"]').length != 1)
					throw "only the active code editor may be mounted";
				var shortEditor = bench.editorFor(b);
				if (Css.query(bench.tree, shortEditor.node.id, ".ui-code-line").length != shortEditor.document.visible.length)
					throw "short files must not allocate empty viewport row slots";
				shot("inactive-data-only");
				bench.active.set(a); settle();
				editor = bench.editorFor(a);
				if (editor.document != document || editor.editing.anchor.get() != 1 || editor.editing.caret.get() != 7 || editor.scroll.y.get() != y || !document.lines[1].folded)
					throw "switching back must restore the document, selection, scroll and folds";
				shot("restored");
				editor.undo(); settle();
				if (bench.buffer(a).get() != source) throw "undo must survive editor disposal";
				editor.redo(); settle();
				if (bench.buffer(a).get() != source + "// edit\n") throw "redo must survive editor disposal";
				bench.closeAll(); settle();
				var buffers = @:privateAccess bench.buffers, documents = @:privateAccess bench.documents, refs = @:privateAccess bench.editorRefs;
				if (!buffers.exists(a) || !documents.exists(a)) throw "closing must preserve unsaved document data";
				if (buffers.exists(b) || documents.exists(b) || refs.exists(b)) throw "closing a saved file must release its caches";
				if (state.mounted || bench.editorFor(a) != null) throw "closing all tabs must release every editor";
				bench.openFile(a); settle();
				bench.editorFor(a).undo(); settle();
				if (bench.buffer(a).get() != source) throw "reopening unsaved text must retain undo";
				bench.editorFor(a).redo(); settle();
				bench.closeFile(a); settle();
				bench.saveAll(); settle();
				if (sys.io.File.getContent(a) != source + "// edit\n" || buffers.exists(a) || documents.exists(a))
					throw "saving closed unsaved text must write it and release the cache";
				shot("closed-released");
				bench.problems.set([{file: null, range: null, severity: 1, message: "Invalid commandline class"}]);
				bench.showPanel("problems"); settle();
				click(".rayde-problem");
				if (bench.active.get() != "") throw "a workspace diagnostic must not navigate to a nonexistent file";
				shot("workspace-diagnostic");
			});
		for (dark in [true, false])
			scenario(dark, "assist", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				settle();
				bench.openFile(file);
				settle(20);
				var tree = bench.tree, text = () -> bench.buffer(file).get();
				var count = (selector:String) -> ashui.css.Css.query(tree, bench.node.id, selector).length;
				var typed = (s:String) -> {
					ashui.input.Keyboard.text(tree, s);
					settle(6);
				};
				// A dot after a name opens the list of its members; typing narrows it, and Enter puts the choice in the text.
				bench.goTo(file, 7, 10);
				settle(4);
				typed(".");
				var editor = bench.editorFor(file);
				until(() -> editor.completionsOpen(), "the member list to open after the dot");
				if (count(".ui-code-completion-row") < 5)
					throw "a String has more members than " + count(".ui-code-completion-row");
				shot("completion");
				typed("charA");
				if (!editor.completionsOpen() || count(".ui-code-completion-row") > 3)
					throw "typing narrows the list: " + count(".ui-code-completion-row") + " rows";
				shot("completion-narrowed");
				press(Named(Enter));
				if (text().indexOf("\t\tgreeting.charAt\n") < 0 || editor.completionsOpen())
					throw "Enter puts the chosen member in the text and closes the list: " + text();
				// A call's parenthesis opens the signature, with the argument the caret is in emphasised.
				bench.goTo(file, 8, 7);
				settle(4);
				typed("(");
				var emphasised = () -> [for (id in ashui.css.Css.query(tree, bench.node.id, ".ui-code-hint [data-emphasis]")) ashui.ui.Text.at(id).text()].join("");
				until(() -> count(".ui-code-hint") > 0, "the signature to show after the parenthesis");
				if (emphasised() != "name:String")
					throw "the first parameter is emphasised: " + emphasised();
				shot("signature");
				typed("greeting, ");
				if (emphasised() != "times:Int")
					throw "after the comma the second parameter is emphasised: " + emphasised();
				shot("signature-second");
				typed(")");
				if (count(".ui-code-hint") > 0)
					throw "the signature goes when the call is closed";
				// The command opens the list wherever the caret is.
				bench.goTo(file, 9, 0);
				settle(4);
				bench.runCommand("suggest");
				until(() -> editor.completionsOpen(), "the suggest command to open the list");
				shot("suggest");
			});
		Sys.println("rayde snapshots: the workbench empty, with problems, after a run, in the command center, with each kind of tab in front, with tabs that overflow, welcome with recent files and after a failed build, in both themes");
	}

	/** Throws unless the first element each selector finds is as tall as the first selector's: controls on one row share a height. */
	static function sameHeight(bench:Workbench, selectors:Array<String>):Void {
		var heights = [
			for (selector in selectors) {
				var found = ashui.css.Css.query(bench.tree, bench.node.id, selector);
				if (found.length == 0)
					throw 'nothing matches $selector';
				bench.tree.getBounds(new ashui.layout.Node(found[0])).height;
			}
		];
		for (i in 1...heights.length)
			if (Math.abs(heights[i] - heights[0]) > .5)
				throw 'controls on a row should be as tall as each other: ' + [for (i in 0...selectors.length) selectors[i] + " " + heights[i]].join(", ");
	}

	/** Ticks the workbench until its run ends, or a minute and a half passes. */
	static function wait(bench:Workbench):Void {
		var end = haxe.Timer.stamp() + 90;
		while (bench.runner.active() && haxe.Timer.stamp() < end) {
			bench.tick();
			Sys.sleep(.02);
		}
		bench.tick();
	}

	/** A copy of the fixture project `name` under bin/fixtures, which a run may change. */
	static function copyOf(name:String):String {
		var from = Sys.getCwd() + "tests/fixtures/" + name, to = Sys.getCwd() + "bin/fixtures/" + name;
		function copy(a:String, b:String):Void {
			sys.FileSystem.createDirectory(b);
			for (entry in sys.FileSystem.readDirectory(a)) {
				var source = haxe.io.Path.join([a, entry]), target = haxe.io.Path.join([b, entry]);
				if (sys.FileSystem.isDirectory(source))
					copy(source, target)
				else
					sys.io.File.copy(source, target);
			}
		}
		if (sys.FileSystem.exists(to))
			for (entry in sys.FileSystem.readDirectory(to))
				if (entry != ".rayde")
					deleteTree(haxe.io.Path.join([to, entry]));
		copy(from, to);
		// What a run opened last, and what it set, is not carried into the next: the project starts as a new one would.
		for (leftover in ["recent.txt", "settings.json", "keybindings.json", "extensions", "history"])
			if (sys.FileSystem.exists(to + "/.rayde/" + leftover))
				deleteTree(to + "/.rayde/" + leftover);
		return to;
	}

	static function installExtensionsFixture(root:String):Void {
		function copy(from:String, to:String):Void {
			sys.FileSystem.createDirectory(to);
			for (name in sys.FileSystem.readDirectory(from)) {
				var source = from + "/" + name, target = to + "/" + name;
				if (sys.FileSystem.isDirectory(source)) copy(source, target); else sys.io.File.copy(source, target);
			}
		}
		var dir = root + "/.rayde/extensions";
		copy(Sys.getCwd() + "tests/fixtures/markdown", dir + "/markdown");
		copy(Sys.getCwd() + "tests/fixtures/views", dir + "/dashboard");
		var config = dir + "/markdown/markdown.rayext", json:Dynamic = haxe.Json.parse(sys.io.File.getContent(config));
		json.id = "markdown";
		json.views = [{id: "preview", title: "Markdown", icon: "eye", location: "sidebar"}];
		sys.io.File.saveContent(config, haxe.Json.stringify(json));
		var script = dir + "/markdown/ext/main.rays";
		sys.io.File.saveContent(script, sys.io.File.getContent(script) + "\nmount(() -> <p class='p-4 text-sm'>Markdown Preview is running</p>, 'preview');\n");
		config = dir + "/dashboard/dashboard.rayext";
		json = haxe.Json.parse(sys.io.File.getContent(config));
		json.id = "dashboard";
		json.contributes = {commands: [{id: "describe", title: "Describe dashboard"}, {id: "fail", title: "Fail dashboard"}], keybindings: [{command: "describe", key: "mod+alt+d"}],
			configuration: {properties: {"dashboard.compact": {type: "boolean", title: "Compact view", description: "Reduce spacing between rows.", "default": false}}}};
		sys.io.File.saveContent(config, haxe.Json.stringify(json));
		script = dir + "/dashboard/ext/main.rays";
		sys.io.File.saveContent(script, sys.io.File.getContent(script) + "\nregisterCommand('describe', args -> trace('dashboard ready'));\nregisterCommand('fail', args -> { throw 'dashboard failure'; });\n");
		var native = dir + "/native-example";
		sys.FileSystem.createDirectory(native + "/natives");
		var library = sys.io.File.getBytes(Sys.getCwd() + "bin/cterm.hdll");
		sys.io.File.saveBytes(native + "/natives/libexample.dylib", library);
		sys.io.File.saveContent(native + "/main.rays", "trace('native example ready');");
		sys.io.File.saveContent(native + "/native-example.rayext", haxe.Json.stringify({id: "native-example", name: "Native Example", version: "0.1.0",
			description: "An extension that declares a native library.", capabilities: ["native:example"],
			natives: {example: {path: "natives/libexample.dylib", sha256: haxe.crypto.Sha256.make(library).toHex()}}}));
		sys.io.File.saveContent(root + "/README.md", "# Workspace extensions\n\nA Haxe project with a Markdown preview and dashboard running in separate hosts.\n");
	}

	static function deleteTree(path:String):Void {
		if (sys.FileSystem.isDirectory(path)) {
			for (entry in sys.FileSystem.readDirectory(path))
				deleteTree(haxe.io.Path.join([path, entry]));
			sys.FileSystem.deleteDirectory(path);
		} else
			sys.FileSystem.deleteFile(path);
	}

	static function scenario(dark:Bool, name:String, steps:(Workbench, String, String->Void, ?Int->Void, String->Float->Void, String->Void, String->String->Void, String->Void, (window.Key, ?Bool, ?Bool, ?Bool, ?Bool)->Void, (Void->Bool)->String->Void) -> Void):Void {
		// SNAPSHOT_ONLY=extension runs just that scenario.
		var only = Sys.getEnv("SNAPSHOT_ONLY");
		if (only != null && only != "" && only != name)
			return;
		if (!dark && name == "git" && Sys.getEnv("RAYDE_EXTENSION_PROBE") == "1") return;
		var root = copyOf(name == "documents" || name == "lsp" ? "basic" : name == "explorer" ? "git" : name == "outline" ? "full" : name), server = new CompilerServer();
		var previousBuiltins = Sys.getEnv("RAYDE_EXTENSIONS");
		if ((name == "git" || name == "explorer") && Sys.command("python3", ["tests/git_fixture.py", root, "--install"]) != 0)
			throw "Git snapshot fixture failed";
		if (name == "extensions") installExtensionsFixture(root);
		if (name == "lsp") {
			var folder = root + "/.snapshot-builtins/rayzor";
			sys.FileSystem.createDirectory(folder + "/ext");
			sys.io.File.copy("extensions/rayzor/rayzor.rayext", folder + "/rayzor.rayext");
			sys.io.File.copy("extensions/rayzor/ext/main.rays", folder + "/ext/main.rays");
			sys.io.File.copy("extensions/rayzor/logo.svg", folder + "/logo.svg");
			var fixture = Sys.getCwd() + "tests/lsp_server_fixture.py", command = root + "/lsp-fixture-server";
			sys.io.File.saveContent(command, "#!/usr/bin/env python3\nimport runpy, sys\nsys.argv = [" + haxe.Json.stringify(fixture) + ", " + haxe.Json.stringify(root + "/lsp-events") + "]\nrunpy.run_path(sys.argv[0], run_name='__main__')\n");
			Sys.command("chmod", ["+x", command]);
			Store.save(root, "extension.rayzor", {command:command});
			Sys.putEnv("RAYDE_EXTENSIONS", haxe.io.Path.directory(folder));
		}
		if (name == "markdownpreview" || name == "git" && Sys.getEnv("RAYDE_EXTENSION_PROBE") == "1") {
			function copy(from:String, to:String):Void {
				sys.FileSystem.createDirectory(to);
				for (name in sys.FileSystem.readDirectory(from)) {
					if (sys.FileSystem.isDirectory(from + "/" + name)) copy(from + "/" + name, to + "/" + name);
					else sys.io.File.copy(from + "/" + name, to + "/" + name);
				}
			}
			copy("extensions/markdown", root + "/.rayde/extensions/markdown");
			sys.io.File.saveContent(root + "/example.rs", "fn main() {\n    /* comment\n       continued */\n    let answer = 42;\n    println!(\"λ: {answer}\");\n}\n");
		}
		ThemeState.init(RestrainedTheme.bundle(), dark ? Dark : Light);
		rayde.ui.Style.use();
		// A fixture with a .rayext is an extension project, opened from that file with no build.
		var config = Lambda.find(sys.FileSystem.readDirectory(root), f -> StringTools.endsWith(f, ".rayext"));
		var extension = config == null ? null : Manifest.read(root + "/" + config);
		// A fixture with a .raytheme is a theme project, in the scheme this run is for.
		var themeName = Lambda.find(sys.FileSystem.readDirectory(root), f -> StringTools.endsWith(f, ".raytheme"));
		var theme = themeName == null ? null : rayde.theme.ThemeFile.read(root + "/" + themeName);
		if (theme != null) {
			var chosen = new rayde.settings.Appearance();
			chosen.scheme = dark ? "dark" : "light";
			chosen.save(root);
		}
		var display = extension != null || theme != null ? new Display(server, root, []) : Display.ofHxml(server, root + "/build.hxml"), tree = new LayoutTree(), bench:Workbench = null, stop:Void->Void = null;
		var view = Owner.root(tree, s -> {
			stop = s;
			return bench = new Workbench({display: display, name: extension != null ? extension.name : theme != null ? theme.name : name, runtime: extension != null ? "rayscript" : "ash", extension: extension, theme: theme});
		});
		if (name == "extensions" || name == "git" || name == "explorer") {
			var home = root + "/snapshot-home";
			sys.FileSystem.createDirectory(home);
			Store.save(home, "extensions", {});
			@:privateAccess bench.extensionManager.options.trustHome = home;
		}
		function settle(?frames:Int):Void
			for (_ in 0...(frames == null ? 20 : frames)) {
				Offscreen.advance(1 / 60);
				Css.setViewport(WIDTH, HEIGHT);
				Css.update();
				tree.flush();
				tree.computeLayout(view.node, WIDTH, HEIGHT);
			}
		function shot(what:String):Void {
			settle();
			if (Sys.getEnv("RAYDE_DEBUG") != null)
				for (sel in [".rayde-tab", ".rayde-tab-body", "#rayde-file-tabs"])
					for (id in ashui.css.Css.query(tree, view.node.id, sel)) {
						var b = tree.getBounds(new ashui.layout.Node(id));
						Sys.println('$what $sel ' + (b == null ? "null" : b.x + "," + b.y + " " + b.width + "x" + b.height));
					}
			Snapshot.capture('rayde-${dark ? "dark" : "light"}-$name-$what', tree, view.node, WIDTH, HEIGHT, ThemeState.get().color(Background).rgb());
			if (Sys.getEnv("ASHUI_FRAME_STATS") == "1")
				Sys.println('[snapshot-frame] ${dark ? "dark" : "light"}/$name/$what: ${Snapshot.renderer().layerRecords} layers; ${ashui.input.Pointer.hooks.length} pointer hooks');
		}
		settle();
		// Scrolls the scroll view that `selector` finds, as far as `y`.
		function scroll(selector:String, y:Float):Void {
			var found = ashui.css.Css.query(tree, view.node.id, selector);
			var scroller = found.length == 0 ? null : ashui.input.Scroll.at(found[0], tree);
			if (scroller != null)
				scroller.scrollTo(0, y);
			settle();
		}
		// A press and release on the first element `selector` finds, as the pointer makes them, once the form it is in has been scrolled to show it.
		function click(selector:String):Void {
			var found = ashui.css.Css.query(tree, view.node.id, selector), area = ashui.css.Css.query(tree, view.node.id, "#rayde-build, #rayde-extension-config, #rayde-theme-studio");
			if (found.length == 0)
				throw 'nothing matches $selector';
			var scroller = area.length == 0 ? null : ashui.input.Scroll.at(area[0], tree);
			var box = tree.getScrolledBounds(new ashui.layout.Node(found[0]));
			var frame = area.length == 0 ? null : tree.getScrolledBounds(new ashui.layout.Node(area[0]));
			if (scroller != null && box != null && frame != null) {
				scroller.scrollTo(0, scroller.y.get() + box.y + box.height / 2 - (frame.y + frame.height / 2));
				settle(2);
			}
			// Where it shows now, in the scrolled form: the pointer goes there, as a hand would.
			var at = tree.getScrolledBounds(new ashui.layout.Node(found[0]));
			ashui.input.Pointer.move(tree, at.x + at.width / 2, at.y + at.height / 2);
			ashui.input.Pointer.press(tree);
			ashui.input.Pointer.release(tree);
			settle(3);
		}
		// Puts `text` in the input `selector` finds.
		function type(selector:String, text:String):Void {
			var found = ashui.css.Css.query(tree, view.node.id, selector);
			if (found.length == 0)
				throw 'no input matches $selector';
			ashui.ui.Input.at(tree, found[0]).value.set(text);
			settle(2);
		}
		// Puts the pointer over the middle of the first element `selector` finds.
		function hover(selector:String):Void {
			var found = ashui.css.Css.query(tree, view.node.id, selector);
			if (found.length == 0)
				throw 'nothing matches $selector';
			var at = tree.getScrolledBounds(new ashui.layout.Node(found[0]));
			ashui.input.Pointer.move(tree, at.x + at.width / 2, at.y + at.height / 2);
			settle(6);
			if (Sys.getEnv("RAYDE_DEBUG") != null)
				Sys.println('hover $selector at ' + (at.x + at.width / 2) + "," + (at.y + at.height / 2) + " hovered=" + (ashui.input.Interaction.byId(tree, found[0]) == null ? "n/a" : "" + ashui.input.Interaction.byId(tree, found[0]).hovered.get()));
		}
		// A key pressed and let go as the keyboard reports it, to what has the keyboard, with the modifiers held.
		function press(key:window.Key, ?shift:Bool, ?control:Bool, ?alt:Bool, ?meta:Bool):Void {
			var mods = window.Modifiers.State(shift == true, control == true, alt == true, meta == true, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown);
			for (state in [window.MouseElementState.Pressed, window.MouseElementState.Released])
				ashui.input.Keyboard.input(tree, window.KeyEvent.Input(Unidentified(Unidentified), key, None, Standard, state, false, Unavailable), mods);
			settle(4);
		}
		// Lets time pass, a process included, until `done` holds, or twenty seconds have gone by.
		function until(done:Void->Bool, what:String):Void {
			var end = haxe.Timer.stamp() + 20;
			while (!done() && haxe.Timer.stamp() < end) {
				settle(3);
				Sys.sleep(.02);
			}
			if (!done())
				throw 'timed out waiting for $what';
		}
		if (extension != null || theme != null)
			bench.openProject();
		steps(bench, extension != null ? extension.mainPath() : theme != null ? theme.file : root + "/src/Main.hx", shot, settle, scroll, click, type, hover, press, until);
		stop();
		tree.dispose();
		server.stop();
		if (name == "lsp") Sys.putEnv("RAYDE_EXTENSIONS", previousBuiltins);
	}
}
