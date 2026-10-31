import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.sync.SyncFeature;
import rayde.ui.Workbench;

/** Opens the Cloud Sync panel in the real workbench in every state it has, checks what each shows, and captures them into bin/snapshots. */
@:access(rayde.ui.Workbench)
class SyncPanelSnapshot {
	static function check(ok:Bool, message:String):Void if (!ok) throw message;

	static function main():Void {
		var root = Sys.getCwd() + "bin/sync-panel-" + Std.random(0x3fffffff), workspace = root + "/workspace", home = Sys.getEnv("HOME");
		for (path in [root + "/home", root + "/extensions", workspace]) sys.FileSystem.createDirectory(path);
		Sys.putEnv("HOME", root + "/home");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/extensions");
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
		function has(selector:String):Bool return Css.query(tree, bench.node.id, selector).length > 0;
		try {
			bench.openProject();
			settle(8);
			check(has("#rayde-activity-sync"), "The activity bar has no Cloud Sync icon");
			var feature = SyncFeature.of(bench.contributions);
			check(feature != null, "The Cloud Sync feature is not installed");
			feature.show();
			settle(8);
			check(has("#rayde-sync-panel"), "The Cloud Sync panel did not open");
			// The folder is not a Git repository, so that is what stands in the way.
			check(has("#rayde-sync-init-git"), "A folder without Git should offer to initialize it");
			Snapshot.capture("cloud-sync-live-no-git", tree, bench.node, 1280, 800);
			// Initializing is the person's own act and works without an account: the folder becomes a repository and the panel moves on to sign-in.
			check(!sys.FileSystem.exists(workspace + "/.git"), "The folder should start without a repository");
			feature.initGit();
			settle(6);
			check(sys.FileSystem.exists(workspace + "/.git"), "Initialize Git did not make a repository");
			check(feature.state.get().phase == "signed-out", "After initializing, the panel should wait on sign-in, not " + feature.state.get().phase);
			check(has("#rayde-sync-sign-in"), "The panel should offer Sign In once the folder is a repository");
			// What each state shows, with the control that state exists for.
			var expected = [
				"signed-out" => "#rayde-sync-sign-in", "no-git" => "#rayde-sync-init-git", "ready" => "#rayde-sync-start", "checking" => "#rayde-sync-cancel",
				"uploading" => "#rayde-sync-progress", "verifying" => "#rayde-sync-cancel", "synced" => "#rayde-sync-copy", "pending" => "#rayde-sync-offline",
				"conflict" => "#rayde-sync-conflict", "failed" => "#rayde-sync-retry", "expiring" => "#rayde-sync-expiring", "expired" => "#rayde-sync-expired", "deleting" => "#rayde-sync-deleting"
			];
			for (phase in expected.keys()) {
				feature.state.set(SyncFeature.sampleOf(phase));
				settle(6);
				check(has("#rayde-sync-phase"), phase + ": no state badge");
				check(has(expected[phase]), phase + ": missing " + expected[phase]);
				Snapshot.capture("cloud-sync-" + phase, tree, bench.node, 1280, 800);
			}
			Sys.println("Cloud Sync panel: " + Lambda.count({iterator: expected.keys}) + " states rendered, each with its own control");
		} catch (error:Dynamic) {
			stop();
			compiler.stop();
			Sys.putEnv("HOME", home);
			throw error;
		}
		stop();
		compiler.stop();
		Sys.putEnv("HOME", home);
	}
}
