package rayde.theme;

/** Where an entry is in JSON text: its key (an array item has none) and its value, as offsets. */
typedef JsonSpan = {keyStart:Int, keyEnd:Int, valueStart:Int, valueEnd:Int};

/**
 * Finds an entry of JSON text by path (`dark.colors.primary`, `fonts[0].files[1]`) without parsing the text into
 * values, so a form can replace one value in place and a problem can be shown on its line. Text that is not valid
 * gives null.
 */
class JsonLocator {
	public static function find(text:String, path:String):Null<JsonSpan> {
		var steps = [];
		for (part in path.split(".")) {
			var bracket = part.indexOf("[");
			if (bracket < 0)
				steps.push(part);
			else {
				if (bracket > 0)
					steps.push(part.substr(0, bracket));
				for (m in part.substr(bracket).split("[").slice(1))
					steps.push("[" + m);
			}
		}
		try
			return new Scan(text).at(steps)
		catch (_:Dynamic)
			return null;
	}

	/** The line and character, counted from zero, of `offset` in `text`. */
	public static function position(text:String, offset:Int):{line:Int, character:Int} {
		var line = 0, start = 0;
		for (i in 0...Std.int(Math.min(offset, text.length)))
			if (text.charCodeAt(i) == "\n".code) {
				line++;
				start = i + 1;
			}
		return {line: line, character: offset - start};
	}
}

private class Scan {
	final text:String;
	var pos = 0;

	public function new(text:String)
		this.text = text;

	public function at(steps:Array<String>):Null<JsonSpan> {
		space();
		return descend(steps, 0, null);
	}

	function descend(steps:Array<String>, step:Int, key:Null<{start:Int, end:Int}>):Null<JsonSpan> {
		var start = pos;
		if (step == steps.length) {
			skip();
			return {keyStart: key == null ? start : key.start, keyEnd: key == null ? start : key.end, valueStart: start, valueEnd: pos};
		}
		var wanted = steps[step], c = text.charAt(pos);
		if (c == "{" && wanted.charAt(0) != "[") {
			pos++;
			space();
			while (text.charAt(pos) != "}") {
				var ks = pos;
				var name = string();
				var ke = pos;
				space();
				expect(":");
				space();
				if (name == wanted)
					return descend(steps, step + 1, {start: ks, end: ke});
				skip();
				space();
				if (text.charAt(pos) == ",") {
					pos++;
					space();
				}
			}
			return null;
		}
		if (c == "[" && wanted.charAt(0) == "[") {
			var index = Std.parseInt(wanted.substring(1, wanted.length - 1)), i = 0;
			pos++;
			space();
			while (text.charAt(pos) != "]") {
				if (i == index)
					return descend(steps, step + 1, null);
				skip();
				space();
				if (text.charAt(pos) == ",") {
					pos++;
					space();
				}
				i++;
			}
		}
		return null;
	}

	function space():Void {
		while (pos < text.length) {
			var c = text.charCodeAt(pos);
			if (c == " ".code || c == "\t".code || c == "\n".code || c == "\r".code)
				pos++;
			else
				break;
		}
	}

	function expect(c:String):Void {
		if (text.charAt(pos) != c)
			throw 'expected $c at $pos';
		pos++;
	}

	function string():String {
		expect("\"");
		var out = new StringBuf();
		while (pos < text.length && text.charAt(pos) != "\"") {
			if (text.charAt(pos) == "\\")
				pos++;
			out.add(text.charAt(pos));
			pos++;
		}
		expect("\"");
		return out.toString();
	}

	/** Moves past the value at the position. */
	function skip():Void {
		var c = text.charAt(pos);
		if (c == "\"") {
			string();
			return;
		}
		if (c == "{" || c == "[") {
			var depth = 0;
			while (pos < text.length) {
				var d = text.charAt(pos);
				if (d == "\"") {
					string();
					continue;
				}
				if (d == "{" || d == "[")
					depth++;
				else if (d == "}" || d == "]")
					depth--;
				pos++;
				if (depth == 0)
					return;
			}
			throw "unterminated";
		}
		while (pos < text.length && !~/[,}\]\s]/.match(text.charAt(pos)))
			pos++;
	}
}
