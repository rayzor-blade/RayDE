package rayde.lang;

import rayde.lang.Display.TextRange;

typedef OutlineSymbol = {name:String, kind:Int, range:TextRange, children:Array<OutlineSymbol>};

/** The compiler's module symbols, nested by their qualified container names. */
class Outline {
	public static function parse(reply:String):Array<OutlineSymbol> {
		var at = reply.indexOf("["), files:Array<Dynamic> = haxe.Json.parse(at < 0 ? reply : reply.substr(at));
		var out:Array<OutlineSymbol> = [], containers = new Map<String, OutlineSymbol>();
		for (file in files) {
			var symbols:Array<Dynamic> = file.symbols;
			for (s in symbols) {
				var symbol:OutlineSymbol = {name:s.name, kind:s.kind, range:s.range, children:[]};
				var parent = s.containerName == null ? null : containers.get(s.containerName);
				(parent == null ? out : parent.children).push(symbol);
				containers.set((s.containerName == null ? "" : s.containerName + ".") + s.name, symbol);
			}
		}
		return out;
	}
}
