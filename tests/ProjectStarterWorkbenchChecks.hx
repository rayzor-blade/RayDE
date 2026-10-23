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
class ProjectStarterWorkbenchChecks {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }
	static function main():Void {
		var root = Sys.getCwd() + "bin/starter-workbench-" + Std.random(0x3fffffff);
		for (path in [root + "/app/console", root + "/home", root + "/workspace"]) sys.FileSystem.createDirectory(path);
		for (name in ["console.rayext", "main.rays"]) sys.io.File.copy("tests/fixtures/starters/console/" + name, root + "/app/console/" + name);
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/app"); Sys.putEnv("HOME", root + "/home");
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), Dark); rayde.ui.Style.use();
		var compiler = new CompilerServer(), tree = new LayoutTree(), stop:Void->Void = null, chosen = "";
		var display = Display.ofProject(compiler, root + "/workspace");
		var bench = Owner.root(tree, cleanup -> {
			stop = cleanup;
			return new Workbench({display:display, name:"RayDE", empty:true, onWorkspace:path -> chosen = path});
		});
		function settle(frames=12):Void for (_ in 0...frames) {
			Offscreen.advance(.025); Css.setViewport(1280, 800); Css.update(); tree.flush(); tree.computeLayout(bench.node, 1280, 800);
		}
		function nodes(selector:String) return Css.query(tree, bench.node.id, selector);
		function click(selector:String):Void {
			var ids = nodes(selector); check(ids.length == 1, "Missing " + selector);
			var b = tree.getScrolledBounds(new ashui.layout.Node(ids[0]));
			ashui.input.Pointer.move(tree, b.x + b.width / 2, b.y + b.height / 2); ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree); settle();
		}
		function wait(done:Void->Bool):Void {
			var until = haxe.Timer.stamp() + 8;
			while (!done() && haxe.Timer.stamp() < until) { bench.extensionManager.tick(); settle(2); Sys.sleep(.005); }
			check(done(), "Welcome starter did not complete"); settle();
		}
		try {
			settle(); check(bench.extensionManager.extensions.length == 0 && !compiler.running(), "Welcome discovered or started workspace services before New Project");
			bench.newProject(); wait(() -> bench.projectStarters.list().length == 1);
			check(nodes(".rayde-project-template").length == rayde.project.ProjectTemplates.all.length + 1 && !compiler.running(), "Welcome gallery did not adopt the extension starter without starting the compiler");
			ashui.input.Scroll.at(nodes("#rayde-project-catalog")[0], tree).scrollTo(0, 1e9); settle();
			click("#" + rayde.ui.NewProject.templateId("ext:console-starter:console"));
			check(ashui.ui.Text.at(nodes("#rayde-project-requirements")[0]).text() == "Haxe", "Welcome gallery retained the previous starter's requirements");
			Snapshot.capture("starter-extension-welcome", tree, bench.node, 1280, 800);
			ashui.ui.Input.at(tree, nodes("#rayde-project-name")[0]).value.set("extension-project");
			ashui.ui.Input.at(tree, nodes("#rayde-project-directory")[0]).value.set(root);
			settle();
			check(StringTools.endsWith(ashui.ui.Text.at(nodes("#rayde-project-destination")[0]).text(), "/extension-project"), "Destination preview did not follow the project name");
			click("#rayde-project-create"); wait(() -> chosen != "");
			check(chosen == root + "/extension-project/build.hxml" && ProjectFile.read(chosen).runtime == "ash", "Welcome did not create and open the extension starter with its chosen runner");
			check(!bench.creatingProject.get() && nodes("#rayde-project-modal").length == 0, "Created starter retained the gallery");
			bench.extensionManager.setDisabled("console-starter", true); settle(); check(bench.projectStarters.list().length == 0, "Disabled starter remained in the workbench registry");
		} catch (error:Dynamic) { stop(); tree.dispose(); compiler.stop(); throw error; }
		stop(); tree.dispose(); compiler.stop();
		Sys.println("Welcome starters: deferred extension discovery, live RayScript registration, selection, worker creation, runner preference and disposal");
	}
}
