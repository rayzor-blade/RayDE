import haxe.io.Bytes;
import rayde.preview.SurfaceProtocol;
import sys.thread.Mutex;
import sys.thread.Thread;

/**
 * A synthetic headless app for measuring the surface protocol: it draws a scene in software, sends the rectangle that changed each frame,
 * and applies input events it is sent (a pointer press draws a marker). Arguments: width height frames scene encoding fps.
 * Scenes: ui (a small box moves over a static page), game (the whole picture scrolls), noise (every pixel changes).
 */
class SurfaceProducer {
	static var pending:Array<SurfaceInput> = [];
	static final lock = new Mutex();

	static function main() {
		var args = Sys.args();
		var width = Std.parseInt(args[0]), height = Std.parseInt(args[1]), frames = Std.parseInt(args[2]), scene = args[3], encoding = Std.parseInt(args[4]), fps = Std.parseFloat(args[5]);
		var out = Sys.stdout();
		var pixels = Bytes.alloc(width * height * 4);
		SurfaceProtocol.writeTo(out, SurfaceProtocol.hello(width, height));
		Thread.create(() -> {
			var stdin = Sys.stdin();
			try while (true) {
				var record = SurfaceProtocol.read(stdin);
				if (record.kind == SurfaceProtocol.INPUT) { lock.acquire(); pending.push(SurfaceProtocol.parseInput(record.payload)); lock.release(); }
			} catch (_:Dynamic) {}
		});
		// The static page of the ui scene: bands of colour with lines of "text".
		if (scene == "ui") for (y in 0...height) for (x in 0...width) {
			var band = (y >> 6) & 3, text = (y % 18 < 9) && (x % 11 < 7) && x > 80 && x < width - 80 && y > 60;
			put(pixels, width, x, y, text ? 0xe0e0e0 : [0x1e1e24, 0x22262e, 0x1a1d24, 0x20242c][band]);
		}
		var last = {x: 0, y: 0, w: 0, h: 0}, applied = 0, seq = 0, start = haxe.Timer.stamp(), markers:Array<{x:Int, y:Int}> = [];
		for (n in 0...frames) {
			lock.acquire();
			var inputs = pending;
			pending = [];
			lock.release();
			for (i in inputs) {
				applied = i.id;
				if (i.type == SurfaceProtocol.POINTER_DOWN) markers.push({x: i.a, y: i.b});
			}
			var rect = {x: 0, y: 0, w: width, h: height};
			switch scene {
				case "ui":
					// Erase the box where it was, draw it where it is: one rectangle holds both.
					var bx = 100 + Std.int((width - 300) * (0.5 + 0.5 * Math.sin(n / 17))), by = 120 + Std.int((height - 300) * (0.5 + 0.5 * Math.cos(n / 23)));
					if (last.w > 0) restore(pixels, width, last.x, last.y, last.w, last.h);
					box(pixels, width, bx, by, 96, 96, 0x4c8bf5);
					for (m in markers) box(pixels, width, m.x - 6, m.y - 6, 12, 12, 0xff5a3c);
					var x0 = Std.int(Math.min(bx, last.w > 0 ? last.x : bx)), y0 = Std.int(Math.min(by, last.w > 0 ? last.y : by));
					var x1 = Std.int(Math.max(bx + 96, last.w > 0 ? last.x + last.w : bx + 96)), y1 = Std.int(Math.max(by + 96, last.w > 0 ? last.y + last.h : by + 96));
					rect = n == 0 || inputs.length > 0 ? {x: 0, y: 0, w: width, h: height} : {x: x0, y: y0, w: x1 - x0, h: y1 - y0};
					last = {x: bx, y: by, w: 96, h: 96};
				case "game":
					for (y in 0...height) for (x in 0...width) put(pixels, width, x, y, ((((x + n * 6) >> 5) + (y >> 5)) & 1) == 0 ? 0x2d5a3a : 0x3b7a4c);
					box(pixels, width, 200 + (n * 5) % (width - 400), height - 220, 64, 96, 0xf2c14e);
				default:
					for (i in 0...pixels.length) pixels.set(i, Std.random(256));
			}
			var data = rows(pixels, width, rect.x, rect.y, rect.w, rect.h);
			// The encoding is chosen per frame: deflate only when it works and is smaller, as noise does not compress.
			var sent = 0;
			if (encoding == 1) {
				var packed:Bytes = try haxe.zip.Compress.run(data, 1) catch (_:Dynamic) null;
				if (packed != null && packed.length < data.length) { data = packed; sent = 1; }
			}
			SurfaceProtocol.writeTo(out, SurfaceProtocol.frame({seq: ++seq, input: applied, x: rect.x, y: rect.y, width: rect.w, height: rect.h, encoding: sent, data: data}));
			if (fps > 0) {
				var due = start + (n + 1) / fps, wait = due - haxe.Timer.stamp();
				if (wait > 0) Sys.sleep(wait);
			}
		}
		SurfaceProtocol.writeTo(out, SurfaceProtocol.record(SurfaceProtocol.EXIT, Bytes.alloc(0)));
	}

	static inline function put(b:Bytes, width:Int, x:Int, y:Int, rgb:Int):Void {
		var at = (y * width + x) * 4;
		b.set(at, (rgb >> 16) & 0xff); b.set(at + 1, (rgb >> 8) & 0xff); b.set(at + 2, rgb & 0xff); b.set(at + 3, 255);
	}

	static function box(b:Bytes, width:Int, x:Int, y:Int, w:Int, h:Int, rgb:Int):Void
		for (yy in y...y + h) for (xx in x...x + w) if (xx >= 0 && yy >= 0 && xx < width && yy * width + xx < b.length >> 2) put(b, width, xx, yy, rgb);

	/** Puts back the static page under a rectangle. */
	static function restore(b:Bytes, width:Int, x:Int, y:Int, w:Int, h:Int):Void
		for (yy in y...y + h) for (xx in x...x + w) {
			var band = (yy >> 6) & 3, text = (yy % 18 < 9) && (xx % 11 < 7) && xx > 80 && xx < width - 80 && yy > 60;
			put(b, width, xx, yy, text ? 0xe0e0e0 : [0x1e1e24, 0x22262e, 0x1a1d24, 0x20242c][band]);
		}

	static function rows(b:Bytes, width:Int, x:Int, y:Int, w:Int, h:Int):Bytes {
		if (w == width && x == 0) return b.sub(y * width * 4, h * width * 4);
		var out = Bytes.alloc(w * h * 4);
		for (r in 0...h) out.blit(r * w * 4, b, ((y + r) * width + x) * 4, w * 4);
		return out;
	}
}
