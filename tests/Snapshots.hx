import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.theme.ThemeState;
import ashui.theme.themes.RestrainedTheme;
import rayde.ext.Manifest;
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
				// A secondary press on a file and on a folder opens a menu for it; the items act on the files and the tabs.
				var tree = bench.tree;
				var rowOf = (path:String) -> {
					var found = ashui.css.Css.query(tree, bench.node.id, '[data-path$="$path"] > .ui-tree-row');
					if (found.length == 0)
						throw 'no row for $path';
					return tree.getScrolledBounds(new ashui.layout.Node(found[0]));
				};
				var menuOn = (path:String) -> {
					var b = rowOf(path);
					ashui.input.Pointer.move(tree, b.x + b.width / 2, b.y + b.height / 2);
					ashui.input.Pointer.press(tree, Right);
					ashui.input.Pointer.release(tree, Right);
					settle(8);
				};
				var folder = haxe.io.Path.directory(file);
				menuOn("src/Main.hx");
				shot("explorer-menu-file");
				press(Named(Escape));
				menuOn("/src");
				shot("explorer-menu-folder");
				click("#rayde-explorer-new-file");
				type("#rayde-prompt-input", "Fresh.hx");
				shot("explorer-prompt");
				click("#rayde-prompt-accept");
				if (!sys.FileSystem.exists(haxe.io.Path.join([folder, "Fresh.hx"])) || bench.active.get() != haxe.io.Path.join([folder, "Fresh.hx"]))
					throw "New File should make the file and open it";
				menuOn("src/Fresh.hx");
				click("#rayde-explorer-rename");
				type("#rayde-prompt-input", "Renamed.hx");
				click("#rayde-prompt-accept");
				var renamed = haxe.io.Path.join([folder, "Renamed.hx"]);
				if (!sys.FileSystem.exists(renamed) || sys.FileSystem.exists(haxe.io.Path.join([folder, "Fresh.hx"])) || bench.open.get().indexOf(renamed) < 0 || bench.active.get() != renamed)
					throw "Rename should move the file and its tab";
				// Duplicate, and copy then paste into the folder, give copies a free name; the menu shows each command's key.
				menuOn("src/Renamed.hx");
				shot("explorer-menu-keys");
				click("#rayde-explorer-duplicate");
				var copyOf = haxe.io.Path.join([folder, "Renamed copy.hx"]);
				if (!sys.FileSystem.exists(copyOf))
					throw "Duplicate should make Renamed copy.hx beside the file";
				menuOn("src/Main.hx");
				click("#rayde-explorer-copy");
				menuOn("/src");
				click("#rayde-explorer-paste");
				if (!sys.FileSystem.exists(haxe.io.Path.join([folder, "Main copy.hx"])))
					throw "Paste should put a copy of Main.hx in the folder under a free name";
				// What is cut moves, and the tab of a moved file follows it.
				sys.FileSystem.createDirectory(haxe.io.Path.join([folder, "sub"]));
				bench.refreshExplorer();
				settle();
				bench.openFile(copyOf);
				menuOn("src/Renamed copy.hx");
				click("#rayde-explorer-cut");
				menuOn("/sub");
				click("#rayde-explorer-paste");
				var cutTo = haxe.io.Path.join([folder, "sub", "Renamed copy.hx"]);
				if (sys.FileSystem.exists(copyOf) || !sys.FileSystem.exists(cutTo) || bench.active.get() != cutTo)
					throw "Cut and paste should move the file, and its tab with it";
				menuOn("src/Renamed.hx");
				click("#rayde-explorer-delete");
				shot("explorer-delete");
				click("#rayde-prompt-accept");
				if (sys.FileSystem.exists(renamed) || bench.open.get().indexOf(renamed) >= 0)
					throw "Delete should remove the file and close its tab";
				bench.closeAll();
				settle();
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
				// The compiler's problems are underlined in the text where they are.
				var wavy = ashui.css.Css.query(bench.tree, bench.node.id, ".ui-code-squiggle-error").length;
				if (wavy < 2)
					throw 'each problem should be underlined in the editor, not $wavy';
				// Resting the pointer on a name shows what the compiler knows of it: its type, and its documentation.
				var text = buffer.get(), at = text.indexOf("greet(greeting") + 2;
				var hint = @:privateAccess bench.hintAt(file, at);
				if (hint == null || hint.signature.indexOf("times:Int") < 0 || hint.docs == null || hint.docs.indexOf("Says hello") < 0)
					throw 'the hint on greet should have its type and documentation: ${hint == null ? "none" : hint.signature + " / " + hint.docs}';
				if (@:privateAccess bench.hintAt(file, text.indexOf('"hello"') + 2) != null)
					throw "where a problem is underlined the problem is what shows, so there is no hint of the compiler's";
				var spot = @:privateAccess bench.editorOf(file).rectAt(at);
				ashui.input.Pointer.move(bench.tree, spot.x + spot.width / 2, spot.y + spot.height / 2);
				settle(60);
				shot("hover");
				ashui.input.Pointer.move(bench.tree, 5, 5);
				settle(30);
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
		for (dark in [true, false])
			scenario(dark, "extension", (bench, rays, shot, settle, scroll, click, type, hover, press, until) -> {
				settle();
				var studio = bench.studioFor(rays);
				if (studio == null)
					throw "opening an extension project should start its extension";
				if (studio.state.get() == "unavailable") {
					Sys.println("extension snapshots skipped: no rayscript-host");
					return;
				}
				var says = (text:String) -> studio.preview != null && Lambda.exists(studio.preview.outline(), o -> o.text == text);
				until(() -> says("ext/main.rays"), "the extension's view, with the file a mocked call answered with");
				// The view is in the sidebar in the Explorer's place, and its icon is in the activity bar; the Explorer's icon brings the Explorer back.
				shot("extension-sidebar");
				click("#rayde-activity-explorer");
				shot("extension-explorer");
				click("#rayde-activity-ext");
				bench.showPanel("extension");
				shot("extension-console");
				click("#rayde-studio-surface button");
				until(() -> says("1"), "the click to reach the extension and its change to come back");
				// The header is the extension's: a tool of its config runs its handler, and it can change the title.
				click("#rayde-tool-add");
				until(() -> says("A note 2") && studio.title.get() == "Notes (4)", "the tool to be answered, and the title changed");
				shot("extension-tool");
				click("#rayde-extension-activity");
				shot("extension-activity");
				click("#rayde-extension-elements");
				shot("extension-elements");
				// The config as a form: a change is written to the .rayext at once, and the heading follows.
				bench.openSettings("extension");
				settle(10);
				shot("extension-config");
				var config = haxe.io.Path.join([haxe.io.Path.directory(haxe.io.Path.directory(rays)), "notes.rayext"]);
				click("#rayde-ext-title");
				type("#rayde-ext-title", "Field notes");
				press(Named(Enter));
				until(() -> studio.title.get() == "Field notes" && sys.io.File.getContent(config).indexOf('"title": "Field notes"') > 0, "the heading to be written to the config and shown");
				click("#rayde-ext-cap-terminal");
				until(() -> sys.io.File.getContent(config).indexOf('"terminal"') > 0, "a capability to be written to the config");
				var text = sys.io.File.getContent(config);
				if (text.indexOf('"id": "reset"') < 0 || text.indexOf('"main": "ext/main.rays"') < 0)
					throw "the form should leave what it did not change as it was: " + text;
				shot("extension-config-edited");
				bench.openFile(rays);
				// A mistake as it is typed: the view stays as it was, the error lands in Problems, and the line opens from the Console.
				var buffer = bench.buffer(rays), good = buffer.get();
				buffer.set(StringTools.replace(good, "var count = signal(0);", "var = signal(0);"));
				bench.edited(rays);
				until(() -> bench.problems.get().length > 0, "the typed mistake to be found");
				if (!says("ext/main.rays"))
					throw "the last view that ran should stay while the source has a mistake";
				bench.showPanel("problems");
				shot("extension-error");
				buffer.set(good);
				bench.edited(rays);
				until(() -> bench.problems.get().length == 0 && !studio.stale.get() && says("ext/main.rays"), "the fixed extension to run again");
				shot("extension-fixed");
			});
		for (dark in [true, false])
			scenario(dark, "markdown", (bench, rays, shot, settle, scroll, click, type, hover, press, until) -> {
				settle();
				var studio = bench.studioFor(rays);
				if (studio == null)
					throw "opening an extension project should start its extension";
				if (studio.state.get() == "unavailable") {
					Sys.println("markdown snapshots skipped: no rayscript-host");
					return;
				}
				var root = haxe.io.Path.directory(haxe.io.Path.directory(rays)), readme = root + "/docs/README.md", tree = bench.tree;
				// Text is placed word by word, so the view is looked at for a word.
				var says = (word:String) -> studio.preview != null && Lambda.exists(studio.preview.outline(), o -> o.text != null && o.text.indexOf(word) >= 0);
				var has = (selector:String) -> ashui.css.Css.query(tree, bench.node.id, selector).length > 0;
				var menuOn = (path:String) -> {
					var found = ashui.css.Css.query(tree, bench.node.id, '[data-path$="$path"] > .ui-tree-row');
					if (found.length == 0)
						throw 'no row for $path';
					var b = tree.getScrolledBounds(new ashui.layout.Node(found[0]));
					ashui.input.Pointer.move(tree, b.x + b.width / 2, b.y + b.height / 2);
					ashui.input.Pointer.press(tree, Right);
					ashui.input.Pointer.release(tree, Right);
					settle(8);
				};
				var previews = () -> [for (f in bench.open.get()) if (StringTools.startsWith(f, Workbench.TAB)) f];
				// The extension declares no view: the Explorer keeps the sidebar and there is no icon for it in the activity bar. Its item is in the menu of a Markdown file only.
				until(() -> studio.state.get() == "running", "the extension to start");
				if (has("#rayde-activity-ext"))
					throw "an extension with no view should have no icon in the activity bar";
				menuOn("README.md");
				if (!has("#rayde-explorer-preview"))
					throw "a Markdown file should have the extension's Preview in its menu";
				shot("markdown-menu");
				press(Named(Escape));
				menuOn("ext/main.rays");
				if (has("#rayde-explorer-preview"))
					throw "a script should not have Preview in its menu";
				press(Named(Escape));
				// Choosing Preview runs the extension's command on the file, and what it mounts opens as a tab.
				menuOn("README.md");
				click("#rayde-explorer-preview");
				until(() -> previews().length == 1 && says("Markdown"), "the preview to open as a tab");
				if (bench.active.get() != previews()[0])
					throw "the new tab should be in front";
				shot("markdown-tab");
				// Preview again on the same file brings it up to date and opens nothing more.
				menuOn("README.md");
				click("#rayde-explorer-preview");
				settle(30);
				if (previews().length != 1 || studio.tabViews.length != 1)
					throw "a file should have one preview";
				// Saving the file brings the tab up to date, from the editor's text.
				var text = bench.buffer(readme);
				text.set("# Rewritten heading\n\nA line, with `code` and **weight**.\n");
				bench.edited(readme);
				bench.saveAll();
				until(() -> says("Rewritten") && !says("Markdown"), "the saved text to reach the tab");
				shot("markdown-saved");
				// Closing the tab tells the extension, which unmounts the view.
				bench.closeFile(previews()[0]);
				until(() -> studio.tabViews.length == 0 && !says("Rewritten"), "the extension to unmount the closed tab");
				shot("markdown-closed");
				// The editor's actions menu has the extension's item for the file in front, when its conditions hold.
				bench.openFile(readme);
				click("#rayde-editor-menu-trigger");
				if (!has("#rayde-menu-ext-preview"))
					throw "a Markdown file should have the extension's Preview in the editor's menu";
				shot("markdown-title-menu");
				press(Named(Escape));
				bench.openFile(rays);
				click("#rayde-editor-menu-trigger");
				if (has("#rayde-menu-ext-preview"))
					throw "a script should not have Preview in the editor's menu";
				press(Named(Escape));
				bench.openFile(readme);
				click("#rayde-editor-menu-trigger");
				click("#rayde-menu-ext-preview");
				until(() -> previews().length == 1 && says("Rewritten"), "the editor menu's Preview to open the tab");
				bench.closeFile(previews()[0]);
				until(() -> studio.tabViews.length == 0, "the closed tab to be unmounted");
				// The config form lists the extension's commands and menu items, and adds to both; each is written to the file at once.
				bench.openSettings("extension");
				settle(10);
				scroll("#rayde-extension-config", 760);
				shot("markdown-config");
				scroll("#rayde-extension-config", 1330);
				shot("markdown-hooks");
				var config = root + "/markdown.rayext";
				click("#rayde-ext-cmd-id");
				type("#rayde-ext-cmd-id", "refresh");
				type("#rayde-ext-cmd-title", "Refresh Preview");
				type("#rayde-ext-cmd-icon", "refresh");
				click("#rayde-ext-cmd-add");
				until(() -> sys.io.File.getContent(config).indexOf('"id": "refresh"') > 0, "the command to be written to the config");
				type("#rayde-ext-item-name", "README*");
				click("#rayde-ext-item-add");
				until(() -> sys.io.File.getContent(config).indexOf('"name": "README*"') > 0, "the menu item to be written to the config");
				var written = sys.io.File.getContent(config);
				if (written.indexOf('"icon": "ext/preview.svg"') < 0 || written.indexOf('"view"') >= 0)
					throw "the form should leave what it did not change as it was: " + written;
				shot("markdown-config-edited");
			});
		for (dark in [true, false])
			scenario(dark, "views", (bench, rays, shot, settle, scroll, click, type, hover, press, until) -> {
				settle();
				var studio = bench.studioFor(rays);
				if (studio == null)
					throw "opening an extension project should start its extension";
				if (studio.state.get() == "unavailable") {
					Sys.println("views snapshots skipped: no rayscript-host");
					return;
				}
				var root = haxe.io.Path.directory(haxe.io.Path.directory(rays)), tree = bench.tree;
				var says = (word:String) -> studio.preview != null && Lambda.exists(studio.preview.outline(), o -> o.text != null && o.text.indexOf(word) >= 0);
				var has = (selector:String) -> ashui.css.Css.query(tree, bench.node.id, selector).length > 0;
				until(() -> says("Overview") && says("Inspector") && says("started"), "the three views to be drawn");
				// A view in each part of the layout: the sidebar, the right side bar and the bottom panel, each with its icon in the activity bar.
				for (selector in ["#rayde-activity-ext", "#rayde-activity-ext-inspector", "#rayde-activity-ext-log"])
					if (!has(selector))
						throw 'the activity bar should have $selector';
				for (selector in ["#rayde-view-ext #rayde-studio-surface", "#rayde-secondary #rayde-studio-surface", "#rayde-view-ext-log #rayde-studio-surface"])
					if (!has(selector))
						throw 'each view should be drawn in its own part: $selector';
				if (!has("#rayde-view-ext-log #rayde-studio-title"))
					throw "the panel view has its own header";
				shot("views");
				// An action of one view's header reaches the extension, and every view that shows the change follows it.
				click("#rayde-tool-refresh");
				until(() -> says("refresh 1") && Lambda.exists(studio.preview.outline(), o -> o.text == "2") && Lambda.exists(studio.preview.outline(), o -> o.text == "1"), "the action to be answered in the views");
				shot("views-refreshed");
				// The form lists each view with its own controls, and declares another. The right side bar and the panel are put away first, so the form has room.
				@:privateAccess bench.closePanel();
				@:privateAccess bench.secondaryWidth.set(0);
				settle(10);
				bench.openSettings("extension");
				settle(10);
				scroll("#rayde-extension-config", 520);
				shot("views-config");
				var config = root + "/dashboard.rayext";
				click("#rayde-ext-newview-id");
				type("#rayde-ext-newview-id", "extra");
				click("#rayde-ext-newview-add");
				until(() -> sys.io.File.getContent(config).indexOf('"id": "extra"') > 0 && has("#rayde-activity-ext-extra"), "the new view to be written to the config and given its icon");
				var written = sys.io.File.getContent(config);
				if (written.indexOf('"id": "inspector"') < 0 || written.indexOf('"refresh"') < 0)
					throw "the form should leave the other views as they were: " + written;
				shot("views-added");
			});
		for (dark in [true, false])
			scenario(dark, "chrome", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				settle();
				var chrome = bench.chrome, tree = bench.tree;
				var has = (selector:String) -> ashui.css.Css.query(tree, bench.node.id, selector).length > 0;
				var at = (x:Float, y:Float, ?times:Int) -> {
					ashui.input.Pointer.move(tree, x, y);
					for (_ in 0...(times == null ? 1 : times)) {
						ashui.input.Pointer.press(tree);
						ashui.input.Pointer.release(tree);
					}
					settle(3);
				};
				var asked = () -> chrome.calls.splice(0, chrome.calls.length).join(",");
				// The controls in the style of each platform; each asks the window for what it says.
				for (style in ["macos", "windows", "gnome", "kde"]) {
					@:privateAccess bench.windowStyle.set(style);
					settle(10);
					shot("bar-" + style);
					// Over a bright colour, to see what the window leaves transparent at its corners.
					Snapshot.capture('rayde-${dark ? "dark" : "light"}-chrome-corners-$style', bench.tree, bench.node, WIDTH, HEIGHT, 0xff00ff);
					var middle = style == "macos" ? "#rayde-win-fullscreen" : "#rayde-win-maximize";
					click("#rayde-win-minimize");
					click(middle);
					click("#rayde-win-close");
					var expected = "minimize," + (style == "macos" ? "fullscreen" : "maximize") + ",close";
					var got = asked();
					if (got != expected)
						throw 'the $style controls should ask for $expected, not $got';
					// With no window the chrome keeps the state itself: the window now fills the screen, so it has no resize edges until it is restored.
					settle(5);
					if (!(style == "macos" ? chrome.fullscreen.get() : chrome.maximized.get()) || has(".rayde-edge-w"))
						throw "a window that fills the screen has no resize edges";
					chrome.fullscreen.set(false);
					chrome.maximized.set(false);
					settle(5);
					if (!has(".rayde-edge-w"))
						throw "a window that does not fill the screen should have resize edges";
				}
				@:privateAccess bench.windowStyle.set("windows");
				settle(10);
				chrome.maximized.set(true);
				settle(5);
				if (has(".rayde-edge-w"))
					throw "a maximized window has no resize edges";
				shot("bar-windows-maximized");
				chrome.maximized.set(false);
				settle(5);
				// The bar moves the window, and a double click on it maximizes; the pill and the controls do not.
				at(250, 20);
				if (asked() != "drag")
					throw "a press on the bar should start a move";
				at(250, 20, 2);
				var twice = asked();
				if (twice.indexOf("maximize") < 0)
					throw 'a double click on the bar should maximize: $twice';
				chrome.maximized.set(false);
				settle(5);
				at(640, 20);
				if (asked() != "")
					throw "the pill is not a place to move the window from";
				bench.closeAll();
				// The edges and corners resize it from where they are.
				at(2, 400);
				at(1278, 400);
				at(640, 798);
				at(2, 2);
				at(1278, 798);
				var edges = asked();
				if (edges != "resize West,resize East,resize South,resize NorthWest,resize SouthEast")
					throw 'the edges should resize from where they are: $edges';
				shot("bar-after");
			});
		for (dark in [true, false])
			scenario(dark, "debug", (bench, rays, shot, settle, scroll, click, type, hover, press, until) -> {
				settle();
				var studio = bench.studioFor(rays);
				if (studio == null)
					throw "opening an extension project should start its extension";
				if (studio.state.get() == "unavailable") {
					Sys.println("debug snapshots skipped: no rayscript-host");
					return;
				}
				var d = studio.debug, root = haxe.io.Path.directory(haxe.io.Path.directory(rays)), tree = bench.tree;
				var has = (selector:String) -> ashui.css.Css.query(tree, bench.node.id, selector).length > 0;
				var says = (word:String) -> studio.preview != null && Lambda.exists(studio.preview.outline(), o -> o.text != null && o.text.indexOf(word) >= 0);
				var stoppedAt = (line:Int) -> () -> d.stopped.get() != null && d.stopped.get().frames[0].line == line;
				until(() -> studio.state.get() == "running" && says("Total"), "the extension to start");
				// A breakpoint from the editor: the command puts one on the line the cursor is on, and keeps it in the project.
				bench.openFile(rays);
				bench.goTo(rays, 6, 0);
				settle(5);
				@:privateAccess bench.toggleBreakpoint();
				if (d.linesOf(rays).join(",") != "7")
					throw 'the breakpoint should be on line 7: ${d.linesOf(rays)}';
				settle(5);
				var editor = @:privateAccess bench.editorOf(rays);
				if (editor.markerLinesOf("breakpoints").join(",") != "6" || !has(".ui-code-marker-breakpoint"))
					throw "the breakpoint should be a dot in the gutter, on the line";
				shot("debug-gutter");
				// A press in the gutter puts one on a line and takes it off again.
				var gutter = ashui.css.Css.query(tree, bench.node.id, ".ui-code-gutter")[0], viewport = ashui.css.Css.query(tree, bench.node.id, ".ui-code-viewport")[0];
				var g = tree.getScrolledBounds(new ashui.layout.Node(gutter)), v = tree.getScrolledBounds(new ashui.layout.Node(viewport));
				var pressGutter = (line:Int) -> {
					ashui.input.Pointer.move(tree, g.x + 9, v.y + 8 + line * editor.metrics.lineHeight + editor.metrics.lineHeight / 2);
					ashui.input.Pointer.press(tree);
					ashui.input.Pointer.release(tree);
					settle(5);
				};
				pressGutter(12);
				if (d.linesOf(rays).join(",") != "7,13")
					throw 'a press in the gutter on line 13 should add a breakpoint: ${d.linesOf(rays)}';
				pressGutter(12);
				if (d.linesOf(rays).join(",") != "7")
					throw 'a second press should take it off: ${d.linesOf(rays)}';
				if (sys.io.File.getContent(root + "/.rayde/settings.json").indexOf('"ext/main.rays"') < 0)
					throw "the breakpoint should be kept in the project's settings";
				// An action runs the handler, which calls the function with the breakpoint, and the extension stops there.
				click("#rayde-tool-add");
				until(stoppedAt(7), "the extension to stop at the breakpoint");
				var stop = d.stopped.get();
				if (stop.frames.length != 2 || stop.frames[0].name != "record" || stop.frames[0].file != rays || stop.reason != "breakpoint")
					throw 'the stack should be record and its caller: ${stop.frames}';
				settle(20);
				until(() -> d.locals.get().length == 3, "the locals of the frame");
				var locals = [for (v in d.locals.get()) v.name + "=" + v.value].join(",");
				if (locals != "amount=5,before=0,entry={amount: 5, before: 0}")
					throw 'the locals of record: $locals';
				settle(5);
				if (!has(".ui-code-line-current"))
					throw "the line the extension is stopped on should be marked";
				// The editor goes to the line and the panel shows the stop.
				if (bench.active.get() != rays || bench.caretLine(rays) != 6 || bench.bottom.get() != "extension" || studio.panel.get() != "debug")
					throw "a stop should show its line in the editor and open the Debug panel";
				if (!has("#rayde-debug-continue") || has("#rayde-debug-pause"))
					throw "while stopped the toolbar offers Continue, not Pause";
				shot("debug-stopped");
				// An expression in the frame, and the members of a variable.
				click("#rayde-debug-evaluate");
				type("#rayde-debug-evaluate", "entry.amount");
				press(Named(Enter));
				until(() -> d.evaluation.get() != null && d.evaluation.get().ok && d.evaluation.get().text == "5", "the expression to be evaluated");
				var entry = Lambda.find(d.locals.get(), v -> v.name == "entry");
				d.toggleOpen(entry.ref);
				until(() -> d.membersOf(entry.ref).length == 2, "the members of entry");
				settle(5);
				shot("debug-variables");
				// The caller's frame has its own variables.
				click("#rayde-frame-1");
				until(() -> d.frame.get() == 1 && d.locals.get().length == 0, "the caller's variables");
				d.select(0);
				until(() -> d.locals.get().length == 3, "the variables of the top frame again");
				// Stepping: over to the next line, and out to the caller.
				click("#rayde-debug-over");
				until(stoppedAt(8), "the step to the next line");
				if (d.stopped.get().reason != "step")
					throw "a step stops because of the step";
				if (says("5"))
					throw "line 7 has run, so the signal has changed, but the view has not been flushed while stopped";
				click("#rayde-debug-out");
				until(stoppedAt(14), "the step out to the caller");
				shot("debug-stepped-out");
				// Going on: the extension runs, the view shows the change, and nothing is stopped.
				click("#rayde-debug-continue");
				until(() -> d.stopped.get() == null && says("5"), "the extension to go on and show the total");
				settle(5);
				if (has(".ui-code-line-current"))
					throw "the mark on the line goes when the extension goes on";
				// A breakpoint comes off with the same command and is not kept.
				bench.goTo(rays, 6, 0);
				settle(5);
				@:privateAccess bench.toggleBreakpoint();
				if (d.linesOf(rays).length != 0 || sys.io.File.getContent(root + "/.rayde/settings.json").indexOf('"ext/main.rays"') >= 0)
					throw "removing the breakpoint should remove it from the project's settings";
				click("#rayde-tool-add");
				settle(30);
				if (d.stopped.get() != null)
					throw "without a breakpoint the action does not stop";
				// A breakpoint moves with the text: a line put in above it moves it down, in the editor and for the host.
				bench.goTo(rays, 6, 0);
				settle(5);
				@:privateAccess bench.toggleBreakpoint();
				settle(5);
				var typing = @:privateAccess bench.editorOf(rays);
				typing.select(0, 0);
				typing.editing.replace("// A line above.\n");
				settle(5);
				if (d.linesOf(rays).join(",") != "8")
					throw 'the breakpoint should have moved down to line 8 with the text: ${d.linesOf(rays)}';
				typing.undo();
				settle(5);
				if (d.linesOf(rays).join(",") != "7")
					throw 'and back up to line 7 when the line goes: ${d.linesOf(rays)}';
			});
		for (dark in [true, false])
			scenario(dark, "themes", (bench, file, shot, settle, scroll, click, type, hover, press, until) -> {
				settle();
				var tree = bench.tree, home = Sys.getCwd() + "bin/fixtures/themes-home";
				if (sys.FileSystem.exists(home))
					for (f in sys.FileSystem.readDirectory(home))
						deleteTree(haxe.io.Path.join([home, f]));
				else
					sys.FileSystem.createDirectory(home);
				Sys.putEnv("RAYDE_THEMES", home);
				var has = (selector:String) -> ashui.css.Css.query(tree, bench.node.id, selector).length > 0;
				var primary = () -> ashui.theme.ThemeState.get().color(ashui.theme.ColorToken.Primary).rgb();
				var clickNth = (selector:String, n:Int) -> {
					var found = ashui.css.Css.query(tree, bench.node.id, selector);
					if (found.length <= n)
						throw 'there is no $n-th element for $selector';
					var at = tree.getScrolledBounds(new ashui.layout.Node(found[n]));
					ashui.input.Pointer.move(tree, at.x + at.width / 2, at.y + at.height / 2);
					ashui.input.Pointer.press(tree);
					ashui.input.Pointer.release(tree);
					settle(6);
				};
				// The scheme is the one this run is for, so what a theme gives is known.
				bench.openSettings("appearance");
				settle(10);
				click(dark ? "#rayde-scheme-dark" : "#rayde-scheme-light");
				if (!has("#rayde-custom-theme-empty") || has("#rayde-custom-theme"))
					throw "with no custom theme installed the card says so and has no list";
				shot("themes-none");
				// Installing a theme from its folder, then choosing it from the list under the built-in ones.
				var root = Sys.getCwd();
				// The card is below the schemes and the built-in themes: the page is scrolled to it.
				scroll("#rayde-appearance", 900);
				click("#rayde-theme-path");
				type("#rayde-theme-path", root + "themes/midnight");
				click("#rayde-theme-install");
				if (!sys.FileSystem.exists(home + "/midnight/midnight.raytheme") || !sys.FileSystem.exists(home + "/midnight/midnight.css"))
					throw "the theme and its stylesheet should be in the themes folder";
				if (!has("#rayde-custom-theme") || has("#rayde-custom-theme-empty"))
					throw "once a theme is installed the card has a list of them";
				shot("themes-installed");
				var before = primary();
				click("#rayde-custom-theme");
				clickNth(".ui-select-item", 1);
				if (rayde.ui.Theming.current.get() != "midnight")
					throw 'Midnight should be in use, not ${rayde.ui.Theming.current.get()}';
				if (primary() != (dark ? 0x8b6cff : 0x6a4cf0) || primary() == before)
					throw 'Midnight\'s primary colour should be in use: ${StringTools.hex(primary(), 6)}';
				if (sys.io.File.getContent(bench.display().cwd + "/.rayde/settings.json").indexOf('"theme": "midnight"') < 0)
					throw "the choice should be kept in the settings";
				if (!has("#rayde-custom-details"))
					throw "the theme in use has its details under the list";
				settle(10);
				shot("themes-midnight");
				bench.openFile(file);
				settle(10);
				shot("themes-midnight-editor");
				// A second theme, from a single file: it takes the place of the first, and the first's rules stop applying with it.
				bench.openSettings("appearance");
				settle(10);
				scroll("#rayde-appearance", 900);
				click("#rayde-theme-path");
				type("#rayde-theme-path", root + "themes/paper/paper.raytheme");
				click("#rayde-theme-install");
				click("#rayde-custom-theme");
				clickNth(".ui-select-item", 2);
				if (rayde.ui.Theming.current.get() != "paper" || primary() != (dark ? 0xe08a5c : 0xb4532a))
					throw 'Paper should be in use with its own primary colour: ${rayde.ui.Theming.current.get()} ${StringTools.hex(primary(), 6)}';
				var shown = ashui.css.Identity.of(tree, bench.node.id).attribute("data-theme");
				if (shown != "paper")
					throw 'the window should carry the theme it is in: $shown';
				shot("themes-paper");
				// The scheme changes within a theme.
				scroll("#rayde-appearance", 0);
				click(dark ? "#rayde-scheme-light" : "#rayde-scheme-dark");
				if (primary() != (dark ? 0xb4532a : 0xe08a5c))
					throw "the other scheme of Paper should be in use";
				click(dark ? "#rayde-scheme-dark" : "#rayde-scheme-light");
				scroll("#rayde-appearance", 900);
				// A theme is taken away, and the window goes back to a built-in one.
				click("#rayde-theme-remove");
				if (sys.FileSystem.exists(home + "/paper") || sys.FileSystem.exists(home + "/paper.raytheme") || rayde.ui.Theming.current.get() != "restrained")
					throw "removing the theme in use removes its files and returns to a built-in theme";
				shot("themes-removed");
				click("#rayde-custom-theme");
				clickNth(".ui-select-item", 1);
				click("#rayde-custom-theme");
				clickNth(".ui-select-item", 0);
				if (rayde.ui.Theming.current.get() != "restrained")
					throw "choosing Built-in themes goes back to a built-in theme";
				Sys.putEnv("RAYDE_THEMES", "");
			});
		for (dark in [true, false])
			scenario(dark, "themestudio", (bench, theme, shot, settle, scroll, click, type, hover, press, until) -> {
				settle(10);
				var studio = bench.themeModel();
				if (studio == null)
					throw "opening a .raytheme should start the Theme Studio";
				var root = haxe.io.Path.directory(theme), read = () -> sys.io.File.getContent(theme);
				var primary = () -> ashui.theme.ThemeState.get().color(ashui.theme.ColorToken.Primary).rgb();
				var has = (selector:String) -> ashui.css.Css.query(bench.tree, bench.node.id, selector).length > 0;
				// Scrolls the page until the element `selector` finds is near the top.
				var reveal = (selector:String) -> {
					var card = ashui.css.Css.query(bench.tree, bench.node.id, selector)[0], area = ashui.css.Css.query(bench.tree, bench.node.id, "#rayde-theme-studio")[0];
					var scroller = ashui.input.Scroll.at(area, bench.tree);
					scroller.scrollTo(0, scroller.y.get() + bench.tree.getScrolledBounds(new ashui.layout.Node(card)).y - 140);
					settle(4);
				};
				if (studio.problems.get().length > 0)
					throw "the fixture theme should read cleanly: " + studio.problems.get().map(p -> p.message).join("; ");
				if (rayde.ui.Theming.current.get() != "studio" || primary() != (dark ? 0x4cc2a8 : 0x12806b))
					throw 'the theme in the file should be on the window: ${rayde.ui.Theming.current.get()} ${StringTools.hex(primary(), 6)}';
				shot("page");
				// A colour typed into its input is written where the file has it, and the window changes with it.
				click("#rayde-token-input-primary");
				type("#rayde-token-input-primary", "#ff5533");
				press(Named(Enter));
				until(() -> read().indexOf("#ff5533") > 0, "the colour to be written to the theme file");
				if (primary() != 0xff5533 || read().indexOf('"extends": "restrained"') < 0 || read().indexOf('"fonts": [{"family"') < 0)
					throw "the colour should be in use and the rest of the file left as written: " + read();
				if (bench.buffer(theme).get() != read())
					throw "the editor should hold what was written";
				shot("palette-edited");
				click("#rayde-token-reset-primary");
				until(() -> read().indexOf("#ff5533") < 0, "the colour to be taken out of the theme file");
				var base = primary();
				if (base == 0xff5533 || base == (dark ? 0x4cc2a8 : 0x12806b))
					throw "a reset colour goes back to the base theme's";
				// A font file from outside is copied beside the theme and listed under its family.
				var extra = Sys.getCwd() + "tests/fixtures/themestudio-extra/Lora-Italic.ttf";
				click("#rayde-font-path");
				type("#rayde-font-path", extra);
				click("#rayde-font-add");
				until(() -> read().indexOf("fonts/Lora-Italic.ttf") > 0, "the font file to be listed in the theme, under the family the file carries");
				if (!sys.FileSystem.exists(root + "/fonts/Lora-Italic.ttf") || studio.problems.get().length > 0)
					throw "the file should be copied beside the theme without problems: " + studio.problems.get().map(p -> p.message).join("; ");
				reveal("#rayde-theme-typography");
				shot("fonts-added");
				click("#rayde-font-remove-Lora-Italic-ttf");
				until(() -> read().indexOf("fonts/Lora-Italic.ttf") < 0, "the font file to be taken out of the theme");
				// A family chosen for a role is set in that face on the window.
				click("#rayde-font-use-sans-Lora");
				until(() -> read().indexOf('"sans": "Lora"') > 0, "the family to be set for sans");
				settle(20);
				// The sans role is the interface's font: a label that was there before the change resolves to it.
				var label = ashui.css.Css.query(bench.tree, bench.node.id, "#rayde-files .ui-tree-row")[0];
				var family = ashui.css.Css.resolved(ashui.css.Identity.of(bench.tree, label), "font-family");
				if (family == null || family.indexOf("Lora") != 0)
					throw "the window's text should be set in the sans family: " + family;
				// The type card at the top of the view, to see the specimens and the window in the new face.
				reveal("#rayde-theme-typography");
				shot("fonts-sans");
				click("#rayde-font-sans");
				type("#rayde-font-sans", "");
				press(Named(Enter));
				until(() -> read().indexOf('"sans"') < 0, "the sans family to be taken out");
				// The scheme changes within the theme.
				scroll("#rayde-theme-studio", 0);
				click(dark ? "#rayde-theme-light" : "#rayde-theme-dark");
				until(() -> primary() == (dark ? 0x12806b : 0x4cc2a8), "the other scheme of the theme to be in use");
				shot("other-scheme");
				click(dark ? "#rayde-theme-dark" : "#rayde-theme-light");
				until(() -> primary() == base, "the scheme to come back");
				// A stylesheet added beside the theme, and what the style system says of its rules.
				click("#rayde-theme-css-new");
				type("#rayde-theme-css-new", "extra.css");
				click("#rayde-theme-css-add");
				until(() -> read().indexOf('"file": "extra.css"') > 0 && sys.FileSystem.exists(root + "/extra.css"), "the stylesheet to be created and listed");
				sys.io.File.saveContent(root + "/extra.css", ".rayde-card { not-a-property: 1; }");
				studio.refresh();
				if (!Lambda.exists(studio.problems.get(), p -> p.message.indexOf("not-a-property") >= 0))
					throw "the style system's warning should be among the problems: " + studio.problems.get().map(p -> p.message).join("; ");
				shot("css-warning");
				// Installing the theme puts it, with its stylesheets and fonts, in the user's themes.
				var home = Sys.getCwd() + "bin/fixtures/themestudio-home";
				if (sys.FileSystem.exists(home))
					deleteTree(home);
				Sys.putEnv("RAYDE_THEMES", home);
				scroll("#rayde-theme-studio", 0);
				click("#rayde-theme-install");
				for (installed in ["studio/studio.raytheme", "studio/studio.css", "studio/extra.css", "studio/fonts/Lora-Regular.ttf"])
					if (!sys.FileSystem.exists(home + "/" + installed))
						throw 'installing the theme should bring $installed';
				if (!has("#rayde-theme-install-note"))
					throw "installing says where the theme went";
				shot("installed");
				Sys.putEnv("RAYDE_THEMES", "");
				// Typing in the editor: broken text keeps the last theme in force, and a mistake in the content is a problem on its line.
				bench.openFile(theme);
				var buffer = bench.buffer(theme), good = buffer.get();
				buffer.set("{nope");
				bench.edited(theme);
				until(() -> studio.stale.get(), "the broken text to be seen");
				if (primary() != base)
					throw "the last readable theme should stay on the window";
				if (!Lambda.exists(bench.problems.get(), p -> p.file == theme && p.severity == 1 && p.message.indexOf("Invalid JSON") == 0))
					throw "text that is not JSON is an error of the theme file";
				shot("text-broken");
				buffer.set(StringTools.replace(good, '"extends": "restrained"', '"extends": "gothic", "tint": 1'));
				bench.edited(theme);
				until(() -> !studio.stale.get() && studio.problems.get().length >= 2, "the mistakes in the content to be found");
				if (!Lambda.exists(bench.problems.get(), p -> p.file == theme && p.message.indexOf("gothic") >= 0 && p.range.start.line == 6))
					throw "a problem is on the line of the entry it names: " + bench.problems.get().map(p -> p.message + "@" + p.range.start.line).join("; ");
				shot("problems-text");
				bench.openThemeStudio();
				settle(10);
				shot("problems");
				click("#rayde-theme-problems .rayde-entry");
				if (bench.active.get() != theme)
					throw "a problem opens the theme as text";
				buffer.set(good);
				bench.edited(theme);
				until(() -> studio.problems.get().length == 0 || Lambda.foreach(studio.problems.get(), p -> p.message.indexOf("not-a-property") >= 0), "the fixed text to read again");
				bench.openThemeStudio();
				settle(20);
				reveal("#rayde-theme-gallery");
				shot("gallery");
				scroll("#rayde-theme-studio", 5000);
				shot("gallery-end");
			});
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
					sys.io.File.copy(source, target);
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
		// SNAPSHOT_ONLY=extension runs just that scenario.
		var only = Sys.getEnv("SNAPSHOT_ONLY");
		if (only != null && only != "" && only != name)
			return;
		var root = copyOf(name), server = new CompilerServer();
		ThemeState.init(RestrainedTheme.bundle(), dark ? Dark : Light);
		rayde.ui.Style.use();
		// A fixture with a .rayext is an extension project, opened from that file with no build.
		var config = Lambda.find(sys.FileSystem.readDirectory(root), f -> StringTools.endsWith(f, ".rayext"));
		var extension = config == null ? null : Manifest.read(root + "/" + config);
		// A fixture with a .raytheme is a theme project, in the scheme this run is for.
		var themeName = Lambda.find(sys.FileSystem.readDirectory(root), f -> StringTools.endsWith(f, ".raytheme"));
		var theme = themeName == null ? null : rayde.theme.ThemeFile.read(root + "/" + themeName);
		if (theme != null) {
			var chosen = new rayde.settings.Appearance();
			chosen.scheme = dark ? "dark" : "light";
			chosen.save(root);
		}
		var display = extension != null || theme != null ? new Display(server, root, []) : Display.ofHxml(server, root + "/build.hxml"), tree = new LayoutTree(), bench:Workbench = null, stop:Void->Void = null;
		var view = Owner.root(tree, s -> {
			stop = s;
			return bench = new Workbench({display: display, name: extension != null ? extension.name : theme != null ? theme.name : name, runtime: extension != null ? "rayscript" : "ash", extension: extension, theme: theme});
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
			var found = ashui.css.Css.query(tree, view.node.id, selector), area = ashui.css.Css.query(tree, view.node.id, "#rayde-build, #rayde-extension-config, #rayde-theme-studio");
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
		if (extension != null || theme != null)
			bench.openProject();
		steps(bench, extension != null ? extension.mainPath() : theme != null ? theme.file : root + "/src/Main.hx", shot, settle, scroll, click, type, hover, press, until);
		stop();
		tree.dispose();
		server.stop();
	}
}
