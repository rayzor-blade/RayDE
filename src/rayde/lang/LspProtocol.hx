package rayde.lang;

import rayde.lang.Display;
import rayde.lang.Outline.OutlineSymbol;

/** LSP uses UTF-16 positions, matching editor string offsets on HashLink. */
class LspProtocol {
	public static function uri(file:String):String {
		var path = haxe.io.Path.normalize(file).split("\\").join("/");
		if (!StringTools.startsWith(path, "/")) path = "/" + path;
		return "file://" + [for (part in path.split("/")) StringTools.urlEncode(part)].join("/");
	}
	public static function path(uri:String):Null<String> {
		if (uri == null || !StringTools.startsWith(uri, "file://")) return null;
		var raw = uri.substr(7);
		if (!StringTools.startsWith(raw, "/")) return null;
		var file = StringTools.urlDecode(raw.split("+").join("%2B"));
		if (Sys.systemName() == "Windows" && ~/^\/[A-Za-z]:/.match(file)) file = file.substr(1);
		return haxe.io.Path.normalize(file);
	}
	public static function position(text:String, offset:Int):TextPosition {
		var line = 0, start = 0, end = Std.int(Math.max(0, Math.min(offset, text.length)));
		for (i in 0...end) if (text.charCodeAt(i) == 10) { line++; start = i + 1; }
		return {line:line, character:end - start};
	}
	public static function offset(text:String, p:TextPosition):Int {
		var at = 0;
		for (_ in 0...p.line) { var next = text.indexOf("\n", at); if (next < 0) return text.length; at = next + 1; }
		var end = text.indexOf("\n", at);
		if (end < 0) end = text.length;
		if (end > at && text.charCodeAt(end - 1) == 13) end--;
		return Std.int(Math.max(at, Math.min(end, at + p.character)));
	}
	public static function at(file:String, text:String, offset:Int):Dynamic
		return {textDocument:{uri:uri(file)}, position:position(text, offset)};

	public static function documentation(value:Dynamic):String {
		if (value == null) return "";
		if (Std.isOfType(value, String)) return value;
		if (Std.isOfType(value, Array)) return [for (part in (value:Array<Dynamic>)) documentation(part)].join("\n\n");
		return value.value == null ? "" : Std.string(value.value);
	}
	public static function locations(value:Dynamic):Array<Location> {
		if (value == null) return [];
		var items:Array<Dynamic> = Std.isOfType(value, Array) ? value : [value];
		var result:Array<Location> = [];
		for (item in items) {
			var file = path(item.uri == null ? item.targetUri : item.uri);
			var range:Dynamic = item.range == null ? item.targetSelectionRange : item.range;
			if (file != null && range != null) result.push({file:file, range:range});
		}
		return result;
	}
	public static function diagnostics(value:Dynamic):Array<Diagnostic> {
		var file = path(value.uri);
		return file == null ? [] : [for (d in (value.diagnostics:Array<Dynamic>))
			{file:file, range:(d.range:TextRange), severity:d.severity == null ? 1 : (d.severity:Int), message:Std.string(d.message)}];
	}
	public static function outline(value:Dynamic):Array<OutlineSymbol> {
		if (value == null || !Std.isOfType(value, Array)) return [];
		return [for (s in (value:Array<Dynamic>)) {
			name:Std.string(s.name), range:(s.selectionRange != null ? s.selectionRange : s.range != null ? s.range : s.location.range),
			kind:s.kind == 5 ? 1 : s.kind == 11 || s.kind == 10 || s.kind == 23 || s.kind == 26 ? 2 : s.kind == 6 || s.kind == 9 || s.kind == 12 ? 8 : s.kind == 7 || s.kind == 8 || s.kind == 22 ? 6 : s.kind == 2 || s.kind == 3 || s.kind == 4 ? 17 : 0,
			children:outline(s.children)
		}];
	}
	public static function signatures(value:Dynamic):Null<SignatureHelp> {
		if (value == null || value.signatures == null || value.signatures.length == 0) return null;
		return {active:value.activeSignature == null ? 0 : value.activeSignature, parameter:value.activeParameter == null ? 0 : value.activeParameter,
			signatures:[for (s in (value.signatures:Array<Dynamic>)) {label:Std.string(s.label), documentation:documentation(s.documentation),
				parameters:s.parameters == null ? [] : [for (p in (s.parameters:Array<Dynamic>)) {
					name:Std.isOfType(p.label, Array) ? Std.string(s.label).substring(p.label[0], p.label[1]) : Std.string(p.label), type:"", optional:false
				}]}]};
	}
}
