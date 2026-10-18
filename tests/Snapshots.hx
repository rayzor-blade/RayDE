import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.theme.ThemeState;
import ashui.theme.themes.RestrainedTheme;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

/**
 * RayDE's workbench on the fixture projects, captured in both themes: as it
 * opens, with a file open and an edit the compiler finds wrong, after a run of
 * a program that works, and after a build that fails. Pictures go to
 * bin/snapshots, or ASHUI_SNAPSHOT_DIR. A run saves what is edited, so each
 * scenario works on a copy of its fixture, never the fixture itself.
 */
class Snapshots {
	static inline var WIDTH = 1280;
	static inline var HEIGHT = 800;

	static function main():Void {
		for (dark in [true, false]) {
			scenario(dark, "basic", (bench, file, shot, settle, scroll, click, type) -> {
				if (bench.panelOpen())
					throw "the bottom panel should start closed";
				shot("empty");
				// Two files open, the first in front, so the strip shows the front tab beside another.
				bench.openFile(file);
				bench.openFile(haxe.io.Path.join([haxe.io.Path.directory(file), "Util.hx"]));
				bench.active.set(file);
				var buffer = bench.buffer(file), original = buffer.get();
				buffer.set(StringTools.replace(original, 'var greeting = "hello";', 'var greeting:Int = "hello";'));
				bench.edited(file);
				settle();
				if (bench.problems.get().length != 2)
					throw 'the edited file should show two problems, not ${bench.problems.get().length}';
				bench.showPanel("problems");
				shot("problems");
				// Put the edit back; from the call on line 8, go to where it is defined.
				buffer.set(original);
				bench.check(file);
				bench.goTo(file, 7, 4);
				settle();
				if (bench.caretLine(file) != 7)
					throw 'go to should put the cursor on line 8, not ${bench.caretLine(file) + 1}';
				bench.goToDefinition();
				settle();
				if (bench.caretLine(file) != 2)
					throw 'go to definition should land on line 3, not ${bench.caretLine(file) + 1}';
				// Run the program.
				bench.run();
				wait(bench);
				settle();
				if (bench.runner.state != "finished" || bench.runner.console.indexOf("hello") < 0)
					throw 'the program did not run: ${bench.runner.state}: ${bench.runner.console}';
				shot("run");
				bench.openCenter();
				shot("command-center");
				bench.openCenter(">");
				shot("command-center-commands");
				bench.quickOpen.set(false);
				// The front tab as the last of three, then as the middle one: its feet go only where there is a neighbour.
				var folder = haxe.io.Path.directory(file);
				bench.openFile(haxe.io.Path.join([folder, "Names.hx"]));
				shot("tab-last");
				bench.showEditorMenu(true);
				shot("editor-menu");
				bench.showEditorMenu(false);
				bench.active.set(haxe.io.Path.join([folder, "Util.hx"]));
				shot("tab-middle");
				// Choosing a folder in the Explorer leaves the open files and the one in front alone, and the selection on that file.
				var front = bench.active.get();
				bench.treeSelected.set(folder);
				settle();
				if (front == "" || bench.open.get().length != 3 || bench.active.get() != front || bench.treeSelected.get() != front)
					throw 'choosing a folder changed what is open or selected: ${bench.open.get().length} files, in front "${bench.active.get()}", selected "${bench.treeSelected.get()}"';
				// With the folder above the file closed, the selection rests on the folder; opened again, it goes back to the file.
				bench.folderState(folder).set(false);
				settle();
				if (bench.treeSelected.get() != folder || bench.active.get() != front)
					throw 'a closed folder should carry the selection: selected "${bench.treeSelected.get()}"';
				shot("folder-closed");
				bench.folderState(folder).set(true);
				settle();
				if (bench.treeSelected.get() != front)
					throw 'the selection should return to the file: "${bench.treeSelected.get()}"';
				// Twelve more files, which do not fit the strip: it scrolls to keep the one in front in view.
				for (n in 1...13) {
					var more = haxe.io.Path.join([folder, 'Module$n.hx']);
					sys.io.File.saveContent(more, 'class Module$n {}\n');
					bench.openFile(more);
				}
				shot("tabs-many");
				bench.active.set(file);
				shot("tabs-many-first");
				bench.openBuild();
				shot("build-tab");
				// A terminal in the panel, running a script that prints in colour and then waits.
				bench.terminalProgram = "/bin/sh";
				bench.terminalArgs = [
					"-c",
					"printf '\\033[32mrayde\\033[0m on \\033[35mmain\\033[0m \\033[2m10:42\\033[0m\\n'; printf '\\033[1mls\\033[0m\\n'; printf '\\033[34msrc\\033[0m  \\033[34mbin\\033[0m  \\033[36mbuild.hxml\\033[0m  README.md\\n'; "
					+ "printf '\\033[31merror\\033[0m: \\033[4munderlined\\033[0m \\033[7minverse\\033[0m  box ┌─┬─┐ ╔═╦═╗ ┃ ▀▄█ ░▒▓ ▖▟ ✓\\n'; printf '\\033[38;5;208morange\\033[0m \\033[38;2;120;200;255mtruecolor\\033[0m \\033[1;33mbold yellow\\033[0m\\n'; printf '$ '; sleep 60"
				];
				bench.showPanel("terminal");
				var waiting = haxe.Timer.stamp() + 8;
				while ((bench.terminal() == null || bench.terminal().line(4).indexOf("orange") < 0) && haxe.Timer.stamp() < waiting) {
					Sys.sleep(.03);
					settle(1);
				}
				if (bench.terminal() == null || bench.terminal().line(0).indexOf("rayde on main") < 0)
					throw 'the terminal did not show what the program printed: "${bench.terminal() == null ? "no terminal" : bench.terminal().line(0)}"';
				settle(12);
				shot("terminal");
				// With the keyboard in it, and something typed: the cursor is a block behind the text, after it.
				bench.focusTerminal();
				bench.terminal().write("echo typed");
				var typing = haxe.Timer.stamp() + 4;
				while (bench.terminal().line(5).indexOf("typed") < 0 && haxe.Timer.stamp() < typing) {
					Sys.sleep(.03);
					settle(1);
				}
				settle(4);
				shot("terminal-typing");
				// A second terminal beside the first, which keeps running; the list of terminals, and the menu of profiles.
				var first = bench.terminal();
				bench.newTerminal();
				var second = bench.terminal();
				if (bench.terminalCount() != 2 || second == null || first == null || second.handle == first.handle || first.exitCode() != -1)
					throw 'a new terminal should start beside the first: ${bench.terminalCount()} running';
				var until = haxe.Timer.stamp() + 6;
				while (second.line(4).indexOf("orange") < 0 && haxe.Timer.stamp() < until) {
					Sys.sleep(.03);
					settle(1);
				}
				settle(8);
				shot("terminals");
				bench.showTerminalMenu(true);
				shot("terminal-profiles");
				bench.showTerminalMenu(false);
				// Choosing the first brings it to the front, still running with what it printed; killing the one in front leaves the other.
				bench.selectTerminal(bench.terminalIds()[0]);
				if (bench.terminal() == null || bench.terminal().handle != first.handle)
					throw "choosing a terminal in the list should bring it to the front";
				settle(8);
				shot("terminals-first");
				bench.killTerminal();
				if (bench.terminalCount() != 1 || bench.terminal() == null || bench.terminal().handle != second.handle)
					throw 'killing a terminal should leave the other in front: ${bench.terminalCount()} running';
				bench.closeTerminals();
				if (bench.terminalCount() != 0)
					throw "every terminal should be ended";
				bench.closePanel();
				// Every tab closed: the welcome page, now with recent files.
				bench.closeAll();
				shot("welcome-recent");
			});
			// A build file with a target, libraries, defines and an argument the form does not manage, as the form shows it.
			scenario(dark, "full", (bench, file, shot, settle, scroll, click, type) -> {
				bench.openBuild();
				shot("build-settings");
				scroll("#rayde-build", 520);
				shot("build-settings-middle");
				scroll("#rayde-build", 5000);
				shot("build-settings-end");
				scroll("#rayde-build", 0);
				var model = bench.buildFile();
				if (model == null || model.values("-cp").join(",") != "src,lib" || model.value("--main") != "app.Main")
					throw "the build form should open the build file as it is";
				// The form's own controls, driven as the pointer would: each writes the file, and the compiler is given the result.
				function written(what:String):String {
					var text = sys.io.File.getContent(model.path);
					return text;
				}
				var args = () -> bench.display().args;
				click("#rayde-build-folders-section .rayde-chip");
				if (written("class path").indexOf("-cp tools") < 0 || args().indexOf("tools") < 0)
					throw "choosing a suggested class path did not write it:\n" + written("");
				type("#rayde-build-library", "tink_macro");
				click("#rayde-build-library-add");
				if (written("library").indexOf("-lib tink_macro") < 0 || args().indexOf("tink_macro") < 0)
					throw "adding a library did not write it:\n" + written("");
				// The column of libraries: a click switches an installed one into the build, and the same click out again.
				click("#rayde-lib-ash-simd");
				if (model.values("-lib").indexOf("ash-simd") < 0 || args().indexOf("ash-simd") < 0)
					throw "choosing an installed library in the column did not add it:\n" + written("");
				click("#rayde-lib-ash-simd");
				if (model.values("-lib").indexOf("ash-simd") >= 0)
					throw "choosing it again did not take it out:\n" + written("");
				click("#rayde-lib-tink_macro");
				if (model.values("-lib").indexOf("tink_macro") >= 0)
					throw "a library of the build did not come out with a click:\n" + written("");
				click("#rayde-build-debug");
				if (!model.has("--debug") || written("debug").indexOf("--debug") < 0)
					throw "the debug switch did not write the file:\n" + written("");
				var defines = model.values("-D").length;
				click("#rayde-build-defines-section .rayde-remove");
				if (model.values("-D").length != defines - 1 || written("define").indexOf("analyzer-optimize") >= 0)
					throw "removing a define did not write the file:\n" + written("");
				var text = written("");
				if (text.indexOf("# The app's build") < 0 || text.indexOf("--macro include('app')") < 0 || text.indexOf("not_installed_yet") < 0)
					throw "the form lost something it does not manage:\n" + text;
				// An input, a select and a button in a row of the form are one height.
				var input = bench.boundsOf("#rayde-build-define"), button = bench.boundsOf("#rayde-build-define-add"), select = bench.boundsOf("#rayde-build-dce");
				if (input == null || button == null || select == null || input.height != button.height || select.height != button.height)
					throw 'the form\'s controls should share a height: input ${input == null ? "?" : "" + input.height}, button ${button == null ? "?" : "" + button.height}, select ${select == null ? "?" : "" + select.height}';
				shot("build-settings-edited");
				// What the form writes is what the compiler is then given.
				model.add("-D", "from-the-form");
				model.save();
				bench.buildChanged();
				if (bench.display().args.indexOf("from-the-form") < 0)
					throw "the compiler's arguments did not follow the build file";
			});
			scenario(dark, "broken", (bench, file, shot, settle, scroll, click, type) -> {
				bench.openFile(file);
				bench.run();
				wait(bench);
				settle();
				if (bench.runner.state != "failed" || bench.runner.problems.length != 1)
					throw 'the build should have failed with one problem: ${bench.runner.state}, ${bench.runner.problems.length}';
				shot("build-failed");
			});
		}
		Sys.println("rayde snapshots: the workbench empty, with problems, after a run, in the command center, with each kind of tab in front, with tabs that overflow, welcome with recent files and after a failed build, in both themes");
	}

