import ashui.core.render.Offscreen;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

/**
 * Runs a headless app in the real Surface Preview tab for RAYDE_RATE_SECONDS (default 30), driving the tab at 60 frames a second in real time, and reports how the
 * pictures arrived and how long the tab itself took per frame: a viewer stalled by a blocked read shows as a late frame. RAYDE_SURFACE_APP is the app's command line
 * and RAYDE_SURFACE_DIR the folder it runs from. Qualitative: it measures arrival of pictures at 60 Hz sampling, not what a display shows.
 */
@:access(rayde.ui.Workbench)
class SurfaceRate {
	static function percentile(sorted:Array<Float>, p:Float):Float
		return sorted.length == 0 ? 0 : sorted[Std.int(Math.min(sorted.length - 1, Math.floor(sorted.length * p)))];

	static function main():Void {
		var command = Sys.getEnv("RAYDE_SURFACE_APP"), dir = Sys.getEnv("RAYDE_SURFACE_DIR"), seconds = Std.parseFloat(Sys.getEnv("RAYDE_RATE_SECONDS") ?? "30");
		if (command == null || command == "") { Sys.println("Surface rate: skipped, RAYDE_SURFACE_APP is not set"); return; }
		var root = Sys.getCwd() + "bin/surface-rate-" + Std.random(0x3fffffff), workspace = root + "/workspace", home = Sys.getEnv("HOME");
		for (path in [root + "/home", root + "/extensions", workspace]) sys.FileSystem.createDirectory(path);
		Sys.putEnv("HOME", root + "/home");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/extensions");
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), Dark);
		rayde.ui.Style.use();
		var compiler = new CompilerServer(), tree = new LayoutTree(), stop:Void->Void = null, bench:Workbench = null;
		bench = Owner.root(tree, cleanup -> {
			stop = cleanup;
			return new Workbench({display: new Display(compiler, workspace, []), name: "Surface rate"});
		});
		function frame():Void {
			Offscreen.advance(1 / 60);
			Css.setViewport(1280, 800);
			Css.update();
			tree.flush();
			tree.computeLayout(bench.node, 1280, 800);
		}
		try {
			bench.openProject();
			for (_ in 0...8) frame();
			bench.runPart.previewSurface(command, dir);
			var pump = bench.runPart.surfacePreview, now = haxe.Timer.stamp, begun = now();
			// The app may take a while to start; the clock for the measurement starts at its first picture.
			var tick = 1 / 60., next = now();
			while (pump.feed.frames < 1 && now() - begun < 60) { frame(); next += tick; var wait = next - now(); if (wait > 0) Sys.sleep(wait); else next = now(); }
			var started = pump.feed.frames > 0;
			var startedAt = now(), end = startedAt + seconds, last = pump.feed.frames, firstFrames = last;
			var arrivals:Array<Float> = [], late:Array<Float> = [], work:Array<Float> = [], stalls = 0;
			next = now();
			while (started && now() < end) {
				var t0 = now();
				late.push(Math.max(0, t0 - next) * 1000);
				frame();
				work.push((now() - t0) * 1000);
				var f = pump.feed.frames;
				for (_ in last...f) arrivals.push(now());
				last = f;
				next += tick;
				var wait = next - now();
				if (wait > 0) Sys.sleep(wait); else { stalls++; next = now(); }
			}
			var gaps = [for (i in 1...arrivals.length) (arrivals[i] - arrivals[i - 1]) * 1000];
			gaps.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
			late.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
			work.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
			inline function r(v:Float):Float return Math.round(v * 10) / 10;
			var elapsed = now() - startedAt, got = last - firstFrames;
			Sys.println('RATE started=$started seconds=${r(elapsed)} pictures=$got fps=${r(got / Math.max(.001, elapsed))} '
				+ 'gap_ms(mean=${r(gaps.length == 0 ? 0 : Lambda.fold(gaps, (g, s) -> g + s, 0.) / gaps.length)} p95=${r(percentile(gaps, .95))} p99=${r(percentile(gaps, .99))} max=${r(gaps.length == 0 ? 0 : gaps[gaps.length - 1])}) '
				+ 'viewer_frame_ms(mean=${r(work.length == 0 ? 0 : Lambda.fold(work, (g, s) -> g + s, 0.) / work.length)} p95=${r(percentile(work, .95))} max=${r(work.length == 0 ? 0 : work[work.length - 1])}) '
				+ 'late_ms(p95=${r(percentile(late, .95))} p99=${r(percentile(late, .99))} max=${r(late.length == 0 ? 0 : late[late.length - 1])}) missed_deadlines=$stalls finished=${pump.finished()} failure=${pump.failure}');
		} catch (error:Dynamic) {
			bench.runPart.closeSurfacePreview();
			stop();
			compiler.stop();
			Sys.putEnv("HOME", home);
			throw error;
		}
		bench.runPart.closeSurfacePreview();
		stop();
		compiler.stop();
		Sys.putEnv("HOME", home);
	}
}
