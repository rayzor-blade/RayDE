import rayde.build.HxmlFile;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.keys.Chord;
import rayde.keys.KeyBindings;
import rayde.ext.ExtensionHost;
import rayde.ui.AppIcon;
import rayde.files.FileOps;
import rayde.ext.Hooks;
import rayde.ext.Manifest;
import rayde.ext.OrderedJson;
import rayde.keys.Keymaps;
import rayde.run.Haxelib;
import rayde.run.Runner;
import rayde.settings.Appearance;
import rayde.settings.Extensions;
import rayde.settings.Store;
import rayde.theme.ThemeCss;
import rayde.theme.ThemeFile;
import rayde.theme.Themes;
import rayde.term.KeyMap;
import rayde.term.Terminal;
import window.Key;

using StringTools;

/**
 * The language layer against the real Haxe compiler: one fixture project,
 * each display request checked for what it should find, a buffer typed as the
 * editor holds it rather than as saved, and a server that died coming back.
 */
class Checks {
	static var failures:Array<String> = [];

	static function check(ok:Bool, what:String):Void
		if (!ok)
			failures.push(what);

	/** The byte offset just after `marker`'s first appearance, plus `shift`. */
	static function at(text:String, marker:String, shift = 0):Int {
		var i = text.indexOf(marker);
		if (i < 0)
			throw 'fixture has no "$marker"';
		return haxe.io.Bytes.ofString(text.substr(0, i)).length + shift;
	}

	/** Ticks a run until it ends, or a minute passes; its final state. */
	static function finish(runner:Runner):String {
		runner.start();
		var end = haxe.Timer.stamp() + 90;
		while (runner.active() && haxe.Timer.stamp() < end) {
			runner.tick();
			Sys.sleep(.02);
		}
		runner.tick();
		return runner.state;
	}

	/** The build file model: what it reads of a file, and that an edit changes only the lines it names. */
	static function hxmlChecks():Void {
		var text = "# the build\n-cp src\n-cp test\n-main Main\n-lib hxcpp\n--library tink_hxx:0.25.1\n-D debug\n--define my-flag=on\n-dce full\n--macro Sys.println('x')\n-hl out/app.hl\n\n";
		var f = new HxmlFile("x.hxml", text);
		check(f.values("-cp").join(",") == "src,test", 'class paths: ${f.values("-cp")}');
		check(f.value("--main") == "Main", "the main class, named with -main");
		check(f.values("-lib").join(",") == "hxcpp,tink_hxx:0.25.1", 'libraries: ${f.values("-lib")}');
		check(f.values("-D").join(",") == "debug,my-flag=on", 'defines: ${f.values("-D")}');
		check(f.value("--dce") == "full", "dead code elimination, named with -dce");
		check(f.target() != null && f.target().kind == "hl" && f.target().output == "out/app.hl", "the target and its output");
		check(f.others().length == 1 && f.others()[0].text.startsWith("--macro"), 'arguments the form leaves alone: ${f.others()}');
		check(f.text() == text, "a file read and written again is the same");
		f.set("--main", "App");
		f.add("-cp", "extra");
		f.remove("-lib", "hxcpp");
		f.setSwitch("--debug", true);
		f.setTarget("js", "bin/app.js");
		f.set("--dce", null);
		var edited = f.text();
		check(edited.startsWith("# the build\n-cp src\n-cp test\n--main App\n"), "the comment and the lines before the edit stay, the main class is rewritten in place");
		check(edited.indexOf("--macro Sys.println('x')") > 0, "an argument the form does not know is kept");
		check(edited.indexOf("hxcpp") < 0 && edited.indexOf("-dce") < 0 && edited.indexOf("-hl") < 0, "removed lines are gone");
		check(edited.indexOf("--js bin/app.js") > 0 && edited.indexOf("--debug") > 0 && edited.indexOf("-cp extra") > 0, "added lines are there");
		check(edited.endsWith("\n\n") && StringTools.trim(edited.substr(edited.length - 40)).indexOf("--js bin/app.js") >= 0, "new lines go before the blank lines that end the file");
		var multi = new HxmlFile("y.hxml", "-cp a\n--next\n-cp b\n");
		multi.add("-cp", "c");
		check(multi.multiple() && multi.values("-cp").join(",") == "a,c" && multi.text() == "-cp a\n-cp c\n--next\n-cp b\n", 'only the first compilation is edited: ${multi.text()}');
		var spaced = new HxmlFile("z.hxml", "");
		spaced.add("-D", "key=a value");
		check(spaced.text().indexOf('-D "key=a value"') >= 0 && spaced.value("-D") == "key=a value", "a value with a space is quoted and read back");
	}

	/** A shell through the native terminal: what it prints, in colour, on the screen; what is typed reaching it; and its exit. */
	static function settingsChecks():Void {
		var parse = (text:String, mac:Bool) -> Chord.parse(text, mac);
		check(parse("mod+shift+p", true).toString() == "shift+cmd+p", "mod is Command on a Mac");
		check(parse("mod+shift+p", false).toString() == "ctrl+shift+p", "mod is Control elsewhere");
		check(parse("Cmd+Shift+P", true).equals(parse("mod+shift+p", true)), "chord text is read without regard to case");
		check(parse("ctrl+shift+`", true).equals(Chord.ofEvent(Character("~"), true, true, false, false)), "Shift+` typed as ~ is the same chord");
		check(parse("ctrl+up", true).key == "up" && parse("ctrl+ArrowUp", true).key == "up", "arrow keys have one name");
		check(parse("f5", true).key == "f5" && parse("f21", true) == null, "function keys run to F20");
		check(parse("mod+", true) == null && parse("shift", true) == null && parse("ctrl+ctrl+p", true) == null && parse("", true) == null, "chords without a key, or with a modifier twice, are refused");
		check(parse("ctrl++", true).key == "=" && parse("ctrl++", true).shift, "ctrl++ is the plus key");
		check(parse("cmd+p", true).label(true) == "⌘P" && parse("shift+f5", true).label(true) == "⇧F5" && parse("ctrl+`", true).label(true) == "⌃`", "labels on a Mac");
		check(parse("ctrl+shift+p", false).label(false) == "Ctrl+Shift+P" && parse("alt+pageup", false).label(false) == "Alt+Page Up", "labels elsewhere");
		check(Chord.ofEvent(Named(Control), false, true, false, false) == null && Chord.ofEvent(Named(Shift), true, false, false, false) == null, "a modifier alone is no chord");
		check(Chord.ofEvent(Named(F12), false, false, false, false).key == "f12", "F12 is a chord");
		var capital = Chord.ofEvent(Character("P"), true, false, false, true);
		check(capital.key == "p" && capital.shift && capital.meta, "a capital letter with Shift is the lowercase key with Shift");

		var root = Sys.getCwd() + "bin/check-settings";
		if (sys.FileSystem.exists(root))
			for (f in ["libs.txt", "haxelib-stub.sh", ".rayde/keybindings.json", ".rayde/settings.json", ".rayde/run/haxelib.log", ".rayde/extensions/hello/hello.rayext", ".rayde/extensions/broken/broken.rayext"])
				if (sys.FileSystem.exists(root + "/" + f))
					sys.FileSystem.deleteFile(root + "/" + f);
		for (d in [root, root + "/.rayde", root + "/.rayde/run", root + "/.rayde/extensions", root + "/.rayde/extensions/hello", root + "/.rayde/extensions/broken"])
			if (!sys.FileSystem.exists(d))
				sys.FileSystem.createDirectory(d);

		var keys = new KeyBindings(true), p = parse.bind(_, true);
		check(keys.commandFor(p("cmd+p")) == "quickopen" && keys.commandFor(p("cmd+shift+p")) == "commands", "the defaults are bound");
		check(keys.commandFor(p("ctrl+p")) == null && keys.label("terminal") == "⌃`", "a default is bound to its own chord only");
		check(keys.commandFor(p("cmd+m")) == "minimize" && keys.commandFor(p("ctrl+cmd+f")) == "fullscreen" && keys.commandFor(p("f11")) == "stepinto", "the window's keys on a Mac: minimize, and full screen where macOS has it; F11 is Step Into, as in VS Code's debugger");
		check(keys.commandFor(p("f9")) == "togglebreakpoint" && keys.commandFor(p("f10")) == "stepover" && keys.commandFor(p("shift+f11")) == "stepout" && keys.commandFor(p("f6")) == "pause", "the debugger's keys");
		var other = KeyBindings.read(root, false);
		check(other.commandFor(p("alt+shift+enter")) == "fullscreen" && other.label("minimize") == null, "and elsewhere: Alt+Shift+Enter is full screen, and minimize has no key");
		keys.set("run", p("f6"));
		check(keys.commandFor(p("f5")) == null && keys.commandFor(p("f6")) == "run" && keys.changed("run"), "a rebound command answers to its new key");
		keys.set("close", null);
		check(keys.label("close") == null && keys.commandFor(p("cmd+w")) == null && keys.changed("close"), "a key can be taken away");
		keys.save(root);
		var again = KeyBindings.read(root, true);
		check(again.label("run") == "F6" && again.label("close") == null && again.label("save") == "⌘S", "changes come back from the file");
		again.reset("run");
		check(again.label("run") == "F5" && !again.changed("run") && again.changed("close"), "reset puts the default back");
		again.set("stop", p("f5"));
		check(again.conflicts("run").join(",") == "stop" && again.conflicts("stop").join(",") == "run" && again.commandFor(p("f5")) == "run", "the same key on two commands is a conflict and the first one runs");
		again.set("stop", p("shift+f5"));
		check(!again.changed("stop"), "putting a command back where it was is not a change");
		again.resetAll();
		again.save(root);
		check(!sys.FileSystem.exists(root + "/.rayde/keybindings.json") && !again.anyChanged(), "with nothing changed there is no file");

		// Each binding is a chord; shared keys belong to distinct focus contexts.
		for (m in Keymaps.all)
			for (mac in [true, false]) {
				var seen = new Map<String, String>();
				for (e in m.keys) {
					var text = Keymaps.key(m, e.command, mac), chord = text == null ? null : Chord.parse(text, mac);
					check(text == null || chord != null, '${m.id}: "$text" for ${e.command} is not a chord');
					check(Keymaps.order.indexOf(e.command) >= 0, '${m.id} binds ${e.command}, which no keymap order names');
					if (chord == null)
						continue;
					check(!seen.exists(chord.toString()) || Keymaps.differentContexts(e.command,seen.get(chord.toString())), '${m.id} gives ${chord.label(mac)} to ${seen.get(chord.toString())} and ${e.command}');
					seen.set(chord.toString(), e.command);
				}
			}
		check(Keymaps.available(true).map(m -> m.id).indexOf("visualstudio") < 0 && Keymaps.available(false).map(m -> m.id).indexOf("xcode") < 0, "a keymap of another platform is not offered");
		var jetbrains = new KeyBindings(true, "intellij");
		check(jetbrains.label("quickopen") == "⇧⌘O" && jetbrains.label("run") == "⌃R" && jetbrains.label("terminal") == "⌥F12", 'IntelliJ on a Mac: ${jetbrains.label("quickopen")} ${jetbrains.label("run")} ${jetbrains.label("terminal")}');
		check(new KeyBindings(false, "intellij").label("quickopen") == "Ctrl+Shift+N" && new KeyBindings(false, "intellij").label("settings") == "Ctrl+Alt+S", "IntelliJ elsewhere");
		var vs = new KeyBindings(true), plain = new KeyBindings(false);
		check(vs.label("renamesymbol") == "F2" && vs.conflicts("renamesymbol").indexOf("filerename") < 0 && plain.conflicts("filerename").indexOf("renamesymbol") < 0,"Contextual rename keys are missing or reported as conflicts");
		check(vs.label("filecopy") == "⌘C" && vs.label("filecut") == "⌘X" && vs.label("filepaste") == "⌘V" && vs.label("filerename") == "F2" && vs.label("fileduplicate") == "⌘D", 'file keys on a Mac: ${vs.label("filecopy")} ${vs.label("filepaste")} ${vs.label("filerename")}');
		check(vs.label("filedelete") == "⌘⌫" && plain.label("filedelete") == "Delete" && parse("mod+enter", true).label(true) == "⌘↩", 'delete is Command+Backspace on a Mac and Delete elsewhere: ${vs.label("filedelete")} ${plain.label("filedelete")}');
		check(plain.label("filecopypath") == "Alt+Shift+C" && vs.label("filecopypath") == "⌥⌘C" && plain.label("filereveal") == "Alt+Shift+R", 'copy path and reveal have keys: ${plain.label("filecopypath")} ${vs.label("filecopypath")} ${plain.label("filereveal")}');
		check(new KeyBindings(true, "intellij").label("filerename") == "⇧F6", "a keymap names its own rename");
		check(new KeyBindings(true, "nonesuch").preset == "vscode" && new KeyBindings(true).label("quickopen") == "⌘P", "an unknown keymap is the default");
		var moving = new KeyBindings(true);
		moving.set("run", p("f6"));
		moving.set("gotoline", p("cmd+l"));
		moving.setPreset("intellij");
		check(moving.label("run") == "F6" && moving.changed("run"), "a change stays when the keymap does");
		check(!moving.changed("gotoline") && moving.label("gotoline") == "⌘L", "a change that is now what the keymap says is no change");
		moving.setPreset("sublime");
		check(moving.label("stop") == null && !moving.inKeymap("stop") && moving.inKeymap("run") && moving.commandFor(p("cmd+b")) == null, "a command the keymap has no key for has none, and one changed leaves the keymap's key free");
		check(moving.commandFor(p("cmd+shift+p")) == "commands" && moving.commandFor(p("cmd+shift+o")) == null, "the keymap in use answers to its own keys");
		moving.save(root);
		var restored = KeyBindings.read(root, true);
		check(restored.preset == "sublime" && restored.label("run") == "F6" && restored.label("commands") == "⇧⌘P", "the keymap and the changes on it come back from the files");
		restored.setPreset("vscode");
		restored.resetAll();
		restored.save(root);

		Store.save(root, "terminal", {cursor: "bar"});
		Store.save(root, "elsewhere", {kept: true});
		var a = new Appearance();
		a.theme = "hybrid";
		a.scheme = "system";
		a.save(root);
		check(Store.section(root, "terminal").cursor == "bar" && Store.section(root, "elsewhere").kept == true, "saving a section keeps the others");
		var back = Appearance.read(root);
		check(back.theme == "hybrid" && back.scheme == "system" && back.windowControls == "auto", "the colour scheme comes back from the file, the window controls at the platform's default");
		a.windowControls = "kde";
		a.save(root);
		check(Appearance.read(root).windowControls == "kde" && Appearance.read(root).theme == "hybrid", "the style of the window's controls is kept beside the scheme");
		Store.save(root, "appearance", {windowControls: "amiga"});
		check(Appearance.read(root).windowControls == "auto", "a style that does not exist falls back to the platform's");
		a.windowControls = "auto";
		Store.save(root, "appearance", {theme: "nonesuch", scheme: "purple"});
		check(Appearance.read(root).theme == "nonesuch" && Appearance.read(root).scheme == "dark", "a theme the file names is kept, to be looked up when it is used, and an unknown scheme falls back to the default");
		Store.save(root, "appearance", {theme: "no such!", scheme: "dark"});
		check(Appearance.read(root).theme == "restrained", "a theme id that cannot be one falls back to the default");
		check(Store.section(root + "/nowhere", "terminal").cursor == null, "a missing file is an empty section");

		var libs = Haxelib.parse("3 libraries found:\nhashlink: [dev:/src/hashlink]\ntink_hxx: 0.4.0 [0.5.0]\nformat: 3.7.0\n");
		check(libs.length == 3 && libs[0].version == "dev" && libs[1].version == "0.5.0" && libs[2].version == "", 'haxelib list is read: ${libs.map(l -> l.name + "=" + l.version)}');

		var stub = root + "/haxelib-stub.sh";
		sys.io.File.saveContent(stub, "#!/bin/sh\nstate=\"$(dirname \"$0\")/libs.txt\"\ncase \"$1\" in\n list) cat \"$state\" 2>/dev/null ;;\n --always) shift; case \"$1\" in install) echo \"$2: [${3:-1.0.0}]\" >> \"$state\"; echo \"Installed $2\" ;; update) echo \"Updated $2\" ;; esac ;;\n remove) grep -v \"^$2:\" \"$state\" > \"$state.new\"; mv \"$state.new\" \"$state\"; echo \"Removed $2\" ;;\nesac\n");
		Sys.command("chmod", ["+x", stub]);
		Sys.putEnv("RAYDE_HAXELIB", stub);
		Haxelib.refresh();
		check(Haxelib.installed().length == 0, "the stand-in starts with no libraries");
		var wait = (job:rayde.run.Job) -> {
			job.start();
			var end = haxe.Timer.stamp() + 20;
			while (job.running() && haxe.Timer.stamp() < end)
				Sys.sleep(.02);
			return job;
		};
		var install = wait(Haxelib.install(root, "tink_macro", "1.2.3"));
		Haxelib.refresh();
		check(install.exit == 0 && install.read().indexOf("Installed tink_macro") >= 0, "install runs and prints its output");
		check(Haxelib.installed().length == 1 && Haxelib.installed()[0].name == "tink_macro" && Haxelib.installed()[0].version == "1.2.3", "an installed library is listed with its version");
		wait(Haxelib.remove(root, "tink_macro"));
		Haxelib.refresh();
		check(Haxelib.installed().length == 0, "a removed library is no longer listed");
		Sys.putEnv("RAYDE_HAXELIB", "");
		Haxelib.refresh();

		sys.io.File.saveContent(root + "/.rayde/extensions/hello/hello.rayext", '{"name": "Hello", "version": "0.1.0", "description": "Says hello", "main": "hello.rays"}');
		sys.io.File.saveContent(root + "/.rayde/extensions/broken/broken.rayext", "{ not json");
		var found = [for (e in Extensions.list(root)) if (e.scope == "Workspace") e];
		check(found.length == 2 && found[0].id == "broken" && found[0].problem != null && found[1].name == "Hello" && found[1].version == "0.1.0", 'extensions are found: ${found.map(e -> e.id + ":" + e.problem)}');
	}

