package rayde.run;

/** CSS values are data: workers decode them without touching a UI node. */
typedef AnsiStyle = {
	?color:String, ?background:String, ?fontWeight:String, ?fontStyle:String, ?textDecoration:String, ?opacity:String
};
typedef AnsiSpan = {from:Int, to:Int, style:AnsiStyle};
typedef AnsiLine = {text:String, spans:Null<Array<AnsiSpan>>, kind:Null<String>};
typedef AnsiSnapshot = {text:String, spans:Array<Null<Array<AnsiSpan>>>, kinds:Array<String>};

/** Streaming SGR decoder with a bounded line cache; terminal cursor controls are discarded. */
class AnsiOutput {
	final limit:Int;
	final lines:Array<AnsiLine> = [];
	var head = 0;
	var count = 0;
	var text = new StringBuf();
	var length = 0;
	var spans:Null<Array<AnsiSpan>>;
	var kind:Null<String>;
	var foreground = 0;
	var background = 0;
	var attributes = 0;
	var style:Null<AnsiStyle>;
	var mode = 0;
	var sequence = "";
	var carriage = false;

	public function new(limit = 2000) this.limit = Std.int(Math.max(1, limit));

	/** Records are separate log entries; writes without a kind may be arbitrary process chunks. */
	public function write(value:String, ?kind:String):Void {
		if (kind != null) this.kind = kind;
		var start = 0, i = 0;
		while (i < value.length) {
			var c = StringTools.fastCodeAt(value, i);
			if (mode == 0 && c != 27 && c != 10 && c != 13 && (c >= 32 || c == 9)) {
				carriage = false; i++; continue;
			}
			append(value.substring(start, i));
			i++; start = i;
			switch mode {
				case 0:
					if (c == 27) { mode = 1; carriage = false; }
					else if (c == 13) { finishLine(); carriage = true; }
					else if (c == 10) { if (!carriage) finishLine(); carriage = false; }
				case 1:
					sequence = "";
					mode = c == 91 ? 2 : c == 93 ? 3 : c == 80 || c == 94 || c == 95 ? 5 : c >= 32 && c <= 47 ? 7 : 0;
				case 2:
					if (c >= 64 && c <= 126) { if (c == 109) sgr(sequence); mode = 0; sequence = ""; }
					else if (sequence.length < 128) sequence += String.fromCharCode(c);
					else { mode = 8; sequence = ""; }
				case 3: if (c == 7) mode = 0; else if (c == 27) mode = 4;
				case 4: mode = c == 92 ? 0 : 3;
				case 5: if (c == 27) mode = 6;
				case 6: mode = c == 92 ? 0 : 5;
				case 7: if (c >= 48 && c <= 126) mode = 0;
				case 8: if (c >= 64 && c <= 126) mode = 0;
			}
		}
		append(value.substring(start));
	}

	function append(value:String):Void {
		if (value == "") return;
		text.add(value);
		if (style != null) {
			if (spans == null) spans = [];
			var last = spans.length == 0 ? null : spans[spans.length - 1];
			if (last != null && last.to == length && last.style == style) last.to += value.length;
			else spans.push({from:length, to:length + value.length, style:style});
		}
		length += value.length;
	}

	function finishLine():Void {
		var line = {text:text.toString(), spans:spans, kind:kind};
		if (count < limit) { lines.push(line); count++; }
		else { lines[head] = line; head = (head + 1) % limit; }
		text = new StringBuf(); length = 0; spans = null;
	}

	public function snapshot():AnsiSnapshot {
		var out:Array<AnsiLine> = [];
		for (i in Std.int(Math.max(0, count + 1 - limit))...count) out.push(lines[(head + i) % limit]);
		out.push({text:text.toString(), spans:spans == null ? null : [for (span in spans) {from:span.from, to:span.to, style:span.style}], kind:kind});
		return {text:out.map(line -> line.text).join("\n"), spans:out.map(line -> line.spans), kinds:out.map(line -> line.kind)};
	}

