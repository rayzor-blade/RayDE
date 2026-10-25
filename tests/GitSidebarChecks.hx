import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.input.Pointer;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

@:access(rayde.ui.workbench.ExtensionsPart)
class GitSidebarChecks {
	static function check(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
	}

	public static function main():Void {
		var home = Sys.getEnv("HOME"),
			extensions = Sys.getEnv("RAYDE_EXTENSIONS");
		try
			for (dark in [false, true])
				run(dark)
		catch (error:Dynamic) {
			Sys.putEnv("HOME", home);
			Sys.putEnv("RAYDE_EXTENSIONS", extensions);
			throw error;
		}
		Sys.putEnv("HOME", home);
		Sys.putEnv("RAYDE_EXTENSIONS", extensions);
		Sys.println("Git sidebar: repeated hide/reopen restores content, tools and readiness without restarting the host in both themes");
	}

	static function run(dark:Bool):Void {
		var root = Sys.getCwd() + "bin/git-sidebar-" + Std.random(0x3fffffff),
			workspace = root + "/workspace";
		for (dir in [root + "/home", root + "/extensions", workspace + "/src"])
			sys.FileSystem.createDirectory(dir);
		Sys.putEnv("HOME", root + "/home");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/extensions");
		sys.io.File.saveContent(workspace + "/build.hxml", "-cp src\n-main Main\n--no-output\n");
		sys.io.File.saveContent(workspace + "/src/Main.hx", "class Main { static function main() {} }\n");
		check(Sys.command("python3", ["tests/git_fixture.py", workspace, "--install"]) == 0, "Git fixture setup failed");
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light);
		rayde.ui.Style.use();
		var tree = new LayoutTree(),
			compiler = new CompilerServer(),
			stop:Void->Void = null;
		var bench = Owner.root(tree, dispose -> {
			stop = dispose;
			return new Workbench({display: Display.ofHxml(compiler, workspace + "/build.hxml"), name: "Git sidebar"});
		});
		function settle(frames = 5):Void
			for (_ in 0...frames) {
				Offscreen.advance(1 / 60);
				Css.setViewport(1280, 850);
				Css.update();
				tree.flush();
				tree.computeLayout(bench.node, 1280, 850);
			}
		function count(selector:String):Int
			return Css.query(tree, bench.node.id, selector).length;
		function click(selector:String):Void {
			var nodes = Css.query(tree, bench.node.id, selector);
			check(nodes.length == 1, 'Missing $selector');
			var box = tree.getScrolledBounds(new Node(nodes[0]));
			Pointer.move(tree, box.x + box.width / 2, box.y + box.height / 2);
			Pointer.press(tree);
			Pointer.release(tree);
			settle();
		}
		function until(done:Void->Bool, message:String):Void {
			var end = haxe.Timer.stamp() + 15;
			while (!done() && haxe.Timer.stamp() < end) {
				settle(3);
				Sys.sleep(.005);
			}
			check(done(), message);
			settle();
		}
		try {
			var entry = bench.extensionsPart.extensionManager.find("git");
			check(entry != null, "Git extension missing");
			bench.extensionsPart.extensionManager.setNativeApproved("git", "git2", true);
			var studio = bench.extensionsPart.studios.get(entry.connection.file),
				icon = "#rayde-activity-ext-git-scm";
			settle();
			click(icon);
			until(() -> studio.hasView("scm")
				&& count("#git-scm") == 1
				&& count("#rayde-studio-loading") == 0
				&& count("#rayde-tool-git-refresh:disabled") == 0,
				"Git sidebar never became ready");
			until(() -> Lambda.exists(studio.preview.outline(), row -> row.text.indexOf("5 files") >= 0)
				&& Lambda.exists(studio.preview.outline(), row -> row.text.indexOf("Add Git history graph") >= 0),
				"Git repository status or history did not load");
			var model = studio.preview,
				roots = [for (view in model.roots) view.id].join(","),
				host = entry.connection.hostDescription();
			for (cycle in 0...3) {
				click(icon);
				check(count("#git-scm") == 0 && !studio.hasView("scm"), "Hiding Git retained its mounted sidebar");
				click(icon);
				settle();
				check(count("#git-scm") == 1 && studio.hasView("scm"), "Reopening Git did not restore its sidebar");
				check(count("#rayde-studio-loading") == 0 && count("#rayde-tool-git-refresh:disabled") == 0,
					"Reopening Git left its loader spinning or tools disabled");
				check(studio.preview == model
					&& [for (view in model.roots) view.id].join(",") == roots
					&& entry.connection.hostDescription() == host,
					"Reopening Git restarted its host or replaced its retained roots");
			}
			check(!Lambda.exists(studio.console.get(), e -> e.kind == "error"), "Git sidebar reported extension errors");
			Snapshot.capture('git-sidebar-reopened-${dark ? "dark" : "light"}', tree, bench.node, 1280, 850);
		} catch (error:Dynamic) {
			stop();
			tree.dispose();
			compiler.stop();
			throw error;
		}
		stop();
		tree.dispose();
		compiler.stop();
	}
}
