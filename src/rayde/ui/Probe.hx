package rayde.ui;

/**
	With `RAYDE_PROBE=1` (the page's `?env=RAYDE_PROBE=1`), publishes what the editor shows to the hosting page as `globalThis.__raydeProbe`, so an
	acceptance run can read it without scraping a canvas. It only reports; nothing in the page can act through it.
**/
class Probe {
	public static function install(host:Host):Void {
		#if wasm
		var bridge = rayde.workspace.PageHost.bridge;
		if (Sys.getEnv("RAYDE_PROBE") != "1" || bridge == null) return;
		var last = "";
		function publish():Void {
			if (host.closed()) return;
			var errors = 0, warnings = 0;
			for (p in host.problems.get()) if (p.severity == 1) errors++ else if (p.severity == 2) warnings++;
			var snapshot = {
				version: 1,
				workspace: host.name,
				tabs: host.tabs.get(),
				active: host.active.get(),
				dirty: host.dirty.get(),
				problems: {errors: errors, warnings: warnings},
				commands: [for (c in host.contributions.commands()) c.id],
				activities: [for (place in ["top", "left", "right", "bottom"]) for (a in host.contributions.activityItems(place)) a.id],
				status: host.contributions.statusIds()
			};
			var text = haxe.Json.stringify(snapshot);
			if (text != last) {
				last = text;
				bridge.notify("page.probe", {snapshot: snapshot});
			}
			ashui.animation.AnimationScheduler.main.after(.5, publish);
		}
		ashui.animation.AnimationScheduler.main.after(.5, publish);
		#end
	}
}
