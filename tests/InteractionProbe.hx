import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import rayde.ui.Workbench;

/** Profiles first opens and retained tab switches without PNG readback allocations. */
class InteractionProbe {
	public static function run(bench:Workbench, file:String, ready:(Void->Bool)->String->Void):Void {
		var renderer = Snapshot.renderer();
		var scale = Std.parseFloat(Sys.getEnv("RAYDE_PROBE_SCALE") ?? "1");
		renderer.scale = scale;
		var texture = renderer.createTexture(Math.round(1280 * scale), Math.round(800 * scale));
		var target = texture.createView(new gpu.GpuTextureViewDescriptor());
		var tree = bench.tree;
		var folders = Std.parseInt(Sys.getEnv("RAYDE_PROBE_FOLDERS") ?? "0");
		if (folders != null && folders > 0) {
			for (i in 0...folders) {
				var dir = haxe.io.Path.directory(file) + '/ProbeFolder$i';
				sys.FileSystem.createDirectory(dir);
				for (j in 0...10) sys.io.File.saveContent(dir + '/File$j.hx', 'class File$j {}\n');
			}
			bench.refreshExplorer();
		}
		var frames = 0;
		var tickedAt = haxe.Timer.stamp();
		if (Sys.getEnv("RAYDE_PROBE_POLL") == "1") @:privateAccess bench.owner.run(() -> rayde.ui.GpuProgress.attach(renderer.device, tree, () -> frames));
		function emit(label:String, stages:Array<Dynamic>):Void {
			var count = 0, gpu = 0, cpu = 0;
			var watches = 0, editors = 0, disposedHosts = 0;
			@:privateAccess for (watch in ashui.reactive.Watch.bySlot) if (watch != null) watches++;
			@:privateAccess for (owner => component in ashui.ui.Component.hosts) {
				if (Type.getClassName(Type.getClass(component)) == "ashui.components.CodeEditor") editors++;
				if (owner.disposed) disposedHosts++;
			}
			var minimaps = Css.query(tree, bench.node.id, ".ui-code-minimap"), maps:Array<Dynamic> = [];
			@:privateAccess for (canvas in ashui.ui.Canvas.bySlot) {
				count++; gpu += canvas.painter.rows * 2048 * 16;
				if (canvas.painter.bytes != null) cpu += canvas.painter.bytes.length;
				var ancestors = tree.ancestors(canvas.node.id);
				if (Lambda.exists(minimaps, id -> ancestors.indexOf(id) >= 0)) maps.push({
					gpuBytes:canvas.painter.rows * 2048 * 16, uploadBytes:canvas.painter.bytes == null ? 0 : canvas.painter.bytes.length,
					vertices:canvas.painter.vertexCount});
			}
			var paths = Css.query(tree, bench.node.id, "#rayde-tree [data-path]"), pathBytes = 0;
			for (id in paths) pathBytes += ashui.css.Identity.of(tree, id).attribute("data-path").length * 2;
			Sys.println("interaction-probe:" + haxe.Json.stringify({phase:label, scheme:Std.string(ashui.theme.ThemeState.get().scheme()), stages:stages, haxe:hl.Gc.stats(),
				nodes:tree.order().length, canvases:count, canvasGpuBytes:gpu, canvasCpuBytes:cpu, primitives:renderer.primitives,
				layers:renderer.layerRecords, pointerHooks:ashui.input.Pointer.hooks.length,
				watches:watches, editors:editors, disposedComponentHosts:disposedHosts,
				minimaps:maps, explorer:{entries:paths.length, pathUtf16Bytes:pathBytes, nodes:Css.query(tree, bench.node.id, "#rayde-files *").length}}));
			Sys.stdout().flush();
			if (Sys.getEnv("RAYDE_PROBE_ACK") == "1") Sys.stdin().readLine();
		}
		function step(label:String, action:Void->Void):Void {
			var stages:Array<Dynamic> = [];
			function stage(name:String, work:Void->Void):Void {
				var before = hl.Gc.stats(), start = haxe.Timer.stamp();
				work();
				var elapsed = haxe.Timer.stamp() - start, after = hl.Gc.stats();
				stages.push({name:name, ms:elapsed * 1000, allocated:after.totalAllocated - before.totalAllocated, memory:after.currentMemory});
			}
			stage("action", action);
			for (frame in 0...3) {
				stage('advance-$frame', () -> {
					var now = haxe.Timer.stamp(), elapsed = now - tickedAt; tickedAt = now;
					ashui.animation.AnimationScheduler.main.tick(Math.min(.1, elapsed), elapsed);
					ashui.theme.ThemeState.get().tick();
				});
				stage('css-$frame', () -> Css.update());
				stage('flush-$frame', () -> { tree.flush(); });
				stage('layout-$frame', () -> tree.computeLayout(bench.node, 1280, 800));
				stage('draw-$frame', () -> { renderer.renderTree(tree, bench.node, target, 1280, 800); frames++; });
				stage('collect-$frame', () -> ashui.core.Memory.afterFrame());
			}
			emit(label, stages);
		}
		step("baseline", () -> {});
		hl.Gc.major(); emit("baseline-collected", []);
		var source = Sys.getEnv("RAYDE_PROBE_SOURCE");
		if (source != null && source != "") {
			var sample = haxe.io.Path.directory(file) + "/" + haxe.io.Path.withoutDirectory(source);
			sys.io.File.copy(source, sample);
			step("sample-open", () -> bench.openFile(sample));
			step("sample-close", () -> bench.closeFile(sample));
			step("idle", () -> Offscreen.advance(3));
			hl.Gc.major(); emit("collected", []);
			target.destroy(); texture.destroy();
			return;
		}
		var folder = haxe.io.Path.directory(file), files = [file];
		for (name in ["Names.hx", "Util.hx"]) {
			sys.io.File.copy("tests/fixtures/basic/src/" + name, folder + "/" + name);
			files.push(folder + "/" + name);
		}
		for (i in 0...7) {
			var path = folder + '/Probe$i.hx';
			sys.io.File.saveContent(path, 'class Probe$i {\n\tstatic function value():Int {\n\t\treturn $i;\n\t}\n}\n');
			files.push(path);
		}
		for (path in files) step("open-" + haxe.io.Path.withoutDirectory(path), () -> bench.openFile(path));
		var scm = @:privateAccess Lambda.find(bench.containers, c -> c.extension.id == "git" && c.location == "sidebar");
		step("open-sidebar", () -> bench.chooseContainer(scm));
		var git = bench.extensionManager.find("git"), studio = @:privateAccess bench.studios.get(git.connection.manifest.mainPath());
		ready(() -> studio.preview.outline().length > 10, "interaction sidebar");
		step("sidebar-ready", () -> {});
		step("open-history", () -> git.connection.command("git.history", null));
		ready(() -> studio.tabViews.length == 1, "interaction history");
		var history = bench.active.get();
		step("history-ready", () -> {});
		for (cycle in 0...3) {
			for (path in files.concat([history])) step('switch-$cycle-' + haxe.io.Path.withoutDirectory(path), () -> bench.active.set(path));
			step('explorer-$cycle', () -> bench.sideView.set("explorer"));
			step('sidebar-$cycle', () -> bench.sideView.set(scm.id));
		}
		step("open-tabs-idle", () -> Offscreen.advance(3));
		hl.Gc.major(); emit("open-tabs-collected", []);
		step("close-history", () -> bench.closeFile(history));
		ready(() -> studio.tabViews.length == 0, "interaction history disposal");
		step("close-editors", () -> {
			for (path in files) bench.closeFile(path);
			bench.sideView.set("explorer");
		});
		for (cycle in 0...3) {
			step('reopen-$cycle', () -> bench.openFile(file));
			step('reclose-$cycle', () -> bench.closeFile(file));
		}
		step("idle", () -> Offscreen.advance(3));
		hl.Gc.major(); emit("collected", []);
		hl.Gc.major(); emit("collected-twice", []);
		renderer.device.poll(); emit("gpu-polled", []);
		renderer.device.queueWorkDone(renderer.device.queue()).await();
		renderer.device.poll(); emit("gpu-drained", []);
		target.destroy(); texture.destroy();
	}
}
