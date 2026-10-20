package rayde.lang;

import rayde.lang.Display.TextRange;

typedef OutlineSymbol = {name:String, kind:Int, range:TextRange, children:Array<OutlineSymbol>};

/** The compiler's module symbols, nested by their qualified container names. */
class Outline {
	/** Module symbols need parsing options, not library resolution, typing or build macros. */
	public static function arguments(project:Array<String>, file:String):Array<String> {
		var out:Array<String> = [], i = 0;
		while (i < project.length) {
			var arg = project[i++];
			switch arg {
				case "-D" | "--define":
					if (i < project.length) { out.push("-D"); out.push(project[i++]); }
				case "-lib" | "-L" | "--library":
					if (i < project.length) {
						var library = project[i++].split(":");
						out.push("-D"); out.push(library[0] + (library.length > 1 ? "=" + library[1] : ""));
					}
				case "--hl" | "-hl" | "--js" | "-js" | "--lua" | "-lua" | "--neko" | "-neko" | "--php" | "-php"
					| "--cpp" | "-cpp" | "--cppia" | "-cppia" | "--java" | "-java" | "--jvm" | "-jvm" | "--cs" | "-cs" | "--swf" | "-swf"
					| "--swf-version" | "-swf-version":
					if (i < project.length) { out.push(arg); out.push(project[i++]); }
				case "--debug" | "-debug" | "--interp": out.push(arg);
				case "--run": out.push("--interp"); break;
				case _:
			}
		}
		return out.concat(["--no-output", "-D", "display-stdin", "--display", file + "@0@module-symbols"]);
	}

	public static function parse(reply:String):Array<OutlineSymbol> {
		var at = reply.indexOf("["), files:Array<Dynamic> = haxe.Json.parse(at < 0 ? reply : reply.substr(at));
		var out:Array<OutlineSymbol> = [], containers = new Map<String, OutlineSymbol>();
		for (file in files) {
			var symbols:Array<Dynamic> = file.symbols;
			for (s in symbols) {
				var symbol:OutlineSymbol = {name:s.name, kind:s.kind, range:s.range, children:[]};
				var parent = s.containerName == null ? null : containers.get(s.containerName);
				(parent == null ? out : parent.children).push(symbol);
				containers.set((s.containerName == null ? "" : s.containerName + ".") + s.name, symbol);
			}
		}
		return out;
	}
}