	static function terminalChecks():Void {
		var t = Terminal.open(40, 6, null, "/bin/sh", ["-c", "printf 'hello\\n'; printf '\\033[1;31mred\\033[0m plain\\n'; read x; printf 'got:%s\\n' $x"]);
		if (t == null) {
			failures.push("the terminal could not start a shell");
			return;
		}
		var end = haxe.Timer.stamp() + 5;
		while (t.line(1).indexOf("plain") < 0 && haxe.Timer.stamp() < end)
			Sys.sleep(.02);
		check(t.line(0) == "hello", 'the first row: "${t.line(0)}"');
		var runs = t.row(1);
		check(runs.length >= 2 && runs[0].text == "red" && runs[0].attrs & 1 == 1 && runs[0].fg == (1 << 24 | 1), 'colour and bold came as a run: ${runs}');
		check(t.screen().rows == 6 && t.screen().cols == 40, "the screen's size");
		check(t.exitCode() == -1, "the shell is still running");
		check(t.write("abc\n"), "typing was written");
		end = haxe.Timer.stamp() + 5;
		while (t.line(3).indexOf("got:abc") < 0 && haxe.Timer.stamp() < end)
			Sys.sleep(.02);
		check(t.line(2) == "abc", 'the terminal echoed what was typed: "${t.line(2)}"');
		check(t.line(3) == "got:abc", 'typing reached the program: "${t.line(3)}"');
		end = haxe.Timer.stamp() + 5;
		while (t.exitCode() == -1 && haxe.Timer.stamp() < end)
			Sys.sleep(.02);
		check(t.exitCode() == 0, "the exit code");
		check(t.dirtyRows().length > 0, "rows are dirty at first");
		check(t.dirtyRows().length == 0, "and clean once looked at");
		t.close();
	}

	/** What keys send a program, which is what xterm sends. */
	static function keyChecks():Void {
		var sends = (key:Key, shift:Bool, control:Bool, alt:Bool, application:Bool) -> KeyMap.encode(key, shift, control, alt, application);
		check(sends(Named(Enter), false, false, false, false) == "\r", "Enter sends a carriage return");
		check(sends(Named(Backspace), false, false, false, false) == "\x7f", "Backspace sends delete");
		check(sends(Character("c"), false, true, false, false) == "\x03", "Ctrl+C is the interrupt");
		check(sends(Character("x"), false, false, true, false) == "\x1bx", "Alt puts an escape before the key");
		check(sends(Named(ArrowUp), false, false, false, false) == "\x1b[A", "up arrow");
		check(sends(Named(ArrowUp), false, false, false, true) == "\x1bOA", "up arrow in application mode");
		check(sends(Named(ArrowRight), false, true, false, false) == "\x1b[1;5C", "Ctrl+right carries its modifier");
		check(sends(Named(Tab), true, false, false, false) == "\x1b[Z", "Shift+Tab");
		check(sends(Named(F5), false, false, false, false) == "\x1b[15~", "F5");
		check(sends(Named(Delete), false, false, false, false) == "\x1b[3~", "Delete");
		check(sends(Character("é"), false, false, false, false) == "é", "a character is sent as it is");
		check(KeyMap.mouse(0, 5, 3, false, 2) == "\x1b[<0;5;3M" && KeyMap.mouse(0, 5, 3, true, 2) == "\x1b[<0;5;3m", "mouse reports in the sgr form");
	}

	/** The icons for each platform exist and are what their formats say. */
	static function iconChecks():Void {
		var icon = AppIcon.window();
		check(icon.width == 256 && icon.height == 256 && icon.pixels != null && icon.pixels.length == 256 * 256 * 4, "the window icon is 256 by 256 RGBA pixels");
		var alphaAt = (x:Int, y:Int) -> icon.pixels.get((y * icon.width + x) * 4 + 3);
		check(alphaAt(0, 0) == 0 && alphaAt(255, 255) == 0 && alphaAt(128, 128) >= 250, "the window icon is cut to its shape: clear at the corner, solid in the middle");
		var root = Sys.getCwd() + "assets/icons/";
		var ico = sys.io.File.getBytes(root + "rayde.ico");
		check(ico.getUInt16(0) == 0 && ico.getUInt16(2) == 1 && ico.getUInt16(4) == 7, "the .ico holds seven images");
		var sizes = [for (i in 0...7) ico.get(6 + i * 16) == 0 ? 256 : ico.get(6 + i * 16)];
		check(sizes.join(",") == "16,24,32,48,64,128,256", 'the .ico sizes: $sizes');
		var icns = sys.io.File.getBytes(root + "rayde.icns");
		check(icns.getString(0, 4) == "icns" && icns.length > 100000, "the .icns has its header");
		for (s in [16, 24, 32, 48, 64, 128, 256, 512, 1024]) {
			var png = sys.io.File.getBytes(root + 'hicolor/${s}x${s}/apps/rayde.png');
			check(png.get(1) == "P".code && png.getString(1, 3) == "PNG", 'hicolor ${s}x$s is a PNG');
			var big = (png.get(16) << 24) | (png.get(17) << 16) | (png.get(18) << 8) | png.get(19);
			check(big == s, 'hicolor ${s}x$s is $s pixels wide: $big');
		}
	}

