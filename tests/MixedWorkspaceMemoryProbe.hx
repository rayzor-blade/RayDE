import ashui.animation.AnimationScheduler;
import ashui.app.WindowedApp;
import ashui.css.Css;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.lang.LspProtocol;
import rayde.ui.Workbench;

private typedef Step = {name:String, run:Void->Void, ready:Void->Bool, wait:Float, sample:Bool};

/** Real workspace files and services, opened by group and closed in the same order. */
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
@:access(rayde.ext.Preview)
@:access(rayde.ext.BridgeControl)
@:access(rayde.lang.LanguageServers)
@:access(rayde.lang.LspClient)
@:access(ashui.ui.Component)
@:access(ashui.reactive.Owner)
@:access(ashui.reactive.Watch)
@:access(ashui.ui.Canvas)
@:access(rayde.ui.SvgDocuments)
class MixedWorkspaceMemoryProbe {
	static function main():Void {
		var root = haxe.io.Path.removeTrailingSlashes(Sys.getCwd()), compiler = new CompilerServer();
		var git = new sys.io.Process("git", ["-c", "core.quotepath=false", "ls-files"]);
		var paths = [for (name in git.stdout.readAll().toString().split("\n")) if (name != "" && sys.FileSystem.exists(name) && !sys.FileSystem.isDirectory(name)) root + "/" + name];
		git.stderr.readAll(); if (git.exitCode() != 0) throw "Cannot list workspace files"; git.close();
		function choose(extensions:Array<String>, count:Int, filter:String->Bool):Array<String> {
			var files = paths.filter(file -> extensions.indexOf(haxe.io.Path.extension(file).toLowerCase()) >= 0 && filter(file));
			files.sort((a,b) -> Reflect.compare(sys.FileSystem.stat(b).size, sys.FileSystem.stat(a).size));
			return files.slice(0, count);
		}
		var markdown = choose(["md", "markdown"], 16, file -> file.indexOf("/notices/") < 0);
		var haxeFiles = choose(["hx"], 32, _ -> true);
		var images = choose(["png", "jpg", "jpeg", "gif", "webp", "avif"], 8, _ -> true);
		var vectors = choose(["svg"], 8, _ -> true);
		if (markdown.length == 0 || haxeFiles.length == 0 || images.length == 0 || vectors.length == 0) throw "Workspace file inventory is empty";
		var ledger:Array<{kind:String, file:String}> = [], vms = new Map<String, Dynamic>();
		var failure:Null<String> = null;
		var requests = 0, replies = 0, answers = 0, lastRecent:Null<String> = null;
		var recent = root + "/.rayde/recent.txt", previousRecent = sys.FileSystem.exists(recent) ? sys.io.File.getContent(recent) : null;
		function rememberWritten():Void { if (sys.FileSystem.exists(recent)) lastRecent = sys.io.File.getContent(recent); }
		function restoreRecent():Void {
			if (lastRecent != null && sys.FileSystem.exists(recent) && sys.io.File.getContent(recent) == lastRecent) {
				if (previousRecent == null) sys.FileSystem.deleteFile(recent); else sys.io.File.saveContent(recent, previousRecent);
			}
		}
		var appearance = rayde.settings.Appearance.read(root);
		rayde.ui.Theming.apply(appearance); rayde.ui.Style.use();
		try WindowedApp.run({title:"RayDE workspace memory workload", width:1280, height:800, decorations:false, transparent:true,
			theme:rayde.ui.Theming.shown(appearance)}, () -> {
			var app = WindowedApp.current, ack = Sys.getEnv("WELCOME_MEMORY_ACK"), at = 0;
			function later(seconds:Float, work:Void->Void):Void {
				AnimationScheduler.main.after(seconds, () -> {
					try work() catch (error:Dynamic) { failure = Std.string(error); Sys.stderr().writeString("Mixed workload failed: " + failure + "\n"); app.quit(); }
				});
			}
			var bench = new Workbench({display:Display.ofProject(compiler, root + "/build.hxml"), name:"RayDE", runtime:"ash", chrome:rayde.ui.WindowChrome.ofApp()});
			// Leave session restoration off; the workload owns only the tabs it opens.
			for (key => studio in bench.extensionsPart.studios) {
				var previous = studio.connection.onMessage;
				studio.connection.onMessage = message -> { if (message.t == "collected") vms.set(key, message); if (previous != null) previous(message); };
			}
			function count<T>(values:Iterator<T>):Int { var total = 0; for (_ in values) total++; return total; }
			function gitStudio():rayde.ext.Studio return Lambda.find([for (studio in bench.extensionsPart.studios) studio], studio -> studio.manifest != null && studio.manifest.id == "git");
			function control(id:String):rayde.ext.BridgeControl {
				var studio = gitStudio();
				if (studio == null || studio.preview == null) return null;
				for (part in studio.preview.parts) if (part.props.get("id") == id) return part.control;
				return null;
			}
			function lspPending():Int {
				var pending = 0; for (entry in bench.languagesPart.languageServers.entries) pending += count(entry.client.pending.iterator()); return pending;
			}
			function sample(name:String):Void {
				var canvases = 0, canvasCpu = 0, canvasGpu = 0, editors = 0, watches = 0, owners = 0, textures = 0, staging = 0, color = 0, imageAtlas = 0;
				@:privateAccess for (canvas in ashui.ui.Canvas.bySlot) { canvases++; canvasGpu += canvas.painter.rows * 2048 * 16; if (canvas.painter.bytes != null) canvasCpu += canvas.painter.bytes.length; }
				for (owner => component in ashui.ui.Component.hosts) if (!owner.disposed) { owners++; if (Std.isOfType(component, ashui.components.CodeEditor)) editors++; }
				for (watch in ashui.reactive.Watch.bySlot) if (watch != null) watches++;
				@:privateAccess {
					var renderer = app.offscreen.renderer;
					for (layer in renderer.layers) if (layer != null) textures += layer.width * layer.height * 4;
					for (target in [renderer.frameLayer, renderer.rows, renderer.shadow]) if (target != null) textures += target.width * target.height * 4;
					for (atlas in [renderer.atlas, renderer.colorAtlas]) if (atlas != null) { textures += atlas.textureWidth * atlas.textureHeight * atlas.bytesPerPixel; staging += atlas.pixels.length; }
					if (renderer.colorAtlas != null) color = renderer.colorAtlas.textureWidth * renderer.colorAtlas.textureHeight * renderer.colorAtlas.bytesPerPixel;
					if (renderer.imageAtlas != null) { imageAtlas = renderer.imageAtlas.size * renderer.imageAtlas.size * 4; textures += imageAtlas; }
					textures += renderer.recordRows * 2048 * 16;
				}
				var servers:Array<Dynamic> = [];
				for (entry in bench.languagesPart.languageServers.entries) {
					var client = entry.client, chars = 0, indexing = 0;
					for (doc in client.documents) chars += doc.text.length;
					for (file in client.files()) if (client.indexing(file)) indexing++;
					servers.push({id:entry.id, command:client.config.command, state:client.state, documents:client.files().length, documentCharacters:chars, pending:count(client.pending.iterator()), indexing:indexing});
				}
				var parts:Array<Dynamic> = [];
				for (key => studio in bench.extensionsPart.studios) { var chars = 0, logChars = 0; for (entry in studio.activity.get()) chars += entry.text.length;
					for (entry in studio.console.get()) logChars += entry.text.length;
					parts.push({extension:studio.manifest == null ? key : studio.manifest.id, roots:studio.tabViews.length, parts:studio.preview == null ? 0 : studio.preview.count(), activityCharacters:chars, consoleEntries:studio.console.get().length, consoleCharacters:logChars}); }
				var heap = hl.Gc.stats();
				Sys.println("welcome-memory:" + haxe.Json.stringify({mode:name, workspace:root, build:root + "/build.hxml", tabs:bench.open.get().copy(), dirty:bench.dirty.get().copy(),
					nodes:app.tree.order().length, editors:editors, owners:owners, watches:watches, canvases:canvases, canvasCpuBytes:canvasCpu, canvasGpuBytes:canvasGpu,
					gcHeapBytes:heap.currentMemory, totalAllocatedBytes:heap.totalAllocated, knownRendererTextureBytes:textures, atlasStagingBytes:staging, colorAtlasBytes:color, imageAtlasBytes:imageAtlas,
					editorRows:Css.query(app.tree,bench.node.id,".ui-code-line").length, editorTokens:Css.query(app.tree,bench.node.id,".ui-code-token").length, problems:bench.problems.get().length,
					buffers:count(bench.documentsPart.buffers.iterator()), documents:count(bench.documentsPart.documents.iterator()), editorRefs:count(bench.editorPart.editorRefs.iterator()), syntax:count(bench.editorPart.nativeSyntax.iterator()), images:count(bench.editorPart.imageViews.iterator()),
					ownedSvgDocuments:count(rayde.ui.SvgDocuments.owned.iterator()), lsp:servers, lspRequests:requests, lspReplies:replies, lspAnswers:answers, parts:parts,
					vmHeaps:[for (key => value in vms) {extension:key, stats:value}]})); Sys.stdout().flush();
				if (Sys.getEnv("MEMORY_PROBE_DUMP") == "1" && (name == "baseline" || name.indexOf("collected") >= 0)) hl.Gc.dumpMemory(ack + "." + name + ".heap");
			}
			var steps:Array<Step> = [];
			function step(name:String, run:Void->Void, ready:Void->Bool, wait = .8, sample = false):Void steps.push({name:name, run:run, ready:ready, wait:wait, sample:sample});
			function collect():Void { for (extension in bench.extensionsPart.extensionManager.extensions) extension.connection.collect(); hl.Gc.major(); app.device.poll(); }
			function checkpoint(name:String):Void { step(name, () -> {}, () -> true, 2, true); step(name + "-collected", collect, () -> true, 2, true); }
			step("baseline", collect, () -> bench.extensionsPart.extensionManager.find("markdown") != null && bench.languagesPart.languageServers.status(haxeFiles[0]) != null, 3, true);
			for (file in markdown) {
				var previous:Array<String> = [];
				step("open-markdown:" + file, () -> { previous = bench.open.get().copy(); bench.extensionsPart.extensionManager.command("markdown", "markdown.preview", {path:file}); },
					() -> { var tabs = bench.open.get().filter(tab -> previous.indexOf(tab) < 0); if (tabs.length != 1 || Css.query(app.tree, bench.node.id, ".rayde-markdown").length == 0) return false;
						if (!Lambda.exists(ledger, entry -> entry.file == tabs[0])) ledger.push({kind:"markdown", file:tabs[0]}); return true; }, .7);
			}
			checkpoint("markdown-open");
			for (file in haxeFiles) {
				var issued = false;
				step("open-haxe:" + file, () -> { bench.openFile(file); rememberWritten(); ledger.push({kind:"haxe", file:file}); }, () -> {
					var client = bench.languagesPart.languageServers.client(file);
					if (client == null || client.state != "ready" || bench.editorFor(file) == null) return false;
					if (!issued) { issued = true; requests++; client.request("textDocument/documentSymbol", {textDocument:{uri:LspProtocol.uri(file)}}, result -> { replies++; if (result != null) answers++; }, file + "#memory-probe", 90); }
					return true;
				}, .3);
			}
			step("lsp-requests-drained", () -> {}, () -> lspPending() == 0 && requests == replies, 3, true);
			checkpoint("haxe-open");
			step("git-sidebar-open", () -> {
				var container = Lambda.find(bench.extensionsPart.containers, c -> c.extension.id == "git" && c.view.id == "scm");
				if (container == null) throw "Git SCM container is missing"; bench.shellPart.chooseContainer(container);
			}, () -> { var canvas = control("git-scm-canvas"); return canvas != null && canvas.scene.get().labels.length > 0; }, 2, true);
			step("git-graph-open", () -> bench.extensionsPart.extensionManager.command("git", "git.history", null), () -> {
				var studio = gitStudio(), canvas = control("git-history-canvas");
				if (studio == null || studio.tabViews.length != 1 || canvas == null || canvas.scene.get().labels.length == 0) return false;
				if (!Lambda.exists(ledger, e -> e.kind == "graph")) ledger.push({kind:"graph", file:bench.active.get()}); return true;
			}, 2, true);
			for (file in images.concat(vectors)) step("open-image:" + file, () -> { bench.openFile(file); rememberWritten(); ledger.push({kind:"image", file:file}); },
				() -> { if (Css.query(app.tree, bench.node.id, "#rayde-image-error").length > 0) throw "Image preview failed: " + file; return Css.query(app.tree, bench.node.id, "#rayde-image-surface").length > 0; }, .7);
			checkpoint("all-open");
			step("all-open-code-active", () -> bench.active.set(haxeFiles[haxeFiles.length-1]), () -> bench.editorFor(haxeFiles[haxeFiles.length-1]) != null, 5, true);
			step("all-open-code-collected", collect, () -> true, 3, true);
			step("all-open-image-restored", () -> bench.active.set(vectors[vectors.length-1]), () -> Css.query(app.tree,bench.node.id,"#rayde-image-surface").length > 0, 2, true);
			for (kind in ["markdown", "haxe", "sidebar", "graph", "image"]) {
				if (kind == "sidebar") step("git-sidebar-closed", () -> bench.sideView.set("explorer"), () -> Css.query(app.tree, bench.node.id, "#git-scm").length == 0, 2, true);
				else {
					var files = kind == "markdown" ? markdown : kind == "haxe" ? haxeFiles : kind == "image" ? images.concat(vectors) : ["graph"];
					for (_ in files) {
						var closing = "";
						step("close-" + kind, () -> {
							var entry = Lambda.find(ledger, e -> e.kind == kind && bench.open.get().indexOf(e.file) >= 0);
							if (entry == null) throw "Missing open tab for " + kind;
							closing = entry.file;
							if (bench.dirty.get().indexOf(closing) >= 0) throw "Refusing to close an unsaved file: " + closing;
							Sys.println("mixed-action:" + haxe.Json.stringify({action:"close", kind:kind, file:closing})); bench.closeFile(closing);
						}, () -> bench.open.get().indexOf(closing) < 0, .25);
					}
					checkpoint(kind + "-closed");
				}
			}
			step("closed-idle-30s", () -> {}, () -> bench.open.get().length == 0, 30, true);
			step("closed-idle-collected", collect, () -> true, 3, true);
			step("lsp-stopped", () -> { for (entry in bench.languagesPart.languageServers.entries) bench.languagesPart.languageServers.control(entry.id, "stop"); },
				() -> Lambda.foreach(bench.languagesPart.languageServers.entries, e -> e.client.state == "stopped"), 2, true);
			step("after-lsp-stop-collected", collect, () -> true, 3, true);
			Sys.println("mixed-plan:" + haxe.Json.stringify({markdown:markdown, haxe:haxeFiles, images:images, svg:vectors})); Sys.stdout().flush();
			function next():Void {
				if (at >= steps.length) { app.quit(); return; }
				var current = steps[at++], start = haxe.Timer.stamp();
				Sys.println("mixed-action:" + haxe.Json.stringify({action:"start", phase:current.name})); Sys.stdout().flush(); current.run();
				function check():Void {
					if (!current.ready()) {
						if (haxe.Timer.stamp() - start > 180) throw "Mixed workload timed out: " + current.name;
						later(.1, check); return;
					}
					later(current.wait, () -> {
						if (!current.sample) { next(); return; }
						sample(current.name);
						var until = haxe.Timer.stamp() + 90;
						function acknowledged():Void {
							if (sys.FileSystem.exists(ack)) { sys.FileSystem.deleteFile(ack); next(); }
							else if (haxe.Timer.stamp() > until) throw "Sampler timeout";
							else later(.1, acknowledged);
						}
						acknowledged();
					});
				}
				check();
			}
			later(1, next); return bench;
		}) catch (error:Dynamic) { compiler.stop(); restoreRecent(); throw error; }
		compiler.stop();
		restoreRecent();
		if (failure != null) throw failure;
	}
}
