import ashui.app.WindowedApp;
import ashui.animation.AnimationScheduler;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

/**
	Footprint of Markdown previews through their life: opened, closed, collected and left idle. One record per phase is printed
	for `tests/memory_probe.py`, which acknowledges each phase after sampling the process.
	`MARKDOWN_PROBE_FILES` previews (default 5) of `MARKDOWN_PROBE_SECTIONS` sections each (default 400) are opened one after another.
	`MARKDOWN_PROBE_SIMULATE=1` retains document payloads for the native-control comparison; omit it for tab-retention measurements.
**/
@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.CodeActionsPart)
@:access(rayde.ui.workbench.DebugPart)
@:access(rayde.ui.workbench.DocumentsPart)
@:access(rayde.ui.workbench.EditorMarksPart)
@:access(rayde.ui.workbench.EditorPart)
@:access(rayde.ui.workbench.ExplorerPart)
@:access(rayde.ui.workbench.ExtensionsPart)
@:access(rayde.ui.workbench.KeymapPart)
@:access(rayde.ui.workbench.LanguagesPart)
@:access(rayde.ui.workbench.MenusPart)
@:access(rayde.ui.workbench.PanelsPart)
@:access(rayde.ui.workbench.ProjectPart)
@:access(rayde.ui.workbench.RunPart)
@:access(rayde.ui.workbench.ShellPart)
@:access(rayde.ui.workbench.TerminalPart)
@:access(rayde.ui.workbench.ThemePart)
class MarkdownMemoryProbe {
	static function document(index:Int, sections:Int):String {
		var out = new StringBuf();
		out.add('# Preview $index\n\n');
		for (i in 0...sections) {
			out.add('## Section $i of document $index\n\n');
			out.add([for (w in 0...160) "word" + ((w * 7 + i) % 97)].join(" ") + " with `inline code`, **bold**, *emphasis* and a [link](https://example.test/$i).\n\n");
			out.add("- first item\n- second item\n- third item\n\n");
			out.add("| name | value | note |\n| --- | --- | --- |\n" + [for (r in 0...6) '| row $r | ${r * i} | text $r |'].join("\n") + "\n\n");
			out.add("```haxe\n" + [for (l in 0...12) '	var value$l = compute($i, $l); // line $l'].join("\n") + "\n```\n\n");
			if (i % 20 == 0) out.add("![picture](welcome.png)\n\n![vector](sample.svg)\n\n");
			if (i % 50 == 0) out.add("$$\\int_0^" + i + " x^2 dx$$\n\n```mermaid\ngraph TD\n  A-->B\n  B-->C\n```\n\n");
		}
		return out.toString();
	}

