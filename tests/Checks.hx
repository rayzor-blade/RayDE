import rayde.build.HxmlFile;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.run.Runner;

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

	static function main():Void {
		hxmlChecks();
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
		Sys.println("rayde checks: the build file model, compilation server, hover, completion on an edited buffer, definition, references, signature help, diagnostics, restart, and building and running passed");
	}
}
