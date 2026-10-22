import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.build.RayzorFile;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

@:access(rayde.ui.Workbench)
class RayzorSampleViews {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }
	public static function main():Void {
		RayzorSamplesChecks.main();
		var repo = sys.FileSystem.fullPath(Sys.args().length == 0 ? "../rayzor" : Sys.args()[0]);
		var scratch = Sys.getCwd() + "bin/rayzor-sample-views-" + Std.random(0x3fffffff);
		sys.FileSystem.createDirectory(scratch + "/empty-extensions"); sys.FileSystem.createDirectory(scratch + "/home");
		Sys.putEnv("RAYDE_EXTENSIONS", scratch + "/empty-extensions"); Sys.putEnv("HOME", scratch + "/home");
		for (dark in [true, false]) for (sample in ["nue", "nue/examples/llama-chat", "rayzor-tensors", "examples/demo-workspace", "examples/demo-workspace/mathlib", "examples/wasm-features", "examples/tink-json"])
			run(repo, scratch + (dark ? "/dark/" : "/light/"), sample, dark);
		Sys.println("Rayzor sample views: Nue library, llama-chat native plugins/tier config, tensor library, demo workspace/library, WASM and tink-json forms in both themes; edits preserve advanced settings and leave originals untouched");
	}

	static function run(repo:String, scratch:String, sample:String, dark:Bool):Void {
		var original = repo + "/" + sample + "/rayzor.toml", source = sys.io.File.getContent(original), root = scratch + sample;
		sys.FileSystem.createDirectory(root); var entry = root + "/rayzor.toml"; sys.io.File.saveContent(entry, source);
		var before = new RayzorFile(entry), compiler = new CompilerServer(), display = Display.ofProject(compiler, entry), tree = new LayoutTree(), stop:Void->Void = null;
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light); rayde.ui.Style.use();
		var bench = Owner.root(tree, cleanup -> { stop = cleanup; return new Workbench({display:display, name:display.project.name, runtime:"rayzor"}); });
		function settle():Void for (_ in 0...8) { ashui.core.render.Offscreen.advance(.03); Css.update(); tree.flush(); tree.computeLayout(bench.node, 1280, 800); }
		function node(selector:String):ashui.layout.Node {
			var ids = Css.query(tree, bench.node.id, selector); check(ids.length == 1, sample + ": missing or duplicated " + selector); return new ashui.layout.Node(ids[0]);
		}
		function scrollTo(selector:String):Void {
			var scroll = ashui.input.Scroll.at(node("#rayde-rayzor-build").id, tree), at = tree.getScrolledBounds(node(selector));
			var frame = tree.getScrolledBounds(node("#rayde-rayzor-build"));
			scroll.scrollTo(0, scroll.y.get() + at.y - frame.y - 24); settle();
		}
		function click(selector:String):Void {
			scrollTo(selector); var at = tree.getScrolledBounds(node(selector));
			ashui.input.Pointer.move(tree, at.x + at.width / 2, at.y + at.height / 2); ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree); settle();
		}
		function shot(suffix:String):Void ashui.core.render.Snapshot.capture('rayzor-sample-${dark ? "dark" : "light"}-${sample.split("/").join("-")}-$suffix', tree, bench.node, 1280, 800, ashui.theme.ThemeState.get().color(Background).rgb());
		try {
			bench.openProject(); settle(); bench.openExplorerFile(entry); settle();
			check(bench.active.get() == Workbench.SETTINGS && Css.query(tree, bench.node.id, "#rayde-rayzor-error").length == 0, sample + ": form failed to open");
			check((Css.query(tree, bench.node.id, "#rayde-run").length > 0) == display.project.runnable, sample + ": wrong Run visibility");
			node(before.workspace() ? "#rayde-rayzor-workspace-section" : "#rayde-rayzor-project-section"); shot("build");
			var libraries = before.strings(["build", "native-libs"]);
			if (libraries.length > 0) {
				var labels = Css.query(tree, bench.node.id, "#rayde-rayzor-native-libs-section .rayde-setting-row text");
				check(labels.length == libraries.length, sample + ": native library rows missing");
				for (i in 0...libraries.length) check(ashui.ui.Text.at(labels[i]).text() == libraries[i], sample + ": native library path changed");
				scrollTo("#rayde-rayzor-native-libs-section"); shot("native-libraries");
			}
			var selector = before.workspace() ? "#rayde-rayzor-workspace-cache-dir" : "#rayde-rayzor-project-version";
			click(selector); ashui.ui.Input.at(tree, node(selector).id).value.set(before.workspace() ? ".test-cache" : "0.2.0");
			var mods = window.Modifiers.State(false, false, false, false, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown);
			for (state in [window.MouseElementState.Pressed, window.MouseElementState.Released]) ashui.input.Keyboard.input(tree, window.KeyEvent.Input(Unidentified(Unidentified), Named(Enter), None, Standard, state, false, Unavailable), mods);
			settle(); var after = new RayzorFile(entry);
			check(after.text(before.workspace() ? ["workspace", "cache", "dir"] : ["project", "version"]) == (before.workspace() ? ".test-cache" : "0.2.0"), sample + ": form change was not saved");
			for (path in [["project", "type"], ["tier"], ["dependencies"], ["wasm"], ["lib"], ["build"]])
				check(haxe.Json.stringify(before.value(path)) == haxe.Json.stringify(after.value(path)), sample + ": editing lost " + path.join("."));
			click("#rayde-rayzor-edit-text"); check(bench.active.get() == entry && bench.editorFor(entry) != null, sample + ": source editing unavailable");
			check(sys.io.File.getContent(original) == source, sample + ": original manifest changed");
		} catch (e:Dynamic) { stop(); tree.dispose(); compiler.stop(); throw e; }
		stop(); tree.dispose(); compiler.stop();
	}
}
