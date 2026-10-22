import ashui.core.render.Offscreen;
import ashui.core.render.Png;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.svg.SvgDocument;
import ashui.ui.Svg;
import rayde.ui.ViewIcons;

class InactiveIconChecks {
	static function main():Void {
		var source = SvgDocument.parse(sys.io.File.getContent("extensions/rayzor/logo.svg")), markup = source.markup;
		var inactive = ViewIcons.inactive(source);
		if (inactive == source || ViewIcons.inactive(source) != inactive || source.markup != markup) throw "Inactive icons mutate their source or are not cached";
		var mask = SvgDocument.parse('<svg viewBox="0 0 8 8"><path fill="currentColor" d="M0 0h8v8H0z"/></svg>');
		if (ViewIcons.inactive(mask) != mask) throw "Tintable icons should retain their source mask";
		var renderer = Offscreen.create(), tree = new LayoutTree(), stop:Void->Void = null;
		function draw(document:SvgDocument):haxe.io.Bytes {
			var icon = Owner.root(tree, cleanup -> { stop = cleanup; return new Svg(document, {width:64, height:64}); });
			var pixels = renderer.renderToRgba8(icon, 64, 64);
			stop();
			return pixels;
		}
		var colored = draw(source), grey = draw(inactive), coloredPixels = 0, greyPixels = 0;
		for (i in 0...64 * 64) {
			var at = i * 4;
			if (Math.abs(colored.get(at + 3) - grey.get(at + 3)) > 1) throw "Inactive icon changed shape or transparency";
			if (grey.get(at + 3) > 8) {
				greyPixels++;
				if (Math.abs(grey.get(at) - grey.get(at + 1)) > 1 || Math.abs(grey.get(at + 1) - grey.get(at + 2)) > 1) throw "Inactive icon is not grey";
				if (Math.abs(colored.get(at) - colored.get(at + 1)) > 8) coloredPixels++;
			}
		}
		if (greyPixels < 20 || coloredPixels < 20) throw "Icon rendering was empty or lost the source colour";
		if (renderer.layerRecords != 0) throw "Inactive icon allocated a compositor layer";
		sys.FileSystem.createDirectory("bin/inactive-icon-checks");
		sys.io.File.saveBytes("bin/inactive-icon-checks/active.png", Png.encode(64, 64, colored));
		sys.io.File.saveBytes("bin/inactive-icon-checks/inactive.png", Png.encode(64, 64, grey));
		tree.dispose();
		Sys.println("inactive icons: cached greyscale, preserved shape and alpha, original colour and mask tinting, zero compositor layers");
	}
}
