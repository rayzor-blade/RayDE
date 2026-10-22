import rayde.run.AnsiOutput;
import rayde.run.AnsiOutput.AnsiSnapshot;

class AnsiOutputChecks {
	static function check(value:Bool, message:String):Void { if (!value) throw message; }
	static function decode(text:String, limit = 2000):AnsiSnapshot {
		var ansi = new AnsiOutput(limit); ansi.write(text); return ansi.snapshot();
	}
	public static function run():Void {
		var plain = decode("plain λ\r\nnext\rfinal\ttext");
		check(plain.text == "plain λ\nnext\nfinal\ttext" && plain.spans[0] == null, "Plain Output changed or allocated styled spans");
		var unicode = decode("🌍 \x1b[31mR\x1b[0m");
		check(unicode.spans[0][0].from == 3 && unicode.spans[0][0].to == 4, "ANSI spans did not use editor string offsets");
		var value = decode("before \x1b[1;31mred\x1b[22;39m after");
		check(value.text == "before red after", "SGR bytes remained in selectable text");
		var span = value.spans[0][0];
		check(span.from == 7 && span.to == 10 && span.style.color == "var(--rayde-ansi-1)" && span.style.fontWeight == "700", "Basic color, bold or offsets were lost");
		value = decode("\x1b[94;103mbright\x1b[39m default foreground\x1b[49m plain");
		check(value.spans[0][0].style.color == "var(--rayde-ansi-12)" && value.spans[0][0].style.background == "var(--rayde-ansi-11)", "Bright ANSI colors were lost");
		check(value.spans[0][1].style.color == null && value.spans[0][1].style.background != null, "Foreground reset cleared the background");
		value = decode("\x1b[38;5;196;48;5;236mindexed\x1b[0m \x1b[38;2;18;52;86;48;2;101;67;33mRGB");
		check(value.spans[0][0].style.color == "#FF0000" && value.spans[0][0].style.background == "#303030", "Indexed color conversion was incorrect");
		check(value.spans[0][1].style.color == "#123456" && value.spans[0][1].style.background == "#654321", "RGB color conversion was incorrect");
		value = decode("\x1b[2;3;4;9;7mstyled\x1b[22;23;24;29;27mplain");
		span = value.spans[0][0];
		check(span.style.opacity == "0.65" && span.style.fontStyle == "italic" && span.style.textDecoration == "underline line-through"
			&& span.style.color == "var(--surface-overlay)" && span.style.background == "var(--text-primary)", "Text attributes or inverse colors were lost");
		check(span.to == 6 && value.spans[0].length == 1, "Attribute resets left styling on plain text");
		var ansi = new AnsiOutput();
		ansi.write("\x1b[38;2;18;"); ansi.write("52;86mλ");
		var before = ansi.snapshot(); ansi.write("more\nsecond\x1b[0m");
		value = ansi.snapshot();
		check(before.text == "λ" && before.spans[0][0].to == 1 && value.text == "λmore\nsecond"
			&& value.spans[1][0].style.color == "#123456", "Chunked SGR or multiline state was lost, or a published snapshot mutated");
		check(decode("\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x07\x1b[2K text\x1bPignored\x1b\\").text == "link text", "OSC links or nonprinting terminal controls leaked into text");
		check(decode("before\x1b[31").text == "before", "Partial control sequence was exposed");
		check(decode("\x1b[38;2;999;0;0mplain").spans[0] == null, "Invalid RGB parameters became formatting");
		value = decode("\x1b[32mold\nsecond\nthird", 2);
		check(value.text == "second\nthird" && value.spans[0][0].style.color == "var(--rayde-ansi-2)", "Line eviction lost active ANSI state");
		check(AnsiOutput.sameSpans(null, decode("plain\nmore plain").spans), "Plain log appends unnecessarily invalidated formatting");
		check(!AnsiOutput.sameSpans(decode("\x1b[31mx").spans, decode("\x1b[32mx").spans), "Identical text hid a color change");
		var diagnostics = rayde.run.CompilerOutput.parse("\x1b[31mMain.hx:2: characters 1-4 : Unknown identifier\x1b[0m", "/workspace");
		check(diagnostics.length == 1 && diagnostics[0].file == "/workspace/Main.hx", "ANSI output broke compiler diagnostic locations");
		Sys.println("ANSI Output: colors, text attributes, resets, streaming controls, bounded lines and clean diagnostic text");
	}
}
