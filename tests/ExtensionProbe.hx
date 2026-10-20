import ashui.core.render.Snapshot;
import ashui.css.Css;
import rayde.ui.Workbench;

/** Measures complete extension opens and the longest uninterrupted UI turn. */
class ExtensionProbe {
	public static function run(bench:Workbench, file:String):Void {
		var renderer = Snapshot.renderer(), tree = bench.tree;
		var texture = renderer.createTexture(1280, 800);
		var target = texture.createView(new gpu.GpuTextureViewDescriptor());
		var last = haxe.Timer.stamp();
		var git = bench.extensionManager.find("git"), studio = bench.studioFor(git.connection.file);
		var stages:Array<Dynamic> = [];
		function stage(name:String, work:Void->Void):Float {
			var at = haxe.Timer.stamp(); work();
			var ms = (haxe.Timer.stamp() - at) * 1000;
			stages.push({name:name, ms:ms}); return ms;
		}
		function frame():Float {
			var start = haxe.Timer.stamp();
			stage("tick", () -> {
				var now = haxe.Timer.stamp(), elapsed = now - last; last = now;
				ashui.animation.AnimationScheduler.main.tick(Math.min(.1, elapsed), elapsed);
				ashui.theme.ThemeState.get().tick();
			});
			stage("css", () -> Css.update());
			stage("flush", () -> { tree.flush(); });
			stage("layout", () -> tree.computeLayout(bench.node, 1280, 800));
			stage("draw", () -> renderer.renderTree(tree, bench.node, target, 1280, 800));
			stage("gc", () -> ashui.core.Memory.afterFrame());
			return (haxe.Timer.stamp() - start) * 1000;
		}
		function measure(label:String, action:Void->Void, done:Void->Bool):Void {
			Sys.println("extension-phase:" + haxe.Json.stringify({phase:label, at:Sys.time()})); Sys.stdout().flush();
			stages = [];
			var start = haxe.Timer.stamp(), actionMs = stage("action", action), longest = actionMs;
			var ready = -1., frames = 0;
			while (haxe.Timer.stamp() - start < 30) {
				longest = Math.max(longest, frame()); frames++;
				var now = haxe.Timer.stamp();
				if (done() && ready < 0) ready = now;
				if (ready >= 0 && now - ready > .35) break;
				Sys.sleep(.006);
			}
			if (ready < 0) {
				Sys.println("extension-probe-timeout:" + haxe.Json.stringify({phase:label, side:bench.sideView.get(), nodes:tree.order().length,
					console:studio.console.get(), roots:studio.preview.roots.map(r -> {id:r.id, name:r.name, node:r.node == null ? null : Std.string(r.node.id)})}));
				throw 'extension probe timed out at $label';
			}
			var totals:Map<String, Float> = [], peaks:Map<String, Float> = [];
			for (s in stages) { totals.set(s.name, (totals.get(s.name) ?? 0) + s.ms); peaks.set(s.name, Math.max(peaks.get(s.name) ?? 0, s.ms)); }
			Sys.println("extension-probe:" + haxe.Json.stringify({phase:label, readyMs:(ready-start)*1000, worstTurnMs:longest,
				actionMs:actionMs, frames:frames, totals:[for (name => ms in totals) {name:name, ms:ms, maxMs:peaks.get(name)}],
				slow:stages.filter(s -> s.ms >= 16), nodes:tree.order().length})); Sys.stdout().flush();
		}
		function has(selector:String):Bool return Css.query(tree, bench.node.id, selector).length > 0;
		function text(selector:String):String {
			var parts = @:privateAccess studio.preview.parts;
			function content(id:Int):String {
				var p = parts.get(id);
				return p.text + [for (child in p.children) content(child)].join("");
			}
			for (p in parts) if (p.props.get("id") == selector.substr(1)) return content(p.host);
			return "";
		}
		function click(selector:String):Void {
			var ids = Css.query(tree, bench.node.id, selector);
			if (ids.length == 0) throw 'missing $selector';
			var b = tree.getScrolledBounds(new ashui.layout.Node(ids[0]));
			ashui.input.Pointer.move(tree, b.x+b.width/2, b.y+b.height/2);
			ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree);
		}
		measure("baseline", () -> {}, () -> true);
		var scm = @:privateAccess Lambda.find(bench.containers, c -> c.extension.id == "git" && c.location == "sidebar");
		measure("sidebar-cold", () -> bench.chooseContainer(scm), () -> has("#git-scm-canvas") && text("#git-scm-selection").indexOf("Fixture") >= 0);
		measure("graph-cold", () -> click("#git-scm-expand"), () -> text("#git-history-count") == "100 commits");
		var history = bench.active.get();
		measure("graph-close", () -> bench.closeFile(history), () -> studio.tabViews.length == 0);
		measure("graph-reopen", () -> click("#git-scm-expand"), () -> text("#git-history-count") == "100 commits");
		history = bench.active.get();
		var root = haxe.io.Path.directory(haxe.io.Path.directory(file));
		var readme = root + "/Preview.md";
		var mdSource = Sys.getEnv("RAYDE_PROBE_MARKDOWN") ?? "tests/fixtures/markdownpreview/README.md";
		sys.io.File.copy(mdSource, readme);
		function copy(from:String, to:String):Void {
			if (sys.FileSystem.isDirectory(from)) {
				sys.FileSystem.createDirectory(to);
				for (name in sys.FileSystem.readDirectory(from)) copy(from + "/" + name, to + "/" + name);
			} else sys.io.File.copy(from, to);
		}
		var assets = haxe.io.Path.join([haxe.io.Path.directory(mdSource), "assets"]);
		if (sys.FileSystem.exists(assets)) copy(assets, root + "/assets");
		sys.io.File.copy("tests/fixtures/markdownpreview/sample.svg", root + "/sample.svg");
		measure("markdown-cold", () -> { bench.extensionManager.command("markdown", "markdown.preview", {path:readme}); }, () -> has(".rayde-markdown"));
		var markdown = bench.active.get();
		measure("markdown-hide", () -> bench.active.set(history), () -> !has(".rayde-markdown"));
		measure("markdown-reopen", () -> bench.active.set(markdown), () -> has(".rayde-markdown"));
		measure("markdown-close", () -> bench.closeFile(markdown), () -> !has(".rayde-markdown"));
		measure("markdown-remount", () -> { bench.extensionManager.command("markdown", "markdown.preview", {path:readme}); }, () -> has(".rayde-markdown"));
		target.destroy(); texture.destroy();
	}
}