	static function main():Void {
		var cwd = Sys.getCwd(), root = cwd + "bin/markdown-memory-" + Std.random(0x3fffffff);
		var count = Std.parseInt(Sys.getEnv("MARKDOWN_PROBE_FILES") ?? "5"), sections = Std.parseInt(Sys.getEnv("MARKDOWN_PROBE_SECTIONS") ?? "400");
		sys.FileSystem.createDirectory(root);
		sys.FileSystem.createDirectory(root + "/src");
		sys.io.File.saveContent(root + "/build.hxml", "-cp src\n--main Main\n");
		sys.io.File.saveContent(root + "/src/Main.hx", "class Main { static function main() {} }\n");
		for (name in ["welcome.png", "sample.svg"]) sys.io.File.copy(cwd + "tests/fixtures/markdownpreview/" + name, root + "/" + name);
		for (i in 0...count) sys.io.File.saveContent(root + '/doc$i.md', document(i, sections));
		var server = new CompilerServer(), bench:Workbench = null;
		rayde.ui.Theming.apply(rayde.settings.Appearance.read(root)); rayde.ui.Style.use();
		WindowedApp.run({title:"Markdown memory measurement", width:1280, height:800, decorations:false, transparent:true,
			theme:rayde.ui.Theming.shown(rayde.settings.Appearance.read(root))}, () -> {
			var app = WindowedApp.current, ack = Sys.getEnv("WELCOME_MEMORY_ACK");
			bench = new Workbench({display:Display.ofHxml(server, root + "/build.hxml"), name:"markdown probe", runtime:"ash", chrome:rayde.ui.WindowChrome.ofApp()});
			function tabs():Array<String> return [for (t in bench.open.get()) if (StringTools.startsWith(t, Workbench.TAB)) t];
			function rendered():Int return ashui.css.Css.query(app.tree, bench.node.id, ".rayde-markdown").length;
			var steps:Array<{name:String, run:Void->Void, ready:Void->Bool, wait:Float}> = [];
			var captured:Array<Dynamic> = [], controls:Array<rayde.ext.BridgeControl> = [], holder = new ashui.ui.Div({});
			var vms = new Map<String, Dynamic>();
			for (key => studio in bench.extensionsPart.studios) {
				var previous = studio.connection.onMessage;
				studio.connection.onMessage = message -> {
					if (message.t == "collected") vms.set(key, message);
					if (previous != null) previous(message);
				};
			}
			function record(name:String):Void {
				var stats = hl.Gc.stats(), parts:Array<String> = [];
				for (key => studio in bench.extensionsPart.studios) {
					var activity = studio.activity.get(), console = studio.console.get(), chars = 0, logChars = 0;
					for (e in activity) chars += e.text.length;
					for (e in console) logChars += e.text.length;
					parts.push(haxe.io.Path.withoutDirectory(key) + ": activity " + activity.length + " entries " + chars + " chars; console " + console.length + " entries " + logChars + " chars; preview parts " + (studio.preview == null ? 0 : Lambda.count(@:privateAccess studio.preview.parts)));
				}
				var textures = 0, staging = 0, color = 0;
				@:privateAccess {
					var renderer = app.offscreen.renderer;
					for (layer in renderer.layers) if (layer != null) textures += layer.width * layer.height * 4;
					for (target in [renderer.frameLayer, renderer.rows, renderer.shadow]) if (target != null) textures += target.width * target.height * 4;
					for (atlas in [renderer.atlas, renderer.colorAtlas]) if (atlas != null) { textures += atlas.textureWidth * atlas.textureHeight * atlas.bytesPerPixel; staging += atlas.pixels.length; }
					if (renderer.colorAtlas != null) color = renderer.colorAtlas.textureWidth * renderer.colorAtlas.textureHeight * renderer.colorAtlas.bytesPerPixel;
					if (renderer.imageAtlas != null) textures += renderer.imageAtlas.size * renderer.imageAtlas.size * 4;
					textures += renderer.recordRows * 2048 * 16;
				}
				Sys.println("welcome-memory:" + haxe.Json.stringify({mode:name, nodes:app.tree.order().length, treeRows:tabs().length, expandedFolders:0, knownRendererTextureBytes:textures,
					atlasStagingBytes:staging, colorAtlasBytes:color, gcHeapBytes:stats.currentMemory, icons:null, parts:parts, indexedPaths:0,
					vmHeaps:[for (key => value in vms) {extension:key, stats:value}]}));
				Sys.stdout().flush();
				if (Sys.getEnv("MEMORY_PROBE_DUMP") == "1" && (name == "baseline" || name.indexOf("collected") >= 0)) hl.Gc.dumpMemory(ack + "." + name + ".heap");
			}
			steps.push({name:"baseline", run:() -> {}, ready:() -> true, wait:3});
			for (i in 0...count) steps.push({name:"open-" + (i + 1), run:() -> bench.extensionsPart.extensionManager.command("markdown", "markdown.preview", {path:root + '/doc$i.md'}),
				ready:() -> tabs().length == i + 1 && rendered() > 0, wait:2});
			steps.push({name:"capture", run:() -> {
				for (studio in bench.extensionsPart.studios) if (studio.preview != null) for (part in @:privateAccess studio.preview.parts) {
					var control:rayde.ext.BridgeControl = part.control;
					if (control != null && control.kind == "markdown-view") captured.push(@:privateAccess control.markdownSource);
				}
			}, ready:() -> true, wait:1});
			steps.push({name:"closed", run:() -> { for (t in tabs()) bench.closeFile(t); }, ready:() -> tabs().length == 0, wait:3});
			steps.push({name:"collected", run:() -> { for (extension in bench.extensionsPart.extensionManager.extensions) extension.connection.collect(); hl.Gc.major(); app.device.poll(); }, ready:() -> true, wait:3});
			steps.push({name:"sim-open", run:() -> {
				for (doc in captured) {
					var control = new rayde.ext.BridgeControl(app.tree, "markdown-view", (_, _) -> {}, null, null);
					control.set("document", doc); control.flush();
					app.tree.addChild(bench.node.id, control.node.id);
					controls.push(control);
				}
			}, ready:() -> true, wait:3});
			steps.push({name:"sim-closed", run:() -> {
				for (control in controls) { var id = control.node.id; control.dispose(); app.tree.removeSubtree(id); }
				controls = []; hl.Gc.major(); app.device.poll();
			}, ready:() -> true, wait:3});
			steps.push({name:"sim-collected", run:() -> { hl.Gc.major(); app.device.poll(); }, ready:() -> true, wait:3});
			steps.push({name:"idle-15s", run:() -> {}, ready:() -> true, wait:15});
			for (round in 2...4) {
				for (i in 0...count) steps.push({name:'round$round-open-' + (i + 1), run:() -> bench.extensionsPart.extensionManager.command("markdown", "markdown.preview", {path:root + '/doc$i.md'}),
					ready:() -> tabs().length == i + 1 && rendered() > 0, wait:2});
				steps.push({name:'round$round-closed', run:() -> { for (t in tabs()) bench.closeFile(t); }, ready:() -> tabs().length == 0, wait:3});
				steps.push({name:'round$round-collected', run:() -> { hl.Gc.major(); hl.Gc.major(); app.device.poll(); }, ready:() -> true, wait:3});
			}
			if (Sys.getEnv("MARKDOWN_PROBE_SIMULATE") != "1") steps = steps.filter(step -> step.name != "capture" && !StringTools.startsWith(step.name, "sim-"));
			var at = 0;
			function next():Void {
				if (at >= steps.length) { app.quit(); return; }
				var step = steps[at++], waited = 0.;
				step.run();
				function check():Void {
					waited += .1;
					if (!step.ready() && waited >= 60) throw "Probe phase timed out: " + step.name;
					if (!step.ready() && waited < 60) { AnimationScheduler.main.after(.1, check); return; }
					AnimationScheduler.main.after(step.wait, () -> {
						record(step.name);
						function acknowledged():Void {
							if (sys.FileSystem.exists(ack)) { sys.FileSystem.deleteFile(ack); next(); }
							else AnimationScheduler.main.after(.1, acknowledged);
						}
						acknowledged();
					});
				}
				check();
			}
			AnimationScheduler.main.after(2, next);
			return bench;
		});
		server.stop();
	}
}
