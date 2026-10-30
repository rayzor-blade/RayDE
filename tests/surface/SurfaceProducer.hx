import haxe.io.Bytes;
import rayde.preview.SurfaceLink;
import rayde.preview.SurfaceProtocol;

/**
 * A synthetic headless app for measuring the surface protocol: it draws a scene in software and applies the input it is sent (a pointer press
 * draws a marker). Arguments: width height frames scene encoding fps.
 * Scenes: ui (a small box moves over a static page), game (the whole picture scrolls), noise (every pixel changes).
 */
class SurfaceProducer {
	static function main() {
		var args = Sys.args();
		var width = Std.parseInt(args[0]), height = Std.parseInt(args[1]), frames = Std.parseInt(args[2]), scene = args[3], encoding = Std.parseInt(args[4]), fps = Std.parseFloat(args[5]);
		SurfaceLink.redirectTrace();
		var link = new SurfaceLink(width, height);
		link.deflate = encoding == 1;
		link.start();
		var pixels = Bytes.alloc(width * height * 4);
		// The static page of the ui scene: bands of colour with lines of "text".
		if (scene == "ui") for (y in 0...height) for (x in 0...width) put(pixels, width, x, y, page(width, x, y));
		var last = {x: 0, y: 0, w: 0, h: 0}, start = haxe.Timer.stamp(), markers:Array<{x:Int, y:Int}> = [];
		for (n in 0...frames) {
			for (i in link.takeInputs()) if (i.type == SurfaceProtocol.POINTER_DOWN) markers.push({x: i.a, y: i.b});
			switch scene {
				case "ui":
					// Erase the box where it was, draw it where it is.
					var bx = 100 + Std.int((width - 300) * (0.5 + 0.5 * Math.sin(n / 17))), by = 120 + Std.int((height - 300) * (0.5 + 0.5 * Math.cos(n / 23)));
					if (last.w > 0) restore(pixels, width, last.x, last.y, last.w, last.h);
					box(pixels, width, bx, by, 96, 96, 0x4c8bf5);
					for (m in markers) box(pixels, width, m.x - 6, m.y - 6, 12, 12, 0xff5a3c);
					last = {x: bx, y: by, w: 96, h: 96};
				case "game":
					for (y in 0...height) for (x in 0...width) put(pixels, width, x, y, ((((x + n * 6) >> 5) + (y >> 5)) & 1) == 0 ? 0x2d5a3a : 0x3b7a4c);
					box(pixels, width, 200 + (n * 5) % (width - 400), height - 220, 64, 96, 0xf2c14e);
				default:
					for (i in 0...pixels.length) pixels.set(i, Std.random(256));
			}
			var picture = link.buffer();
			picture.blit(0, pixels, 0, pixels.length);
			link.submit(picture);
			if (fps > 0) {
				var due = start + (n + 1) / fps, wait = due - haxe.Timer.stamp();
				if (wait > 0) Sys.sleep(wait);
			}
		}
		link.finishAndExit();
	}

	static function page(width:Int, x:Int, y:Int):Int {
		var band = (y >> 6) & 3, text = (y % 18 < 9) && (x % 11 < 7) && x > 80 && x < width - 80 && y > 60;
		return text ? 0xe0e0e0 : [0x1e1e24, 0x22262e, 0x1a1d24, 0x20242c][band];
	}

	static inline function put(b:Bytes, width:Int, x:Int, y:Int, rgb:Int):Void {
		var at = (y * width + x) * 4;
		b.set(at, (rgb >> 16) & 0xff); b.set(at + 1, (rgb >> 8) & 0xff); b.set(at + 2, rgb & 0xff); b.set(at + 3, 255);
	}

	static function box(b:Bytes, width:Int, x:Int, y:Int, w:Int, h:Int, rgb:Int):Void
		for (yy in y...y + h) for (xx in x...x + w) if (xx >= 0 && yy >= 0 && xx < width && yy * width + xx < b.length >> 2) put(b, width, xx, yy, rgb);

	/** Puts back the static page under a rectangle. */
	static function restore(b:Bytes, width:Int, x:Int, y:Int, w:Int, h:Int):Void
		for (yy in y...y + h) for (xx in x...x + w) put(b, width, xx, yy, page(width, xx, yy));
}
