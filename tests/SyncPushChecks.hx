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
			// Open asks the gateway for a browser session on the published copy and is told its link.
			var job = rayde.sync.NativeSync.start({root: workspace, gateway: gateway, account: Sys.getEnv("RAYDE_SYNC_DEV_ACCOUNT"), action: "open"}), opened:Dynamic = null;
			until(() -> {
				var events = rayde.sync.NativeSync.poll(job);
				if (events != null) for (event in events) if (event.event == "opened" || event.event == "error") opened = event;
				return opened != null;
			}, "Open did not answer");
			rayde.sync.NativeSync.close(job);
			check(opened.event == "opened" && opened.url == first.url && opened.generation == 2, "Open should report the workspace link at generation 2: " + haxe.Json.stringify(opened));
			// Another device that has synced the same workspace saves first; this folder is told, pulls, and syncs again.
			var account = Sys.getEnv("RAYDE_SYNC_DEV_ACCOUNT"), clone = root + "/clone";
			function job(config:Dynamic):Dynamic {
				var id = rayde.sync.NativeSync.start(config), last:Dynamic = null;
				until(() -> {
					var events = rayde.sync.NativeSync.poll(id);
					if (events != null) for (event in events) if (event.event == "published" || event.event == "merged" || event.event == "error") last = event;
					return last != null;
				}, "A sync job did not answer");
				rayde.sync.NativeSync.close(id);
				return last;
			}
			function settled(what:String):Void until(() -> ["synced", "conflict", "failed"].indexOf(feature.state.get().phase) >= 0, what);
			check(Sys.command("git", ["clone", "-q", workspace, clone]) == 0, "git clone failed");
			for (name in ["rayde-sync.json", "rayde-sync-base"]) check(Sys.command("cp", ["-R", workspace + "/.git/" + name, clone + "/.git/" + name]) == 0, "copying " + name + " failed");
			sys.io.File.saveContent(clone + "/notes.txt", "from the other device");
			check(job({root: clone, gateway: gateway, account: account, device: "other"}).event == "published", "The other device should have synced");
			sys.io.File.saveContent(workspace + "/Main.hx", "class Main { static function main() {} }\n");
			feature.sync();
			settled("The sync did not end");
			check(feature.state.get().phase == "conflict" && feature.state.get().conflicts == 0, "A newer cloud copy should ask to pull, not fail: " + feature.state.get().phase + " " + feature.state.get().message);
			feature.pull();
			settled("The pull did not end");
			check(feature.state.get().phase == "synced" && feature.state.get().message.indexOf("Pulled generation") == 0, "A pull should say what it did: " + feature.state.get().phase + " " + feature.state.get().message);
			check(sys.io.File.getContent(workspace + "/notes.txt") == "from the other device" && sys.io.File.getContent(workspace + "/Main.hx").indexOf("static function main()") > 0, "The pull should bring in the other device's file and keep this folder's own");
			feature.sync();
			settled("The sync after the pull did not end");
			check(feature.state.get().phase == "synced", "A pulled folder should sync: " + feature.state.get().message);
			// Both edit the same file in the same place: the pull lists it, and a choice settles it.
			check(job({root: clone, gateway: gateway, account: account, action: "pull"}).event == "merged", "The other device should have caught up");
			sys.io.File.saveContent(clone + "/notes.txt", "other device, again");
			check(job({root: clone, gateway: gateway, account: account, device: "other"}).event == "published", "The other device should have synced again");
			sys.io.File.saveContent(workspace + "/notes.txt", "this device, again");
			feature.sync();
			settled("The sync did not end");
			check(feature.state.get().phase == "conflict", "A newer cloud copy should ask to pull");
			feature.pull();
			settled("The pull did not end");
			check(feature.state.get().phase == "conflict" && feature.state.get().conflicts == 1, "The shared edit should be listed: " + feature.state.get().phase + " " + feature.state.get().message);
			check(sys.io.File.getContent(workspace + "/notes.txt") == "this device, again", "Nothing is changed until a choice is made");
			feature.resolve("mine");
			settled("The choice did not settle");
			check(feature.state.get().phase == "synced", "Keeping this folder's version should settle it: " + feature.state.get().message);
			feature.sync();
			settled("The sync after the choice did not end");
			check(feature.state.get().phase == "synced" && sys.io.File.getContent(workspace + "/notes.txt") == "this device, again", "The kept version should sync: " + feature.state.get().message);
			// The same again with a pick per file: Apply waits until every file has one, and each file takes the side picked for it.
			sys.io.File.saveContent(workspace + "/Main.hx", "class Main { var shared = 1; }\n");
			feature.sync();
			settled("The sync did not end");
			check(job({root: clone, gateway: gateway, account: account, action: "pull"}).event == "merged", "The other device should have caught up");
			sys.io.File.saveContent(clone + "/notes.txt", "other device, third");
			sys.io.File.saveContent(clone + "/Main.hx", "class Main { var shared = 2; }\n");
			check(job({root: clone, gateway: gateway, account: account, device: "other"}).event == "published", "The other device should have synced a third time");
			sys.io.File.saveContent(workspace + "/notes.txt", "this device, third");
			sys.io.File.saveContent(workspace + "/Main.hx", "class Main { var shared = 3; }\n");
			feature.sync();
			settled("The sync did not end");
			feature.pull();
			settled("The pull did not end");
			check(feature.state.get().phase == "conflict" && feature.state.get().conflicts == 2 && feature.state.get().items.length == 2, "Both files should be listed: " + feature.state.get().message);
			feature.pick(feature.state.get().items[0].path, "mine");
			feature.apply();
			check(feature.state.get().phase == "conflict" && feature.state.get().items[1].choice == "", "Apply must wait for every file to have a pick");
			var firstPath = feature.state.get().items[0].path, secondPath = feature.state.get().items[1].path;
			feature.pick(secondPath, "theirs");
			feature.apply();
			settled("The picks did not settle");
			check(feature.state.get().phase == "synced", "Picking a side for each file should settle them: " + feature.state.get().message);
			function side(path:String):String return path == "notes.txt" ? "this device, third" : "class Main { var shared = 3; }\n";
			function other(path:String):String return path == "notes.txt" ? "other device, third" : "class Main { var shared = 2; }\n";
			check(sys.io.File.getContent(workspace + "/" + firstPath) == side(firstPath), firstPath + " should have kept this folder's version");
			check(sys.io.File.getContent(workspace + "/" + secondPath) == other(secondPath), secondPath + " should have taken the other device's version");
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
