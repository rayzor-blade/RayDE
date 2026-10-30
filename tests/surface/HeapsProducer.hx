import haxe.io.Bytes;
import rayde.preview.SurfaceProtocol;
import sys.thread.Mutex;
import sys.thread.Thread;

/**
 * A real Heaps app as a surface producer: it draws an h2d scene into an offscreen texture each frame, reads the pixels back, sends the
 * rectangle that differs from the last frame, and applies the pointer presses it is sent. Arguments: width height frames.
 * Heaps writes traces to stdout, so they are sent to stderr before anything else runs.
 */
class HeapsProducer extends hxd.App {
	static var width = 640;
	static var height = 360;
	static var frames = 0;
	static var pending:Array<SurfaceInput> = [];
	static final lock = new Mutex();

	var target:h3d.mat.Texture;
	var previous:Null<Bytes>;
	var ball:h2d.Graphics;
	var markers:h2d.Object;
	var surface:h2d.Interactive;
	var applied = 0;
	var seq = 0;
	var sent = 0;
	var time = 0.;

	override function init() {
		hxd.Window.getInstance().resize(width, height);
		s2d.scaleMode = Fixed(width, height, 1);
		engine.backgroundColor = 0xFF20242C;
		target = new h3d.mat.Texture(width, height, [Target]);
		var label = new h2d.Text(hxd.res.DefaultFont.get(), s2d);
		label.text = "Heaps through the surface protocol";
		label.x = 24;
		label.y = 24;
		label.scale(2);
		ball = new h2d.Graphics(s2d);
		ball.beginFill(0x4C8BF5);
		ball.drawCircle(0, 0, 40);
		ball.endFill();
		markers = new h2d.Object(s2d);
		surface = new h2d.Interactive(width, height, s2d);
		surface.onPush = e -> {
			var m = new h2d.Graphics(markers);
			m.beginFill(0xFF5A3C);
			m.drawCircle(e.relX, e.relY, 8);
			m.endFill();
		};
		Thread.create(() -> {
			var stdin = Sys.stdin();
			try while (true) {
				var record = SurfaceProtocol.read(stdin);
				if (record.kind == SurfaceProtocol.INPUT) {
					lock.acquire();
					pending.push(SurfaceProtocol.parseInput(record.payload));
					lock.release();
				}
			} catch (_:Dynamic) {}
		});
		SurfaceProtocol.writeTo(Sys.stdout(), SurfaceProtocol.hello(width, height));
	}

	override function update(dt:Float) {
		time += dt;
		lock.acquire();
		var inputs = pending;
		pending = [];
		lock.release();
		for (i in inputs) {
			applied = i.id;
			if (i.type == SurfaceProtocol.POINTER_DOWN) {
				var e = new hxd.Event(EPush, i.a, i.b);
				e.relX = i.a;
				e.relY = i.b;
				surface.onPush(e);
			}
		}
		ball.x = width / 2 + Math.cos(time * 2) * (width / 3);
		ball.y = height / 2 + Math.sin(time * 3) * (height / 4);

		target.clear(0x20242C, 1);
		s2d.drawTo(target);
		var pixels = target.capturePixels();
		pixels.convert(RGBA);
		var now = pixels.bytes;
		var rect = changed(now);
		if (rect != null) {
			var data = Bytes.alloc(rect.w * rect.h * 4);
			for (r in 0...rect.h) data.blit(r * rect.w * 4, now, ((rect.y + r) * width + rect.x) * 4, rect.w * 4);
			SurfaceProtocol.writeTo(Sys.stdout(), SurfaceProtocol.frame({seq: ++seq, input: applied, x: rect.x, y: rect.y, width: rect.w, height: rect.h, encoding: 0, data: data}));
			previous = now.sub(0, now.length);
		}
		if (++sent >= frames) {
			SurfaceProtocol.writeTo(Sys.stdout(), SurfaceProtocol.record(SurfaceProtocol.EXIT, Bytes.alloc(0)));
			Sys.exit(0);
		}
	}

	/** The rectangle that differs from the last frame sent, the whole picture for the first, or null when nothing changed. */
	function changed(now:Bytes):Null<{x:Int, y:Int, w:Int, h:Int}> {
		if (previous == null) return {x: 0, y: 0, w: width, h: height};
		var x0 = width, y0 = height, x1 = 0, y1 = 0, row = width * 4;
		for (y in 0...height) {
			var base = y * row, first = -1, last = -1;
			for (x in 0...width) if (now.getInt32(base + x * 4) != previous.getInt32(base + x * 4)) {
				if (first < 0) first = x;
				last = x;
			}
			if (first < 0) continue;
			if (first < x0) x0 = first;
			if (last + 1 > x1) x1 = last + 1;
			if (y < y0) y0 = y;
			y1 = y + 1;
		}
		return x1 <= x0 ? null : {x: x0, y: y0, w: x1 - x0, h: y1 - y0};
	}

	static function main() {
		haxe.Log.trace = (v, ?pos) -> Sys.stderr().writeString(Std.string(v) + "\n");
		var args = Sys.args();
		if (args.length > 0) width = Std.parseInt(args[0]);
		if (args.length > 1) height = Std.parseInt(args[1]);
		if (args.length > 2) frames = Std.parseInt(args[2]);
		if (frames <= 0) frames = 120;
		new HeapsProducer();
	}
}
