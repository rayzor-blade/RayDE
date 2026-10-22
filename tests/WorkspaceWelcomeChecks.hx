import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.project.ProjectFile;
import rayde.settings.RecentProjects;
import rayde.settings.Store;
import rayde.ui.WorkspaceWindow;

@:access(rayde.ui.Workbench)
@:access(rayde.ui.ProjectPicker)
class WorkspaceWelcomeChecks {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }
	public static function main():Void {
		RecentProjectsChecks.run();
		var before = haxe.Timer.stamp();
		check(rayde.ui.ProjectPicker.run("python3", ["-c", "import time; time.sleep(10)"], () -> true) == null && haxe.Timer.stamp() - before < 2, "Cancelled picker process did not exit promptly");
		var previousHome = Sys.getEnv("HOME"), previousExtensions = Sys.getEnv("RAYDE_EXTENSIONS");
		try for (dark in [true, false]) run(dark) catch (error:Dynamic) {
			Sys.putEnv("HOME", previousHome); Sys.putEnv("RAYDE_EXTENSIONS", previousExtensions); throw error;
		}
		Sys.putEnv("HOME", previousHome); Sys.putEnv("RAYDE_EXTENSIONS", previousExtensions);
		Sys.println("Welcome workspaces: empty startup, recent folders, all file types, same-window switching, unsaved-file protection, owner cleanup and tab restoration in both schemes");
	}

	static function run(dark:Bool):Void {
		var root = Sys.getCwd() + "bin/workspace-welcome-" + Std.random(0x3fffffff), home = root + "/home", folder = root + "/folder workspace λ";
		for (path in [home, folder, root + "/empty-extensions"]) sys.FileSystem.createDirectory(path);
		Sys.putEnv("HOME", home); Sys.putEnv("RAYDE_EXTENSIONS", root + "/empty-extensions");
		var entry = ProjectFile.create(root, "haxe-app", "hxml"), code = folder + "/app.js";
		for (file in ["app.js", "main.py", "package.json", "README.md"]) sys.io.File.saveContent(folder + "/" + file, file == "package.json" ? "{}" : "hello\n");
		for (path in [home, folder, haxe.io.Path.directory(entry)]) Store.save(path, "appearance", {scheme:dark ? "dark" : "light"});
		for (i in 0...18) {
			var recent = root + '/recent-$i'; sys.FileSystem.createDirectory(recent); RecentProjects.remember(recent);
		}
		RecentProjects.remember(entry); RecentProjects.remember(folder);
		new rayde.settings.WorkspaceSession(home, home).close({files:[code], active:code});
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light); rayde.ui.Style.use();
		var tree = new LayoutTree(), server = new CompilerServer(), stop:Void->Void = null;
		var host = Owner.root(tree, cleanup -> { stop = cleanup; return new WorkspaceWindow({initial:WorkspaceWindow.describe(server), server:server}); });
		function settle(frames = 8):Void for (_ in 0...frames) {
			ashui.core.render.Offscreen.advance(.03); Css.update(); tree.flush(); tree.computeLayout(host.node, 1280, 800);
		}
		function until(done:Void->Bool):Void {
			var end = haxe.Timer.stamp() + 8;
			while (!done() && haxe.Timer.stamp() < end) { settle(); Sys.sleep(.005); }
			check(done(), "Workspace did not settle");
		}
		function count(selector:String):Int return Css.query(tree, host.node.id, selector).length;
		function click(selector:String):Void {
			var ids = Css.query(tree, host.node.id, selector); check(ids.length == 1, 'Missing or duplicate control: $selector');
			var box = tree.getScrolledBounds(new ashui.layout.Node(ids[0]));
			ashui.input.Pointer.move(tree, box.x + box.width / 2, box.y + box.height / 2);
			ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree); settle();
		}
		function shot(name:String):Void ashui.core.render.Snapshot.capture('workspace-${dark ? "dark" : "light"}-$name', tree, host.node, 1280, 800, ashui.theme.ThemeState.get().color(Background).rgb());
		try {
			settle();
			var fresh = host.bench;
			check(fresh.open.get().length == 0 && !fresh.explorerShown.get(), "Fresh launch restored tabs or expanded Explorer");
			check(!fresh.fileIndex.busy() && fresh.projectFiles().length == 0 && fresh.extensionManager.extensions.length == 0 && !fresh.languageServers.busy() && !server.running(), "Fresh launch started workspace services");
			check(count("#welcome-open-folder, #welcome-open-project, #welcome-new-project") == 3 && count("#welcome-project-0") == 1, "Welcome omitted workspace opening choices or recents");
			check(count("#rayde-runtime, #rayde-run, #welcome-build") == 0, "Empty Welcome advertises a build or runtime");
			var projectList = Css.query(tree, host.node.id, "#welcome-projects")[0];
			check(ashui.input.Scroll.at(projectList, tree).limits().y > 0 && tree.getBounds(new ashui.layout.Node(projectList)).height <= 361, "Long recent-workspace lists are not bounded and scrollable");
			shot("fresh");
			click("#rayde-activity-explorer");
			check(count("#rayde-empty-open-folder") == 1 && count("#rayde-explorer-tree") == 0, "Empty Explorer browses the user home");
			click("#rayde-activity-explorer");
			click("#welcome-project-0");
			until(() -> host.bench != fresh && host.bench.projectFiles().length == 4);
			var opened = host.bench;
			check(fresh.gone && count("#rayde") == 1 && opened.display().cwd == folder && opened.display().project.kind == "folder", "Recent folder did not replace the workspace owner");
			check(opened.explorerShown.get() && opened.projectEntry() == null && count("#rayde-runtime, #rayde-run, #welcome-build") == 0, "Folder workspace assumes a Haxe project");
			for (file in ["app.js", "main.py", "package.json", "README.md"]) check(count('[data-path="' + folder + "/" + file + '"]') == 1, "Explorer omitted " + file);
			shot("folder");
			opened.openFile(code); settle();
			check(opened.editorFor(code) != null, "Folder source did not open in an editor tab");
			opened.buffer(code).set("changed\n"); opened.edited(code); settle();
			opened.openWorkspace(entry); settle();
			check(host.bench == opened && opened.prompt.get() != null, "Switching discarded an unsaved buffer");
			click("#rayde-prompt-cancel");
			check(host.bench == opened && sys.io.File.getContent(code) == "hello\n", "Cancelling changed the workspace or file");
			opened.openWorkspace(entry); settle(); click("#rayde-prompt-accept");
			until(() -> host.bench != opened);
			check(opened.gone && sys.io.File.getContent(code) == "changed\n" && host.bench.display().project.file == entry, "Save and Open lost changes or the project entry");
			var project = host.bench;
			project.openWorkspace(folder); settle();
			check(project.gone && host.bench.active.get() == code && host.bench.buffer(code).get() == "changed\n", "Folder workspace tabs did not restore");
			check(count("#rayde") == 1, "Switching retained an old workbench");
			host.bench.closeAll(); settle(); shot("folder-returned");
			host.bench.openWorkspace(root + "/missing"); settle();
			check(host.bench.display().cwd == folder && !host.bench.gone, "Invalid workspace replaced the current one");
		} catch (error:Dynamic) { stop(); tree.dispose(); server.stop(); throw error; }
		stop(); tree.dispose(); server.stop();
	}
}
