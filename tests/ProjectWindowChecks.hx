import ashui.app.WindowedApp;
import ashui.animation.AnimationScheduler;
import rayde.ui.ProjectWindows;
import rayde.ui.WorkspaceWindow;
import rayde.settings.Store;
import rayde.settings.RecentProjects;
import rayde.settings.WorkspaceSession;
import rayde.settings.WindowSession;

@:access(rayde.ui.ProjectWindows)
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
class ProjectWindowChecks {
	static var failure:Dynamic;
	static var completed = false;
	static var phase = 0;
	static final hostContext = ashui.core.UiContext.current;

	static function check(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
	}

	static function later(seconds:Float, fn:Void->Void):Void
		hostContext.run(() -> AnimationScheduler.main.after(seconds, () -> {
			if (failure != null)
				return;
			try
				fn()
			catch (error:Dynamic) {
				failure = error;
				for (app in WindowedApp.windows()) {
					@:privateAccess app.config.onClose = null;
					app.quit();
				}
			}
		}));

	static function main():Void {
		WindowSessionChecks.run();
		var root = Sys.getCwd() + "bin/project-windows-" + Std.random(0x3fffffff);
		for (path in [root, root + "/home", root + "/extensions", root + "/one", root + "/two"])
			sys.FileSystem.createDirectory(path);
		Sys.putEnv("HOME", root + "/home");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/extensions");
		Sys.putEnv("RAYDE_MENU_BAR", "1");
		var codeA = root + "/one/First.hx", codeB = root + "/two/Second.hx";
		sys.io.File.saveContent(codeA, "class First {}\n");
		sys.io.File.saveContent(codeB, "class Second {}\n");
		Store.save(root + "/one", "appearance", {scheme: "dark"});
		Store.save(root + "/two", "appearance", {scheme: "light"});
		var fresh = ProjectWindows.startup(null)[0];
		check(fresh.config.data.title == "RayDE", "first launch opens Welcome");
		fresh.server.stop();
		var broken = root + "/haxelib.json";
		sys.io.File.saveContent(broken, "{");
		RecentProjects.remember(broken);
		var fallback = ProjectWindows.startup(null)[0];
		check(fallback.config.data.title == "RayDE", "unreadable last project falls back to Welcome");
		fallback.server.stop();
		RecentProjects.remember(root + "/one");
		var explicit = ProjectWindows.startup(root + "/two")[0];
		check(explicit.config.data.title == "RayDE · two", "explicit path takes precedence over last workspace");
		explicit.server.stop();
		RecentProjects.remember(root + "/one");
		var codeOther = root + "/one/Other.hx";
		sys.io.File.saveContent(codeOther, "class Other {}\n");
		new WorkspaceSession(root + "/one", root + "/one").close({files:["First.hx", "Other.hx"], active:"Other.hx"});
		new WorkspaceSession(root + "/two", root + "/two").close({files:["Second.hx"], active:"Second.hx"});
		WindowSession.save([root + "/one", root + "/two"]);
		var created = rayde.ui.ProjectPicker.choose({mode:"new", kind:"hxml", name:"generated", selected:root}, () -> false);
		check(created != null && sys.FileSystem.exists(created), "native folder selection creates a project without another dialog");
		check(rayde.ui.ProjectPicker.choose({mode:"project", selected:created}, () -> false) == created, "native file selection returns the project path");
		check(rayde.ui.ProjectPicker.choose({mode:"project", selected:created}, () -> true) == null, "cancelled picker work does not return a selection");
		rayde.ui.Style.use();
		var startup = ProjectWindows.startup(null);
		check(startup.length == 2 && startup[0].config.data.title == "RayDE · one" && startup[1].config.data.title == "RayDE · two", "startup selects every saved window in order");
		for (window in startup) window.server.stop();
		var a:WorkspaceWindow = null, b:WorkspaceWindow = null;
		function poll():Void {
			switch phase {
				case 0:
					if (ProjectWindows.live.length != 2 || WindowedApp.windows().length != 2) { later(.05, poll); return; }
					a = ProjectWindows.live[0].host; b = ProjectWindows.live[1].host;
					if (Lambda.count(a.bench.documentsPart.documents) != 1 || Lambda.count(b.bench.documentsPart.documents) != 1) { later(.05, poll); return; }
					check(a.bench.display().cwd != b.bench.display().cwd, "workspace roots are separate");
					check(a.bench.open.get().join(",") == [codeA, codeOther].join(",") && a.bench.active.get() == codeOther, "startup restores ordered tabs and active file");
					check(!a.bench.documentsPart.buffers.exists(codeA) && Lambda.count(a.bench.documentsPart.documents) == 1, "startup leaves inactive editors unloaded");
					check(b.bench.open.get().join(",") == codeB && b.bench.active.get() == codeB, "second window restores its own tabs");
					b.tree.context.run(() -> b.bench.projectPart.openWorkspace(root + "/missing"));
					check(!b.bench.gone && WindowedApp.windows().length == 2, "invalid project opening leaves existing windows intact");
					a.tree.context.run(() -> {
						a.bench.openFile(codeA);
						a.bench.documentsPart.buffer(codeA).set("class First { var edited = true; }\n");
						a.bench.documentsPart.edited(codeA);
					});
					phase = 1; later(.2, poll);
				case 1:
					check(a.bench.active.get() == codeA && b.bench.active.get() == codeB, "tabs are window-local");
					check(a.tree.context.run(() -> ashui.theme.ThemeState.get().scheme()) != b.tree.context.run(() -> ashui.theme.ThemeState.get().scheme()), "workspace appearance is window-local");
					check(ashui.css.Css.query(b.tree, b.node.id, "#rayde-menubar .ui-menubar-trigger").length == 8, "desktop menus render for the other platforms");
					b.tree.context.run(() -> a.bench.chrome.close());
					check(a.bench.prompt.get() != null && b.bench.prompt.get() == null && !a.bench.gone, "unsaved close prompts in the owning window");
					a.bench.prompt.set(null);
					a.bench.chrome.close();
					check(a.bench.prompt.get().discard != null, "close offers discard as well as save and cancel");
					phase = 2; later(.05, poll);
					a.bench.prompt.get().discard();
				case 2:
					if (!a.bench.gone || WindowedApp.windows().length != 1) { later(.05, poll); return; }
					check(!b.bench.gone, "closing the original project leaves the second usable");
					check(sys.io.File.getContent(codeA) == "class First {}\n", "discard does not save the buffer");
					check(WindowSession.read().join(",") == root + "/two", "closing one window removes it from the next session");
					phase = 3; later(.05, poll);
					b.tree.context.run(() -> b.bench.runCommand("newwindow"));
				case 3:
					if (WindowedApp.windows().length != 2 || ProjectWindows.live.length != 2) { later(.05, poll); return; }
					var welcome = WindowedApp.windows()[1];
					check(ashui.css.Css.query(welcome.tree, ProjectWindows.live[1].host.node.id, "#welcome-open-folder").length == 1, "New Window stays on Welcome even with recent projects");
					check(b.bench.documentsPart.buffer(codeB).get() == "class Second {}\n", "surviving editor remains intact");
					phase = 4; completed = true;
					ProjectWindows.quit();
				case _:
			}
		}
		later(.05, poll);
		later(15, () -> {
			throw "window test timed out: " + haxe.Json.stringify({phase:phase, firstGone:a == null ? null : a.bench.gone, secondGone:b == null ? null : b.bench.gone,
				windows:WindowedApp.windows().map(app -> ({disposed:app.disposed, frames:app.frames, quitting:@:privateAccess app.quitting})), records:ProjectWindows.live.map(window -> ({entry:window.entry, closing:window.closing}))});
		});
		ProjectWindows.run();
		if (failure != null)
			throw failure;
		check(completed && b.bench.gone && ProjectWindows.live.length == 0, "last close disposes the workbench and window records");
		var saved = WindowSession.read();
		check(saved.length == 2 && saved[0] == root + "/two" && saved[1] == null, "application quit retains every window, including Welcome");
		Sys.println("project windows: startup resumes all workspaces and tabs, explicit paths, Welcome fallback, window-local services, close decisions and quit persistence: PASS");
	}
}
