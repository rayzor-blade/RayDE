package rayde.ui;

import ashui.components.code.CodeHighlighter;

/** Extension severities are explicit; build output uses compiler diagnostic prefixes. */
class OutputHighlighter implements CodeHighlighter {
	public var kinds:Null<Array<String>>;

	public function new(?kinds:Array<String>) this.kinds = kinds;

	public function highlight(line:String, state:String):CodeHighlight {
		var parts = state.split("|"), index = state == "" ? 0 : Std.parseInt(parts[0]);
		var kind = kinds == null ? buildKind(line, parts.length > 1 ? parts[1] : "") : kinds[index];
		var token = switch kind {
			case "error": "output-error";
			case "warning", "warn": "output-warning";
			case "success": "output-success";
			case _: "plain";
		};
		return {tokens: line == "" ? [] : [{from: 0, to: line.length, kind: cast token}], state: (index + 1) + "|" + kind};
	}

	static function buildKind(line:String, previous:String):String {
		var text = StringTools.trim(line);
		if (~/^.+?:\d+: (?:characters \d+-\d+|lines \d+-\d+) : /.match(line))
			return text.indexOf(" : Warning : ") >= 0 ? "warning" : "error";
		if (~/^(?:warning\b|\[warning\])/i.match(text)) return "warning";
		if (~/^(?:error\b|\[error\]|uncaught exception\b|exception:|fatal\b)/i.match(text)
			|| text == "The build did not make a program.") return "error";
		if (~/^Exited with [1-9]\d*\.$/.match(text)) return "error";
		if (text == "Exited with 0.") return "success";
		if (text != "" && (StringTools.startsWith(line, " ") || StringTools.startsWith(line, "\t"))) return previous;
		return "info";
	}
}
