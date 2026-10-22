import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.project.ProjectFile;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

@:access(rayde.ui.Workbench)
class ProjectWorkbenchChecks {
	static function main():Void {
		var root = Sys.getCwd() + "bin/project-ui-checks-" + Std.random(0x3fffffff);
		sys.FileSystem.createDirectory(root + "/empty-extensions");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/empty-extensions");
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), Dark); rayde.ui.Style.use();
		for (kind in ["hxml", "haxelib", "rayzor"]) {
			var entry = ProjectFile.create(root, "test-" + kind, kind), compiler = new CompilerServer(), display = Display.ofProject(compiler, entry);
			var tree = new LayoutTree(), stop:Void->Void = null;
			var bench = Owner.root(tree, cleanup -> { stop = cleanup; return new Workbench({display:display, name:display.project.name, runtime:display.project.runtime}); });
			function settle():Void for (_ in 0...12) {
				ashui.core.render.Offscreen.advance(.03); Css.update(); tree.flush(); tree.computeLayout(bench.node, 1280, 800);
			}
			try {
				bench.openProject(); settle();
				if (bench.projectEntry() != entry || bench.classpaths().length == 0) throw "Workbench lost manifest identity or source folders";
				if (Css.query(tree, bench.node.id, '[data-path="$entry"]').length != 1) throw "Project entry is missing or duplicated in the Explorer";
				if (kind == "haxelib") {
					if (bench.active.get() != "" || Css.query(tree, bench.node.id, "#welcome-run, #rayde-run").length != 0) throw "Library welcome page offers an application run";
				} else {
					if (bench.mainFile() != display.cwd + "/src/Main.hx") throw "New application did not resolve Main.hx";
					bench.openFile(bench.mainFile()); settle();
					if (bench.editorFor(bench.active.get()) == null) throw "New application cannot open Main.hx";
				}
				bench.openFile(entry); settle();
				if (bench.editorFor(entry) == null || bench.buffer(entry).get() != sys.io.File.getContent(entry)) throw "Project descriptor cannot be edited as code";
			} catch (error:Dynamic) { stop(); tree.dispose(); compiler.stop(); throw error; }
			stop(); tree.dispose(); compiler.stop();
		}
		Sys.println("project UI: all descriptors, source folders, unique Explorer entry, Main.hx navigation, library welcome and editable manifest tabs");
	}
}
