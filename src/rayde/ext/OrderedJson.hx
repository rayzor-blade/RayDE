package rayde.ext;

/** A JSON value that keeps the order of an object's keys and the text of its numbers, so a file read and written again is the same file but for what was changed. */
enum J {
	Null;
	Bool(value:Bool);
	Num(text:String);
	Str(value:String);
	Arr(items:Array<J>);
	Obj(entries:Array<{key:String, value:J}>);
}

class OrderedJson {
	/** Reads `text`; throws a sentence saying what is wrong and where. */
	public static function parse(text:String):J {
		var p = new Reader(text);
		var v = p.value(0);
		p.space();
		if (!p.done())
			throw p.fail("there is more after the value");
		return v;
	}

	/** `value` as text, an object's entries on lines of their own, indented by `indent`; a list of plain values stays on one line. */
	public static function stringify(value:J, indent = "  "):String {
		var out = new StringBuf();
		write(value, indent, "", out);
		return out.toString();
	}

	public static function get(object:J, key:String):Null<J>
		return switch object {
			case Obj(entries):
				for (e in entries)
					if (e.key == key)
						return e.value;
				null;
			case _: null;
		}

	/** Sets `key` of an object in place, at the end when it is new; `null` takes it away. */
	public static function set(object:J, key:String, value:Null<J>):Void {
		switch object {
			case Obj(entries):
				for (i in 0...entries.length)
					if (entries[i].key == key) {
						if (value == null)
							entries.splice(i, 1);
						else
							entries[i].value = value;
						return;
					}
				if (value != null)
					entries.push({key: key, value: value});
			case _:
				throw "not an object";
		}
	}

	/** The text of a string value, or null for anything else. */
	public static function text(v:Null<J>):Null<String>
		return switch v {
			case Str(s): s;
			case _: null;
		}

	static function scalar(v:J):Bool
		return switch v {
			case Arr(_) | Obj(_): false;
			case _: true;
		}

	static function write(v:J, indent:String, pad:String, out:StringBuf):Void {
		switch v {
			case Null:
				out.add("null");
			case Bool(b):
				out.add(b ? "true" : "false");
			case Num(t):
				out.add(t);
			case Str(s):
				quote(s, out);
			case Arr(items):
				if (items.length == 0)
					out.add("[]");
				else if (Lambda.foreach(items, scalar)) {
					out.add("[");
					for (i in 0...items.length) {
						if (i > 0)
							out.add(", ");
						write(items[i], indent, pad, out);
					}
					out.add("]");
				} else {
					out.add("[\n");
					for (i in 0...items.length) {
						out.add(pad + indent);
						write(items[i], indent, pad + indent, out);
						out.add(i < items.length - 1 ? ",\n" : "\n");
					}
					out.add(pad + "]");
				}
			case Obj(entries):
				if (entries.length == 0)
					out.add("{}");
				else {
					out.add("{\n");
					for (i in 0...entries.length) {
						out.add(pad + indent);
						quote(entries[i].key, out);
						out.add(": ");
						write(entries[i].value, indent, pad + indent, out);
						out.add(i < entries.length - 1 ? ",\n" : "\n");
					}
					out.add(pad + "}");
				}
		}
	}

	static function quote(s:String, out:StringBuf):Void {
		out.add('"');
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			switch c {
				case '"'.code: out.add('\\"');
				case "\\".code: out.add("\\\\");
				case "\n".code: out.add("\\n");
				case "\r".code: out.add("\\r");
				case "\t".code: out.add("\\t");
				case _ if (c < 0x20): out.add("\\u" + StringTools.hex(c, 4).toLowerCase());
				case _: out.addChar(c);
			}
		}
		out.add('"');
	}
}

private class Reader {
	final text:String;
	var pos = 0;

	public function new(text:String)
		this.text = text;

	public function done():Bool
		return pos >= text.length;

	public function fail(what:String):String {
		var line = 1, col = 1;
		for (i in 0...Std.int(Math.min(pos, text.length)))
			if (text.charAt(i) == "\n") {
				line++;
				col = 1;
			} else
				col++;
		return 'line $line, column $col: $what';
	}

	public function space():Void
		while (pos < text.length && " \n\r\t".indexOf(text.charAt(pos)) >= 0)
			pos++;

	function expect(c:String):Void {
		space();
		if (text.charAt(pos) != c)
			throw fail('expected `$c`');
		pos++;
	}

	public function value(depth:Int):J {
		if (depth > 100)
			throw fail("nested too deeply");
		space();
		if (pos >= text.length)
			throw fail("the text ends here");
		var c = text.charAt(pos);
		switch c {
			case "{":
				pos++;
				var entries = [];
				space();
				if (text.charAt(pos) == "}") {
					pos++;
					return Obj(entries);
				}
				while (true) {
					space();
					if (text.charAt(pos) != '"')
						throw fail("expected a key in quotes");
					var key = string();
					expect(":");
					entries.push({key: key, value: value(depth + 1)});
					space();
					if (text.charAt(pos) == ",") {
						pos++;
						continue;
					}
					expect("}");
					return Obj(entries);
				}
			case "[":
				pos++;
				var items = [];
				space();
				if (text.charAt(pos) == "]") {
					pos++;
					return Arr(items);
				}
				while (true) {
					items.push(value(depth + 1));
					space();
					if (text.charAt(pos) == ",") {
						pos++;
						continue;
					}
					expect("]");
					return Arr(items);
				}
			case '"':
				return Str(string());
			case _:
				if (text.substr(pos, 4) == "true") {
					pos += 4;
					return Bool(true);
				}
				if (text.substr(pos, 5) == "false") {
					pos += 5;
					return Bool(false);
				}
				if (text.substr(pos, 4) == "null") {
					pos += 4;
					return Null;
				}
				var start = pos;
				while (pos < text.length && "-+.eE0123456789".indexOf(text.charAt(pos)) >= 0)
					pos++;
				if (pos == start)
					throw fail('unexpected `$c`');
				return Num(text.substring(start, pos));
		}
	}

	function string():String {
		pos++;
		var out = new StringBuf();
		while (true) {
			if (pos >= text.length)
				throw fail("this string is never closed");
			var c = text.charAt(pos++);
			if (c == '"')
				return out.toString();
			if (c != "\\") {
				out.add(c);
				continue;
			}
			var e = text.charAt(pos++);
			switch e {
				case "n": out.add("\n");
				case "t": out.add("\t");
				case "r": out.add("\r");
				case "b": out.addChar(8);
				case "f": out.addChar(12);
				case "u":
					var hex = text.substr(pos, 4);
					var code = Std.parseInt("0x" + hex);
					if (hex.length < 4 || code == null)
						throw fail("`\\u` needs four hexadecimal digits");
					out.addChar(code);
					pos += 4;
				case _: out.add(e);
			}
		}
	}
}
