import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.project.ProjectFile;
import rayde.ui.Workbench;

@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.CodeActionsPart)
@:access(rayde.ui.workbench.DebugPart)
@:access(rayde.ui.workbench.DocumentsPart)
@:access(rayde.ui.workbench.EditorMarksPart)
@:access(rayde.ui.workbench.EditorPart)
@:access(rayde.ui.workbench.ExplorerPart)
@:access(rayde.ui.workbench.ExtensionsPart)
@:access(rayde.ui.workbench.KeymapPart)
@:access(rayde.ui.workbench.LanguagesPart)
@:access(rayde.ui.workbench.MenusPart)
@:access(rayde.ui.workbench.PanelsPart)
@:access(rayde.ui.workbench.ProjectPart)
@:access(rayde.ui.workbench.RunPart)
@:access(rayde.ui.workbench.ShellPart)
@:access(rayde.ui.workbench.TerminalPart)
@:access(rayde.ui.workbench.ThemePart)
@:access(rayde.ui.CommandCenter)
class CodeActionWorkbenchChecks {
	static function check(ok:Bool,message:String):Void { if (!ok) throw message; }
	static function main():Void {
		CodeActionChecks.run(); CodeActionExtensionChecks.run();
		for (dark in [true,false]) run(dark);
		Sys.println("code-action UI: active-only providers, SVG hints, extension edits as one undo, stale execution, chooser, Run routing and tab cleanup in both themes");
	}
	static function run(dark:Bool):Void {
		var root = Sys.getCwd() + "bin/code-action-ui-" + Std.random(0x3fffffff), previous = Sys.getEnv("RAYDE_EXTENSIONS");
		sys.FileSystem.createDirectory(root + "/extensions/actions");
		for (name in ["actions.rayext","main.rays"]) sys.io.File.copy("tests/fixtures/codeactions/" + name,root + "/extensions/actions/" + name);
		Sys.putEnv("RAYDE_EXTENSIONS",root + "/extensions");
		var entry = ProjectFile.create(root,"sample","hxml"), dir = haxe.io.Path.directory(entry), file = dir + "/src/Main.hx", other = dir + "/src/Other.hx";
		var source = 'class Main {\n\tstatic function main() {\n\t\tvar n = 0;\n\t\ttrace("ACTION_RAN");\n\t}\n}\n';
		sys.io.File.saveContent(file,source); sys.io.File.saveContent(other,"class Other {}\n");
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),dark ? Dark : Light); rayde.ui.Style.use();
		var tree = new LayoutTree(), compiler = new CompilerServer(), stop:Void->Void = null;
		var bench = Owner.root(tree,cleanup -> { stop = cleanup; return new Workbench({display:Display.ofProject(compiler,entry),name:"sample"}); });
		function settle(frames=3):Void for (_ in 0...frames) { Offscreen.advance(.03); Css.setViewport(1100,760); Css.update(); tree.flush(); tree.computeLayout(bench.node,1100,760); }
		function until(done:Void->Bool):Void {
			var end = haxe.Timer.stamp() + 20;
			while (haxe.Timer.stamp() < end) { settle(); if (done()) return; Sys.sleep(.004); }
			check(done(),"Actions did not settle: " + bench.runPart.runner.console);
		}
		function nodes(selector:String) return Css.query(tree,bench.node.id,selector);
		function click(selector:String):Void {
			var found = nodes(selector); check(found.length == 1,"Missing or duplicate " + selector);
			var box = tree.getScrolledBounds(new ashui.layout.Node(found[0]));
			ashui.input.Pointer.move(tree,box.x + box.width/2,box.y + box.height/2); settle(1);
			ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree); settle();
		}
		try {
			bench.openProject(); settle(); check(bench.codeActionsPart.codeActions.list().length == 0,"Welcome retained document actions");
			bench.openFile(file); until(() -> bench.codeActionsPart.codeActions.list().length == 2 && !bench.codeActionsPart.codeActions.busy());
			check(nodes(".rayde-code-action").length == 2 && nodes(".ui-code-marker-icon").length == 2,"Providers did not share SVG gutter hints");
			var activeGutter = tree.getBounds(new ashui.layout.Node(nodes(".ui-code-gutter")[0])).width;
			var typingEditor = bench.editorFor(file);
			for (i in 0...4) {
				var oldItem = bench.codeActionsPart.codeActions.list()[0], oldVersion = bench.codeActionsPart.codeActionVersion;
				typingEditor.value.set(source + [for (_ in 0...i + 1) " "].join(""));
				settle(1);
				check(Math.abs(tree.getBounds(new ashui.layout.Node(nodes(".ui-code-gutter")[0])).width-activeGutter)<.1,"Typing collapsed the action column during refresh");
				check(!bench.codeActionsPart.codeActions.execute(oldItem.key,file,oldVersion,(_, _) -> true),"Refreshing actions retained an executable stale result");
				until(() -> bench.codeActionsPart.codeActions.list().length == 2 && !bench.codeActionsPart.codeActions.busy());
				check(Math.abs(tree.getBounds(new ashui.layout.Node(nodes(".ui-code-gutter")[0])).width-activeGutter)<.1,"Refreshed actions moved the code");
			}
			typingEditor.value.set(source); settle(1);
			until(() -> bench.codeActionsPart.codeActions.list().length == 2 && !bench.codeActionsPart.codeActions.busy());
			check(Lambda.exists(bench.commandList,c -> c.id == "codeactions") && bench.keymapPart.bindings.of("codeactions") != null,"Code actions command or shortcut is missing");
			Snapshot.capture('code-actions-${dark ? "dark" : "light"}',tree,bench.node,1100,760);
			var editor = bench.editorFor(file), item = Lambda.find(bench.codeActionsPart.codeActions.list(),i -> i.action.kind == "quickfix"), version = bench.codeActionsPart.codeActionVersion;
			click('.rayde-code-action[title="Set value to one"]');
			check(editor.value.get().indexOf("n = 1") >= 0 && StringTools.endsWith(editor.value.get(),"// fixed") && bench.dirty.get().indexOf(file) >= 0,"Hint did not apply its edits or mark the buffer dirty");
			check(!bench.codeActionsPart.executeCodeAction(item.key,version),"Consumed/stale action ran a second time");
			editor.undo(); settle(); check(editor.value.get() == source,"Action edits did not undo together");
			until(() -> bench.codeActionsPart.codeActions.list().length == 2 && !bench.codeActionsPart.codeActions.busy());
			bench.codeActionsPart.showCodeActions(); until(() -> bench.centerRequest.get().picker.items.length == 2 && !bench.codeActionsPart.codeActions.busy());
			check(bench.quickOpen.get() && bench.centerRequest.get().picker.items[0].label == "Run Project","Manual chooser lost provider actions");
			click("#rayde-command-input"); ashui.input.Keyboard.text(tree,"Set"); settle();
			var inputNode = nodes("#rayde-command-input"), query = inputNode.length == 0 ? "missing" : ashui.ui.Input.at(tree,inputNode[0]).value.get();
			check(nodes(".rayde-cc-item").length == 1,"Code-action chooser did not filter typed text: " + nodes(".rayde-cc-item").length + " rows, query=" + query + ", open=" + bench.quickOpen.get());
			bench.codeActionsPart.updateCodeActionPicker(); settle();
			check(nodes(".rayde-cc-item").length == 1 && nodes("#center-action-code-action-1").length == 1,"Asynchronous action updates reset the chooser query");
			bench.quickOpen.set(false); settle();
			bench.openFile(other); settle(); until(() -> !bench.codeActionsPart.codeActions.busy() && bench.codeActionsPart.codeActions.current(other,bench.codeActionsPart.codeActionVersion));
			check(bench.codeActionsPart.codeActions.list().length == 0 && nodes(".rayde-code-action").length == 0,"Inactive tab retained its actions or Run hint");
			var compactGutter = tree.getBounds(new ashui.layout.Node(nodes(".ui-code-gutter")[0])).width;
			check(nodes(".ui-code-marker-slot").length == 0 && nodes(".ui-code-fold-slot").length == 0 && Math.abs(activeGutter-compactGutter-40)<.1,"Unused gutter columns remained allocated in a tab without actions or folds");
			Snapshot.capture('code-actions-${dark ? "dark" : "light"}-compact',tree,bench.node,1100,760);
			bench.openFile(file); until(() -> bench.codeActionsPart.codeActions.list().length == 2 && !bench.codeActionsPart.codeActions.busy());
			check(Math.abs(tree.getBounds(new ashui.layout.Node(nodes(".ui-code-gutter")[0])).width-activeGutter)<.1,"Reopening an actionable tab did not restore its gutter columns");
			click('.rayde-code-action[title="Run Project"]'); until(() -> !bench.runPart.runner.active());
			check(bench.runPart.runner.console.indexOf("ACTION_RAN") >= 0 && bench.runPart.runner.exitCode == 0,"Run provider did not route through the project runner");
			bench.runPart.saveAll(); bench.closeFile(file); bench.closeFile(other); settle();
			check(bench.codeActionsPart.codeActions.list().length == 0 && !bench.codeActionsPart.codeActions.busy(),"Closed tabs retained action data");
		} catch(error:Dynamic) { stop(); tree.dispose(); compiler.stop(); Sys.putEnv("RAYDE_EXTENSIONS",previous ?? ""); throw error; }
		stop(); tree.dispose(); compiler.stop(); Sys.putEnv("RAYDE_EXTENSIONS",previous ?? "");
	}
}
