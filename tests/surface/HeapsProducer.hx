import haxe.io.Bytes;
import rayde.preview.SurfaceProtocol;
import sys.thread.Mutex;
import sys.thread.Thread;

/** What the render thread hands the sender: the newest picture and the last input applied before it. Older unsent pictures are replaced. */
private class Slot {
	final lock = new Mutex();
	final ready = new sys.thread.Lock();
	var pending:Null<Bytes>;
	var input = 0;
	final spare:Array<Bytes> = [];
	public var dropped = 0;

	public function new() {}

	/** A buffer to read pixels into: a recycled one when there is one. */
	public function buffer(size:Int):Bytes {
		lock.acquire();
		var b = spare.pop();
		lock.release();
		return b != null && b.length == size ? b : Bytes.alloc(size);
	}

	/** Publishes a picture; an unsent one it replaces is recycled and counted as dropped. */
	public function put(b:Bytes, applied:Int):Void {
		lock.acquire();
		var old = pending;
		pending = b;
		input = applied;
		if (old != null) { spare.push(old); dropped++; }
		lock.release();
		if (old == null) ready.release();
	}

	public function give(b:Bytes):Void {
		lock.acquire();
		spare.push(b);
		lock.release();
	}

	/** Blocks until a picture is waiting. */
	public function take():{pixels:Bytes, input:Int} {
		ready.wait();
		lock.acquire();
		var r = {pixels: pending, input: input};
		pending = null;
		lock.release();
		return r;
	}
}

/**
 * A real Heaps app as a surface producer: it draws an h2d scene into an offscreen texture each frame, reads the pixels back, sends the
 * rectangle that differs from the last frame, and applies the pointer presses it is sent. Arguments: width height frames.
 * Rendering never waits for the pipe: the render thread reads the picture back into a pooled buffer and publishes it to a latest-wins slot, and
 * a sender thread diffs it against the last picture it sent, writes the changed rectangle and recycles the buffer. Set SURFACE_STATS=1 for
 * per-stage timings on stderr.
 * Heaps writes traces to stdout, so they are sent to stderr before anything else runs.
 */
class HeapsProducer extends hxd.App {
	static var width = 640;
	static var height = 360;
	static var frames = 0;
	static var pending:Array<SurfaceInput> = [];
	static final lock = new Mutex();

	var target:h3d.mat.Texture;
	final slot = new Slot();
	final stats = Sys.getEnv("SURFACE_STATS") == "1";
	var captureMs = 0.;
	var renderMs = 0.;
	var sentFrames = 0;
	var diffMs = 0.;
	var writeMs = 0.;
	var ball:h2d.Graphics;
	var markers:h2d.Object;
	var surface:h2d.Interactive;
	var applied = 0;
	var rendered = 0;
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
		Thread.create(() -> try send() catch (e:Dynamic) {
			Sys.stderr().writeString('sender failed: $e\n${haxe.CallStack.toString(haxe.CallStack.exceptionStack())}\n');
			Sys.exit(1);
		});
	}

	override function update(dt:Float) {
		try frame(dt) catch (e:Dynamic) {
			Sys.stderr().writeString('producer failed: $e\n${haxe.CallStack.toString(haxe.CallStack.exceptionStack())}\n');
			Sys.exit(1);
		}
	}

	function frame(dt:Float):Void {
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

		var t0 = haxe.Timer.stamp();
		target.clear(0x20242C, 1);
		s2d.drawTo(target);
		var t1 = haxe.Timer.stamp();
		var pixels = new hxd.Pixels(width, height, slot.buffer(width * height * 4), RGBA);
		// Reads into a pooled buffer, as Texture.capturePixels does but without allocating a picture each frame.
		engine.driver.setRenderTarget(target);
		engine.driver.captureRenderBuffer(pixels);
		engine.driver.setRenderTarget(null);
		var t2 = haxe.Timer.stamp();
		renderMs += t1 - t0;
		captureMs += t2 - t1;
		slot.put(pixels.bytes, applied);
		if (++rendered >= frames) slot.put(null, -1);
	}

	/** Runs on the sender thread: diffs each picture against the last one sent and writes what changed. */
	function send():Void {
		var out = Sys.stdout(), previous:Null<Bytes> = null, seq = 0;
		while (true) {
			var next = slot.take();
			if (next.pixels == null) {
				SurfaceProtocol.writeTo(out, SurfaceProtocol.record(SurfaceProtocol.EXIT, Bytes.alloc(0)));
				Sys.exit(0);
			}
			var t0 = haxe.Timer.stamp(), now = next.pixels, rect = changed(now, previous);
			var t1 = haxe.Timer.stamp();
			if (rect != null) {
				var data = Bytes.alloc(rect.w * rect.h * 4);
				for (r in 0...rect.h) data.blit(r * rect.w * 4, now, ((rect.y + r) * width + rect.x) * 4, rect.w * 4);
				SurfaceProtocol.writeTo(out, SurfaceProtocol.frame({seq: ++seq, input: next.input, x: rect.x, y: rect.y, width: rect.w, height: rect.h, encoding: 0, data: data}));
				if (previous != null) slot.give(previous);
				previous = now;
			} else slot.give(now);
			var t2 = haxe.Timer.stamp();
			diffMs += t1 - t0;
			writeMs += t2 - t1;
			if (stats && ++sentFrames % 60 == 0)
				Sys.stderr().writeString('stats: per frame ms render ${fmt(renderMs / rendered)} capture ${fmt(captureMs / rendered)} diff ${fmt(diffMs / sentFrames)} write ${fmt(writeMs / sentFrames)}; rendered $rendered sent $sentFrames dropped ${slot.dropped}\n');
		}
	}

	static function fmt(seconds:Float):String
		return Std.string(Math.round(seconds * 10000) / 10);

	/** The rectangle that differs from the last frame sent, the whole picture for the first, or null when nothing changed. */
	static function changed(now:Bytes, previous:Null<Bytes>):Null<{x:Int, y:Int, w:Int, h:Int}> {
		if (previous == null) return {x: 0, y: 0, w: width, h: height};
		var x0 = width, y0 = height, x1 = 0, y1 = 0, row = width * 4;
		var a:hl.Bytes = @:privateAccess now.b, b:hl.Bytes = @:privateAccess previous.b;
		for (y in 0...height) {
			if (a.compare(y * row, b, y * row, row) == 0) continue;
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
