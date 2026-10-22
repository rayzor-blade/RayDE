import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

@:access(rayde.ui.Workbench)
class LspPollingLifecycle {
	public static function main():Void {
		var root = Sys.getCwd() + "bin/lsp-polling-lifecycle", file = root + "/Main.hx", entry = root + "/build.hxml";
		for (dir in [root, root + "/empty-extensions"]) sys.FileSystem.createDirectory(dir);
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/empty-extensions");
		sys.io.File.saveContent(file, "class Main { static function main() {} }\n");
		sys.io.File.saveContent(entry, "-cp .\n-main Main\n");
		new rayde.settings.WorkspaceSession(root, entry).close({files:[], active:""});
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), Dark);
		rayde.ui.Style.use();
		var tree = new LayoutTree(), compiler = new CompilerServer(), stop:Void->Void = null;
		var bench = Owner.root(tree, cleanup -> { stop = cleanup; return new Workbench({display:Display.ofHxml(compiler, entry), name:"Polling", runtime:"ash"}); });
		bench.openProject();
		function settle():Void {
			ashui.core.render.Offscreen.advance(.03); Css.update(); tree.flush(); tree.computeLayout(bench.node, 1280, 800);
		}
		function until(done:Void->Bool):Void {
			var deadline = haxe.Timer.stamp() + 8;
			while (!done() && haxe.Timer.stamp() < deadline) { settle(); Sys.sleep(.005); }
			if (!done()) throw "LSP workbench polling did not settle";
		}
		function paused():Bool return !bench.languagesScheduled && bench.languagePollTimer == null && !bench.languageServers.busy();
		try {
			bench.languageServers.register("fixture", {id:"fixture", lazy:true, languages:["haxe"], fileExtensions:[".hx"], transport:{kind:"stdio", command:"python3",
				args:[Sys.getCwd() + "tests/lsp_server_fixture.py", root + "/events"]}}, (_, _) -> {});
			settle();
			var client = bench.languageServers.client(file);
			if (!paused() || client.state != "idle") throw "Welcome page polled an unused lazy language server";
			bench.openFile(file);
			until(() -> client.state == "ready");
			if (!bench.languagesScheduled) throw "Opening code did not schedule language polling";
			bench.closeFile(file); settle();
			if (!paused() || client.state != "ready" || client.files().length != 0) throw "Closing the last code tab left an LSP poll scheduled";
			for (_ in 0...30) settle();
			if (!paused()) throw "Welcome page resumed language polling";
			var answered = false;
			client.request("test/state", {}, _ -> answered = true);
			until(() -> answered); settle();
			if (!paused()) throw "Documentless request left language polling scheduled after its reply";
			bench.languageServers.control("fixture", "restart");
			until(() -> client.state == "ready"); settle();
			if (!paused()) throw "Explicit restart did not finish and pause on the welcome page";
			bench.openFile(file); settle();
			if (!bench.languagesScheduled || client.files().indexOf(file) < 0) throw "Reopening code did not resume the retained language client";
			bench.closeAll(); settle();
			if (!paused()) throw "Bulk close left language polling scheduled";
		} catch (error:Dynamic) { stop(); tree.dispose(); compiler.stop(); throw error; }
		stop(); tree.dispose(); compiler.stop();
		Sys.println("LSP UI: welcome page pauses polling, code tabs resume it, last/bulk close cancels timers, documentless requests and restart complete");
	}
}
