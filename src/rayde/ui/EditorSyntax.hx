package rayde.ui;

/** Immediate editor grammars, including filename aliases used by browser workspaces. */
class EditorSyntax {
	public static function languageOf(file:String):String return switch (haxe.io.Path.extension(file).toLowerCase()) {
		case "hx" | "rays": "haxe";
		case "json" | "jsonc" | "rayext" | "raytheme": "json";
		case "js" | "mjs" | "cjs" | "jsx": "javascript";
		case "ts" | "mts" | "cts" | "tsx": "typescript";
		case "rs": "rust";
		case "css": "css";
		case "py" | "pyw" | "pyi": "python";
		case "lua": "lua";
		case _: "plain";
	};
}
