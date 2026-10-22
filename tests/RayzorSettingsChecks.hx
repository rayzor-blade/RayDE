import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.build.RayzorFile;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.project.ProjectFile;
import rayde.ui.Workbench;

@:access(rayde.ui.Workbench)
class RayzorSettingsChecks {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }
	public static function main():Void {
		for (dark in [true, false]) run(dark, false);
		run(true, true);
		Sys.println("Rayzor settings: Explorer routing, form edits, TOML preservation, compiler reload, text editing, unsaved protection, workspace members and malformed source recovery");
	}

	static function run(dark:Bool, workspace:Bool):Void {
		var root = Sys.getCwd() + "bin/rayzor-settings-" + Std.random(0x3fffffff);
		sys.FileSystem.createDirectory(root + "/empty-extensions");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/empty-extensions");
		Sys.putEnv("HOME", root + "/home");
		sys.FileSystem.createDirectory(root + "/home");
		var entry = ProjectFile.create(root, "test-app", "rayzor");
		var source = workspace ? "# workspace\n[workspace]\nmembers = ['app']\n" : sys.io.File.getContent(entry) + "\n[dependencies]\nexample = { path = '../example' } # keep dependency\n[tier]\nverbosity = 1 # keep tier\n";
		sys.io.File.saveContent(entry, source);
		var compiler = new CompilerServer(), display = Display.ofProject(compiler, entry), tree = new LayoutTree(), stop:Void->Void = null;
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light); rayde.ui.Style.use();
		var bench = Owner.root(tree, cleanup -> { stop = cleanup; return new Workbench({display:display, name:display.project.name, runtime:"rayzor"}); });
		function settle(frames = 8):Void for (_ in 0...frames) {
			ashui.core.render.Offscreen.advance(.03); Css.update(); tree.flush(); tree.computeLayout(bench.node, 1280, 800);
		}
		function count(selector:String):Int return Css.query(tree, bench.node.id, selector).length;
		function node(selector:String):ashui.layout.Node {
			var ids = Css.query(tree, bench.node.id, selector); check(ids.length == 1, 'Missing or duplicate control: $selector');
			return new ashui.layout.Node(ids[0]);
		}
		function click(selector:String):Void {
			var target = node(selector), area = Css.query(tree, bench.node.id, "#rayde-rayzor-build");
			if (area.length > 0 && selector != "#rayde-rayzor-build") {
				var scroll = ashui.input.Scroll.at(area[0], tree), box = tree.getScrolledBounds(target), frame = tree.getScrolledBounds(new ashui.layout.Node(area[0]));
				scroll.scrollTo(0, scroll.y.get() + box.y + box.height / 2 - frame.y - frame.height / 2); settle(2);
			}
			var box = tree.getScrolledBounds(target);
			ashui.input.Pointer.move(tree, box.x + box.width / 2, box.y + box.height / 2);
			ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree); settle();
		}
		function press(key:window.Key):Void {
			var mods = window.Modifiers.State(false, false, false, false, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown);
			for (state in [window.MouseElementState.Pressed, window.MouseElementState.Released])
				ashui.input.Keyboard.input(tree, window.KeyEvent.Input(Unidentified(Unidentified), key, None, Standard, state, false, Unavailable), mods);
			settle();
		}
		function type(selector:String, text:String, commit = true):Void {
			click(selector); ashui.ui.Input.at(tree, node(selector).id).value.set(text); settle(2);
			if (commit) press(Named(Enter));
		}
		function shot(name:String):Void ashui.core.render.Snapshot.capture('rayzor-settings-${dark ? "dark" : "light"}-$name', tree, bench.node, 1280, 800, ashui.theme.ThemeState.get().color(Background).rgb());
		function read():RayzorFile return new RayzorFile(entry);
		try {
			bench.openProject(); settle();
			bench.openExplorerFile(entry); settle();
			check(bench.active.get() == Workbench.SETTINGS && bench.settingsSection() == "build" && count("#rayde-rayzor-build") == 1 && bench.editorFor(entry) == null, "Explorer did not open the Rayzor settings form");
			shot(workspace ? "workspace" : "project");
			if (workspace) {
				check(count("#rayde-rayzor-project-name") == 0, "Workspace shows project-only settings");
				type("#rayde-rayzor-workspace-members-new", "tools");
				check(read().strings(["workspace", "members"]).join(",") == "app,tools", "Workspace member was not saved");
				type("#rayde-rayzor-workspace-cache-dir", ".shared-cache");
				check(read().text(["workspace", "cache", "dir"]) == ".shared-cache", "Workspace cache directory was not saved");
			} else {
				type("#rayde-rayzor-project-name", "My app λ");
				check(read().text(["project", "name"]) == "My app λ" && display.project.name == "My app λ", "Project name was not written and reloaded");
				click("#rayde-rayzor-build-target"); press(Named(End)); press(Named(Enter));
				check(read().text(["build", "target"]) == "bundle", "Target selection did not save");
				click("#rayde-rayzor-build-opt-level"); press(Named(End)); press(Named(Enter));
				check(read().value(["build", "opt-level"]) == 3, "Optimization was not saved as a number");
				type("#rayde-rayzor-build-class-paths-new", "lib code");
				check(display.args.indexOf("lib code") >= 0, "Class paths did not reload compiler inputs");
				type("#rayde-rayzor-define-name", "feature.name", false);
				type("#rayde-rayzor-define-value", "hello world", false); click("#rayde-rayzor-define-add");
				check(display.args.indexOf("feature.name=hello world") >= 0, "Quoted define name or value was lost");
				click("#rayde-rayzor-cache-enabled"); press(Named(End)); press(Named(Enter));
				check(read().value(["cache", "enabled"]) == false, "Cache setting was not saved as a boolean");
				shot("cache");
				var hxml = display.cwd + "/editor.hxml";
				sys.io.File.saveContent(hxml, "-cp alternate-src\n-main Main\n");
				type("#rayde-rayzor-project-hxml", "editor.hxml");
				check(display.hxml == hxml && display.args.indexOf("alternate-src") >= 0, "HXML delegation did not update display identity and inputs");
				type("#rayde-rayzor-project-hxml", "");
				check(display.hxml == null && display.args.indexOf("lib code") >= 0, "Removing HXML delegation did not restore manifest inputs");
				type("#rayde-rayzor-project-hxml", "missing.hxml");
				check(count("#rayde-rayzor-error") == 1 && read().value(["project", "hxml"]) == null, "Missing delegated HXML was saved");
				click("#rayde-rayzor-reload");
				var external = sys.io.File.getContent(entry) + "\n[custom]\nvalue = 'external'\n";
				sys.io.File.saveContent(entry, external);
				type("#rayde-rayzor-project-version", "0.2.0");
				check(read().text(["custom", "value"]) == "external" && sys.io.File.getContent(entry).indexOf("# keep dependency") >= 0 && sys.io.File.getContent(entry).indexOf("# keep tier") >= 0, "Editing dropped unrelated or externally edited TOML");
				click("#rayde-rayzor-edit-text");
				check(bench.active.get() == entry && bench.editorFor(entry) != null, "Edit as Text did not open the manifest source");
				bench.buffer(entry).set(sys.io.File.getContent(entry) + "# unsaved\n"); bench.edited(entry); settle();
				bench.openBuild(); settle();
				var before = sys.io.File.getContent(entry);
				type("#rayde-rayzor-project-version", "0.3.0");
				check(sys.io.File.getContent(entry) == before && count("#rayde-rayzor-error") == 1, "Form overwrote an unsaved source tab");
				bench.dirty.set([]); bench.buffer(entry).set(before); settle();
				click("#rayde-rayzor-reload");
				type("#rayde-rayzor-project-version", "0.3.0");
				check(bench.buffer(entry).get() == sys.io.File.getContent(entry), "Saved source buffer did not follow form changes");
				before = sys.io.File.getContent(entry); sys.io.File.saveContent(entry, "[project\ninvalid");
				click("#rayde-rayzor-reload");
				check(count("#rayde-rayzor-error") == 1 && count("#rayde-rayzor-edit-text") == 1 && count("#rayde-rayzor-project-name") == 0, "Malformed source has no recovery UI");
				shot("invalid");
				sys.io.File.saveContent(entry, before); click("#rayde-rayzor-reload");
				check(count("#rayde-rayzor-project-name") == 1 && count("#rayde-rayzor-error") == 0, "Corrected source did not reload");
			}
			bench.closeAll(); settle(); bench.openBuild(); settle();
			check(count("#rayde-rayzor-build") == 1, "Reopened settings lost the form");
		} catch (e:Dynamic) { stop(); tree.dispose(); compiler.stop(); throw e; }
		stop(); tree.dispose(); compiler.stop();
	}
}
