import rayde.build.HxmlFile;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.keys.Chord;
import rayde.keys.KeyBindings;
import rayde.run.Haxelib;
import rayde.run.Runner;
import rayde.settings.Appearance;
import rayde.settings.Extensions;
import rayde.settings.Store;
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
			for (f in ["libs.txt", "haxelib-stub.sh", ".rayde/keybindings.json", ".rayde/settings.json", ".rayde/run/haxelib.log", ".rayde/extensions/hello/extension.json", ".rayde/extensions/broken/extension.json"])
				if (sys.FileSystem.exists(root + "/" + f))
					sys.FileSystem.deleteFile(root + "/" + f);
		for (d in [root, root + "/.rayde", root + "/.rayde/run", root + "/.rayde/extensions", root + "/.rayde/extensions/hello", root + "/.rayde/extensions/broken"])
			if (!sys.FileSystem.exists(d))
				sys.FileSystem.createDirectory(d);

		var keys = new KeyBindings(true), p = parse.bind(_, true);
		check(keys.commandFor(p("cmd+p")) == "quickopen" && keys.commandFor(p("cmd+shift+p")) == "commands", "the defaults are bound");
		check(keys.commandFor(p("ctrl+p")) == null && keys.label("terminal") == "⌃`", "a default is bound to its own chord only");
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

		Store.save(root, "terminal", {cursor: "bar"});
		Store.save(root, "elsewhere", {kept: true});
		var a = new Appearance();
		a.theme = "hybrid";
		a.scheme = "system";
		a.save(root);
		check(Store.section(root, "terminal").cursor == "bar" && Store.section(root, "elsewhere").kept == true, "saving a section keeps the others");
		var back = Appearance.read(root);
		check(back.theme == "hybrid" && back.scheme == "system", "the colour scheme comes back from the file");
		Store.save(root, "appearance", {theme: "nonesuch", scheme: "purple"});
		check(Appearance.read(root).theme == "restrained" && Appearance.read(root).scheme == "dark", "an unknown theme or scheme falls back to the default");
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

		sys.io.File.saveContent(root + "/.rayde/extensions/hello/extension.json", '{"name": "Hello", "version": "0.1.0", "description": "Says hello"}');
		sys.io.File.saveContent(root + "/.rayde/extensions/broken/extension.json", "{ not json");
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

	static function main():Void {
		hxmlChecks();
		keyChecks();
		settingsChecks();
		terminalChecks();
		var root = Sys.getCwd() + "tests/fixtures/basic", file = root + "/src/Main.hx";
		var text = sys.io.File.getContent(file);
		var server = new CompilerServer(), display = Display.ofHxml(server, root + "/build.hxml");
		try {
			var started = haxe.Timer.stamp();
			var hover = display.hover(file, at(text, "var greeting", 5));
			check(hover != null && hover.type == "String", 'hover on greeting: ${hover == null ? "nothing" : hover.type}');
			var cold = haxe.Timer.stamp() - started;

			started = haxe.Timer.stamp();
			var doc = display.hover(file, at(text, "greet(greeting", 1));
			check(doc != null && doc.documentation != null && doc.documentation.indexOf("Says hello") >= 0, "hover on greet carries its doc comment");
			check(doc != null && doc.type == "(name:String, times:Int) -> String", 'hover type of greet: ${doc == null ? "nothing" : doc.type}');
			var warm = haxe.Timer.stamp() - started;

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
		Sys.println("rayde checks: the build file model, the terminal and its keys, chords and key bindings, the settings file, haxelib, extensions, compilation server, hover, completion on an edited buffer, definition, references, signature help, diagnostics, restart, and building and running passed");
	}
}