	/** What the Explorer's menus do to files: made, renamed and deleted inside the project, and refused with a reason outside it or on a bad name. */
	static function fileOpsChecks():Void {
		var root = Sys.getCwd() + "bin/check-fileops";
		if (sys.FileSystem.exists(root))
			for (e in sys.FileSystem.readDirectory(root))
				FileOps.delete(root, root + "/" + e);
		else
			sys.FileSystem.createDirectory(root);
		var refused = (f:Void->Void) -> {
			try {
				f();
				return null;
			} catch (e:Dynamic)
				return Std.string(e);
		};
		var a = FileOps.createFile(root, root, "a.txt");
		check(a == root + "/a.txt" && sys.FileSystem.exists(a), "a file is made");
		check(refused(() -> FileOps.createFile(root, root, "a.txt")) == "a.txt is already there.", "a file that is there is not made again");
		var dir = FileOps.createFolder(root, root, "src");
		check(sys.FileSystem.isDirectory(dir), "a folder is made");
		for (bad in ["", ".", "..", "a/b", "a\\b", " a", "a ", "x\x01"])
			check(FileOps.invalid(bad) != null && refused(() -> FileOps.createFile(root, root, bad)) != null, 'the name "${StringTools.replace(bad, "\x01", "^A")}" is refused');
		check(FileOps.invalid("Notes v2.md") == null, "a name with a space inside is fine");
		check(refused(() -> FileOps.createFile(root, "/tmp", "x.txt")) == "That is outside the project.", "nothing is made outside the project");
		sys.io.File.saveContent(dir + "/Main.hx", "class Main {}");
		sys.FileSystem.createDirectory(dir + "/deep");
		sys.io.File.saveContent(dir + "/deep/Util.hx", "class Util {}");
		var b = FileOps.rename(root, a, "b.txt");
		check(b == root + "/b.txt" && !sys.FileSystem.exists(a) && sys.FileSystem.exists(b), "a file is renamed");
		check(refused(() -> FileOps.rename(root, b, "src")) == "src is already there.", "a name that is taken is refused");
		check(FileOps.rename(root, b, "B.txt") == root + "/B.txt", "a change of capitals alone is allowed");
		check(refused(() -> FileOps.rename(root, root, "x")) != null && refused(() -> FileOps.delete(root, root)) != null, "the project's own folder is not renamed or deleted");
		check(FileOps.summary(dir) == "src (2 files)" && FileOps.summary(root + "/B.txt") == "B.txt", 'what a delete would take: ${FileOps.summary(dir)}');
		var open = [dir + "/Main.hx", dir + "/deep/Util.hx", root + "/B.txt"];
		var renamed = FileOps.rename(root, dir, "lib");
		var moved = FileOps.moved(open, dir, renamed);
		check(moved.get(open[0]) == root + "/lib/Main.hx" && moved.get(open[1]) == root + "/lib/deep/Util.hx" && !moved.exists(open[2]), "the open files under a renamed folder follow it");
		check(FileOps.under(open, dir).length == 2 && FileOps.under(open, root + "/B.txt").length == 1, "the open files under a path are found");
		FileOps.delete(root, renamed);
		check(!sys.FileSystem.exists(renamed), "a folder is deleted with what is in it");
		check(refused(() -> FileOps.delete(root, "/tmp/nothing-here")) == "That is outside the project.", "nothing is deleted outside the project");
		check(FileOps.relative(root, root + "/lib/Main.hx") == "lib/Main.hx", "paths are shown from the project");

		// Copies and moves.
		sys.FileSystem.createDirectory(root + "/pkg");
		sys.FileSystem.createDirectory(root + "/pkg/inner");
		sys.io.File.saveContent(root + "/pkg/Main.hx", "class Main {}");
		sys.io.File.saveContent(root + "/pkg/inner/Deep.hx", "class Deep {}");
		sys.io.File.saveContent(root + "/pkg/.hidden", "h");
		check(FileOps.uniqueName(root + "/pkg", "Other.hx") == "Other.hx", "a free name is kept");
		check(FileOps.uniqueName(root + "/pkg", "Main.hx") == "Main copy.hx", "a taken name gets copy before its extension");
		check(FileOps.duplicate(root, root + "/pkg/Main.hx") == root + "/pkg/Main copy.hx" && sys.io.File.getContent(root + "/pkg/Main copy.hx") == "class Main {}", "a file is duplicated beside itself");
		check(FileOps.duplicate(root, root + "/pkg/Main.hx") == root + "/pkg/Main copy 2.hx" && FileOps.duplicate(root, root + "/pkg/Main.hx") == root + "/pkg/Main copy 3.hx", "duplicates are numbered");
		check(FileOps.uniqueName(root + "/pkg", ".hidden") == ".hidden copy", "a name that starts with a dot has no extension");
		var dup = FileOps.duplicate(root, root + "/pkg");
		check(dup == root + "/pkg copy" && sys.io.File.getContent(dup + "/inner/Deep.hx") == "class Deep {}" && sys.FileSystem.exists(dup + "/.hidden"), "a folder is duplicated with what is in it");
		check(refused(() -> FileOps.copy(root, root + "/pkg", root + "/pkg/inner")) == "A folder cannot be copied into itself.", "a folder is not copied into itself");
		check(refused(() -> FileOps.copy(root, root + "/pkg/Main.hx", root + "/pkg")) == "Main.hx is already there.", "a copy does not overwrite");
		var into = FileOps.copy(root, root + "/pkg/Main.hx", dup + "/inner", "Renamed.hx");
		check(into == dup + "/inner/Renamed.hx" && sys.FileSystem.exists(into), "a copy can be given another name");
		sys.io.File.saveContent(root + "/pkg/Move.hx", "m");
		var moved = FileOps.move(root, root + "/pkg/Move.hx", dup);
		check(moved == dup + "/Move.hx" && !sys.FileSystem.exists(root + "/pkg/Move.hx") && sys.FileSystem.exists(moved), "a file is moved into a folder");
		check(refused(() -> FileOps.move(root, root + "/pkg/Main copy.hx", dup)) == "Main copy.hx is already there.", "a move does not overwrite");
		check(FileOps.move(root, moved, dup) == moved, "moving into the folder it is in changes nothing");
		check(refused(() -> FileOps.move(root, root + "/pkg", root + "/pkg/inner")) == "A folder cannot be moved into itself.", "a folder is not moved into itself");
		check(FileOps.move(root, moved, dup + "/inner") == dup + "/inner/Move.hx" && sys.FileSystem.exists(dup + "/inner/Move.hx"), "a file can be moved again");
		check(refused(() -> FileOps.move(root, root + "/pkg/Main.hx", "/tmp")) == "That is outside the project.", "nothing is moved out of the project");
	}

