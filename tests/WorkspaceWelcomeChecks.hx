import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.project.ProjectFile;
import rayde.settings.RecentProjects;
import rayde.settings.Store;
import rayde.ui.WorkspaceWindow;

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
		for (path in [folder,haxe.io.Path.directory(entry)]) sys.FileSystem.createDirectory(path + "/.git");
		var source="sources/a-long-directory-for-shared-project-components";
		sys.FileSystem.createDirectory(haxe.io.Path.directory(entry)+"/"+source);
		sys.io.File.saveContent(entry,sys.io.File.getContent(entry)+"\n-cp "+source+"\n");
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
		var width = 1280, height = 800;
		function settle(frames = 8):Void for (_ in 0...frames) {
			ashui.core.render.Offscreen.advance(.03); Css.setViewport(width,height); Css.update(); tree.flush(); tree.computeLayout(host.node,width,height);
		}
		function until(done:Void->Bool):Void {
			var end = haxe.Timer.stamp() + 8;
			while (!done() && haxe.Timer.stamp() < end) { settle(); Sys.sleep(.005); }
			check(done(), "Workspace did not settle: " + host.bench.display().cwd + ", files=" + host.bench.explorerPart.projectFiles().length);
		}
		function count(selector:String):Int return Css.query(tree, host.node.id, selector).length;
		function click(selector:String):Void {
			var ids = Css.query(tree, host.node.id, selector); check(ids.length == 1, 'Missing or duplicate control: $selector');
			var box = tree.getScrolledBounds(new ashui.layout.Node(ids[0]));
			ashui.input.Pointer.move(tree, box.x + box.width / 2, box.y + box.height / 2);
			ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree); settle();
		}
		function shot(name:String):Void ashui.core.render.Snapshot.capture('workspace-${dark ? "dark" : "light"}-$name', tree, host.node,width,height,ashui.theme.ThemeState.get().color(Background).rgb());
		function bounds(selector:String) {
			var ids=Css.query(tree,host.node.id,selector); check(ids.length==1,"Missing or duplicate Welcome element: " + selector);
			return tree.getBounds(new ashui.layout.Node(ids[0]));
		}
		function layout(name:String, w:Int, h:Int, stacked:Bool):Void {
			width=w; height=h; settle();
			var welcome=bounds("#rayde-welcome"), start=bounds(".rayde-welcome-start"), info=bounds(".rayde-welcome-info");
			check(start.width>=250 && info.width>=250,"Welcome columns collapsed: " + name);
			check(stacked ? info.y>=start.y+start.height : Math.abs(start.y-info.y)<1 && info.x>=start.x+start.width,"Welcome did not reflow for its pane: " + name);
			for (box in [start,info]) check(box.x>=welcome.x && box.x+box.width<=welcome.x+welcome.width+1,"Welcome column escaped horizontally: " + name);
			for (text in Css.query(tree,host.node.id,".rayde-summary text")) {
				var label=tree.getBounds(new ashui.layout.Node(text));
				check(label.x>=info.x && label.x+label.width<=info.x+info.width+1,"Project detail escaped its card: " + name);
			}
			for (node in Css.query(tree,host.node.id,".rayde-welcome-start .rayde-action")) {
				var row=tree.getBounds(new ashui.layout.Node(node));
				for (text in Css.query(tree,node,"text")) {
					var label=tree.getBounds(new ashui.layout.Node(text));
					check(label.x>=row.x && label.x+label.width<=row.x+row.width+1 && label.y>=row.y && label.y+label.height<=row.y+row.height+1,"Welcome action text escapes its row: " + name);
				}
			}
			var scroll=ashui.input.Scroll.at(Css.query(tree,host.node.id,"#rayde-welcome")[0],tree);
			check(scroll.limits().x<=1,"Welcome requires horizontal scrolling: " + name);
			shot(name);
			if(h<500){
				check(scroll.limits().y>0,"Short Welcome viewport cannot scroll");
				scroll.jumpTo(0,scroll.limits().y); settle();
				var end=tree.getScrolledBounds(new ashui.layout.Node(Css.query(tree,host.node.id,".rayde-welcome-info")[0]));
				check(end.y<welcome.y+welcome.height && end.y+end.height<=welcome.y+welcome.height+1,"Welcome details are not reachable by scrolling");
				shot(name+"-end");
			}
			scroll.jumpTo(0,0);
		}
		try {
			settle();
			var fresh = host.bench;
			check(fresh.open.get().length == 0 && !fresh.explorerShown.get(), "Fresh launch restored tabs or expanded Explorer");
			check(!fresh.explorerPart.fileIndex.busy() && fresh.explorerPart.projectFiles().length == 0 && fresh.extensionsPart.extensionManager.extensions.length == 0 && !fresh.languagesPart.languageServers.busy() && !server.running(), "Fresh launch started workspace services");
			check(count("#welcome-open-folder, #welcome-open-project, #welcome-new-project") == 3 && count("#welcome-project-0") == 1, "Welcome omitted workspace opening choices or recents");
			check(count("#rayde-runtime, #rayde-run, #welcome-build") == 0, "Empty Welcome advertises a build or runtime: " + [for (id in ["#rayde-runtime","#rayde-run","#welcome-build"]) id + "=" + count(id)].join(","));
			var projectList = Css.query(tree, host.node.id, "#welcome-projects")[0];
			check(ashui.input.Scroll.at(projectList, tree).limits().y > 0 && tree.getBounds(new ashui.layout.Node(projectList)).height <= 361, "Long recent-workspace lists are not bounded and scrollable");
			shot("fresh");
			layout("fresh-narrow",800,600,false);
			click("#rayde-activity-explorer");
			check(count("#rayde-empty-open-folder") == 1 && count("#rayde-explorer-tree") == 0, "Empty Explorer browses the user home");
			layout("fresh-sidebar",800,600,true);
			click("#rayde-activity-explorer");
			width=1280; height=800; settle();
			click("#welcome-project-0");
			until(() -> host.bench != fresh && host.bench.explorerPart.projectFiles().length == 4);
			var opened = host.bench;
			check(fresh.gone && count("#rayde") == 1 && opened.display().cwd == folder && opened.display().project.kind == "folder", "Recent folder did not replace the workspace owner");
			check(opened.explorerShown.get() && opened.explorerPart.projectEntry() == null && count("#rayde-runtime, #rayde-run, #welcome-build") == 0, "Folder workspace assumes a Haxe project");
			for (file in ["app.js", "main.py", "package.json", "README.md"]) check(count('[data-path="' + folder + "/" + file + '"]') == 1, "Explorer omitted " + file);
			shot("folder");
			layout("folder-narrow",800,600,true);
			layout("folder-short",800,360,true);
			layout("folder-wide",1280,800,false);
			opened.openFile(code); settle();
			check(opened.editorFor(code) != null, "Folder source did not open in an editor tab");
			opened.documentsPart.buffer(code).set("changed\n"); opened.documentsPart.edited(code); settle();
			opened.projectPart.openWorkspace(entry); settle();
			check(host.bench == opened && opened.prompt.get() != null, "Switching discarded an unsaved buffer");
			click("#rayde-prompt-cancel");
			check(host.bench == opened && sys.io.File.getContent(code) == "hello\n", "Cancelling changed the workspace or file");
			opened.projectPart.openWorkspace(entry); settle(); click("#rayde-prompt-accept");
			until(() -> host.bench != opened);
			check(opened.gone && sys.io.File.getContent(code) == "changed\n" && host.bench.display().project.file == entry, "Save and Open lost changes or the project entry");
			var project = host.bench;
			layout("project-narrow",800,600,true);
			var sidebar=project.treeWidth.get(); project.treeWidth.set(440);
			layout("project-sidebar-wide",800,600,true);
			check(bounds("#welcome-build").height>52,"Wrapped action descriptions did not grow their row");
			project.treeWidth.set(sidebar);
			layout("project-wide",1280,800,false);
			project.projectPart.openWorkspace(folder); settle();
			check(project.gone && host.bench.active.get() == code && host.bench.documentsPart.buffer(code).get() == "changed\n", "Folder workspace tabs did not restore");
			check(count("#rayde") == 1, "Switching retained an old workbench");
			host.bench.closeAll(); settle(); shot("folder-returned");
			host.bench.projectPart.openWorkspace(root + "/missing"); settle();
			check(host.bench.display().cwd == folder && !host.bench.gone, "Invalid workspace replaced the current one");
		} catch (error:Dynamic) { stop(); tree.dispose(); server.stop(); throw error; }
		stop(); tree.dispose(); server.stop();
	}
}
