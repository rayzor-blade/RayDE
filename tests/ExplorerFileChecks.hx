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
		sys.FileSystem.createDirectory(root + "/src");
		sys.FileSystem.createDirectory(root + "/.config");
		sys.FileSystem.createDirectory(root + "/empty-extensions");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/empty-extensions");
		var files = ["z.HX", "a.py", "b.ts", "config.json", "rayzor.toml", "settings.yml", ".env", "Dockerfile", "unknown.custom", "README", "page.html", "theme.css"];
		for (name in files) sys.io.File.saveContent(root + "/src/" + name, "// " + name);
		sys.io.File.saveContent(root + "/.config/tool.conf", "enabled=true");
		sys.io.File.saveContent(root + "/build.hxml", "-cp src\n");
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), Dark); rayde.ui.Style.use();
		var compiler = new CompilerServer(), tree = new LayoutTree(), stop:Void->Void = null;
		var bench = Owner.root(tree, cleanup -> { stop = cleanup; return new Workbench({display:Display.ofProject(compiler, root + "/build.hxml"), name:"mixed files"}); });
		function settle():Void for (_ in 0...8) { ashui.core.render.Offscreen.advance(.03); Css.update(); tree.flush(); tree.computeLayout(bench.node, 1280, 800); }
		try {
			bench.openProject(); settle();
			for (name in files) if (Css.query(tree, bench.node.id, '[data-path="$root/src/$name"]').length != 1) throw "Explorer hid " + name;
			if (Css.query(tree, bench.node.id, '[data-path="$root/.config"]').length != 1) throw "Explorer hid dotfolder";
			var rows = bench.owner.run(() -> bench.folderEntries(root + "/src"));
			if (Identity.of(tree, rows[0].node.id).attribute("data-path") != root + "/src/z.HX") throw "Haxe file priority was lost";
			var before = bench.active.get(); bench.openExplorerFile(root + "/.config");
			if (bench.active.get() != before) throw "Folder selection opened an editor";
			for (name in ["a.py", "config.json", ".env", "unknown.custom", "README"]) {
				var path = root + "/src/" + name;
				bench.openExplorerFile(path); settle();
				if (bench.active.get() != path || bench.editorFor(path) == null || bench.buffer(path).get() != "// " + name) throw "Cannot edit " + name;
			}
			if (FileIcons.of("unknown.custom") != Icons.FILE_CODE_LINE || FileIcons.of("a.py") != Icons.DEVICON_PYTHON || FileIcons.of("z.HX") != Icons.HAXE || FileIcons.of("settings.yml") != Icons.FILE_SETTINGS_LINE || FileIcons.of("page.HTML") != Icons.HTML5_LINE || FileIcons.of("theme.css") != Icons.CSS3_LINE || FileIcons.of(".env") != Icons.FILE_SETTINGS_LINE) throw "File icon mapping failed";
			for (extension in ["c", "cpp", "cs", "py", "ts", "rs", "go", "rb", "kt", "swift", "dart", "lua", "pl", "scala", "hs", "ex", "erl", "ml", "fs", "clj", "jl", "r", "zig", "elm", "nim", "f90", "coffee", "svelte", "nix", "gql", "tex", "m", "mm", "groovy", "sol"]) if (FileIcons.of("sample." + extension) == null) throw "Language SVG failed to load: " + extension;
		} catch (error:Dynamic) { stop(); tree.dispose(); compiler.stop(); throw error; }
		stop(); tree.dispose(); compiler.stop();
		Sys.println("explorer: all file types, dotfiles/folders, Haxe priority, folder selection, editable unknown files and Remix icon fallback");
	}
}
