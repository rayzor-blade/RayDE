import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.project.ProjectFile;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
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
				ashui.core.render.Offscreen.advance(.03); Css.setViewport(1280, 800); Css.update(); tree.flush(); tree.computeLayout(bench.node, 1280, 800);
			}
			try {
				bench.openProject(); settle();
				if (kind == "hxml") {
					bench.projectPart.newProject(); settle();
					if (bench.quickOpen.get() || bench.prompt.get() != null || Css.query(tree, bench.node.id, ".rayde-project-template").length != rayde.project.ProjectTemplates.all.length) throw "New Project did not open the dedicated template modal";
					var panel = tree.getScrolledBounds(new ashui.layout.Node(Css.query(tree, bench.node.id, "#rayde-project-modal")[0]));
					if (panel.width < 700 || panel.height < 500 || panel.y < 0 || panel.y + panel.height > 800) throw "Workbench project modal is not visible within the viewport";
					ashui.core.render.Snapshot.capture("project-templates-workbench", tree, bench.node, 1280, 800);
					bench.projectPart.creatingProject.set(false); settle();
					if (Css.query(tree, bench.node.id, "#rayde-project-modal").length != 0) throw "Workbench retained the closed project catalog";
				}
				if (bench.explorerPart.projectEntry() != entry || bench.explorerPart.classpaths().length == 0) throw "Workbench lost manifest identity or source folders";
				if (Css.query(tree, bench.node.id, '[data-path="$entry"]').length != 1) throw "Project entry is missing or duplicated in the Explorer";
				if (kind == "haxelib") {
					if (bench.active.get() != "" || Css.query(tree, bench.node.id, "#welcome-run, #rayde-run").length != 0) throw "Library welcome page offers an application run";
				} else {
					if (bench.mainFile() != display.cwd + "/src/Main.hx") throw "New application did not resolve Main.hx";
					bench.openFile(bench.mainFile()); settle();
					if (bench.editorFor(bench.active.get()) == null) throw "New application cannot open Main.hx";
				}
				bench.openFile(entry); settle();
				if (bench.editorFor(entry) == null || bench.documentsPart.buffer(entry).get() != sys.io.File.getContent(entry)) throw "Project descriptor cannot be edited as code";
			} catch (error:Dynamic) { stop(); tree.dispose(); compiler.stop(); throw error; }
			stop(); tree.dispose(); compiler.stop();
		}
		Sys.println("project UI: all descriptors, source folders, unique Explorer entry, Main.hx navigation, library welcome and editable manifest tabs");
	}
}
