package rayde.run;

import rayde.lang.Display.Diagnostic;

/** What the Haxe compiler printed for a build, as problems at positions. */
class CompilerOutput {
	/**
	 * Each `file:line: characters a-b : message` becomes a problem, a warning
	 * when the message says so; indented lines after one continue its message.
	 */
	public static function parse(text:String, cwd:String):Array<Diagnostic> {
		if (text.indexOf("\x1b") >= 0) { var ansi = new AnsiOutput(); ansi.write(text); text = ansi.snapshot().text; }
		var out:Array<Diagnostic> = [], at = ~/^(.+?):(\d+): (?:characters (\d+)-(\d+)|lines (\d+)-(\d+)) : (.*)$/;
		for (raw in text.split("\n")) {
			var line = StringTools.rtrim(raw);
			if (at.match(line)) {
				var file = at.matched(1), first = Std.parseInt(at.matched(2)) - 1, message = at.matched(7), warning = StringTools.startsWith(message, "Warning : ");
				if (warning)
					message = message.substr("Warning : ".length);
				var from = at.matched(3) != null ? Std.parseInt(at.matched(3)) : 0, to = at.matched(4) != null ? Std.parseInt(at.matched(4)) : 0;
				out.push({
					file: haxe.io.Path.isAbsolute(file) ? file : haxe.io.Path.normalize(haxe.io.Path.join([cwd, file])),
					range: {start: {line: first, character: from}, end: {line: first, character: to}},
					severity: warning ? 2 : 1,
					message: message
				});
			} else if (out.length > 0 && line != "" && (StringTools.startsWith(raw, " ") || StringTools.startsWith(raw, "\t")))
				out[out.length - 1].message += "\n" + StringTools.trim(line);
		}
		return out;
	}
}
