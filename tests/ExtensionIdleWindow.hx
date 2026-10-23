import ashui.app.WindowedApp;
import ashui.animation.AnimationScheduler;
import ashui.reactive.Owner;
import ashui.reactive.Watch;
import rayde.ext.Studio;

/** A sleeping extension wakes its native window on output without a supervisor poll timer. */
@:access(rayde.ext.Studio)
class ExtensionIdleWindow {
	static function main():Void {
		var passed = false, slept = false, armed = false, failure:Dynamic = null;
		ashui.components.Library.use();
		WindowedApp.run({title:"Extension idle wake check", width:640, height:360}, () -> {
			var app = WindowedApp.current;
			var root = <div class="p-4"/>;
			var native = Sys.getEnv("RAYDE_IDLE_NATIVE");
			var manifest = native == null ? null : rayde.ext.Manifest.read(native);
			var studio = new Studio(Sys.getCwd() + "bin/idle-extension.rays", () -> "mount(() -> <div>First view</div>, 'first'); trace('started'); await sleep(2200); mount(() -> <div>Late view</div>, 'late'); trace('late-output');", app.tree,manifest);
			if (manifest != null) studio.connection.nativeAllowed = _ -> true;
			Owner.onCleanup(studio.dispose);
			studio.attach(root.node);
			new Watch(() -> studio.console.get(), list -> {
				if (!armed && Lambda.exists(list, e -> e.text.indexOf("started") >= 0)) {
					armed = true;
					AnimationScheduler.main.after(.6, () -> {
						if (!studio.connection.canWake() || studio.scheduled || studio.pollTimer != null) {
							failure = "Idle extension retained a supervisor timer"; app.quit();
						} else slept = true;
					});
				}
				if (Lambda.exists(list, e -> e.text.indexOf("late-output") >= 0)) {
					passed = slept && !studio.scheduled && studio.pollTimer == null && studio.preview.roots.length == 2 && app.tree.children(root.node.id).length == 2;
					app.quit();
				}
			});
			AnimationScheduler.main.after(8, () -> { failure = "Extension output did not wake the native window"; app.quit(); });
			studio.reload();
			return root;
		});
		if (failure != null) throw failure;
		if (!passed) throw "Extension idle wake check did not complete";
		Sys.println("Extension native idle wake: PASS");
	}
}
