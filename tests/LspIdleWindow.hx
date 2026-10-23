import ashui.app.WindowedApp;
import ashui.animation.AnimationScheduler;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

/** A delayed server notification must wake a native window with no LSP poll timer. */
@:access(rayde.ui.Workbench)
@:access(rayde.lang.LspClient)
class LspIdleWindow {
	static function main():Void {
		var root = Sys.getCwd() + "bin/lsp-idle-window", file = root + "/Main.hx";
		sys.FileSystem.createDirectory(root + "/empty-extensions");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/empty-extensions");
		sys.io.File.saveContent(file, "class Main { static function main() {} }\n");
		sys.io.File.saveContent(root + "/build.hxml", "-cp .\n-main Main\n");
		var compiler = new CompilerServer(), passed = false, failure:Dynamic = null;
		rayde.ui.Style.use();
		WindowedApp.run({title:"LSP idle wake check", width:1000, height:650, active:false,
			theme:ashui.theme.themes.RestrainedTheme.bundle()}, () -> {
			var app = WindowedApp.current;
			var bench = new Workbench({display:Display.ofHxml(compiler, root + "/build.hxml"), name:"LSP idle", runtime:"ash"});
			function later(seconds:Float, fn:Void->Void):Void AnimationScheduler.main.after(seconds, () -> {
				try fn() catch (error:Dynamic) { failure = error; app.quit(); }
			});
			var requested = false, answered = false, sentAt = 0.;
			bench.languageServers.register("fixture", {id:"fixture", lazy:true, languages:["haxe"], fileExtensions:[".hx"],
				transport:{kind:"stdio", command:"python3", args:[Sys.getCwd() + "tests/lsp_server_fixture.py", root + "/events"]}}, (_, text) -> {
				if (text != "fixture: idle-notification") return;
				if (!requested || !answered || bench.languagesScheduled || haxe.Timer.stamp() - sentAt > 1.5) {
					failure = "Delayed server notification did not wake a sleeping window";
				} else passed = true;
				app.quit();
			});
			bench.openFile(file);
			var client = bench.languageServers.client(file);
			function ready():Void {
				if (client.state != "ready" || bench.languagesScheduled || bench.editorFor(file) == null) { later(.05, ready); return; }
				if (!client.transport.canWake()) throw "Native LSP wake primitive was not found";
				var editor = bench.editorFor(file);
				editor.editing.readOnly = true; editor.editing.stopBlink();
				later(2, () -> {
					if (bench.languagesScheduled || bench.languagePollTimer != null) throw "Idle code retained an LSP poll timer";
					requested = true; sentAt = haxe.Timer.stamp();
					client.request("test/notifyLater", {delay:.6, message:"idle-notification"}, _ -> {
						answered = true;
						later(.2, () -> {
							if (bench.languagesScheduled || bench.languagePollTimer != null) throw "Completed request retained a poll timer";
						});
					});
				});
			}
			later(.1, ready);
			later(12, () -> { throw "LSP native idle wake check timed out"; });
			return bench;
		});
		compiler.stop();
		if (failure != null) throw failure;
		if (!passed) throw "LSP native idle wake check did not complete";
		Sys.println("LSP native idle wake: PASS");
	}
}
