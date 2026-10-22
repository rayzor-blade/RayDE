package rayde.ui;

import ashui.components.code.CodeHighlighter;
import rayde.run.AnsiOutput.AnsiSpan;

/** Extension severities are explicit; build output uses compiler diagnostic prefixes. */
class OutputHighlighter implements CodeHighlighter {
	public var kinds:Null<Array<String>>;
	public var spans:Null<Array<Null<Array<AnsiSpan>>>>;
	static final location = ~/^.+?:\d+: (?:characters \d+-\d+|lines \d+-\d+) : /;
	static final warning = ~/^(?:warning\b|\[warning\])/i;
	static final error = ~/^(?:error\b|\[error\]|uncaught exception\b|exception:|fatal\b)/i;
	static final failedExit = ~/^Exited with [1-9]\d*\.$/;

	public function new(?kinds:Array<String>, ?spans:Array<Null<Array<AnsiSpan>>>) {
		this.kinds = kinds; this.spans = spans;
	}

	public function highlight(line:String, state:String):CodeHighlight {
		var parts = state.split("|"), index = state == "" ? 0 : Std.parseInt(parts[0]);
		var kind = kinds == null ? buildKind(line, parts.length > 1 ? parts[1] : "") : kinds[index];
		// The code viewer stores its declared token kinds; Output scopes their severity colors.
		var token:CodeTokenKind = switch kind {
			case "error": Keyword;
			case "warning", "warn": Number;
			case "success": StringLiteral;
			case _: Plain;
		};
		var styled = spans == null || index >= spans.length ? null : spans[index], tokens:Array<CodeToken> = [], at = 0;
		if (styled != null) for (span in styled) {
			if (span.from > at) tokens.push({from:at, to:span.from, kind:token});
			tokens.push({from:span.from, to:span.to, kind:token, style:span.style});
			at = span.to;
		}
		if (at < line.length) tokens.push({from:at, to:line.length, kind:token});
		return {tokens:tokens, state:(index + 1) + "|" + kind};
	}

	static function buildKind(line:String, previous:String):String {
		var text = StringTools.trim(line);
		if (location.match(line))
			return text.indexOf(" : Warning : ") >= 0 ? "warning" : "error";
		if (warning.match(text)) return "warning";
		if (error.match(text)
			|| text == "The build did not make a program.") return "error";
		if (failedExit.match(text)) return "error";
		if (text == "Exited with 0.") return "success";
		if (text != "" && (StringTools.startsWith(line, " ") || StringTools.startsWith(line, "\t"))) return previous;
		return "info";
	}
}
