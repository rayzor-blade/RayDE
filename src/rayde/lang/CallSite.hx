package rayde.lang;

/** Where in a call the caret is, found from the text alone, so signature help can follow typing without asking the compiler again. */
typedef Span = {from:Int, to:Int};

class CallSite {
	/** The offset of the `(` that opens the call the caret is inside, or -1 when it is in none. Strings and comments are skipped. */
	public static function openParen(text:String, caret:Int):Int {
		var depth = 0, i = caret - 1;
		while (i >= 0) {
			var c = text.charAt(i);
			if (c == "\"" || c == "'") {
				i = skipStringBack(text, i);
				continue;
			}
			if (c == ")" || c == "]" || c == "}")
				depth++;
			else if (c == "(" || c == "[" || c == "{") {
				if (depth == 0)
					return c == "(" ? i : -1;
				depth--;
			}
			i--;
		}
		return -1;
	}

	/** Which argument the caret is in, counting from 0: the commas at the call's own level between its `(` at `open` and the caret. */
	public static function parameterIndex(text:String, open:Int, caret:Int):Int {
		var depth = 0, index = 0, i = open + 1;
		while (i < caret) {
			var c = text.charAt(i);
			if (c == "\"" || c == "'") {
				i = skipStringForward(text, i);
				continue;
			}
			if (c == "(" || c == "[" || c == "{")
				depth++;
			else if (c == ")" || c == "]" || c == "}")
				depth--;
			else if (c == "," && depth == 0)
				index++;
			i++;
		}
		return index;
	}

	/** The part of a signature label such as `(name:String, times:Int):String` that is parameter `index`, or null when it has none. */
	public static function emphasis(label:String, index:Int):Null<Span> {
		var open = label.indexOf("(");
		if (open < 0)
			return null;
		var depth = 0, at = 0, start = open + 1, i = open + 1;
		while (i < label.length) {
			var c = label.charAt(i);
			var end = false;
			if (c == "(" || c == "[" || c == "{" || (c == "<"))
				depth++;
			else if (c == ")" || c == "]" || c == "}" || (c == ">" && label.charAt(i - 1) != "-")) {
				if (depth == 0)
					end = true;
				else
					depth--;
			} else if (c == "," && depth == 0)
				end = true;
			if (end) {
				if (at == index)
					return trim(label, start, i);
				if (c == ")")
					return null;
				at++;
				start = i + 1;
			}
			i++;
		}
		return null;
	}

	static function trim(s:String, from:Int, to:Int):Null<Span> {
		while (from < to && s.charAt(from) == " ")
			from++;
		while (to > from && s.charAt(to - 1) == " ")
			to--;
		return to > from ? {from: from, to: to} : null;
	}

	static function skipStringBack(text:String, at:Int):Int {
		var quote = text.charAt(at), i = at - 1;
		while (i >= 0 && !(text.charAt(i) == quote && text.charAt(i - 1) != "\\"))
			i--;
		return i - 1;
	}

	static function skipStringForward(text:String, at:Int):Int {
		var quote = text.charAt(at), i = at + 1;
		while (i < text.length && text.charAt(i) != quote)
			i += text.charAt(i) == "\\" ? 2 : 1;
		return i + 1;
	}
}
