import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.theme.ThemeState;
import ashui.theme.themes.RestrainedTheme;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.run.Haxelib;
import rayde.settings.Appearance;
import rayde.settings.Store;
import rayde.ui.Theming;
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
		// haxelib is a stand-in with a few libraries, so the page and what it runs do not depend on the machine or the network; home is empty.
		var scratch = haxe.io.Path.join([Sys.getCwd(), "bin", "snapshot-tools"]);
		if (!sys.FileSystem.exists(scratch))
			sys.FileSystem.createDirectory(scratch);
		var stub = haxe.io.Path.join([scratch, "haxelib.sh"]), home = haxe.io.Path.join([scratch, "home"]);
		if (!sys.FileSystem.exists(home))
			sys.FileSystem.createDirectory(home);
		sys.io.File.saveContent(stub, "#!/bin/sh\nstate=\"$(dirname \"$0\")/libs.txt\"\ncase \"$1\" in\n list) cat \"$state\" 2>/dev/null ;;\n --always) shift; case \"$1\" in install) echo \"$2: [${3:-1.0.0}]\" >> \"$state\"; echo \"Installed $2\" ;; update) echo \"Updated $2\" ;; esac ;;\n remove) grep -v \"^$2:\" \"$state\" > \"$state.new\"; mv \"$state.new\" \"$state\"; echo \"Removed $2\" ;;\nesac\n");
		Sys.command("chmod", ["+x", stub]);
		Sys.putEnv("RAYDE_HAXELIB", stub);
		Sys.putEnv("HOME", home);
		for (dark in [true, false]) {
			sys.io.File.saveContent(haxe.io.Path.join([scratch, "libs.txt"]), "ash-simd: [0.1.0]\nformat: [3.7.0]\nhashlink: [1.14.0]\ntink_core: [2.1.1]\ntink_hxx: [0.25.1]\n");
			Haxelib.refresh();
			scenario(dark, "basic", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				if (bench.panelOpen())
					throw "the bottom panel should start closed";
				shot("empty");
				// The guide lines of the Explorer's tree are hidden until the pointer is over it.
				bench.openFile(file);
				bench.closeAll();
				hover("#rayde-tree");
				shot("explorer-hover");
				hover("#rayde-bottom");
				shot("explorer-away");
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
				// Split the screen of the second terminal, which sits beside it; the list shows both under one.
				var before = bench.terminalCount();
				bench.splitTerminal();
				if (bench.terminalCount() != before + 1)
					throw "splitting should start another terminal";
				var third = bench.terminal();
				until = haxe.Timer.stamp() + 6;
				while (third.line(4).indexOf("orange") < 0 && haxe.Timer.stamp() < until) {
					Sys.sleep(.03);
					settle(1);
				}
				settle(10);
				shot("terminal-split");
				bench.killTerminal();
				// The pickers of the menu, in the command center.
				bench.splitWithProfile();
				shot("terminal-split-profile");
				bench.quickOpen.set(false);
				bench.selectDefaultProfile();
				shot("terminal-default-profile");
				bench.quickOpen.set(false);
				// A task of the project's own, from .rayde/tasks.json, run in a terminal of its own that keeps its output after it ends.
				var taskFile = haxe.io.Path.join([haxe.io.Path.directory(haxe.io.Path.directory(file)), ".rayde", "tasks.json"]);
				sys.FileSystem.createDirectory(haxe.io.Path.directory(taskFile));
				sys.io.File.saveContent(taskFile, '{"tasks": [{"label": "Say hello", "command": "echo hello from a task"}, {"label": "Format source", "command": "echo formatting"}]}');
				var tasks = rayde.run.Tasks.list(bench.display());
				if (!Lambda.exists(tasks, t -> t.label == "Say hello") || !Lambda.exists(tasks, t -> t.label == "Build build.hxml") || !Lambda.exists(tasks, t -> StringTools.startsWith(t.label, "Run build.hxml")))
					throw 'the project should offer its own tasks and the hxml ones: ${[for (t in tasks) t.label]}';
				bench.runTaskPicker();
				shot("tasks");
				bench.quickOpen.set(false);
				bench.openCenter("task ");
				shot("center-tasks");
				bench.quickOpen.set(false);
				// Closed and opened again while it is part-way through closing, as a quick Esc and Cmd+P do.
				settle(3);
				bench.openCenter();
				settle(30);
				if (!bench.quickOpen.get())
					throw "the center asked for while it was closing should open once it has closed";
				bench.quickOpen.set(false);
				settle(40);
				var before = bench.terminalCount();
				bench.runTask(Lambda.find(tasks, t -> t.label == "Say hello"));
				if (bench.terminalCount() != before + 1)
					throw "a task should run in a terminal of its own";
				var ran = bench.terminal();
				until = haxe.Timer.stamp() + 6;
				while ((ran.line(0).indexOf("hello from a task") < 0 || ran.exitCode() == -1) && haxe.Timer.stamp() < until) {
					Sys.sleep(.03);
					settle(1);
				}
				if (ran.line(0).indexOf("hello from a task") < 0 || ran.exitCode() != 0)
					throw 'the task did not run: "${ran.line(0)}", exit ${ran.exitCode()}';
				settle(10);
				shot("terminal-task");
				bench.killTerminal();
				// The file the menu's Configure Tasks opens, as JSON.
				bench.configureTasks();
				shot("tasks-file");
				// The terminal's settings page, and a profile made the default is kept in the project.
				bench.openTerminalSettings();
				bench.setDefaultProfile("bash");
				shot("terminal-settings");
				if (sys.io.File.getContent(haxe.io.Path.join([haxe.io.Path.directory(haxe.io.Path.directory(file)), ".rayde", "settings.json"])).indexOf('"bash"') < 0)
					throw "the default profile was not kept";
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
				// The other sections of the Settings page, reached from its list, and the extensions folder empty.
				click("#rayde-activity-settings");
				if (bench.settingsSection() != "terminal" || bench.active.get() != Workbench.SETTINGS)
					throw "the gear should bring the Settings page forward on the section last in view";
				click("#rayde-settings-nav-extensions");
				if (bench.settingsSection() != "extensions")
					throw "a click on a section in the list should show it";
				shot("settings-extensions-empty");
				click("#rayde-settings-nav-libraries");
				shot("settings-libraries");
				// Every tab closed: the welcome page, now with recent files.
				bench.closeAll();
				shot("welcome-recent");
			});
			// A build file with a target, libraries, defines and an argument the form does not manage, as the form shows it.
			scenario(dark, "full", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
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
				// Libraries: a name typed in and added goes into the build file and is installed when haxelib lacks it.
				bench.openSettings("libraries");
				shot("settings-libraries-full");
				type("#rayde-library-name", "tink_macro");
				click("#rayde-library-add");
				if (written("library").indexOf("-lib tink_macro") < 0 || args().indexOf("tink_macro") < 0)
					throw "adding a library did not write it:\n" + written("");
				until(() -> !bench.librariesBusy(), "haxelib to install tink_macro");
				if (!Lambda.exists(Haxelib.installed(), l -> l.name == "tink_macro"))
					throw "adding a library haxelib lacks did not install it";
				shot("settings-libraries-installed");
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
				// An installed library is removed from the machine, and one the build names but haxelib lacks is installed from its row.
				click("#rayde-lib-remove-tink_macro");
				until(() -> !bench.librariesBusy(), "haxelib to remove tink_macro");
				if (Lambda.exists(Haxelib.installed(), l -> l.name == "tink_macro"))
					throw "removing a library did not remove it";
				shot("settings-libraries-removed");
				click("#rayde-lib-install-not_installed_yet");
				until(() -> !bench.librariesBusy(), "haxelib to install not_installed_yet");
				if (!Lambda.exists(Haxelib.installed(), l -> l.name == "not_installed_yet"))
					throw "installing from the row did not install it";
				bench.openSettings("build");
				settle();
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
				var root = bench.display().cwd;
				// Color scheme: a theme is chosen from its picture, applied at once and written down; so is light or dark.
				bench.openSettings("appearance");
				shot("settings-appearance");
				click("#rayde-theme-hybrid");
				if (Store.section(root, "appearance").theme != "hybrid")
					throw "choosing a theme did not write it";
				shot("settings-appearance-hybrid");
				click(dark ? "#rayde-scheme-light" : "#rayde-scheme-dark");
				if (Store.section(root, "appearance").scheme != (dark ? "light" : "dark") || ThemeState.get().scheme() != (dark ? Light : Dark))
					throw 'choosing a scheme did not apply and write it: ${dark ? "dark" : "light"} run, file says ${Store.section(root, "appearance").scheme}, window is ${ThemeState.get().scheme()}';
				shot("settings-appearance-switched");
				// The landing page follows the scheme: its wordmark is the one drawn for the scheme in use.
				bench.closeAll();
				shot("welcome-switched");
				// What the rest of the snapshots expect: the theme and scheme they began with.
				var again = new Appearance();
				again.scheme = dark ? "dark" : "light";
				Theming.apply(again);
				settle();
				// Key bindings: a key is recorded for a command, a letter alone is refused, the new key runs the command, and a key on two commands is marked.
				var keysFile = haxe.io.Path.join([root, ".rayde", "keybindings.json"]);
				bench.openSettings("keys");
				shot("settings-keys");
				// A keymap of another editor: choosing it writes the choice, its keys run the commands and the default's no longer do.
				var mac = Sys.systemName() == "Mac";
				click("#rayde-keymap-intellij");
				if (Store.section(root, "keymap").preset != "intellij")
					throw "choosing a keymap did not write it";
				shot("settings-keymap-intellij");
				// The command center offers the same choice, and a keymap chosen there is shown on the page.
				bench.selectKeymap();
				shot("keymap-picker");
				bench.quickOpen.set(false);
				click("#rayde-keys-filter");
				press(Character(mac ? "o" : "n"), true, !mac, false, mac);
				until(() -> bench.quickOpen.get(), "the keymap's key for Go to File to open it");
				bench.quickOpen.set(false);
				press(Character("p"), false, !mac, false, mac);
				if (bench.quickOpen.get())
					throw "a key of the keymap left behind still did its command";
				bench.useKeymap("sublime");
				click("#rayde-keys-filter");
				shot("settings-keymap-sublime");
				if (Store.section(root, "keymap").preset != "sublime")
					throw "choosing a keymap from the center did not write it";
				click("#rayde-keymap-vscode");
				if (Store.section(root, "keymap").preset != "vscode")
					throw "going back to the default keymap did not write it";
				type("#rayde-keys-filter", "terminal");
				shot("settings-keys-filtered");
				type("#rayde-keys-filter", "toggle explorer");
				scroll("#rayde-keys", 5000);
				click("#rayde-key-edit-explorer");
				shot("settings-keys-recording");
				if (bench.boundsOf("#rayde-key-recorder") == null)
					throw "the pencil should show the recorder";
				if (!bench.hasKeyboard("#rayde-key-recorder"))
					throw "the recorder should have the keyboard";
				press(Character("a"));
				if (sys.FileSystem.exists(keysFile))
					throw "a letter alone should not become a key";
				shot("settings-keys-refused");
				press(Character("e"), false, false, true);
				if (!sys.FileSystem.exists(keysFile) || sys.io.File.getContent(keysFile).indexOf("alt+e") < 0)
					throw "the key pressed was not written:\n" + (sys.FileSystem.exists(keysFile) ? sys.io.File.getContent(keysFile) : "no file");
				shot("settings-keys-changed");
				click("#rayde-keys-filter");
				var before = bench.boundsOf("#rayde-files") != null;
				press(Character("e"), false, false, true);
				if ((bench.boundsOf("#rayde-files") != null) == before)
					throw "the key chosen for Toggle Explorer did not run it";
				press(Character("e"), false, false, true);
				press(Character("p"), false, false, false, true);
				until(() -> bench.quickOpen.get(), "Cmd+P to open the command center");
				bench.quickOpen.set(false);
				type("#rayde-keys-filter", "run");
				scroll("#rayde-keys", 5000);
				click("#rayde-key-edit-run");
				press(Character("p"), false, false, false, true);
				shot("settings-keys-conflict");
				click("#rayde-keys-reset-all");
				if (sys.FileSystem.exists(keysFile))
					throw "resetting every key should leave no file";
				shot("settings-keys-reset");
				// Extensions: a folder with a manifest is listed, and one whose manifest cannot be read says so.
				var extensions = haxe.io.Path.join([root, ".rayde", "extensions"]);
				if (!sys.FileSystem.exists(extensions))
					sys.FileSystem.createDirectory(extensions);
				for (name in ["hello", "broken"])
					sys.FileSystem.createDirectory(haxe.io.Path.join([extensions, name]));
				sys.io.File.saveContent(haxe.io.Path.join([extensions, "hello", "extension.json"]), '{"name": "Hello", "version": "0.1.0", "description": "Says hello in the status bar"}');
				sys.io.File.saveContent(haxe.io.Path.join([extensions, "broken", "extension.json"]), "{ nope");
				bench.openSettings("extensions");
				click("#rayde-settings-nav-keys");
				click("#rayde-settings-nav-extensions");
				shot("settings-extensions");
			});
			scenario(dark, "broken", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
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
		// What a run opened last, and what it set, is not carried into the next: the project starts as a new one would.
		for (leftover in ["recent.txt", "settings.json", "keybindings.json", "extensions"])
			if (sys.FileSystem.exists(to + "/.rayde/" + leftover))
				deleteTree(to + "/.rayde/" + leftover);
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

	static function scenario(dark:Bool, name:String, steps:(Workbench, String, String->Void, ?Int->Void, String->Float->Void, String->Void, String->String->Void, String->Void, (window.Key, ?Bool, ?Bool, ?Bool, ?Bool)->Void, (Void->Bool)->String->Void) -> Void):Void {
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
		// Puts the pointer over the middle of the first element `selector` finds.
		function hover(selector:String):Void {
			var found = ashui.css.Css.query(tree, view.node.id, selector);
			if (found.length == 0)
				throw 'nothing matches $selector';
			var at = tree.getScrolledBounds(new ashui.layout.Node(found[0]));
			ashui.input.Pointer.move(tree, at.x + at.width / 2, at.y + at.height / 2);
			settle(6);
			if (Sys.getEnv("RAYDE_DEBUG") != null)
				Sys.println('hover $selector at ' + (at.x + at.width / 2) + "," + (at.y + at.height / 2) + " hovered=" + (ashui.input.Interaction.byId(tree, found[0]) == null ? "n/a" : "" + ashui.input.Interaction.byId(tree, found[0]).hovered.get()));
		}
		// A key pressed and let go as the keyboard reports it, to what has the keyboard, with the modifiers held.
		function press(key:window.Key, ?shift:Bool, ?control:Bool, ?alt:Bool, ?meta:Bool):Void {
			var mods = window.Modifiers.State(shift == true, control == true, alt == true, meta == true, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown);
			for (state in [window.MouseElementState.Pressed, window.MouseElementState.Released])
				ashui.input.Keyboard.input(tree, window.KeyEvent.Input(Unidentified(Unidentified), key, None, Standard, state, false, Unavailable), mods);
			settle(4);
		}
		// Lets time pass, a process included, until `done` holds, or twenty seconds have gone by.
		function until(done:Void->Bool, what:String):Void {
			var end = haxe.Timer.stamp() + 20;
			while (!done() && haxe.Timer.stamp() < end) {
				settle(3);
				Sys.sleep(.02);
			}
			if (!done())
				throw 'timed out waiting for $what';
		}
		steps(bench, root + "/src/Main.hx", shot, settle, scroll, click, type, hover, press, until);
		stop();
		tree.dispose();
		server.stop();
	}
}
