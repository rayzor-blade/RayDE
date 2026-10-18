package rayde.ui;

import ashui.draw.DrawContext;
import ashui.types.Brush;

/**
 * The characters a terminal draws itself rather than trust a font with: the
 * lines and corners of U+2500 to U+257F, as arms from the middle of the cell, and the blocks and
 * shades of U+2580 to U+259F, so a program's borders and bars meet at the cell's edges whatever
 * font the text is in. The arm table was made from the Unicode names, each cell's left, right, up and down
 * as 0 none, 1 light, 2 heavy or 3 double, two bits each.
 */
class BoxDrawing {
	/** U+2500 to U+257F: left in the lowest two bits, then right, up and down. */
	static final arms:Array<Int> = [
		5, 10, 80, 160, 5, 10, 80, 160, 5, 10, 80, 160, 68, 72, 132, 136,
		65, 66, 129, 130, 20, 24, 36, 40, 17, 18, 33, 34, 84, 88, 100, 148,
		164, 104, 152, 168, 81, 82, 97, 145, 161, 98, 146, 162, 69, 70, 73, 74,
		133, 134, 137, 138, 21, 22, 25, 26, 37, 38, 41, 42, 85, 86, 89, 90,
		101, 149, 165, 102, 105, 150, 153, 106, 154, 166, 169, 170, 5, 10, 80, 160,
		15, 240, 76, 196, 204, 67, 193, 195, 28, 52, 60, 19, 49, 51, 92, 244,
		252, 83, 241, 243, 79, 197, 207, 31, 53, 63, 95, 245, 255, 68, 65, 17,
		20, 5, 5, 0, 1, 16, 4, 64, 2, 32, 8, 128, 9, 144, 6, 96
	];

	/** Whether `code` is drawn by this class and so left out of the text. */
	public static inline function draws(code:Int):Bool
		return code >= 0x2500 && code <= 0x259f;

	/** Draws the character `code` in the cell at `(x, y)`, `w` by `h`, in `color`. */
	public static function draw(ctx:DrawContext, code:Int, x:Float, y:Float, w:Float, h:Float, color:Int):Void {
		if (code < 0x2580)
			lines(ctx, arms[code - 0x2500], x, y, w, h, color);
		else
			block(ctx, code, x, y, w, h, color);
	}

	static function lines(ctx:DrawContext, a:Int, x:Float, y:Float, w:Float, h:Float, color:Int):Void {
		var light = Math.max(1, Math.round(h / 14)), heavy = light * 2, brush = Brush.solid(color);
		var cx = x + Math.round(w / 2), cy = y + Math.round(h / 2);
		// An arm is a bar from the middle of the cell to its edge, as thick as its weight; a double arm is two thin bars either side.
		inline function arm(weight:Int, horizontal:Bool, towardStart:Bool):Void {
			if (weight == 0)
				return;
			var t = weight == 2 ? heavy : light, gap = light * 1.5;
			var bars = weight == 3 ? [-gap, gap] : [0.];
			for (o in bars) {
				if (horizontal) {
					var from = towardStart ? x : cx - t / 2, to = towardStart ? cx + t / 2 : x + w;
					ctx.fillRect(from, cy + o - t / 2, to - from, t, brush);
				} else {
					var from = towardStart ? y : cy - t / 2, to = towardStart ? cy + t / 2 : y + h;
					ctx.fillRect(cx + o - t / 2, from, t, to - from, brush);
				}
			}
		}
		arm(a & 3, true, true);
		arm((a >> 2) & 3, true, false);
		arm((a >> 4) & 3, false, true);
		arm((a >> 6) & 3, false, false);
	}

	static function block(ctx:DrawContext, code:Int, x:Float, y:Float, w:Float, h:Float, color:Int):Void {
		inline function rect(l:Float, t:Float, r:Float, b:Float, alpha = 1.):Void
			ctx.fillRect(x + w * l, y + h * t, w * (r - l), h * (b - t), Brush.solid(color, alpha));
		switch code {
			case 0x2580: rect(0, 0, 1, .5);
			case c if (c >= 0x2581 && c <= 0x2588): rect(0, 1 - (c - 0x2580) / 8, 1, 1);
			case c if (c >= 0x2589 && c <= 0x258f): rect(0, 0, (0x2590 - c) / 8, 1);
			case 0x2590: rect(.5, 0, 1, 1);
			case 0x2591: rect(0, 0, 1, 1, .25);
			case 0x2592: rect(0, 0, 1, 1, .5);
			case 0x2593: rect(0, 0, 1, 1, .75);
			case 0x2594: rect(0, 0, 1, 1 / 8);
			case 0x2595: rect(7 / 8, 0, 1, 1);
			case c if (c >= 0x2596 && c <= 0x259f):
				// Quadrants as bits: upper left 1, upper right 2, lower left 4, lower right 8.
				var mask = [0x4, 0x8, 0x1, 0xd, 0x9, 0x7, 0xb, 0x2, 0x6, 0xe][c - 0x2596];
				if (mask & 1 != 0) rect(0, 0, .5, .5);
				if (mask & 2 != 0) rect(.5, 0, 1, .5);
				if (mask & 4 != 0) rect(0, .5, .5, 1);
				if (mask & 8 != 0) rect(.5, .5, 1, 1);
			case _:
		}
	}
}
