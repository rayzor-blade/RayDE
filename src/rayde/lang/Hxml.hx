package rayde.lang;

using StringTools;

/**
 * A project's compiler arguments, read from its `.hxml`: comments dropped,
 * quoted arguments kept whole, and nested `.hxml` files expanded where they
 * appear. Relative paths, a nested file's included, are the compiler's: from
 * its working directory, which RayDE sets to the top file's. Only the first
 * compilation is kept: a display request types one, and `--next` starts
 * another.
 */
class Hxml {
	public static function read(file:String):Array<String> {
		var out:Array<String> = [];
		file = sys.FileSystem.fullPath(file);
		expand(file, haxe.io.Path.directory(file), out, 0);
		var next = out.indexOf("--next");
		return next < 0 ? out : out.slice(0, next);
	}

	/** The arguments of `text`, split as the compiler splits an `.hxml` line by line. */
	public static function parse(text:String):Array<String> {
		var out:Array<String> = [];
		for (raw in text.split("\n")) {
			var line = raw.trim();
			if (line == "" || line.startsWith("#"))
				continue;
			// A first word that is a flag takes the rest of the line as its one value, as the compiler reads it.
			var space = line.indexOf(" ");
			if (line.startsWith("-") && space > 0) {
				out.push(line.substr(0, space));
				out.push(unquote(line.substr(space + 1).trim()));
			} else
				out.push(unquote(line));
		}
		return out;
	}

	static function expand(file:String, cwd:String, out:Array<String>, depth:Int):Void {
		if (depth > 16)
			throw 'hxml files include each other too deeply at $file';
		for (arg in parse(sys.io.File.getContent(file)))
			if (arg.endsWith(".hxml") && !arg.startsWith("-"))
				expand(haxe.io.Path.isAbsolute(arg) ? arg : haxe.io.Path.join([cwd, arg]), cwd, out, depth + 1);
			else
				out.push(arg);
	}

	static function unquote(s:String):String
		return s.length >= 2 && (s.startsWith('"') && s.endsWith('"') || s.startsWith("'") && s.endsWith("'")) ? s.substr(1, s.length - 2) : s;
}
