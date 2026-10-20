import rayde.lang.Hxml;
import rayde.lang.Outline;

class OutlineChecks {
	public static function main():Void run();

	public static function run():Void {
		var root = sys.FileSystem.fullPath("tests/fixtures/full"), args = Hxml.read(root + "/build.hxml");
		function query(file:String, text:String, options:Array<String>):Array<rayde.lang.Outline.OutlineSymbol> {
			var process = new sys.io.Process("haxe", ["--cwd", root].concat(Outline.arguments(options, file)));
			process.stdin.writeString(text); process.stdin.close();
			var reply = process.stdout.readAll().toString() + process.stderr.readAll().toString(), code = process.exitCode();
			process.close();
			if (code != 0) throw 'Outline compiler failed: $reply';
			return Outline.parse(reply);
		}
		for (path in ["src/app/Main.hx", "lib/Util.hx", "tools/Gen.hx"]) {
			var file = root + "/" + path, text = sys.io.File.getContent(file), symbols = query(file, text, args);
			if (symbols.length != 1 || symbols[0].name != haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(path))) throw 'missing full fixture Outline for $path';
			if (path == "src/app/Main.hx") {
				var changed = query(file, StringTools.replace(text, "function main", "function edited"), args);
				if (changed[0].children[0].name != "edited" || sys.io.File.getContent(file) != text) throw "Outline did not use the unsaved buffer";
			}
		}
		var conditional = '#if (hl && sys && outline_feature == "enabled" && missing_outline_lib == "9.8.7")\nclass Selected { var unresolved:MissingType; }\n#else\nclass WrongBranch {}\n#end';
		var options = args.concat(["--define", "outline-feature=enabled", "--library", "missing_outline_lib:9.8.7", "--macro", "invalid build macro", "--cmd", "invalid build command"]);
		var symbols = query(root + "/tools/Gen.hx", conditional, options);
		if (symbols.length != 1 || symbols[0].name != "Selected") throw "Outline lost target, explicit or library-version defines";
		Sys.println("outline: incomplete full fixture, files outside class paths, unsaved buffers, conditional defines and unresolved types");
	}
}
