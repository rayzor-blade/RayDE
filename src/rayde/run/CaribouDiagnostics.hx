package rayde.run;

import rayde.lang.Display.Diagnostic;

/**
 * What `caribou run --diagnostics <file>` writes: one JSON object per line, each a compile, reload or runtime finding with
 * an absolute file and a 1-based range when a position is known, as Caribou's `Diagnostic`. A finding without a position is
 * a workspace problem. Other lines of the file, such as `serve`'s `{"serving": ...}`, are not findings.
 */
class CaribouDiagnostics {
	public static function parse(text:String):Array<Diagnostic> {
		var out:Array<Diagnostic> = [];
		for (line in text.split("\n")) {
			line = StringTools.trim(line);
			if (line == "") continue;
			var data:Dynamic;
			try data = haxe.Json.parse(line) catch (_:Dynamic) continue;
			if (data == null || !Reflect.isObject(data) || data.message == null) continue;
			out.push({file: data.file == null ? null : Std.string(data.file), range: range(data.range), severity: severity(data.severity), message: message(data)});
		}
		return out;
	}

	/** LSP's numbering: 1 error, 2 warning, 3 information, 4 hint; Caribou writes the number or its name. */
	static function severity(value:Dynamic):Int {
		if (Std.isOfType(value, Int)) return value;
		return switch Std.string(value) {
			case "warning", "warn": 2;
			case "information", "info": 3;
			case "hint": 4;
			case _: 1;
		};
	}

	static function range(value:Dynamic):Null<rayde.lang.Display.TextRange> {
		if (value == null || value.start == null || value.end == null) return null;
		function position(p:Dynamic):rayde.lang.Display.TextPosition return {line: Std.int(Math.max(0, Std.int(p.line) - 1)), character: Std.int(Math.max(0, Std.int(p.column) - 1))};
		return {start: position(value.start), end: position(value.end)};
	}

	/** The message, led by where it came from when that is a guest language: `[lua game/hello] message`. */
	static function message(data:Dynamic):String {
		var language = data.language == null ? "" : Std.string(data.language), module = data.module == null ? "" : Std.string(data.module);
		var where = StringTools.trim(language + " " + module);
		return (where == "" ? "" : "[" + where + "] ") + Std.string(data.message);
	}
}
