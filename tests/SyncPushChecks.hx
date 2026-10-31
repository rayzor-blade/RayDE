import ashui.core.render.Offscreen;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.sync.SyncFeature;
import rayde.ui.Workbench;

/** Syncs a real Git folder through the panel's native client to a running gateway (RAYDE_SYNC_GATEWAY), then again after a change, and once to a gateway that is not there. */
class SyncPushChecks {
	static function check(ok:Bool, message:String):Void if (!ok) throw message;

	static function git(workspace:String, args:Array<String>):Void
		check(Sys.command("git", ["-C", workspace, "-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"].concat(args)) == 0, "git " + args.join(" ") + " failed");

	static function main():Void {
		var root = Sys.getCwd() + "bin/sync-push-" + Std.random(0x3fffffff), workspace = root + "/workspace";
		for (path in [root + "/home", workspace]) sys.FileSystem.createDirectory(path);
		Sys.putEnv("HOME", root + "/home");
		git(workspace, ["init", "-q", "-b", "main"]);
		sys.io.File.saveContent(workspace + "/Main.hx", "class Main {}\n");
		sys.io.File.saveContent(workspace + "/notes.txt", "one");
		git(workspace, ["add", "-A"]);
		git(workspace, ["commit", "-q", "-m", "first"]);
		var gateway = Sys.getEnv("RAYDE_SYNC_GATEWAY");
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), Dark);
		rayde.ui.Style.use();
		var compiler = new CompilerServer(), tree = new LayoutTree(), stop:Void->Void = null, bench:Workbench = null;
		bench = Owner.root(tree, cleanup -> {
			stop = cleanup;
			return new Workbench({display: new Display(compiler, workspace, []), name: "Cloud Sync"});
		});
		function settle(frames = 3):Void for (_ in 0...frames) {
			Offscreen.advance(1 / 60);
			Css.setViewport(1280, 800);
			Css.update();
			tree.flush();
			tree.computeLayout(bench.node, 1280, 800);
		}
		function until(done:Void->Bool, message:String):Void {
			var end = haxe.Timer.stamp() + 30;
			while (!done() && haxe.Timer.stamp() < end) { settle(3); Sys.sleep(.01); }
			check(done(), message);
		}
		try {
			bench.openProject();
			settle(8);
			var feature = SyncFeature.of(bench.contributions);
			feature.refresh();
			check(feature.state.get().phase == "ready", "A repository with a gateway and an account should be ready, not " + feature.state.get().phase);
			feature.sync();
			until(() -> feature.state.get().phase == "synced" || feature.state.get().phase == "failed", "The upload did not finish");
			var first = feature.state.get();
			check(first.phase == "synced", "The upload failed: " + first.message);
			check(first.url.indexOf(gateway) == 0 && first.url.length == gateway.length + 44, "The workspace link is wrong: " + first.url);
			check(first.files == 2, "Two files should have been sent, not " + first.files);
			sys.io.File.saveContent(workspace + "/notes.txt", "two");
			feature.sync();
			until(() -> feature.state.get().phase == "synced" || feature.state.get().phase == "failed", "The second upload did not finish");
			check(feature.state.get().phase == "synced" && feature.state.get().url == first.url, "A second sync should publish to the same workspace");
			check(feature.state.get().total < first.total + 1 && feature.state.get().total <= 3, "Only the changed file should go again, not " + feature.state.get().total + " bytes");
			Sys.putEnv("RAYDE_SYNC_GATEWAY", "http://127.0.0.1:1");
			feature.sync();
			until(() -> feature.state.get().phase == "synced" || feature.state.get().phase == "failed", "An unreachable gateway did not end the upload");
			check(feature.state.get().phase == "failed" && feature.state.get().message.indexOf("could not be reached") >= 0, "An unreachable gateway should say so: " + feature.state.get().message);
		} catch (error) {
			stop();
			Sys.println(Std.string(error));
			Sys.exit(1);
		}
		stop();
		Sys.println("Cloud Sync push: ok");
	}
}
