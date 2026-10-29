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
class BuildWorkbenchChecks {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }
	static function main():Void {
		BuildChecks.run();
		ProjectRunnerChecks.run();
		for (dark in [true, false]) run(dark);
		Sys.println("Build UI: distinct actions, shortcut, save-before-build, background progress, output, diagnostics, rebuild and toolbar bounds in both themes");
	}
	static function run(dark:Bool):Void {
		var root = Sys.getCwd() + "bin/build-ui-" + Std.random(0x3fffffff), previous = Sys.getEnv("RAYDE_EXTENSIONS");
		sys.FileSystem.createDirectory(root + "/extensions"); Sys.putEnv("RAYDE_EXTENSIONS", root + "/extensions");
		var entry = ProjectFile.create(root, "sample", "hxml"), project = haxe.io.Path.directory(entry), file = project + "/src/Main.hx";
		sys.io.File.saveContent(entry, "-cp src\n-main Main\n-js bin/app.js\n");
		var good = 'class Main { static function main() { trace("DO_NOT_RUN"); } }\n';
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light); rayde.ui.Style.use();
		var tree = new LayoutTree(), compiler = new CompilerServer(), stop:Void->Void = null;
		var bench = Owner.root(tree, cleanup -> { stop = cleanup; return new Workbench({display:Display.ofProject(compiler, entry), name:"sample"}); });
		var width = 1100;
		function settle(frames = 8):Void for (_ in 0...frames) { Offscreen.advance(.03); Css.setViewport(width, 760); Css.update(); tree.flush(); tree.computeLayout(bench.node, width, 760); }
		function nodes(selector:String) return Css.query(tree, bench.node.id, selector);
		function box(selector:String) { var found = nodes(selector); check(found.length == 1, "Missing " + selector); return tree.getScrolledBounds(new ashui.layout.Node(found[0])); }
		function click(selector:String):Void { var b = box(selector); ashui.input.Pointer.move(tree, b.x + b.width / 2, b.y + b.height / 2); ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree); }
		function until(done:Void->Bool):Void {
			var deadline = haxe.Timer.stamp() + 12;
			while (!done() && haxe.Timer.stamp() < deadline) { settle(); Sys.sleep(.005); }
			check(done(), "Build UI did not settle: " + bench.runPart.runner.console); settle();
		}
		try {
			bench.openProject(); settle();
			check(nodes("#rayde-build-action").length == 1 && nodes("#rayde-run").length == 1, "Build and Run are not separate controls");
			check(Lambda.exists(bench.commandList, c -> c.id == "buildproject") && Lambda.exists(bench.commandList, c -> c.id == "build"), "Build replaced Build Settings");
			check(bench.keymapPart.bindings.commandFor(rayde.keys.Chord.parse("mod+shift+b", Sys.systemName() == "Mac")) == "buildproject", "Default Build shortcut is missing");
			var windowStyle = bench.windowStyle.get();
			for (style in ["macos","icon","windows","gnome","kde"]) for (size in [800,1100]) {
				bench.windowStyle.set(style); width = size; settle();
				var build = box("#rayde-build-action"), run = box("#rayde-run"), bar = box("#rayde-bar"), pill = box("#rayde-project"), controls = box("#rayde-window-controls");
				check(build.y >= bar.y && build.y + build.height <= bar.y + bar.height && run.y >= bar.y && run.y + run.height <= bar.y + bar.height,"Build/Run exceed the title bar: " + style);
				check(build.x >= bar.x + bar.width / 2 && run.x >= build.x + build.width && run.x + run.width <= bar.x + bar.width,"Build/Run are not at the top-right: " + style);
				check(pill.x + pill.width <= build.x && Math.abs(pill.x + pill.width / 2 - (bar.x + bar.width / 2)) < 1,"Project search overlaps actions or lost centering: " + style);
				check(rayde.ui.WindowControls.onLeft(style) ? controls.x + controls.width <= pill.x : run.x + run.width <= controls.x,"Run overlaps window controls: " + style);
				check(nodes("#rayde-status-bar #rayde-build-action, #rayde-status-bar #rayde-run").length == 0,"Bottom bar retained duplicate actions");
				if (size == 800) Snapshot.capture('build-title-${style}-${dark ? "dark" : "light"}',tree,bench.node,width,760);
			}
			bench.windowStyle.set(windowStyle); width = 1100; settle();
			bench.openBuild(); until(() -> nodes("#rayde-build-main").length == 1);
			check(nodes("#rayde-build").length == 1 && nodes("#rayde-build-action").length == 1,"Build toolbar conflicts with the Build Settings surface");
			bench.closeFile(Workbench.SETTINGS); settle();
			bench.documentsPart.buffer(file).set(good); bench.dirty.set([file]);
			var idleBuild=box("#rayde-build-action"), idleRun=box("#rayde-run");
			click("#rayde-build-action");
			check(bench.runPart.runState.get() == "building", "Build did not publish background progress: " + bench.runPart.runState.get() + "\n" + bench.runPart.runner.console);
			settle(1);
			check(nodes("#rayde-stop").length == 1, "Build did not expose Stop");
			check(nodes("#rayde-build-action #rayde-build-spinner").length==1,"Build did not replace its hammer with a spinner");
			check(nodes("#rayde-run").length==1 && nodes("#rayde-run:disabled").length==1,"Build hid or left Run enabled");
			check(Math.abs(box("#rayde-build-action").x-idleBuild.x)<1 && Math.abs(box("#rayde-run").x-idleRun.x)<1,"Active controls shifted Build or Run");
			var stopBox=box("#rayde-stop"), pill=box("#rayde-project");
			check(stopBox.x>=pill.x+pill.width && stopBox.x+stopBox.width<=box("#rayde-build-action").x,"Stop overlaps project search or Build");
			Snapshot.capture('build-toolbar-${dark ? "dark" : "light"}-busy',tree,bench.node,1100,760);
			click("#rayde-run"); bench.runCommand("run");
			until(() -> !bench.runPart.runner.active());
			check(nodes("#rayde-build-spinner, #rayde-stop").length==0 && nodes("#rayde-run:disabled").length==0,"Build completion retained busy controls");
			check(bench.runPart.runState.get() == "built" && bench.runPart.runner.exitCode == 0 && sys.FileSystem.exists(project + "/bin/app.js"), "Toolbar Build did not compile the declared target");
			check(sys.io.File.getContent(file) == good && bench.dirty.get().length == 0, "Build did not save edited buffers first");
			check(bench.runPart.runner.console.indexOf("DO_NOT_RUN") < 0 && !compiler.running(), "Build ran the program or started an idle compiler server");
			check(bench.panelsPart.bottom.get() == "console" && bench.panelsPart.panelShown.get(), "Build output was not opened");
			Snapshot.capture('build-toolbar-${dark ? "dark" : "light"}', tree, bench.node, 1100, 760);
			bench.documentsPart.buffer(file).set("class Main { static function main() { var broken:Int = 'text'; } }\n"); bench.dirty.set([file]);
			bench.runCommand("buildproject"); until(() -> !bench.runPart.runner.active());
			check(bench.runPart.runState.get() == "failed" && bench.problems.get().length > 0 && bench.panelsPart.bottom.get() == "problems", "Failed build did not surface its diagnostic");
			check(nodes("#rayde-build-spinner, #rayde-stop").length==0 && nodes("#rayde-run:disabled").length==0,"Failed build retained busy controls");
			bench.documentsPart.buffer(file).set(good); bench.dirty.set([file]);
			click("#rayde-build-action"); until(() -> !bench.runPart.runner.active());
			check(bench.runPart.runState.get() == "built" && bench.problems.get().length == 0, "Successful rebuild retained the previous build diagnostic");
			click("#rayde-build-action"); settle(1); click("#rayde-stop"); settle();
			check(bench.runPart.runState.get()=="idle" && nodes("#rayde-build-spinner, #rayde-stop").length==0 && nodes("#rayde-run:disabled").length==0,"Cancelled build retained busy controls");
		} catch (error:Dynamic) { stop(); tree.dispose(); compiler.stop(); Sys.putEnv("RAYDE_EXTENSIONS", previous ?? ""); throw error; }
		stop(); tree.dispose(); compiler.stop(); Sys.putEnv("RAYDE_EXTENSIONS", previous ?? "");
	}
}
