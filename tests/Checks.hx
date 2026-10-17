import rayde.lang.CompilerServer;
import rayde.lang.Display;

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

	static function main():Void {
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

			Sys.println('language: first request ${Math.round(cold * 1000)} ms, warm ${Math.round(warm * 1000)} ms');
		} catch (e:Dynamic) {
			failures.push("threw: " + Std.string(e));
		}
		server.stop();
		if (failures.length > 0) {
			Sys.println("rayde checks failed:\n  " + failures.join("\n  "));
			Sys.exit(1);
		}
		Sys.println("rayde checks: compilation server, hover, completion on an edited buffer, definition, references, signature help, diagnostics and restart passed");
	}
}