	/** Ticks the workbench until its run ends, or a minute and a half passes. */
	static function wait(bench:Workbench):Void {
		var end = haxe.Timer.stamp() + 90;
		while (bench.runner.active() && haxe.Timer.stamp() < end) {
			bench.tick();
			Sys.sleep(.02);
		}
		bench.tick();
	}

	/** A copy of the fixture project `name` under bin/fixtures, which a run may change. */
	static function copyOf(name:String):String {
		var from = Sys.getCwd() + "tests/fixtures/" + name, to = Sys.getCwd() + "bin/fixtures/" + name;
		function copy(a:String, b:String):Void {
			sys.FileSystem.createDirectory(b);
			for (entry in sys.FileSystem.readDirectory(a)) {
				var source = haxe.io.Path.join([a, entry]), target = haxe.io.Path.join([b, entry]);
				if (sys.FileSystem.isDirectory(source))
					copy(source, target)
				else
					sys.io.File.saveContent(target, sys.io.File.getContent(source));
			}
		}
		if (sys.FileSystem.exists(to))
			for (entry in sys.FileSystem.readDirectory(to))
				if (entry != ".rayde")
					deleteTree(haxe.io.Path.join([to, entry]));
		copy(from, to);
		// What a run opened last is not carried into the next, so the welcome page starts as it would in a new project.
		if (sys.FileSystem.exists(to + "/.rayde/recent.txt"))
			sys.FileSystem.deleteFile(to + "/.rayde/recent.txt");
		return to;
	}

