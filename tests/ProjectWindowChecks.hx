import ashui.app.WindowedApp;
import ashui.animation.AnimationScheduler;
import rayde.ui.ProjectWindows;
import rayde.ui.WorkspaceWindow;
import rayde.settings.Store;

@:access(rayde.ui.ProjectWindows)
@:access(rayde.ui.Workbench)
class ProjectWindowChecks {
	static var failure:Dynamic;
	static var completed = false;
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

	static function until(ready:Void->Bool, fn:Void->Void):Void
		later(.05, () -> {
			if (ready())
				fn();
			else
				until(ready, fn);
		});

	static function main():Void {
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
		var created = rayde.ui.ProjectPicker.choose({mode:"new", kind:"hxml", name:"generated", selected:root}, () -> false);
		check(created != null && sys.FileSystem.exists(created), "native folder selection creates a project without another dialog");
		check(rayde.ui.ProjectPicker.choose({mode:"project", selected:created}, () -> false) == created, "native file selection returns the project path");
		check(rayde.ui.ProjectPicker.choose({mode:"project", selected:created}, () -> true) == null, "cancelled picker work does not return a selection");
		rayde.ui.Style.use();
		var first = ProjectWindows.prepare(root + "/one"),
			second = ProjectWindows.prepare(root + "/two");
		var a:WorkspaceWindow = null, b:WorkspaceWindow = null;
		WindowedApp.run(first.config, () -> {
			a = cast first.build();
			WindowedApp.open(second.config, () -> {
				b = cast second.build();
				return b;
			});
			until(() -> b != null && WindowedApp.windows().length == 2 && WindowedApp.windows()[1].frames > 0, () -> {
				check(WindowedApp.windows().length == 2, "two projects share the application");
				check(a.bench.display().cwd != b.bench.display().cwd, "workspace roots are separate");
				b.tree.context.run(() -> b.bench.openWorkspace(root + "/missing"));
				check(!b.bench.gone && WindowedApp.windows().length == 2, "invalid project opening leaves existing windows intact");
				a.tree.context.run(() -> {
					a.bench.openFile(codeA);
					a.bench.buffer(codeA).set("class First { var edited = true; }\n");
					a.bench.edited(codeA);
				});
				b.tree.context.run(() -> b.bench.openFile(codeB));
				later(.2, () -> {
					check(a.bench.active.get() == codeA && b.bench.active.get() == codeB, "tabs are window-local");
					check(a.tree.context.run(() -> ashui.theme.ThemeState.get().scheme()) != b.tree.context.run(() -> ashui.theme.ThemeState.get().scheme()),
						"workspace appearance is window-local");
					check(ashui.css.Css.query(b.tree, b.node.id, "#rayde-menubar .ui-menubar-trigger").length == 8,
						"desktop menus render for the other platforms");
					b.tree.context.run(() -> a.bench.chrome.close());
					check(a.bench.prompt.get() != null && b.bench.prompt.get() == null && !a.bench.gone, "unsaved close prompts in the owning window");
					a.bench.prompt.set(null);
					a.bench.chrome.close();
					check(a.bench.prompt.get().discard != null, "close offers discard as well as save and cancel");
					a.bench.prompt.get().discard();
					until(() -> a.bench.gone, () -> {
						check(a.bench.gone && !b.bench.gone && WindowedApp.windows().length == 1, "closing the original project leaves the second usable");
						check(sys.io.File.getContent(codeA) == "class First {}\n", "discard does not save the buffer");
						b.tree.context.run(() -> b.bench.runCommand("newwindow"));
						until(() -> WindowedApp.windows().length == 2 && WindowedApp.windows()[1].frames > 0, () -> {
							check(WindowedApp.windows().length == 2, "New Window command works after closing the original window");
							check(b.bench.buffer(codeB).get() == "class Second {}\n", "surviving editor remains intact");
							completed = true;
							for (app in WindowedApp.windows())
								app.quit();
						});
					});
				});
			});
			later(15, () -> {
				throw "window test timed out";
			});
			return a;
		});
		if (failure != null)
			throw failure;
		check(completed && b.bench.gone, "last close disposes the workbench");
		Sys.println("project windows: PASS");
	}
}
