package rayde.workspace;

#if macro
import haxe.macro.Context;
import sys.io.File;

/** The page's code face and missing-glyph fallback, registered with Ashui's defaults before layout. */
class PageFonts {
	public static function stage():Void {
		if (!Context.defined("wasm")) return;
		for (file in ["JetBrainsMono-Regular.woff2", "KeyboardSymbols.ttf"])
			Context.addResource("ashui.font.default:rayde:" + file, File.getBytes("assets/fonts/" + file));
	}
}
#end
