import ashui.app.WindowedApp;
import ashui.animation.AnimationScheduler;
import ashui.layout.Element;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.FileIcons;
import rayde.ui.Workbench;

/** Footprint of the Explorer on this project: mode `full` shows it, `no-explorer` folds it away, `expanded` opens every folder, `icons` loads every file type's icon document in an otherwise empty window. */
@:access(rayde.ui.Workbench)
class ExplorerMemoryProbe {
	static final EXTENSIONS = ["7z", "aac", "adoc", "aiff", "avi", "avif", "bash", "bat", "bib", "bmp", "bz2", "c", "cc", "cer", "cfg", "cjs", "class", "clj", "cljc", "cljs", "cls", "cmd", "coffee", "conf", "config", "cpp", "crt", "cs", "css", "csv", "csx", "cts", "cxx", "dart", "db", "doc", "docx", "editorconfig", "edn", "elm", "erl", "ex", "exs", "f", "f03", "f08", "f90", "f95", "fish", "flac", "for", "fs", "fsi", "fsx", "gemspec", "gif", "go", "gql", "gradle", "graphql", "groovy", "gvy", "gz", "h", "heic", "hh", "hpp", "hrl", "hs", "htm", "html", "hx", "hxml", "hxx", "icns", "ico", "ini", "ipynb", "jar", "java", "jl", "jpe", "jpeg", "jpg", "js", "json", "json5", "jsonc", "jsx", "key", "kt", "kts", "less", "lhs", "litcoffee", "lock", "log", "lua", "m", "m4a", "m4v", "markdown", "mat", "md", "mdown", "mdx", "mid", "midi", "mjs", "mkd", "mkv", "ml", "mli", "mm", "mov", "mp3", "mp4", "mts", "nim", "nims", "nix", "odp", "ods", "odt", "ogg", "otf", "p12", "pdf", "pem", "pfx", "php", "phtml", "pl", "pm", "png", "pod", "ppt", "pptx", "properties", "ps1", "py", "pyi", "pyw", "r", "rake", "rar", "rayext", "rays", "raytheme", "rb", "rmd", "rs", "rst", "rtf", "sass", "sc", "scala", "scss", "sh", "sol", "sql", "sqlite", "sqlite3", "sty", "svelte", "svg", "swift", "tar", "tex", "tgz", "tif", "tiff", "toml", "ts", "tsv", "tsx", "ttf", "txt", "vue", "wav", "webm", "webp", "woff", "woff2", "xhtml", "xls", "xlsx", "xz", "yaml", "yml", "zig", "zip", "zon", "zsh"];
	static final NAMES = ["dockerfile", "makefile", "license", "package.json", ".env", ".gitignore"];

	static function heap():Float return hl.Gc.stats().currentMemory;

	static function expand(bench:Workbench, dir:String, depth:Int):Int {
		var count = 0;
		for (name in sys.FileSystem.readDirectory(dir)) {
			var path = dir + "/" + name;
			if (name == ".git" || name == ".deps" || name == "bin" || name == "target" || name == "node_modules" || !sys.FileSystem.isDirectory(path) || depth > 8) continue;
			bench.folderState(path, true).set(true);
			count += 1 + expand(bench, path, depth + 1);
		}
		return count;
	}

	static function main():Void {
		var mode = Sys.getEnv("WELCOME_MEMORY_MODE") ?? "full", root = Sys.getCwd();
		var server = new CompilerServer(), bench:Workbench = null, element:Element = null;
		rayde.ui.Theming.apply(rayde.settings.Appearance.read(root)); rayde.ui.Style.use();
		WindowedApp.run({title:"Explorer memory measurement · " + mode, width:1280, height:800, decorations:false, transparent:true,
			theme:rayde.ui.Theming.shown(rayde.settings.Appearance.read(root))}, () -> {
			var app = WindowedApp.current, folders = 0, icons:Dynamic = null;
			rayde.ui.GpuProgress.attach(app.device, app.tree, () -> app.frames);
			if (mode == "minimal" || mode == "icons") element = <div widthPercent={1} heightPercent={1} class="bg-background"/>;
			else {
				bench = new Workbench({display:Display.ofHxml(server, root + "/build.hxml"), name:"RayDE", runtime:"ash", chrome:rayde.ui.WindowChrome.ofApp()});
				if (mode == "no-explorer") bench.treeWidth.set(48);
				if (mode == "expanded") folders = expand(bench, root, 0);
				element = bench;
			}
			AnimationScheduler.main.after(6, () -> {
				if (bench != null) for (extension in bench.extensionManager.extensions) extension.connection.collect();
				if (mode == "icons") {
					hl.Gc.major(); var before = heap(), documents = [];
					for (extension in EXTENSIONS) { var icon = FileIcons.of("file." + extension); if (documents.indexOf(icon) < 0) documents.push(icon); }
					for (name in NAMES) { var icon = FileIcons.of(name); if (documents.indexOf(icon) < 0) documents.push(icon); }
					hl.Gc.major(); icons = {distinct:documents.length, heapBytes:heap() - before, perIcon:(heap() - before) / documents.length};
				}
				hl.Gc.major(); app.device.poll();
				AnimationScheduler.main.after(1, () -> {
					var gpu = 0, staging = 0, color = 0, rows = 0, parts:Array<String> = [];
					@:privateAccess {
						var renderer = app.offscreen.renderer;
						for (layer in renderer.layers) if (layer != null) { gpu += layer.width * layer.height * 4; parts.push("layer " + layer.width + "x" + layer.height); }
						for (target in [renderer.frameLayer, renderer.rows, renderer.shadow]) if (target != null) { gpu += target.width * target.height * 4; parts.push("target " + target.width + "x" + target.height); }
						for (atlas in [renderer.atlas, renderer.colorAtlas]) if (atlas != null) { gpu += atlas.textureWidth * atlas.textureHeight * atlas.bytesPerPixel; staging += atlas.pixels.length; parts.push("atlas " + atlas.textureWidth + "x" + atlas.textureHeight + "x" + atlas.bytesPerPixel); }
						if (renderer.colorAtlas != null) color = renderer.colorAtlas.textureWidth * renderer.colorAtlas.textureHeight * renderer.colorAtlas.bytesPerPixel;
						if (renderer.imageAtlas != null) { gpu += renderer.imageAtlas.size * renderer.imageAtlas.size * 4; parts.push("images " + renderer.imageAtlas.size); }
						gpu += renderer.recordRows * 2048 * 16; parts.push("recordRows " + renderer.recordRows);
					}
					if (bench != null) rows = ashui.css.Css.query(app.tree, bench.node.id, "[data-path]").length;
					Sys.println("welcome-memory:" + haxe.Json.stringify({mode:mode, nodes:app.tree.order().length, treeRows:rows, expandedFolders:folders,
						knownRendererTextureBytes:gpu, atlasStagingBytes:staging, colorAtlasBytes:color, gcHeapBytes:heap(), icons:icons, parts:parts,
						indexedPaths:bench == null ? 0 : bench.fileIndex.paths.length}));
					Sys.stdout().flush();
					var finish:Void->Void = null;
					finish = () -> {
						if (sys.FileSystem.exists(Sys.getEnv("WELCOME_MEMORY_ACK"))) app.quit();
						else AnimationScheduler.main.after(.1, finish);
					};
					AnimationScheduler.main.after(.1, finish);
				});
			});
			return element;
		});
		server.stop();
	}
}