	static function deleteTree(path:String):Void {
		if (sys.FileSystem.isDirectory(path)) {
			for (entry in sys.FileSystem.readDirectory(path))
				deleteTree(haxe.io.Path.join([path, entry]));
			sys.FileSystem.deleteDirectory(path);
		} else
			sys.FileSystem.deleteFile(path);
	}

	static function scenario(dark:Bool, name:String, steps:(Workbench, String, String->Void, ?Int->Void, String->Float->Void, String->Void, String->String->Void) -> Void):Void {
		var root = copyOf(name), server = new CompilerServer();
		ThemeState.init(RestrainedTheme.bundle(), dark ? Dark : Light);
		rayde.ui.Style.use();
		var display = Display.ofHxml(server, root + "/build.hxml"), tree = new LayoutTree(), bench:Workbench = null, stop:Void->Void = null;
		var view = Owner.root(tree, s -> {
			stop = s;
			return bench = new Workbench({display: display, name: name, runtime: "ash"});
		});
		function settle(?frames:Int):Void
			for (_ in 0...(frames == null ? 20 : frames)) {
				Offscreen.advance(1 / 60);
				Css.setViewport(WIDTH, HEIGHT);
				Css.update();
				tree.flush();
				tree.computeLayout(view.node, WIDTH, HEIGHT);
			}
		function shot(what:String):Void {
			settle();
			if (Sys.getEnv("RAYDE_DEBUG") != null)
				for (sel in [".rayde-tab", ".rayde-tab-body", "#rayde-file-tabs"])
					for (id in ashui.css.Css.query(tree, view.node.id, sel)) {
						var b = tree.getBounds(new ashui.layout.Node(id));
						Sys.println('$what $sel ' + (b == null ? "null" : b.x + "," + b.y + " " + b.width + "x" + b.height));
					}
			Snapshot.capture('rayde-${dark ? "dark" : "light"}-$name-$what', tree, view.node, WIDTH, HEIGHT, ThemeState.get().color(Background).rgb());
		}
		settle();
		// Scrolls the scroll view that `selector` finds, as far as `y`.
		function scroll(selector:String, y:Float):Void {
			var found = ashui.css.Css.query(tree, view.node.id, selector);
			var scroller = found.length == 0 ? null : ashui.input.Scroll.at(found[0], tree);
			if (scroller != null)
				scroller.scrollTo(0, y);
			settle();
		}
		// A press and release on the first element `selector` finds, as the pointer makes them, once the form it is in has been scrolled to show it.
		function click(selector:String):Void {
			var found = ashui.css.Css.query(tree, view.node.id, selector), area = ashui.css.Css.query(tree, view.node.id, "#rayde-build");
			if (found.length == 0)
				throw 'nothing matches $selector';
			var scroller = area.length == 0 ? null : ashui.input.Scroll.at(area[0], tree);
			var box = tree.getScrolledBounds(new ashui.layout.Node(found[0]));
			var frame = area.length == 0 ? null : tree.getScrolledBounds(new ashui.layout.Node(area[0]));
			if (scroller != null && box != null && frame != null) {
				scroller.scrollTo(0, scroller.y.get() + box.y + box.height / 2 - (frame.y + frame.height / 2));
				settle(2);
			}
			// Where it shows now, in the scrolled form: the pointer goes there, as a hand would.
			var at = tree.getScrolledBounds(new ashui.layout.Node(found[0]));
			ashui.input.Pointer.move(tree, at.x + at.width / 2, at.y + at.height / 2);
			ashui.input.Pointer.press(tree);
			ashui.input.Pointer.release(tree);
			settle(3);
		}
		// Puts `text` in the input `selector` finds.
		function type(selector:String, text:String):Void {
			var found = ashui.css.Css.query(tree, view.node.id, selector);
			if (found.length == 0)
				throw 'no input matches $selector';
			ashui.ui.Input.at(tree, found[0]).value.set(text);
			settle(2);
		}
		steps(bench, root + "/src/Main.hx", shot, settle, scroll, click, type);
		stop();
		tree.dispose();
		server.stop();
	}
}