	/** Extension selectors and manifest paths, without mounting a view. */
	static function extensionStyleChecks():Void {
		var problems:Array<String> = [];
		function scoped(css:String):String return rayde.ext.ExtensionStyles.scope(css, "notes", problems, "s.css");
		var base = rayde.ext.ExtensionStyles.base("notes");
		check(base == '#rayde [data-extension="notes"]', "the views of an extension are found by an attribute under #rayde, above RayDE's own rules");
		check(scoped(".a, .b > c { color: red }") == '$base .a, $base .b > c { color: red }\n', 'each selector of a list is scoped: ${scoped(".a, .b > c { color: red }")}');
		check(StringTools.startsWith(scoped(":view { --background: #fff }"), base + " {"), "`:view` is the view itself");
		check(StringTools.startsWith(scoped(":root .x { top: 0 }"), base + " .x {"), "`:root` is the view, with what follows it");
		check(scoped(".a:not(.b, .c) { top: 0 }").indexOf(base + " .a:not(.b, .c) {") == 0, "a comma inside a pseudo-class is not a split");
		var media = scoped("@media (min-width: 100px) { .a { top: 0 } .b { top: 1 } }");
		check(media.indexOf("@media (min-width: 100px) {") == 0 && media.indexOf(base + " .a") > 0 && media.indexOf(base + " .b") > 0, 'rules inside @media are scoped: $media');
		var animated = scoped(".a { animation: spin 1s linear infinite; animation-name: spin } @keyframes spin { from { top: 0 } to { top: 1 } }");
		var name = "rayde-ext-" + haxe.crypto.Sha256.encode("notes").substr(0,16) + "-spin";
		check(animated.indexOf("@keyframes " + name + " {") >= 0 && animated.indexOf("animation: " + name + " 1s linear infinite") >= 0 && animated.indexOf("animation-name: " + name) >= 0, "keyframes and forward references share an extension-local name");
		check(scoped(".a { animation: var(--spin) } @keyframes --spin { from { opacity: 0 } to { opacity: 1 } }").indexOf("animation: var(--spin)") >= 0, "animation rewriting leaves function arguments and custom property names intact");
		check(problems.length == 0, 'good rules have no problems: $problems');
		check(scoped("@import url(a.css); .x { top: 0 }").indexOf("@import") < 0 && problems.length == 1, 'an @import is refused: $problems');
		var kept = scoped(".x { background: url(a.png); color: red }");
		check(kept.indexOf("url") < 0 && kept.indexOf("color: red") > 0 && problems.length == 2, 'url() is dropped and the rest kept: $kept $problems');
		check(scoped("@font-face { font-family: x }") == "" && problems.length == 3, 'an @font-face is refused: $problems');
		check(scoped("/* .x { top: 0 } */ .y { top: 1 }").indexOf(".x") < 0, "comments are gone");
		check(scoped(':view + #outside, :view:hover ~ #outside, + #outside { color: red }') == "", "root sibling combinators cannot escape the view");
		check(scoped(':view { & + #outside { color: red } }').indexOf("#outside") < 0, "nested rules cannot escape the root either");
		check(scoped(':view > .a + .b { color: red }').indexOf(base + ' > .a + .b') == 0, "siblings inside a view remain available");
		check(scoped('[title="a,b"] { content: "/* { , } */ url(x)"; color: red }').indexOf('[title="a,b"]') >= 0, "quoted punctuation does not split selectors or comments");
		check(scoped('.a { background: u\\72l(x); color: red }').indexOf('background') < 0, "escaped url functions are dropped too");
		var dir = Sys.getCwd() + "bin/check-styles";
		if (!sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
		sys.io.File.saveContent(dir + "/main.rays", "");
		sys.io.File.saveContent(dir + "/themed.rayext", '{"name":"Themed","main":"main.rays","styles":["a.css","../escape.css","/abs.css","readme.txt","a.css","sub/b.css"]}');
		var m = Manifest.read(dir + "/themed.rayext");
		check(m.styles.join(",") == "a.css,sub/b.css", 'only .css files inside the folder are styles, once each: ${m.styles}');
		check(m.problems.length == 3, 'the others are problems: ${m.problems}');
		sys.io.File.saveContent(dir + "/bad.rayext", '{"main":"main.rays","styles":"a.css"}');
		check(Manifest.read(dir + "/bad.rayext").problems[0] == '"styles" must be an array of strings.', "styles have a checked manifest type");
	}

	/** The .rayext config file: what it says, what it defaults to, and what is wrong with one that is wrong. */
	static function manifestChecks():Void {
		var dir = Sys.getCwd() + "bin/check-manifest";
		for (d in [dir, dir + "/ext"])
			if (!sys.FileSystem.exists(d))
				sys.FileSystem.createDirectory(d);
		sys.io.File.saveContent(dir + "/ext/main.rays", "");
		sys.io.File.saveContent(dir + "/notes.rayext", '{"name": "Notes", "version": "0.2.0", "description": "A panel", "main": "ext/main.rays", "sources": ["ext", "missing"], "mocks": "ext/answers.json", "capabilities": ["workspace.read"]}');
		var m = Manifest.read(dir + "/notes.rayext");
		check(m.problems.length == 0, 'a good file has no problems: ${m.problems}');
		check(m.name == "Notes" && m.version == "0.2.0" && m.description == "A panel" && m.capabilities.join(",") == "workspace.read", "the fields are read");
		check(m.mainPath() == sys.FileSystem.fullPath(dir) + "/ext/main.rays", 'the main script in full: ${m.mainPath()}');
		check(m.mocksPath() == sys.FileSystem.fullPath(dir) + "/ext/answers.json", 'the mocks file in full: ${m.mocksPath()}');
		check(m.sourceDirs().length == 1 && m.sourceDirs()[0].label == "ext", "a source folder that is not there is left out");
		check(m.importRoot() == sys.FileSystem.fullPath(dir) + "/ext", "imports come from the first source folder");
		sys.io.File.saveContent(dir + "/bare.rayext", "{}");
		var bare = Manifest.read(dir + "/bare.rayext");
		check(bare.name == "bare" && bare.main == "main.rays" && bare.sources.join(",") == "." && bare.mocks == "studio.mocks.json", 'the defaults: ${bare.name} ${bare.main} ${bare.sources} ${bare.mocks}');
		check(bare.problems.length == 1 && bare.problems[0] == "Main script main.rays not found.", 'a missing main script is a problem: ${bare.problems}');
		sys.io.File.saveContent(dir + "/inner.rayext", '{"main": "ext/start.rays"}');
		var inFolder = Manifest.read(dir + "/inner.rayext");
		check(inFolder.sources.join(",") == "ext" && inFolder.mocks == "ext/studio.mocks.json", 'defaults follow the main script: ${inFolder.sources} ${inFolder.mocks}');
		sys.io.File.saveContent(dir + "/broken.rayext", "{ not json");
		var broken = Manifest.read(dir + "/broken.rayext");
		check(broken.problems.length > 0 && StringTools.startsWith(broken.problems[0], "Invalid JSON"), 'bad JSON is said to be: ${broken.problems}');
		sys.io.File.saveContent(dir + "/list.rayext", "[1, 2]");
		check(Manifest.read(dir + "/list.rayext").problems[0] == "The config must be a JSON object.", "a JSON file that is not an object is refused");
		sys.io.File.saveContent(dir + "/types.rayext", '{"name": 3, "sources": "ext", "capabilities": [1]}');
		var types = Manifest.read(dir + "/types.rayext");
		check(types.name == "types" && types.problems.length >= 3, 'wrong types are named: ${types.problems}');
		check(Manifest.isManifest("a/notes.rayext") && !Manifest.isManifest("build.hxml"), "a config file is known by its extension");
		check(m.location == "sidebar" && m.viewTitle == "Notes" && m.viewIcon == null, "a view is in the sidebar, under the extension's name, with no icon, unless said otherwise");
		sys.io.File.saveContent(dir + "/ext/notes.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="M4 4h16v16H4z" fill="currentColor"/></svg>');
		sys.io.File.saveContent(dir + "/view.rayext", '{"name": "V", "main": "ext/main.rays", "view": {"title": "My notes", "icon": "ext/notes.svg", "location": "panel"}}');
		var v = Manifest.read(dir + "/view.rayext");
		check(v.problems.length == 0 && v.viewTitle == "My notes" && v.viewIcon == "ext/notes.svg" && v.location == "panel", 'the view is read: ${v.problems} ${v.viewTitle} ${v.location}');
		check(v.iconPath() == sys.FileSystem.fullPath(dir) + "/ext/notes.svg" && sys.FileSystem.exists(v.iconPath()), "the icon file's place is in full");
		sys.io.File.saveContent(dir + "/odd.rayext", '{"name": "O", "main": "ext/main.rays", "view": {"icon": "nowhere.svg", "location": "moon"}}');
		var odd = Manifest.read(dir + "/odd.rayext");
		sys.io.File.saveContent(dir + "/tools.rayext", '{"name": "T", "main": "ext/main.rays", "view": {"tools": [{"id": "add", "title": "Add", "icon": "ext/notes.svg"}, {"id": "refresh", "icon": "refresh"}, {"title": "no id"}, {"id": "add"}, "text", {"id": "gone", "icon": "missing.svg"}]}}');
		var tools = Manifest.read(dir + "/tools.rayext");
		check(tools.tools.length == 3 && tools.tools[0].id == "add" && tools.tools[0].title == "Add" && tools.tools[1].title == "refresh" && tools.tools[1].icon == "refresh", 'tools are read, the title defaulting to the id: ${tools.tools}');
		check(tools.toolIconPath(tools.tools[0]) == sys.FileSystem.fullPath(dir) + "/ext/notes.svg" && tools.toolIconPath(tools.tools[1]) == null, "a tool's icon is a file or a name");
		check(tools.problems.length == 4, 'the tools that are wrong are named: ${tools.problems}');
		sys.io.File.saveContent(dir + "/contrib.rayext", '{"name": "C", "main": "ext/main.rays", "contributes": {"commands": [{"id": "preview", "title": "Markdown: Open Preview"}, {"id": "other"}], "menus": {"explorer/context": [{"command": "preview", "when": {"kind": "file", "ext": [".MD", ".markdown"]}}, {"command": "other", "title": "Do it", "when": {"name": "README*"}}], "editor/title": [{"command": "ghost"}, {"nothing": 1}]}}}');
		var contrib = Manifest.read(dir + "/contrib.rayext");
		check(contrib.commands.length == 2 && contrib.commands[0].title == "Markdown: Open Preview" && contrib.commands[1].title == "other", 'commands are read: ${contrib.commands}');
		check(contrib.problems.length == 2 && contrib.problems[0].indexOf('unknown command "ghost"') > 0, 'menu mistakes are named: ${contrib.problems}');
		var menu = (path:String, kind:String) -> contrib.menuFor("explorer/context", path, kind).map(i -> i.command + ":" + i.title);
		check(menu("a/README.md", "file").join(",") == "preview:Markdown: Open Preview,other:Do it", 'a README.md gets both: ${menu("a/README.md", "file")}');
		check(menu("a/notes.markdown", "file").join(",") == "preview:Markdown: Open Preview", "the extension is matched without regard to case");
		check(menu("a/README.md", "folder").join(",") == "other:Do it" && menu("a/notes.txt", "file").length == 0 && menu("a/Main.hx", "file").length == 0, "kind and extension limit an item");
		check(contrib.menuFor("editor/context", "x.md", "file").length == 0, "a location with no items gives none");
		check(Manifest.applies({kind: null, ext: [], name: "*.test.hx"}, "a/Foo.test.hx", "file") && !Manifest.applies({kind: null, ext: [], name: "*.test.hx"}, "a/Foo.hx", "file") && Manifest.applies({kind: null, ext: [], name: "a*c"}, "abc", "file") && !Manifest.applies({kind: null, ext: [], name: "a*c"}, "abcd", "file"), "a name pattern takes * for any run");
		check(odd.location == "sidebar" && odd.problems.length == 2, 'a wrong location and a missing icon are named: ${odd.problems}');
		// An item shows its command's icon unless it has one of its own; an SVG file that is missing is named.
		sys.io.File.saveContent(dir + "/places.rayext", '{"name": "P", "main": "ext/main.rays", "contributes": {"commands": [{"id": "a"}], "menus": {"editor/title": [{"command": "a"}], "explorer/context": [{"command": "a"}], "moon/context": [{"command": "a"}]}}}');
		var places = Manifest.read(dir + "/places.rayext");
		check(places.problems.length == 1 && places.problems[0].indexOf('"moon/context"') > 0 && places.problems[0].indexOf(Hooks.menuIds().join(" or ")) > 0, 'a menu location that does not exist is named with the ones that do: ${places.problems}');
		check(places.menuFor("editor/title", "a.md", "file").length == 1, "each location has its own items");
		check(Hooks.knownEvent("file.saved") && Hooks.knownEvent("view.visibility") && !Hooks.knownEvent("file.save") && Hooks.knownMenu("editor/title") && Hooks.knownMenu("editor/context") && !Hooks.knownMenu("editor/unknown"), "hooks and menus are told apart by name");
		sys.io.File.saveContent(dir + "/icons.rayext", '{"name": "I", "main": "ext/main.rays", "contributes": {"commands": [{"id": "a", "title": "A", "icon": "ext/notes.svg"}, {"id": "b", "title": "B", "icon": "eye"}, {"id": "c", "title": "C", "icon": "gone.svg"}, {"id": "d"}], "menus": {"explorer/context": [{"command": "a"}, {"command": "b", "icon": "star"}, {"command": "d"}, {"command": "d", "icon": "nowhere.svg"}]}}}');
		var icons = Manifest.read(dir + "/icons.rayext");
		var shown = icons.menuFor("explorer/context", "x", "file").map(i -> i.command + ":" + i.icon);
		check(shown.join(",") == "a:ext/notes.svg,b:star,d:null,d:nowhere.svg", 'a menu item takes its command\'s icon, or its own: $shown');
		check(icons.iconFile("ext/notes.svg") == sys.FileSystem.fullPath(dir) + "/ext/notes.svg" && icons.iconFile("eye") == null && icons.iconFile(null) == null, "an icon is a file in the extension, or a name of RayDE's");
		check(icons.problems.length == 2 && icons.problems[0].indexOf("gone.svg") > 0 && icons.problems[1].indexOf("nowhere.svg") > 0, 'icon files that are missing are named: ${icons.problems}');

		// The form adds and removes commands and menu items; what it did not touch stays as written, and an emptied `contributes` goes.
		var cfile = dir + "/contribute-edit.rayext";
		sys.io.File.saveContent(cfile, '{\n  "zeta": 1.50,\n  "name": "E",\n  "main": "ext/main.rays"\n}\n');
		Manifest.addCommand(cfile, {id: "preview", title: "Preview", icon: "eye"});
		Manifest.addCommand(cfile, {id: "other", title: "other", icon: null});
		Manifest.addMenuItem(cfile, "explorer/context", {command: "preview", title: null, icon: null, when: {kind: "file", ext: [".md"], name: null}});
		Manifest.addMenuItem(cfile, "explorer/context", {command: "other", title: "Do it", icon: "star", when: {kind: null, ext: [], name: "README*"}});
		var edited = Manifest.read(cfile);
		check(edited.problems.length == 0 && edited.commands.length == 2 && edited.commands[1].title == "other", 'commands are added: ${edited.problems} ${edited.commands}');
		var entries = edited.menuFor("explorer/context", "x/README.md", "file").map(i -> i.command + ":" + i.title + ":" + i.icon);
		check(entries.join(",") == "preview:Preview:eye,other:Do it:star", 'menu items are added with their conditions: $entries');
		check(sys.io.File.getContent(cfile).indexOf('"zeta": 1.50') > 0, "what the edit did not touch is as written");
		Manifest.addCommand(cfile, {id: "preview", title: "Open preview", icon: null});
		check(Manifest.read(cfile).commands[0].title == "Open preview" && Manifest.read(cfile).commands.length == 2, "a command with an id that exists is replaced where it is");
		Manifest.removeMenuItem(cfile, "explorer/context", 0);
		check(Manifest.read(cfile).menus.get("explorer/context").length == 1, "a menu item is removed by its place");
		Manifest.removeCommand(cfile, "other");
		var after = Manifest.read(cfile);
		check(after.commands.length == 1 && !after.menus.exists("explorer/context") && after.problems.length == 0, 'removing a command removes the items that name it: ${after.problems}');
		Manifest.removeCommand(cfile, "preview");
		check(sys.io.File.getContent(cfile).indexOf("contributes") < 0, "an emptied contributes is not written");

		// A form edits the file and leaves the rest of it alone: the order of the keys, the keys it does not know, the text of numbers.
		var text = '{\n  "zeta": 1.50,\n  "name": "Keep",\n  "contributes": {"commands": [{"id": "a"}]},\n  "main": "ext/main.rays"\n}\n';
		sys.io.File.saveContent(dir + "/edit.rayext", text);
		Manifest.setText(dir + "/edit.rayext", "version", "1.0.0");
		Manifest.setText(dir + "/edit.rayext", "location", "secondary", true);
		Manifest.setText(dir + "/edit.rayext", "title", "Keep it", true);
		Manifest.setList(dir + "/edit.rayext", "capabilities", ["workspace.read", "terminal"]);
		var edited = sys.io.File.getContent(dir + "/edit.rayext");
		check(edited.indexOf('"zeta": 1.50') > 0, 'a number keeps its text: $edited');
		check(edited.indexOf('"zeta"') < edited.indexOf('"name"') && edited.indexOf('"name"') < edited.indexOf('"contributes"') && edited.indexOf('"contributes"') < edited.indexOf('"main"') && edited.indexOf('"main"') < edited.indexOf('"version"'), 'keys stay in order and new ones go last: $edited');
		check(edited.indexOf('"commands": [{') < 0 && edited.indexOf('"id": "a"') > 0, 'what the form does not know is kept: $edited');
		var again = Manifest.read(dir + "/edit.rayext");
		check(again.version == "1.0.0" && again.location == "secondary" && again.viewTitle == "Keep it" && again.capabilities.length == 2, 'the edit reads back: ${again.version} ${again.location} ${again.viewTitle}');
		Manifest.setText(dir + "/edit.rayext", "location", null, true);
		Manifest.setText(dir + "/edit.rayext", "title", "", true);
		var left = Manifest.read(dir + "/edit.rayext");
		check(left.views.length == 1 && left.views[0].id == "main" && left.views[0].location == "sidebar" && left.viewTitle == left.name, "a view with nothing left in it is still declared, with the defaults");
		Manifest.removeView(dir + "/edit.rayext", "main");
		check(Manifest.read(dir + "/edit.rayext").views.length == 0 && OrderedJson.get(OrderedJson.parse(sys.io.File.getContent(dir + "/edit.rayext")), "view") == null, "removing the view takes it out of the file");

		// Views: an extension declares as many as it likes, each in a part of the layout; a first one added to `view` moves into `views`.
		var vfile = dir + "/views.rayext";
		sys.io.File.saveContent(vfile, '{"name": "V", "main": "ext/main.rays", "zeta": 2.0}');
		check(Manifest.read(vfile).views.length == 0, "a config with no view declares none");
		Manifest.addView(vfile, {id: "main", title: "", icon: null, location: "sidebar", tools: []});
		check(sys.io.File.getContent(vfile).indexOf('"view": {}') > 0 && Manifest.read(vfile).views.length == 1, "a first view is written as `view`");
		Manifest.addTool(vfile, {id: "add", title: "Add", icon: "add"});
		Manifest.addView(vfile, {id: "inspector", title: "Inspector", icon: "eye", location: "secondary", tools: []});
		Manifest.addView(vfile, {id: "log", title: "", icon: null, location: "panel", tools: []});
		var many = Manifest.read(vfile);
		var describe = many.views.map(v -> v.id + "@" + v.location + ":" + v.title + ":" + v.tools.length).join(",");
		check(many.problems.length == 0 && describe == "main@sidebar:V:1,inspector@secondary:Inspector:0,log@panel:V:0", 'views are read in order, the first moved into views with its tools: $describe ${many.problems}');
		check(many.viewTitle == "V" && many.location == "sidebar" && many.tools.length == 1, "the first view is what the single-view fields name");
		check(sys.io.File.getContent(vfile).indexOf('"view"') < 0 && sys.io.File.getContent(vfile).indexOf('"zeta": 2.0') > 0, "`view` is gone once there are several, and what is not a view is kept");
		Manifest.setText(vfile, "location", "editor", true, "log");
		Manifest.addTool(vfile, {id: "clear", title: "Clear", icon: null}, "log");
		check(Manifest.read(vfile).viewOf("log").location == "editor" && Manifest.read(vfile).viewOf("log").tools[0].id == "clear", "a view is edited by its id");
		Manifest.removeTool(vfile, "clear", "log");
		Manifest.removeView(vfile, "inspector");
		check(Manifest.read(vfile).views.map(v -> v.id).join(",") == "main,log" && Manifest.read(vfile).viewOf("log").tools.length == 0, "a view and a tool are removed by id");
		sys.io.File.saveContent(dir + "/viewbad.rayext", '{"name": "B", "main": "ext/main.rays", "views": [{"id": "a"}, {"id": "a"}, {"title": "no id"}, {"id": "t:x"}, {"id": "b", "location": "moon", "tools": [{"id": "go"}]}, {"id": "c", "tools": [{"id": "go"}]}, "text"]}');
		var bad = Manifest.read(dir + "/viewbad.rayext");
		check(bad.views.length == 3 && bad.problems.length == 6, 'views that are wrong are named: ${bad.views.length} ${bad.problems}');
		var refused = false;
		sys.io.File.saveContent(dir + "/refuse.rayext", "{ not json");
		try
			Manifest.setText(dir + "/refuse.rayext", "name", "x")
		catch (_:Dynamic)
			refused = true;
		check(refused && sys.io.File.getContent(dir + "/refuse.rayext") == "{ not json", "a file that is not JSON is not overwritten");
		for (sample in ['{"a": [1, 2.5e3, -4], "b": {"c": null, "d": true}, "e": "x\\ny\\u00e9"}', "[]", "{}", '"s"'])
			check(OrderedJson.stringify(OrderedJson.parse(sample), "") != null, 'JSON is read: $sample');
		var bad = 0;
		for (sample in ['{"a": }', '{"a" 1}', "[1, 2", '"open', "{,}", "tru"])
			try
				OrderedJson.parse(sample)
			catch (_:Dynamic)
				bad++;
		check(bad == 6, 'six broken texts are all refused: $bad');
	}

	/** An embedded extension: a view comes back as operations, an event goes in, an error comes with its place. */
	static function extensionHostChecks():Void {
		var host = new ExtensionHost();
		// Waits for a message the test wants, polling as the frame loop would; everything seen on the way is kept.
		var seen:Array<Dynamic> = [];
		function until(want:Dynamic->Bool):Null<Dynamic> {
			var end = haxe.Timer.stamp() + 5;
			while (haxe.Timer.stamp() < end) {
				for (m in host.poll()) {
					seen.push(m);
					if (want(m))
						return m;
				}
				Sys.sleep(.01);
			}
			return null;
		}
		host.start();
		check(host.running(), "the host starts");
		var ready = until(m -> m.t == "ready");
		check(ready != null && ready.protocol == 1, "the host says it is ready");
		check(host.send({t: "run", name: "main.rays", source: "var n = signal(0); mount(() -> <button onClick={() -> n.value++}>{n}</button>, 'check');"}), "a message is sent");
		var ops = until(m -> m.t == "ops");
		check(ops != null && Std.string(ops.ops).indexOf("button") >= 0, 'the view comes back as operations: ${ops == null ? "nothing" : Std.string(ops.ops)}');
		var listen = ops == null ? null : Lambda.find((ops.ops : Array<Dynamic>), o -> o[0] == "listen");
		check(listen != null && listen[2] == "click", "the button asks for clicks");
		if (listen != null) {
			host.send({t: "event", node: listen[1], event: "click"});
			var text = until(m -> m.t == "ops");
			check(text != null && text.ops[0][0] == "setText" && text.ops[0][2] == "1", 'a click changes the text: ${text == null ? "nothing" : Std.string(text.ops)}');
		}
		host.send({t: "run", name: "bad.rays", source: "var ok = 1;\nvar = 2;"});
		var error = until(m -> m.t == "error");
		check(error != null && error.kind == "syntax" && error.items[0].line == 2 && error.items[0].col == 5, 'an error comes with its place: ${error == null ? "nothing" : Std.string(error.items)}');
		host.send({t: "this is not a message"});
		check(until(m -> m.t == "error" && m.kind == "protocol") != null, "a message the host cannot read is answered, not fatal");
		host.stop();
		check(host.state == "idle", "the host is stopped");
		// An explicit shutdown ends the embedded runtime.
		var second = new ExtensionHost();
		second.start();
		var gone = haxe.Timer.stamp() + 5;
		second.send({t: "shutdown"});
		while (second.state == "running" && haxe.Timer.stamp() < gone) {
			second.poll();
			Sys.sleep(.01);
		}
		check(second.state == "exited" && second.exitCode == 0, 'a shut down host exits: ${second.state} ${second.exitCode}');
		Sys.println('embedded extension host: ${seen.length} messages');
		markdownExtensionChecks();
	}

	/**
	 * The Markdown preview extension in a real host: a command mounts a tab built from a file's text, a hook
	 * brings it up to date, and closing the tab unmounts it. The file reads are answered here, as the workbench would.
	 */
	static function markdownExtensionChecks():Void {
		var fixture = Sys.getCwd() + "tests/fixtures/markdown/";
		var manifest = Manifest.read(fixture + "markdown.rayext");
		check(manifest.problems.length == 0, 'the markdown config reads cleanly: ${manifest.problems.join("; ")}');
		var items = manifest.menuFor("explorer/context", "docs/README.md", "file");
		check(items.length == 1 && items[0].command == "preview" && items[0].title == "Preview", "the config puts Preview in the Explorer's menu for a Markdown file");
		check(items[0].icon == "ext/preview.svg" && sys.FileSystem.exists(manifest.iconFile(items[0].icon)), "with the icon of its command");
		check(manifest.menuFor("explorer/context", "docs/notes.txt", "file").length == 0, "and for no other file");
		var host = new ExtensionHost(manifest.importRoot());
		host.start();
		var text = "# First\n\nSome **bold** text.";
		// Messages not yet looked at, so one batch can answer several waits.
		var queue:Array<Dynamic> = [];
		function until(want:Dynamic->Bool):Null<Dynamic> {
			var end = haxe.Timer.stamp() + 5;
			while (haxe.Timer.stamp() < end) {
				for (m in host.poll())
					queue.push(m);
				while (queue.length > 0) {
					var m = queue.shift();
					if (m.t == "call")
						host.send({t: "resolve", id: m.id, value: text});
					if (want(m))
						return m;
				}
				Sys.sleep(.01);
			}
			return null;
		}
		function ops(contains:String):Null<Dynamic>
			return until(m -> m.t == "ops" && Std.string(m.ops).indexOf(contains) >= 0);
		host.send({t: "module", path: "rayde.workspace", functions: ["readFile"]});
		host.send({t: "run", name: manifest.mainPath(), source: sys.io.File.getContent(manifest.mainPath())});
		check(until(m -> m.t == "started") != null, "the extension starts");
		var command = until(m -> m.t == "registered");
		check(command != null && command.id == "preview", "it registers the command the config lists");
		check(until(m -> m.t == "subscribe" && m.hook == "file.saved") != null, "and listens for saves");
		host.send({t: "command", id: "preview", args: {path: "README.md"}});
		var first = ops("tab:Preview of README.md");
		check(first != null, "the command mounts a tab titled for the file");
		check(first != null && Std.string(first.ops).indexOf("First") >= 0, "the tab shows the file's heading");
		var named:Null<Array<Dynamic>> = first == null ? null : Lambda.find((first.ops : Array<Array<Dynamic>>), o -> o[0] == "set" && o[2] == "name");
		var root:Int = named == null ? -1 : (named[1] : Int);
		text = "# Second";
		host.send({t: "hook", name: "file.saved", data: {path: "README.md"}});
		check(ops("Second") != null, "a save brings the tab up to date");
		host.send({t: "closed", root: root});
		check(until(m -> m.t == "ops" && Std.string(m.ops).indexOf("remove") >= 0) != null, "closing the tab unmounts the view");
		host.stop();
	}

	/** Theme bundles: the file model, its colours, the stylesheet scoping, and installing. */
	static function themeChecks():Void {
		var dir = Sys.getCwd() + "bin/check-themes";
		if (sys.FileSystem.exists(dir))
			for (f in sys.FileSystem.readDirectory(dir))
				removeTree(haxe.io.Path.join([dir, f]));
		else
			sys.FileSystem.createDirectory(dir);
		var write = (name:String, text:String) -> {
			var path = haxe.io.Path.join([dir, name]);
			var folder = haxe.io.Path.directory(path);
			if (!sys.FileSystem.exists(folder))
				sys.FileSystem.createDirectory(folder);
			sys.io.File.saveContent(path, text);
			return path;
		};
		var hex = (c:rayde.theme.ThemeFile.Color) -> [for (v in [c.r, c.g, c.b]) StringTools.hex(Math.round(v * 255), 2).toLowerCase()].join("");
		check(hex(ThemeFile.parseColor("#7c5cff")) == "7c5cff" && hex(ThemeFile.parseColor("#abc")) == "aabbcc" && ThemeFile.parseColor("#11223344").a > .26 && ThemeFile.parseColor("#11223344").a < .27, "colours are read as #rgb, #rrggbb and #rrggbbaa");
		check(hex(ThemeFile.parseColor("rgb(255, 0, 128)")) == "ff0080" && ThemeFile.parseColor("rgba(0, 0, 0, 0.5)").a == .5 && ThemeFile.parseColor("rgba(0 0 0 / 50%)").a == .5 && ThemeFile.parseColor("transparent").a == 0, "and as rgb(), rgba() and transparent");
		check(ThemeFile.parseColor("purple") == null && ThemeFile.parseColor("#12") == null && ThemeFile.parseColor("#ggg") == null && ThemeFile.parseColor(5) == null, "anything else is no colour");

		var good = ThemeFile.read(write("good.raytheme", '{"id": "good", "name": "Good", "version": "1.2.0", "author": "A", "extends": "hybrid", "colors": {"primary": "#336699", "surface-elevated": "#101010"}, "radii": {"xl": 20}, "shape": {"smoothing": 0.5}, "typography": {"mono": "Menlo", "sizes": {"sm": 13}}, "spacing": {"base": 5}, "dark": {"colors": {"primary": "#99ccff", "background": "#000"}}, "css": [".a { color: red; }", {"file": "good.css"}]}'));
		write("good.css", ".b { color: blue; }");
		check(good.problems.length == 0 || good.problems.join(";") == 'css file "good.css" not found.', 'a good theme reads cleanly: ${good.problems}');
		var good2 = ThemeFile.read(haxe.io.Path.join([dir, "good.raytheme"]));
		check(good2.problems.length == 0 && good2.id == "good" && good2.name == "Good" && good2.version == "1.2.0" && good2.base == "hybrid", 'the identity and the base are read: ${good2.problems}');
		check(hex(good2.light.colors.get("primary")) == "336699" && hex(good2.dark.colors.get("primary")) == "99ccff", "a scheme's own colour wins over the shared one");
		check(hex(good2.light.colors.get("surfaceElevated")) == "101010" && hex(good2.dark.colors.get("surfaceElevated")) == "101010", "a token is named with dashes or as ashui names it, and shared colours go to both schemes");
		check(good2.dark.colors.exists("background") && !good2.light.colors.exists("background"), "a colour set in one scheme is not in the other");
		check(good2.light.radii.get("xl") == 20 && good2.dark.shape.get("smoothing") == .5 && good2.light.fonts.get("mono") == "Menlo" && good2.dark.sizes.get("sm") == 13 && good2.light.spacing == 5, "radii, shape, fonts, sizes and spacing are read");
		check(good2.sheetTexts().join("|") == ".a { color: red; }|.b { color: blue; }", "the stylesheets are the texts and the files beside the theme");

		var derived = ThemeFile.derive(["primary" => ThemeFile.parseColor("#3366cc"), "accent" => ThemeFile.parseColor("#ff8800")], true);
		check(derived.exists("primaryHover") && derived.exists("primaryActive") && derived.exists("borderFocus") && derived.exists("selection") && derived.exists("accentSubtle") && !derived.exists("secondaryHover"), "what follows from primary and accent is filled in");
		check(derived.get("primaryHover").b > derived.get("primary").b && derived.get("selection").a < 1, "hover is lighter in the dark scheme, and the selection is see-through");
		var kept = ThemeFile.derive(["primary" => ThemeFile.parseColor("#3366cc"), "primaryHover" => ThemeFile.parseColor("#000000")], false);
		check(hex(kept.get("primaryHover")) == "000000" && kept.get("primaryActive").r < kept.get("primary").r, "a token that is named is not derived");

		var bad = ThemeFile.read(write("bad.raytheme", '{"id": "restrained", "extends": "gothic", "colors": {"primry": "#fff", "primary": "puce"}, "radii": {"huge": 4, "xl": "big"}, "shape": {"smoothing": "x"}, "typography": {"sans": 3, "sizes": {"xl": true}, "weight": 1}, "spacing": {"base": 0}, "css": [{"file": "../x.css"}, 5], "light": [], "flavour": "mint"}'));
		var said = bad.problems.join("\n");
		for (needle in ["built-in themes", 'Unknown base theme "gothic"', 'Unknown colour "primry"', "colors.primary: expected a colour", 'Unknown name "huge"', "radii.xl must be a number", "shape.smoothing must be a number", "typography.sans must be a font family name", "typography.sizes.xl must be a number", 'Unknown field "weight" in typography', "spacing.base must be a number above 0", "beside the theme file", 'Each "css" entry', '"light" must be an object', 'Unknown field "flavour"'])
			check(said.indexOf(needle) >= 0, 'the problem is named: $needle in\n$said');
		check(ThemeFile.read(write("broken.raytheme", "{nope")).problems[0].indexOf("Invalid JSON") == 0 && ThemeFile.read(write("array.raytheme", "[1]")).problems[0] == "The theme must be a JSON object.", "a file that is not a JSON object says so");
		check(ThemeFile.read(write("Bad Name.raytheme", "{}")).problems.length == 1 && ThemeFile.read(write("fine-name.raytheme", "{}")).problems.length == 0, "an id comes from the file name when there is none, and must be usable");

		var scope = '#rayde[data-theme="x"]';
		var out = ThemeCss.scope("/* c */ .a, .b > .c:hover { color: red; }\n:root { --p: 1; }\n#rayde .d { top: 0; }\n@media (min-width: 10px) { .e { top: 1px; } }\n@keyframes k { from { top: 0; } to { top: 1px; } }\n.f { content: \"}{\"; }\n@import url(x.css);", scope);
		check(out.indexOf(scope + " .a,\n" + scope + " .b > .c:hover {") >= 0, 'selectors are put under the theme, each of a list: $out');
		check(out.indexOf(scope + " {\n") < 0 && out.indexOf(scope + " { --p: 1; }") >= 0, ':root is the theme itself');
		check(out.indexOf(scope + " .d {") >= 0 && out.indexOf("@media (min-width: 10px) {" + " " + scope + " .e") < 0 && out.indexOf(scope + " .e {") > 0, "#rayde stands for the theme, and a rule inside @media is scoped");
		check(out.indexOf("@keyframes k { from { top: 0; } to { top: 1px; } }") >= 0 && out.indexOf(scope + " .f { content: \"}{\"; }") >= 0 && out.indexOf("@import url(x.css);") >= 0, "keyframes, strings with braces and an @import are kept as written");
		check(out.indexOf("/* c */") < 0, "comments are dropped");

		// Installing: from a loose file with its stylesheet, from a folder, over another of the same id, and the reasons it refuses.
		var home = haxe.io.Path.join([dir, "home"]);
		Sys.putEnv("RAYDE_THEMES", home);
		var problems:Array<String> = [];
		var one = Themes.install(haxe.io.Path.join([dir, "good.raytheme"]), problems);
		check(one != null && one.file.id == "good" && one.scope == "User" && sys.FileSystem.exists(home + "/good/good.raytheme") && sys.FileSystem.exists(home + "/good/good.css"), 'a file is installed with the stylesheet it names: $problems');
		var folder = write("pack/pack.raytheme", '{"name": "Pack", "css": [{"file": "css/pack.css"}]}');
		write("pack/css/pack.css", ".p { top: 0; }");
		write("pack/readme.txt", "hello");
		var two = Themes.install(haxe.io.Path.join([dir, "pack"]), problems);
		check(two != null && two.file.id == "pack" && sys.FileSystem.exists(home + "/pack/css/pack.css") && sys.FileSystem.exists(home + "/pack/readme.txt"), "a folder is installed whole");
		var all = Themes.scan(dir + "/nowhere");
		check(all.map(t -> t.file.id).join(",") == "good,pack" && Themes.find("pack") != null && Themes.find("missing") == null, 'the themes installed are found: ${all.map(t -> t.file.id)}');
		write("good.raytheme", '{"id": "good", "name": "Good, again"}');
		check(Themes.install(haxe.io.Path.join([dir, "good.raytheme"]), problems) != null && ThemeFile.read(home + "/good/good.raytheme").name == "Good, again" && !sys.FileSystem.exists(home + "/good/good.css"), "an installed theme is replaced by one with its id");
		var refused:Array<String> = [];
		check(Themes.install(haxe.io.Path.join([dir, "bad.raytheme"]), refused) == null && refused.length > 5, "a theme with problems is not installed, and each is said");
		var nothing:Array<String> = [];
		check(Themes.install(dir + "/none.raytheme", nothing) == null && nothing[0].indexOf("Nothing at") == 0 && Themes.install(dir + "/good.css", nothing) == null && Themes.install(dir + "/home", nothing) == null, "a path with nothing, something else, or no theme in it is refused");
		check(Themes.remove("good") && !sys.FileSystem.exists(home + "/good") && Themes.find("good") == null && !Themes.remove("good") && Themes.scan(dir).length == 1, "a theme is taken away with its folder, once");
		write("home/loose.raytheme", '{"name": "Loose"}');
		check(Themes.scan(dir).map(t -> t.file.id).join(",") == "loose,pack" && Themes.remove("loose") && !sys.FileSystem.exists(home + "/loose.raytheme"), "a loose file in the themes folder is a theme too");
		Sys.putEnv("RAYDE_THEMES", "");
		Themes.scan(dir);

		// Fonts: the family a file carries, the entries that name them, and installing them with the theme.
		var lora = Sys.getCwd() + "tests/fixtures/themestudio/fonts/Lora-Regular.ttf";
		var names = rayde.theme.FontName.of(sys.io.File.getBytes(lora));
		check(names != null && names.join(",") == "Lora", 'a TrueType file gives the family it carries: $names');
		check(rayde.theme.FontName.of(haxe.io.Bytes.ofString("not a font at all")) == null && rayde.theme.FontName.of(haxe.io.Bytes.ofString("wOF2....................")) == null, "text and WOFF2 give no name");
		check(rayde.theme.FontName.isFontFile("a/B.TTF") && rayde.theme.FontName.isFontFile("x.woff2") && !rayde.theme.FontName.isFontFile("x.woff") && !rayde.theme.FontName.isFontFile("x.css"), "a font file is .ttf, .otf, .ttc or .woff2");
		sys.FileSystem.createDirectory(dir + "/fonted");
		sys.FileSystem.createDirectory(dir + "/fonted/fonts");
		sys.io.File.copy(lora, dir + "/fonted/fonts/Lora-Regular.ttf");
		var fonted = ThemeFile.read(write("fonted/fonted.raytheme", '{"fonts": [{"family": "Lora", "files": ["fonts/Lora-Regular.ttf"]}], "typography": {"sans": "Lora"}}'));
		check(fonted.problems.length == 0 && fonted.fonts.length == 1 && fonted.fonts[0].family == "Lora" && fonted.fontPaths().length == 1 && fonted.light.fonts.get("sans") == "Lora", 'fonts are read: ${fonted.problems}');
		var badFonts = ThemeFile.read(write("fonted/bad.raytheme", '{"fonts": [{"family": "Inter", "files": ["fonts/Lora-Regular.ttf", "fonts/none.ttf", "fonts/x.woff", "../up.ttf", 4]}, {"family": "Inter", "files": []}, {"family": 3}, "x"]}'));
		var badSaid = badFonts.problems.join("\n");
		for (needle in ['is "Lora", not "Inter"', 'Font file "fonts/none.ttf" not found', "must be .ttf, .otf, .ttc or .woff2", "beside the theme file", "must be a file name", 'listed twice', 'Each "fonts" entry'])
			check(badSaid.indexOf(needle) >= 0, 'the font problem is named: $needle in\n$badSaid');
		check(ThemeFile.read(write("fonted/list.raytheme", '{"fonts": {}}')).problems[0].indexOf('"fonts" must be a list') == 0, "fonts that are not a list are said");
		var located = ThemeFile.read(write("fonted/at.raytheme", '{"dark": {"colors": {"primary": "puce"}}, "fonts": [{"family": "X", "files": ["fonts/nope.ttf"]}], "css": [5]}'));
		var ats = [for (i in located.issues) i.at].join(",");
		check(ats == "dark.colors.primary,fonts[0].files[0],css[0]", 'problems say where they are: $ats');
		check(located.placed.get("primary").join(",") == "dark.colors.primary" && ThemeFile.parse(dir + "/x.raytheme", '{"colors": {"surface-elevated": "#111"}, "light": {"colors": {"surfaceElevated": "#222"}}}').placed.get("surfaceElevated").join(",") == "colors.surface-elevated,light.colors.surfaceElevated", "where each colour is set in the file is kept, as spelled");
		var unreadable = ThemeFile.parse(dir + "/u.raytheme", "{nope");
		check(unreadable.unreadable && unreadable.problems[0].indexOf("Invalid JSON") == 0 && !ThemeFile.parse(dir + "/u.raytheme", '{"name": "A"}').unreadable && ThemeFile.parse(dir + "/u.raytheme", '{"name": "A"}').name == "A", "text that is not a JSON object is unreadable, and what is read from text is the theme");
		check(ThemeFile.toHex(ThemeFile.parseColor("#7c5cff")) == "#7c5cff" && ThemeFile.toHex(ThemeFile.parseColor("rgba(255, 0, 0, 0.5)")) == "#ff000080" && ThemeFile.toHex(ThemeFile.parseColor("transparent")) == "#00000000", "a colour is written as #rrggbb, with the alpha only when it is not 1");
		var home2 = haxe.io.Path.join([dir, "home2"]);
		Sys.putEnv("RAYDE_THEMES", home2);
		var fontProblems:Array<String> = [];
		var withFont = Themes.install(dir + "/fonted/fonted.raytheme", fontProblems);
		check(withFont != null && sys.FileSystem.exists(home2 + "/fonted/fonts/Lora-Regular.ttf"), 'a loose file is installed with its fonts: $fontProblems');
		Sys.putEnv("RAYDE_THEMES", "");
		Themes.scan(dir);

		// Locating entries in the text, and editing it.
		var doc = '{\n  "name": "A",\n  "dark": {"colors": {"primary": "#111111"}},\n  "fonts": [{"family": "F", "files": ["a.ttf", "b.ttf"]}]\n}';
		var span = rayde.theme.JsonLocator.find(doc, "dark.colors.primary");
		check(span != null && doc.substring(span.valueStart, span.valueEnd) == '"#111111"' && doc.substring(span.keyStart, span.keyEnd) == '"primary"', "an entry is found by its path");
		var item = rayde.theme.JsonLocator.find(doc, "fonts[0].files[1]");
		check(item != null && doc.substring(item.valueStart, item.valueEnd) == '"b.ttf"' && rayde.theme.JsonLocator.find(doc, "dark.colors.none") == null && rayde.theme.JsonLocator.find(doc, "fonts[2]") == null && rayde.theme.JsonLocator.find("{bad", "a") == null, "an array item is found by its index, and what is not there, or text that is not JSON, is null");
		var where = rayde.theme.JsonLocator.position(doc, rayde.theme.JsonLocator.find(doc, "dark").keyStart);
		check(where.line == 2 && where.character == 2, 'a position is a line and a character from zero: ${where.line}:${where.character}');
		var replaced = rayde.theme.ThemeEdit.setText(doc, "dark.colors.primary", "#222222");
		check(replaced == StringTools.replace(doc, "#111111", "#222222"), "a value in the file is replaced where it stands: " + replaced);
		var added = rayde.theme.ThemeEdit.setText(doc, "light.colors.primary", "#ffffff");
		check(ThemeFile.parse(dir + "/e.raytheme", added).light.colors.exists("primary") && added.indexOf('"fonts"') > added.indexOf('"dark"') && added.indexOf('"light"') > added.indexOf('"fonts"'), "a new entry is added at the end, with the objects on the way: " + added);
		var removed = rayde.theme.ThemeEdit.remove(doc, "dark.colors.primary");
		check(removed.indexOf('"dark"') < 0 && removed.indexOf('"name"') > 0 && rayde.theme.ThemeEdit.remove(doc, "dark.colors.none") == doc, "removing the last entry removes the objects it leaves empty, and removing what is not there changes nothing");
		var fontAdded = rayde.theme.ThemeEdit.addFont(doc, "F", "c.ttf");
		check(ThemeFile.parse(dir + "/f.raytheme", fontAdded).fonts[0].files.join(",") == "a.ttf,b.ttf,c.ttf" && ThemeFile.parse(dir + "/f.raytheme", rayde.theme.ThemeEdit.addFont(fontAdded, "G", "g.ttf")).fonts.length == 2, "a font file joins its family, and a new family is a new entry");
		var fontGone = rayde.theme.ThemeEdit.removeFont(rayde.theme.ThemeEdit.addFont(doc, "G", "g.ttf"), "g.ttf");
		check(ThemeFile.parse(dir + "/g.raytheme", fontGone).fonts.length == 1 && ThemeFile.parse(dir + "/g.raytheme", rayde.theme.ThemeEdit.removeFont(rayde.theme.ThemeEdit.removeFont(fontGone, "a.ttf"), "b.ttf")).fonts.length == 0 && rayde.theme.ThemeEdit.removeFont(rayde.theme.ThemeEdit.removeFont(rayde.theme.ThemeEdit.removeFont(fontGone, "a.ttf"), "b.ttf"), "none").indexOf('"fonts"') < 0, "a family goes with its last file, and the fonts entry with its last family");
		var sheet = rayde.theme.ThemeEdit.addCss('{"css": ".a {}"}', "x.css");
		check(ThemeFile.parse(dir + "/c.raytheme", sheet).css.length == 2 && ThemeFile.parse(dir + "/c.raytheme", rayde.theme.ThemeEdit.addCss(sheet, "x.css")).css.length == 2 && ThemeFile.parse(dir + "/c.raytheme", rayde.theme.ThemeEdit.addCss("{}", "y.css")).css[0].file == "y.css", "a stylesheet is added to the list the text or the entry becomes, once");
		var threw = false;
		try
			rayde.theme.ThemeEdit.setText("[1]", "name", "x")
		catch (_:Dynamic)
			threw = true;
		check(threw, "an edit of text that is not a JSON object says so");
		Sys.println("themes: files, colours, scoping, installing, fonts and text edits");
	}

	static function callSiteChecks():Void {
		var open = (t:String) -> rayde.lang.CallSite.openParen(t, t.length);
		check(open("greet(a, b") == 5 && open("greet(a)") == -1 && open("f(g(1), ") == 1 && open("f(g(1, ") == 3, "the call the caret is in is found by its unmatched paren");
		check(open("f(\"(\", ") == 1 && open("x = [1, 2") == -1 && open("{ f(1") == 3 && open("no call") == -1, "strings are skipped, and a bracket or brace is not a call");
		var index = (t:String, o:Int) -> rayde.lang.CallSite.parameterIndex(t, o, t.length);
		check(index("greet(a, b", 5) == 1 && index("greet(a", 5) == 0 && index("f(g(1, 2), 3", 1) == 2 - 1 && index("f(\"a,b\", ", 1) == 1 && index("f([1, 2], {a: 1, b: 2}, ", 1) == 2, "the argument is the commas at the call's own level");
		var part = (label:String, i:Int) -> {
			var span = rayde.lang.CallSite.emphasis(label, i);
			span == null ? null : label.substring(span.from, span.to);
		};
		check(part("(name:String, times:Int):String", 0) == "name:String" && part("(name:String, times:Int):String", 1) == "times:Int" && part("(name:String, times:Int):String", 2) == null, "the emphasised part of a signature is the parameter");
		check(part("(m:Map<String, Int>, ?x:Int):Void", 0) == "m:Map<String, Int>" && part("(m:Map<String, Int>, ?x:Int):Void", 1) == "?x:Int", "commas inside generics do not split a parameter");
		check(part("(f:(a:Int)->Void, b:Int)->Void", 0) == "f:(a:Int)->Void" && part("(f:(a:Int)->Void, b:Int)->Void", 1) == "b:Int" && part("():Void", 0) == null, "nor do function types, and a signature with no parameters has none");
		check(Display.byteOffset("héllo wörld", 8) == 10 && Display.byteOffset("abc", 2) == 2 && Display.byteOffset("", 0) == 0, "an editor's character offset becomes the compiler's byte offset");
		Sys.println("call sites: the call a caret is in, its argument, and the part of the signature to emphasise");
	}

	static function removeTree(path:String):Void {
		if (sys.FileSystem.isDirectory(path)) {
			for (entry in sys.FileSystem.readDirectory(path))
				removeTree(haxe.io.Path.join([path, entry]));
			sys.FileSystem.deleteDirectory(path);
		} else
			sys.FileSystem.deleteFile(path);
	}

	/** Content that opens in the top layer sits outside the workbench in a real window, so its rules cannot be scoped to #rayde. */
	static function topLayerStyleChecks():Void {
		var css = sys.io.File.getContent("src/rayde/ui/rayde.css");
		for (line in css.split("\n"))
			for (name in [".rayde-glass", ".rayde-command-center", ".rayde-cc"])
				if (line.indexOf(name) >= 0 && line.indexOf("#rayde ") >= 0 && !StringTools.startsWith(StringTools.ltrim(line), "/*"))
					check(false, "top-layer style scoped to #rayde, so it misses the real window: " + StringTools.trim(line).substr(0, 70));
	}

	static function gitIgnoreChecks():Void {
		var root = Sys.getCwd() + "bin/gitignore-checks-" + Std.random(0x3fffffff);
		for (dir in ["/.git/info", "/build", "/src/nested", "/src/keep", "/docs/api", "/out/deep"]) sys.FileSystem.createDirectory(root + dir);
		function put(name:String, text = "x") sys.io.File.saveContent(root + "/" + name, text);
		put(".gitignore", "# comment\nbuild/\n*.log\n!keep.log\n/top-only.txt\nout/**/*.bin\n*.[ch]\nfoo?bar\ndocs/api\n\\#hash\n");
		put(".git/info/exclude", "excluded.txt\n");
		put("src/.gitignore", "*.tmp\n!important.tmp\nkeep/*\n!keep/this.txt\n");
		for (name in ["build/a.o", "app.log", "keep.log", "src/x.log", "top-only.txt", "src/top-only.txt", "out/deep/a.bin", "out/a.bin", "out/deep/a.txt", "a.c", "foo-bar", "fooxxbar",
			"docs/api/index.html", "docs/guide.md", "#hash", "excluded.txt", "src/a.tmp", "src/important.tmp", "src/keep/this.txt", "src/keep/other.txt", "src/nested/b.tmp", "a.tmp", "plain.hx"]) {
			put(name);
		}
		var ignore = new rayde.files.GitIgnore(root);
		var expected = ["build" => true, "build/a.o" => true, "app.log" => true, "keep.log" => false, "src/x.log" => true, "top-only.txt" => true, "src/top-only.txt" => false,
			"out/deep/a.bin" => true, "out/a.bin" => true, "out/deep/a.txt" => false, "a.c" => true, "foo-bar" => true, "fooxxbar" => false, "docs/api" => true,
			"docs/api/index.html" => true, "docs/guide.md" => false, "#hash" => true, "excluded.txt" => true, "src/a.tmp" => true, "src/important.tmp" => false,
			"src/keep/this.txt" => false, "src/keep/other.txt" => true, "src/nested/b.tmp" => true, "a.tmp" => false, "plain.hx" => false, ".gitignore" => false, "src" => false, ".git" => true, ".git/info/exclude" => true];
		for (path => value in expected) check(ignore.ignored(root + "/" + path) == value, "gitignore: " + path + (value ? " is ignored" : " is not ignored"));
		check(!new rayde.files.GitIgnore("/").ignored("/tmp"), "gitignore: nothing is ignored outside a repository");
		put(".gitignore", "plain.hx\n");
		check(!ignore.ignored(root + "/plain.hx"), "gitignore: answers are kept until the next refresh");
		ignore.refresh();
		check(ignore.ignored(root + "/plain.hx") && !ignore.ignored(root + "/build/a.o"), "gitignore: an edited file is read again after a refresh");
		function remove(path:String):Void {
			if (sys.FileSystem.isDirectory(path)) { for (name in sys.FileSystem.readDirectory(path)) remove(path + "/" + name); sys.FileSystem.deleteDirectory(path); }
			else sys.FileSystem.deleteFile(path);
		}
		remove(root);
	}

	static function main():Void {
		themeChecks();
		callSiteChecks();
		hxmlChecks();
		keyChecks();
		settingsChecks();
		RecentProjectsChecks.run();
		WorkspaceSessionChecks.run();
		EditorGroupsChecks.run();
		ProjectChecks.run();
		CaribouProjectChecks.run();
		ProjectStarterChecks.run();
		CodeActionChecks.run();
		CodeActionExtensionChecks.run();
		ProjectRunnerChecks.run();
		BuildChecks.run();
		terminalChecks();
		manifestChecks();
		extensionStyleChecks();
		ExtensionStylesChecks.run();
		iconChecks();
		fileOpsChecks();
		gitIgnoreChecks();
		topLayerStyleChecks();
		extensionHostChecks();
		ActivityLogChecks.run();
		ExtensionManagerChecks.run();
		DiagnosticJobsChecks.run();
		PanelWorkerChecks.run();
		FileIndexChecks.run();
		AnsiOutputChecks.run();
		OutlineChecks.run();
		LspChecks.run();
		LocalHistoryChecks.run();
		var root = Sys.getCwd() + "tests/fixtures/basic", file = root + "/src/Main.hx";
		var text = sys.io.File.getContent(file);
		var server = new CompilerServer(), display = Display.ofHxml(server, root + "/build.hxml");
		try {
			var symbols = rayde.lang.Outline.parse(server.request(root, display.args.concat(["--no-output", "--display", file + "@0@module-symbols"])));
			check(symbols.length == 1 && symbols[0].name == "Main", "Outline uses the compiler's module symbols");
			var method = Lambda.find(symbols[0].children, s -> s.name == "greet");
			check(method != null && method.children.length == 2 && method.children[0].name == "name", "Outline nests parameters under their method");
			check(Lambda.find(symbols[0].children, s -> s.name == "main").children[0].name == "greeting", "Outline nests local variables");
			var started = haxe.Timer.stamp();
			var hover = display.hover(file, at(text, "var greeting", 5));
			check(hover != null && hover.type == "String", 'hover on greeting: ${hover == null ? "nothing" : hover.type}');
			var cold = haxe.Timer.stamp() - started;

			started = haxe.Timer.stamp();
			var doc = display.hover(file, at(text, "greet(greeting", 1));
			check(doc != null && doc.documentation != null && doc.documentation.indexOf("Says hello") >= 0, "hover on greet carries its doc comment");
			check(doc != null && doc.type == "(name:String, times:Int) -> String", 'hover type of greet: ${doc == null ? "nothing" : doc.type}');
			var warm = haxe.Timer.stamp() - started;

			// An editor counts characters and the compiler bytes: text with accents before the position still lands on the name.
			var accented = StringTools.replace(text, '"hello"', '"héllo wörld"');
			var moved = display.hover(file, at(accented, "greet(greeting", 1), accented);
			check(moved != null && moved.type == "(name:String, times:Int) -> String", 'hover after accented text: ${moved == null ? "nothing" : moved.type}');

			// Completion on the buffer as edited, the file on disk untouched.
			var edited = StringTools.replace(text, "trace(greeting);", "greeting.");
			var completion = display.completion(file, at(edited, "greeting.", 9), edited);
			check(Lambda.exists(completion.items, i -> i.label == "charAt" && i.kind == "ClassField"), "member completion on a String offers charAt");
			var charAt = Lambda.find(completion.items, i -> i.label == "charAt");
			check(charAt != null && charAt.detail == "(index:Int) -> String", 'charAt detail: ${charAt == null ? "missing" : charAt.detail}');

			var toplevel = display.completion(file, at(text, "trace(", 6));
			check(Lambda.exists(toplevel.items, i -> i.label == "greeting" && i.kind == "Local"), "top-level completion offers the local greeting");
			check(Lambda.exists(toplevel.items, i -> i.label == "greet" && i.kind == "ClassField"), "top-level completion offers greet");

			var definition = display.definition(file, at(text, "greet(greeting", 2));
			check(definition.length == 1 && definition[0].range.start.line == 2, 'definition of greet: ${definition.map(d -> d.range.start.line)}');

			var references = display.references(file, at(text, "var greeting", 6));
			check(references.length == 2, 'references to greeting: ${references.length}');

			var signature = display.signatureHelp(file, at(text, "greet(greeting, 2", 16));
			check(signature != null && signature.signatures.length == 1 && signature.parameter == 1, "signature help inside greet's second argument");
			check(signature != null && signature.signatures[0].label == "(name:String, times:Int):String", 'signature label: ${signature == null ? "none" : signature.signatures[0].label}');

			check(display.diagnostics(file).length == 0, "the saved fixture has no diagnostics");
			var broken = StringTools.replace(text, 'var greeting = "hello";', 'var greeting:Int = "hello";');
			var problems = display.diagnostics(file, broken);
			// The declaration is wrong, and so then is the call that passes greeting as a String.
			check(Lambda.exists(problems, p -> p.severity == 1 && p.message == "String should be Int" && p.range.start.line == 6)
				&& Lambda.exists(problems, p -> p.range.start.line == 7),
				'diagnostics on the edited buffer: ${problems.map(p -> p.message + "@" + p.range.start.line)}');

			// A server that died is started again by the next request.
			server.stop();
			check(display.hover(file, at(text, "var greeting", 5)) != null, "a request after the server stopped starts it again");

			// Building and running through the same warm server, a program that works and one that does not build.
			var runner = new Runner(display), done = finish(runner);
			check(done == "finished" && runner.exitCode == 0, 'the fixture did not run to its end: $done, exit ${runner.exitCode}');
			check(runner.console.indexOf("hello") >= 0, "the program's output is not in the console: " + runner.console);
			check(runner.problems.length == 0, "a good build reports problems");
			// A project of its own has a server of its own: two with a module Main would share it.
			var other = new CompilerServer(), broken = Display.ofHxml(other, Sys.getCwd() + "tests/fixtures/broken/build.hxml");
			var bad = new Runner(broken), result = finish(bad);
			check(result == "failed", 'the broken fixture ended as $result');
			check(bad.problems.length == 1 && bad.problems[0].message == "String should be Int" && bad.problems[0].range.start.line == 2
				&& StringTools.endsWith(bad.problems[0].file, "tests/fixtures/broken/src/Main.hx"), 'the build error as a problem: ${bad.problems.map(p -> p.message + "@" + p.range.start.line + " " + p.file)}');
			check(!sys.FileSystem.exists(bad.program()), "a failed build left a program behind");
			var stopped = new Runner(display);
			stopped.start();
			stopped.stop();
			check(stopped.state == "idle" && !stopped.active(), "stopping a build did not return it to idle");
			other.stop();

			Sys.println('language: first request ${Math.round(cold * 1000)} ms, warm ${Math.round(warm * 1000)} ms');
		} catch (e:Dynamic) {
			failures.push("threw: " + Std.string(e));
		}
		server.stop();
		if (failures.length > 0) {
			Sys.println("rayde checks failed:\n  " + failures.join("\n  "));
			Sys.exit(1);
		}
		Sys.println("rayde checks: the build file model, the terminal and its keys, chords and key bindings, the settings file, theme bundles, haxelib, extensions, compilation server, an embedded extension VM, hover, completion on an edited buffer, definition, references, signature help, diagnostics, restart, and building and running passed");
	}
}
