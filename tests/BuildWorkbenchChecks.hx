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
		function settle(frames = 8):Void for (_ in 0...frames) { Offscreen.advance(.03); Css.setViewport(1100, 760); Css.update(); tree.flush(); tree.computeLayout(bench.node, 1100, 760); }
		function nodes(selector:String) return Css.query(tree, bench.node.id, selector);
		function box(selector:String) { var found = nodes(selector); check(found.length == 1, "Missing " + selector); return tree.getScrolledBounds(new ashui.layout.Node(found[0])); }
		function click(selector:String):Void { var b = box(selector); ashui.input.Pointer.move(tree, b.x + b.width / 2, b.y + b.height / 2); ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree); }
		function until(done:Void->Bool):Void {
			var deadline = haxe.Timer.stamp() + 12;
			while (!done() && haxe.Timer.stamp() < deadline) { settle(); Sys.sleep(.005); }
			check(done(), "Build UI did not settle: " + bench.runner.console); settle();
		}
		try {
			bench.openProject(); settle();
			check(nodes("#rayde-build").length == 1 && nodes("#rayde-run").length == 1, "Build and Run are not separate controls");
			check(Lambda.exists(bench.commandList, c -> c.id == "buildproject") && Lambda.exists(bench.commandList, c -> c.id == "build"), "Build replaced Build Settings");
			check(bench.bindings.commandFor(rayde.keys.Chord.parse("mod+shift+b", Sys.systemName() == "Mac")) == "buildproject", "Default Build shortcut is missing");
			var build = box("#rayde-build"), bar = box("#rayde-status-bar");
			check(build.y >= bar.y && build.y + build.height <= bar.y + bar.height, "Build button exceeds the toolbar");
			bench.buffer(file).set(good); bench.dirty.set([file]);
			click("#rayde-build");
			check(bench.runState.get() == "building", "Build did not publish background progress: " + bench.runState.get() + "\n" + bench.runner.console);
			settle(1);
			check(nodes("#rayde-stop").length == 1, "Build did not expose Stop");
			until(() -> !bench.runner.active());
			check(bench.runState.get() == "built" && bench.runner.exitCode == 0 && sys.FileSystem.exists(project + "/bin/app.js"), "Toolbar Build did not compile the declared target");
			check(sys.io.File.getContent(file) == good && bench.dirty.get().length == 0, "Build did not save edited buffers first");
			check(bench.runner.console.indexOf("DO_NOT_RUN") < 0 && !compiler.running(), "Build ran the program or started an idle compiler server");
			check(bench.bottom.get() == "console" && bench.panelShown.get(), "Build output was not opened");
			Snapshot.capture('build-toolbar-${dark ? "dark" : "light"}', tree, bench.node, 1100, 760);
			bench.buffer(file).set("class Main { static function main() { var broken:Int = 'text'; } }\n"); bench.dirty.set([file]);
			bench.runCommand("buildproject"); until(() -> !bench.runner.active());
			check(bench.runState.get() == "failed" && bench.problems.get().length > 0 && bench.bottom.get() == "problems", "Failed build did not surface its diagnostic");
			bench.buffer(file).set(good); bench.dirty.set([file]);
			click("#rayde-build"); until(() -> !bench.runner.active());
			check(bench.runState.get() == "built" && bench.problems.get().length == 0, "Successful rebuild retained the previous build diagnostic");
		} catch (error:Dynamic) { stop(); tree.dispose(); compiler.stop(); Sys.putEnv("RAYDE_EXTENSIONS", previous ?? ""); throw error; }
		stop(); tree.dispose(); compiler.stop(); Sys.putEnv("RAYDE_EXTENSIONS", previous ?? "");
	}
}
