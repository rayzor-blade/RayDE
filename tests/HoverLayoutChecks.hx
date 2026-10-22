import ashui.css.Css;
import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.project.ProjectFile;
import rayde.ui.WorkspaceWindow;

class HoverLayoutChecks {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }
	public static function main():Void {
		for (dark in [true, false]) for (width in [1280, 800]) run(dark, width);
		Sys.println("Hover layout: nested native workspace root, GitIgnore signature/qualified name/docs, wrapping, scrolling and disposal in both themes and window widths");
	}

	static function run(dark:Bool, width:Int):Void {
		var root = Sys.getCwd() + "bin/hover-layout-" + Std.random(0x3fffffff);
		sys.FileSystem.createDirectory(root + "/empty-extensions"); sys.FileSystem.createDirectory(root + "/home");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/empty-extensions"); Sys.putEnv("HOME", root + "/home");
		var entry = ProjectFile.create(root, "hover", "hxml"), file = haxe.io.Path.directory(entry) + "/src/GitIgnore.hx";
		rayde.settings.Store.save(haxe.io.Path.directory(entry), "appearance", {scheme:dark ? "dark" : "light"});
		sys.io.File.saveContent(file, "class GitIgnore {}\n");
		var compiler = new CompilerServer(), tree = new LayoutTree(), stop:Void->Void = null;
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light); rayde.ui.Style.use();
		var host = Owner.root(tree, cleanup -> { stop = cleanup; return new WorkspaceWindow({initial:WorkspaceWindow.describe(compiler, entry), server:compiler}); });
		function settle():Void for (_ in 0...12) { Offscreen.advance(.02); Css.setViewport(width, 800); Css.update(); tree.flush(); tree.computeLayout(host.node, width, 800); }
		function nodes(selector:String) return Css.query(tree, host.node.id, selector);
		function bounds(selector:String) {
			var ids = nodes(selector); check(ids.length == 1, 'Missing or duplicate $selector'); return tree.getScrolledBounds(new ashui.layout.Node(ids[0]));
		}
		function shot(name:String):Void Snapshot.capture('hover-layout-${dark ? "dark" : "light"}-$width-$name', tree, host.node, width, 800, ashui.theme.ThemeState.get().color(Background).rgb());
		try {
			host.bench.openFile(file); settle(); var editor = host.bench.editorFor(file);
			check(nodes("#rayde")[0] != host.node.id, "Hover test must mount the workbench below the native window root");
			var source = sys.io.File.getContent("src/rayde/files/GitIgnore.hx"), start = source.indexOf("/**") + 3;
			var docs = [for (line in source.substring(start, source.indexOf("*/", start)).split("\n")) StringTools.trim(~/^\s*\* ?/.replace(line, ""))].join("\n");
			var markdown = "```haxe\nclass GitIgnore\n```\n\n*rayde.files.GitIgnore*\n\n" + docs;
			editor.showHint({from:6, to:15, renderDocs:() -> rayde.ui.HoverDocumentation.render({kind:"markdown", value:markdown})}, true); settle(); shot("gitignore");
			var code = bounds(".rayde-hover-markdown > .rayde-md-code"), paragraphs = nodes(".rayde-hover-markdown > .rayde-md-paragraph");
			check(paragraphs.length == 2, "GitIgnore hover lost the qualified name or documentation paragraph");
			var name = tree.getScrolledBounds(new ashui.layout.Node(paragraphs[0])), description = tree.getScrolledBounds(new ashui.layout.Node(paragraphs[1]));
			check(code.y + code.height <= name.y && name.y + name.height <= description.y, "Hover signature, qualified name and documentation overlap horizontally");
			check(description.height >= 60 && bounds(".rayde-hover-docs").width <= 411, "Hover documentation does not wrap to its bounded column");
			editor.hideHint(); settle(); check(nodes(".rayde-hover-docs").length == 0, "Closed hover retained its Markdown views");
			editor.showHint({from:6, to:15, renderDocs:() -> rayde.ui.HoverDocumentation.render({kind:"markdown", value:markdown + "\n\n" + [for (i in 0...40) 'Paragraph **$i** with `code` and [a link](https://haxe.org).'].join("\n\n")})}, true); settle();
			var body = bounds(".ui-code-hint-body"), scroll = ashui.input.Scroll.at(nodes(".ui-code-hint-body")[0], tree), editorY = editor.scroll.y.get();
			check(body.height <= 321 && scroll != null && scroll.limits().y > 0, "Long hover is not bounded and scrollable");
			ashui.input.Pointer.move(tree, body.x + 30, body.y + body.height - 20); ashui.input.Pointer.wheel(tree, 0, -10000); settle(); shot("scrolled");
			check(scroll.y.get() > 0 && editor.scroll.y.get() == editorY, "Hover wheel did not stay in the documentation popup");
		} catch (e:Dynamic) { stop(); tree.dispose(); compiler.stop(); throw e; }
		stop(); tree.dispose(); compiler.stop();
	}
}
