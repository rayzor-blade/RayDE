import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.settings.WorkspaceSession;
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
class WorkspaceSessionLifecycle {
	public static function main():Void {
		var root = Sys.getCwd() + "bin/session-lifecycle", entry = root + "/build.hxml";
		for (dir in [root, root + "/src", root + "/empty-extensions"]) sys.FileSystem.createDirectory(dir);
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/empty-extensions");
		sys.io.File.saveContent(entry, "-cp src\n-main A\n");
		var files = [for (name in ["A", "B", "C"]) {
			var file = root + '/src/$name.hx'; sys.io.File.saveContent(file, 'class $name { static function main() {} }\n'); file;
		}];
		new WorkspaceSession(root, entry).close({files:[], active:""});
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), Dark); rayde.ui.Style.use();
		var tree:LayoutTree, stop:Void->Void = null, bench:Workbench, compiler = new CompilerServer();
		function start():Void {
			tree = new LayoutTree();
			bench = Owner.root(tree, cleanup -> { stop = cleanup; return new Workbench({display:Display.ofHxml(compiler, entry), name:"Session", runtime:"ash"}); });
			bench.openProject();
		}
		function settle():Void for (_ in 0...20) {
			ashui.core.render.Offscreen.advance(1/60); Css.update(); tree.flush(); tree.computeLayout(bench.node, 1280, 800);
		}
		start(); for (file in files) bench.openFile(file); bench.active.set(files[1]); settle();
		var recovered = bench.documentsPart.buffer(files[1]).get() + "// unsaved session edit\n";
		bench.documentsPart.buffer(files[1]).set(recovered); bench.documentsPart.edited(files[1]); settle();
		stop(); tree.dispose();
		sys.FileSystem.deleteFile(files[2]);
		start(); settle();
		bench.languagesPart.languageServers.onChanged(); settle();
		if (bench.open.get().join(",") != files.slice(0,2).join(",") || bench.active.get() != files[1]) throw "Tabs lost order or active selection, or restored a missing file";
		if (bench.documentsPart.buffer(files[1]).get() != recovered || bench.dirty.get().indexOf(files[1]) < 0) throw "Tab restore lost unsaved local-history recovery";
		if (bench.documentsPart.buffers.exists(files[0]) || Lambda.count(bench.documentsPart.documents) != 1) throw "Restore eagerly loaded inactive documents";
		bench.active.set(files[0]); settle();
		if (bench.editorFor(files[0]) == null) throw "Restored inactive tab did not open its code editor";
		ashui.core.render.Snapshot.capture("workspace-tabs-restored", tree, bench.node, 1280, 800);
		bench.closeAll(); settle(); stop(); tree.dispose();
		start(); settle();
		if (bench.open.get().length != 0 || bench.active.get() != "") throw "Explicitly closed tabs reappeared";
		stop(); compiler.stop(); tree.dispose();
		Sys.println("session UI: ordered tabs, active tab, missing files, lazy documents, unsaved recovery and explicit close-all survive restart");
	}
}