	function sgr(value:String):Void {
		var before = foreground + "/" + background + "/" + attributes;
		var args = value.split(";"), i = 0;
		while (i < args.length) {
			var code = args[i] == "" ? 0 : Std.parseInt(args[i]); i++;
			if (code == null) continue;
			switch code {
				case 0: foreground = background = attributes = 0;
				case 1: attributes |= 1;
				case 2: attributes |= 2;
				case 3: attributes |= 4;
				case 4, 21: attributes |= 8;
				case 7: attributes |= 16;
				case 9: attributes |= 32;
				case 22: attributes &= ~3;
				case 23: attributes &= ~4;
				case 24: attributes &= ~8;
				case 27: attributes &= ~16;
				case 29: attributes &= ~32;
				case 39: foreground = 0;
				case 49: background = 0;
				case 38, 48:
					var color:Null<Int> = null, form = i < args.length ? Std.parseInt(args[i++]) : null;
					if (form == 5 && i < args.length) {
						var index = Std.parseInt(args[i++]);
						if (index != null && index >= 0 && index <= 255) color = 0x1000000 | index;
					} else if (form == 2 && i + 2 < args.length) {
						var r = Std.parseInt(args[i++]), g = Std.parseInt(args[i++]), b = Std.parseInt(args[i++]);
						if (r != null && g != null && b != null && r >= 0 && r <= 255 && g >= 0 && g <= 255 && b >= 0 && b <= 255)
							color = 0x2000000 | r << 16 | g << 8 | b;
					} else i = args.length;
					if (color != null) { if (code == 38) foreground = color; else background = color; }
				case _:
					if (code >= 30 && code <= 37) foreground = 0x1000000 | (code - 30);
					else if (code >= 90 && code <= 97) foreground = 0x1000000 | (code - 90 + 8);
					else if (code >= 40 && code <= 47) background = 0x1000000 | (code - 40);
					else if (code >= 100 && code <= 107) background = 0x1000000 | (code - 100 + 8);
			}
		}
		if (before == foreground + "/" + background + "/" + attributes) return;
		if (foreground == 0 && background == 0 && attributes == 0) { style = null; return; }
		var fg = AnsiColors.css(foreground), bg = AnsiColors.css(background);
		if (attributes & 16 != 0) { var original = fg; fg = bg == null ? "var(--surface-overlay)" : bg; bg = original == null ? "var(--text-primary)" : original; }
		var decoration = attributes & 8 != 0 ? "underline" : "";
		if (attributes & 32 != 0) decoration += decoration == "" ? "line-through" : " line-through";
		style = {color:fg, background:bg, fontWeight:attributes & 1 != 0 ? "700" : null,
			fontStyle:attributes & 4 != 0 ? "italic" : null, textDecoration:decoration == "" ? null : decoration,
			opacity:attributes & 2 != 0 ? "0.65" : null};
	}

	public static function sameSpans(a:Array<Null<Array<AnsiSpan>>>, b:Array<Null<Array<AnsiSpan>>>):Bool {
		if (a == b) return true;
		var length = Std.int(Math.max(a == null ? 0 : a.length, b == null ? 0 : b.length));
		for (i in 0...length) {
			var left = a == null || i >= a.length ? null : a[i], right = b == null || i >= b.length ? null : b[i];
			if (left == right) continue;
			if (left == null || right == null || left.length != right.length) return false;
			for (j in 0...left.length) {
				var x = left[j], y = right[j], p = x.style, q = y.style;
				if (x.from != y.from || x.to != y.to || p.color != q.color || p.background != q.background || p.fontWeight != q.fontWeight
					|| p.fontStyle != q.fontStyle || p.textDecoration != q.textDecoration || p.opacity != q.opacity) return false;
			}
		}
		return true;
	}
}
