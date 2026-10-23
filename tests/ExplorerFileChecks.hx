import ashui.css.Css;
import ashui.css.Identity;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.FileIcons;
import rayde.ui.Icons;
import rayde.ui.Workbench;

@:access(rayde.ui.Workbench)
@:access(ashui.ui.Component)
class ExplorerFileChecks {
	static function main():Void {
		var root = Sys.getCwd() + "bin/explorer-files-" + Std.random(0x3fffffff);
		var dependency = root + "-dependency", library = root + "-library", unrelated = root + "-unrelated.md";
		for (path in [dependency, library]) {
			sys.FileSystem.createDirectory(path);
			sys.io.File.saveContent(path + "/README.md", "# Dependency\n");
			sys.io.File.saveContent(path + "/.env", "LOCAL=true\n");
		}
		sys.io.File.saveContent(unrelated, "Unrelated file");
		sys.FileSystem.createDirectory(root + "/src");
		sys.FileSystem.createDirectory(root + "/.config");
		sys.FileSystem.createDirectory(root + "/empty-extensions");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/empty-extensions");
		var files = ["z.HX", "a.py", "b.ts", "config.json", "rayzor.toml", "settings.yml", ".env", "Dockerfile", "unknown.custom", "README", "page.html", "theme.css"];
		for (name in files) sys.io.File.saveContent(root + "/src/" + name, "// " + name);
		sys.io.File.saveContent(root + "/.config/tool.conf", "enabled=true");
		sys.io.File.saveContent(root + "/build.hxml", "-cp src\n-cp ../" + haxe.io.Path.withoutDirectory(dependency) + "\n-lib fixture-dependency\n");
		var haxelib = root + "/haxelib-fixture";
		sys.io.File.saveContent(haxelib, '#!/bin/sh\ncase "$1" in\nlist) echo "fixture-dependency: [dev:fixture]";;\npath) echo "$library";;\nesac\n');
		Sys.command("chmod", ["+x", haxelib]);
		Sys.putEnv("RAYDE_HAXELIB", haxelib);
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), Dark); rayde.ui.Style.use();
		var compiler = new CompilerServer(), tree = new LayoutTree(), stop:Void->Void = null;
		var bench = Owner.root(tree, cleanup -> { stop = cleanup; return new Workbench({display:Display.ofProject(compiler, root + "/build.hxml"), name:"mixed files"}); });
		function settle():Void for (_ in 0...8) { ashui.core.render.Offscreen.advance(.03); Css.update(); tree.flush(); tree.computeLayout(bench.node, 1280, 800); }
		try {
			bench.openProject(); settle();
			if (Css.query(tree, bench.node.id, '[data-path="$dependency"]').length != 0) throw "External class path appeared in the workspace tree";
			var services = bench.services();
			if (services.readFile(dependency + "/README.md") != "# Dependency\n" || haxe.crypto.Base64.decode(services.readBytes(dependency + "/.env")).toString() != "LOCAL=true\n") throw "Declared dependency reads failed";
			function refused(run:Void->Void):String { try run() catch (error:Dynamic) return Std.string(error); throw "Expected path refusal"; }
			var denied = refused(() -> services.readFile(unrelated));
			if (denied.indexOf(unrelated) < 0 || denied.indexOf(root) < 0) throw "Read refusal omitted the requested path or workspace";
			refused(() -> services.writeFile(dependency + "/README.md", "overwritten"));
			if (sys.io.File.getContent(dependency + "/README.md") != "# Dependency\n") throw "Extension wrote outside the workspace";
			if (Sys.systemName() != "Windows") {
				Sys.command("ln", ["-s", unrelated, dependency + "/escape.md"]);
				refused(() -> services.readFile(dependency + "/escape.md"));
				Sys.command("ln", ["-s", library, root + "/linked-library"]);
				refused(() -> services.writeFile(root + "/linked-library/new.md", "escaped"));
				if (sys.FileSystem.exists(library + "/new.md")) throw "Extension wrote through a directory symlink";
			}
			function click(selector:String):Void {
				var found = Css.query(tree, bench.node.id, selector);
				if (found.length != 1) throw "Missing dependency row: " + selector;
				var bounds = tree.getScrolledBounds(new ashui.layout.Node(found[0]));
				ashui.input.Pointer.move(tree, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
				ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree); settle();
			}
			click("#rayde-explorer-toggle-dependencies");
			click("#rayde-library-" + haxe.crypto.Md5.encode(dependency) + " > .ui-tree-row");
			for (name in ["README.md", ".env"]) if (Css.query(tree, bench.node.id, "#rayde-library-file-" + haxe.crypto.Md5.encode(dependency + "/" + name)).length != 1) throw "Dependency hid " + name;
			click("#rayde-library-file-" + haxe.crypto.Md5.encode(dependency + "/README.md") + " > .ui-tree-row");
			if (bench.active.get() != dependency + "/README.md") throw "Selecting a dependency did not open its editor tab";
			var deadline = haxe.Timer.stamp() + 8;
			while (bench.dependencyReadRoots.indexOf(library) < 0 && haxe.Timer.stamp() < deadline) { settle(); Sys.sleep(.01); }
			if (services.readFile(library + "/README.md") != "# Dependency\n") throw "Resolved library source read failed";
			services.openFile(library + "/README.md"); settle();
			if (bench.active.get() != library + "/README.md") throw "Library source navigation failed";
			click("#rayde-explorer-toggle-dependencies");
			if (services.readFile(library + "/README.md") != "# Dependency\n") throw "Collapsing Dependencies revoked the active preview's source";
			for (name in files) if (Css.query(tree, bench.node.id, '[data-path="$root/src/$name"]').length != 1) throw "Explorer hid " + name;
			if (Css.query(tree, bench.node.id, '[data-path="$root/.config"]').length != 1) throw "Explorer hid dotfolder";
			var rows = bench.explorerEntries(root + "/src");
			if (rows[0].path != root + "/src/z.HX") throw "Haxe file priority was lost";
			var before = bench.active.get(); bench.openExplorerFile(root + "/.config");
			if (bench.active.get() != before) throw "Folder selection opened an editor";
			for (name in ["a.py", "config.json", ".env", "unknown.custom", "README"]) {
				var path = root + "/src/" + name;
				bench.openExplorerFile(path); settle();
				if (bench.active.get() != path || bench.editorFor(path) == null || bench.buffer(path).get() != "// " + name) throw "Cannot edit " + name;
			}
			if (FileIcons.of("unknown.custom") != Icons.FILE_CODE_LINE || FileIcons.of("a.py") != Icons.DEVICON_PYTHON || FileIcons.of("z.HX") != Icons.HAXE || FileIcons.of("settings.yml") != Icons.FILE_SETTINGS_LINE || FileIcons.of("page.HTML") != Icons.HTML5_LINE || FileIcons.of("theme.css") != Icons.CSS3_LINE || FileIcons.of(".env") != Icons.FILE_SETTINGS_LINE) throw "File icon mapping failed";
			for (extension in ["c", "cpp", "cs", "py", "ts", "rs", "go", "rb", "kt", "swift", "dart", "lua", "pl", "scala", "hs", "ex", "erl", "ml", "fs", "clj", "jl", "r", "zig", "elm", "nim", "f90", "coffee", "svelte", "nix", "gql", "tex", "m", "mm", "groovy", "sol"]) if (FileIcons.of("sample." + extension) == null) throw "Language SVG failed to load: " + extension;
			bench.closeAll();
			sys.io.File.saveContent(root + "/build.hxml", "-cp src\n"); bench.buildChanged(); settle();
			refused(() -> services.readFile(dependency + "/README.md"));
			refused(() -> services.readFile(library + "/README.md"));
		} catch (error:Dynamic) { stop(); tree.dispose(); compiler.stop(); throw error; }
		stop(); tree.dispose(); compiler.stop();
		Sys.println("explorer: mixed files and icons; external class paths in Dependencies; declared source reads/navigation; workspace-only writes; symlink escapes refused; resolved libraries survive panel collapse");
	}
}
