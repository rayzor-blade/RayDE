import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

/**
 * Opens a headless app that speaks the surface protocol in a Surface Preview tab of the real workbench, presses inside its picture, and
 * captures the window before and after. RAYDE_SURFACE_APP is the app's shell command line and RAYDE_SURFACE_DIR the folder it runs from.
 */
@:access(rayde.ui.Workbench)
class SurfacePreviewSnapshot {
	static function check(ok:Bool, message:String):Void if (!ok) throw message;

	static function main():Void {
		var command = Sys.getEnv("RAYDE_SURFACE_APP"), dir = Sys.getEnv("RAYDE_SURFACE_DIR");
		if (command == null || command == "") { Sys.println("Surface preview snapshot: skipped, RAYDE_SURFACE_APP is not set"); return; }
		var root = Sys.getCwd() + "bin/surface-preview-" + Std.random(0x3fffffff), workspace = root + "/workspace", home = Sys.getEnv("HOME");
		for (path in [root + "/home", root + "/extensions", workspace]) sys.FileSystem.createDirectory(path);
		Sys.putEnv("HOME", root + "/home");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/extensions");
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), Dark);
		rayde.ui.Style.use();
		var compiler = new CompilerServer(), tree = new LayoutTree(), stop:Void->Void = null, bench:Workbench = null;
		bench = Owner.root(tree, cleanup -> {
			stop = cleanup;
			return new Workbench({display: new Display(compiler, workspace, []), name: "Surface preview"});
		});
		function settle(frames = 3):Void for (_ in 0...frames) {
			Offscreen.advance(1 / 60);
			Css.setViewport(1280, 800);
			Css.update();
			tree.flush();
			tree.computeLayout(bench.node, 1280, 800);
		}
		try {
			bench.openProject();
			settle(8);
			bench.runPart.previewSurface(command, dir);
			var pump = bench.runPart.surfacePreview;
			var waited = 0;
			while ((pump.feed.frames < 5 || Css.query(tree, bench.node.id, "#rayde-surface-preview").length == 0) && waited++ < 600) { settle(); Sys.sleep(.02); }
			if (pump.feed.frames < 5) Sys.println("app log: " + pump.takeLog().filter(l -> l.indexOf("[ash]") != 0 && l.indexOf("[promote]") != 0).slice(0, 12).join(" | ") + " failure=" + pump.failure + " finished=" + pump.finished() + " ready=" + pump.ready());
			check(pump.feed.frames >= 5, "No frames reached the tab");
			// RAYDE_SURFACE_SETTLE=N runs N more frames first, so the tab can finish resizing the app to its own size.
			for (_ in 0...(Std.parseInt(Sys.getEnv("RAYDE_SURFACE_SETTLE") ?? "0") ?? 0)) { settle(); Sys.sleep(.02); }
			Sys.println("size " + pump.size().width + "x" + pump.size().height + " frames " + pump.feed.frames + " outstanding " + pump.outstanding() + " finished " + pump.finished() + " failure " + pump.failure);
			settle(10);
			Snapshot.capture("surface-preview-running", tree, bench.node, 1280, 800);
			var views = Css.query(tree, bench.node.id, "#rayde-surface-preview canvas");
			check(views.length > 0, "The tab has no surface");
			var box = tree.getScrolledBounds(new Node(views[0]));
			check(box != null && box.width > 0, "The picture has no box");
			ashui.input.Pointer.move(tree, box.x + box.width * .25, box.y + box.height * .5);
			ashui.input.Pointer.press(tree);
			ashui.input.Pointer.release(tree);
			Sys.println("pressed at " + Std.int(box.x + box.width * .25) + "," + Std.int(box.y + box.height * .5) + " box " + box.width + "x" + box.height + " inputs sent " + pump.inputs);
			waited = 0;
			while (pump.feed.appliedInput < 1 && waited++ < 100) { settle(); Sys.sleep(.02); }
			Sys.println("applied " + pump.feed.appliedInput + " sent " + pump.inputs);
			check(pump.feed.appliedInput >= 1, "The press never reached the app");
			var frames = pump.feed.frames;
			waited = 0;
			while (pump.feed.frames < frames + 2 && waited++ < 60) { settle(); Sys.sleep(.02); }
			settle(6);
			Snapshot.capture("surface-preview-after-press", tree, bench.node, 1280, 800);
			Sys.println('Surface preview: ${pump.feed.frames} frames in the tab; a press in the picture was applied by the app (input ${pump.feed.appliedInput})');
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
