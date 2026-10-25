package rayde.ui;

import ashui.components.code.CodeHighlighter;

/** A native TextMate session stores lexical states while Ashui retains packed line tokens. */
class TextMateSyntax implements CodeHighlighter {
	var handle:Int;
	function new(handle:Int) this.handle = handle;

	public static function forFile(file:String):Null<TextMateSyntax> {
		#if wasm
		return null;
		#else
		var bytes = haxe.io.Bytes.ofString(file), handle = openNative(bytes.getData(), bytes.length);
		return handle < 0 ? null : new TextMateSyntax(handle);
		#end
	}

	public function highlight(line:String, state:String):CodeHighlight {
		var bytes = haxe.io.Bytes.ofString(line), incoming = state == "" ? -1 : Std.parseInt(state);
		var result = lineNative(handle, bytes.getData(), bytes.length, incoming ?? -1);
		if (result == null) return {tokens:[], state:state};
		var data:Dynamic = haxe.Json.parse(result.sub(4, result.getI32(0)).toBytes(result.getI32(0)).toString());
		var tokens:Array<Dynamic> = data.tokens;
		return {tokens:[for (t in tokens) {from:Std.int(t.from), to:Std.int(t.to), kind:cast Std.string(t.kind)}], state:Std.string(data.state)};
	}

	public function dispose():Void {
		if (handle >= 0) closeNative(handle);
		handle = -1;
	}

	/** Precomputed tokens from the same registry, for read-only fenced blocks. */
	public static function fromTokens(lines:Dynamic):CodeHighlighter return new TextMateTokens(lines);

	@:hlNative("rayscript", "syntax_open") static function openNative(bytes:hl.Bytes, length:Int):Int return -1;
	@:hlNative("rayscript", "syntax_close") static function closeNative(handle:Int):Void {}
	@:hlNative("rayscript", "syntax_line") static function lineNative(handle:Int, bytes:hl.Bytes, length:Int, state:Int):hl.Bytes return null;
}

private class TextMateTokens implements CodeHighlighter {
	final lines:Array<Array<Dynamic>>;
	public function new(lines:Dynamic) this.lines = lines == null ? [] : lines;
	public function highlight(line:String, state:String):CodeHighlight {
		var index = state == "" ? 0 : Std.parseInt(state);
		var input = index == null || index >= lines.length ? [] : lines[index];
		return {tokens:[for (t in input) {from:Std.int(t.from), to:Std.int(t.to), kind:cast Std.string(t.kind)}], state:((index ?? 0) + 1) + ""};
	}
}
