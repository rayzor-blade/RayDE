package rayde.preview;

import haxe.io.Bytes;
import rayde.preview.SurfaceProtocol.SurfaceInput;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

/** What the render side hands the sender: the newest picture and the last input applied before it. */
private typedef Picture = {pixels:Null<Bytes>, input:Int};

/**
 * The producer's end of the surface protocol, for any framework's shim. The render side calls `submit` with each picture and `takeInputs`
 * for what the viewer sent; neither waits. A sender thread keeps only the newest picture, diffs it against the last one it sent, writes the
 * changed rectangle and recycles the buffer, so a slow reader costs frames and never stalls rendering.
 * Everything an app prints to stdout would corrupt the stream, so `redirectTrace` sends `trace` to stderr; call it first.
 */
class SurfaceLink {
	public final width:Int;
	public final height:Int;
	/** Deflate a frame's rectangle when that makes it smaller. */
	public var deflate = false;
	/** Frames replaced before they were sent. */
	public var dropped(default, null) = 0;

	/** True once the viewer is gone (its pipe closed): the app should end, since nobody can see or stop it. */
	public var viewerGone(default, null) = false;

	final lock = new Mutex();
	final ready = new Lock();
	final spare:Array<Bytes> = [];
	final inputLock = new Mutex();
	final creditWait = new Lock();
	var credits = 0;
	var spent = 0;
	var creditsSeen = false;
	var queued:Array<SurfaceInput> = [];
	var pending:Null<Picture>;
	var closing = false;
	var applied = 0;
	var started = false;
	final stats:Bool;
	var diffTime = 0.;
	var writeTime = 0.;
	var sent = 0;

	public function new(width:Int, height:Int) {
		this.width = width;
		this.height = height;
		stats = Sys.getEnv("SURFACE_STATS") == "1";
	}

	/** Sends `trace` output to stderr, where it cannot be taken for protocol. */
	public static function redirectTrace():Void
		haxe.Log.trace = (v, ?pos) -> Sys.stderr().writeString(Std.string(v) + "\n");

	/** Announces the size and starts the reader and sender threads. */
	public function start():Void {
		if (started) return;
		started = true;
		SurfaceProtocol.writeTo(Sys.stdout(), SurfaceProtocol.hello(width, height));
		Thread.create(readInputs);
		Thread.create(() -> try send() catch (e:Dynamic) {
			viewerGone = true;
			Sys.stderr().writeString('surface sender failed: $e\n');
			Sys.exit(1);
		});
	}

	/** A buffer for one picture, `width * height * 4` bytes of RGBA: a recycled one when there is one. */
	public function buffer():Bytes {
		lock.acquire();
		var b = spare.pop();
		lock.release();
		return b != null ? b : Bytes.alloc(width * height * 4);
	}

	/** Publishes a picture. Ownership passes to the link. One still unsent is replaced and recycled. */
	public function submit(pixels:Bytes):Void {
		lock.acquire();
		var old = pending;
		pending = {pixels: pixels, input: applied};
		if (old != null) {
			spare.push(old.pixels);
			dropped++;
		}
		lock.release();
		if (old == null) ready.release();
	}

	/** Sends what is pending, then the end of the stream, and stops. */
	public function finish():Void {
		lock.acquire();
		closing = true;
		var wake = pending == null;
		lock.release();
		if (wake) ready.release();
	}

	/** `finish`, then waits for the sender to write the end of the stream and exit the process. For a program with nothing else to do. */
	public function finishAndExit():Void {
		finish();
		while (true) Sys.sleep(1);
	}

	/** The inputs the viewer sent since the last call, oldest first. Frames submitted afterwards carry the last one's number. */
	public function takeInputs():Array<SurfaceInput> {
		inputLock.acquire();
		var inputs = queued;
		queued = [];
		inputLock.release();
		if (inputs.length > 0) applied = inputs[inputs.length - 1].id;
		return inputs;
	}

	/** Whether the viewer has sent a credit, which means it paces the frames: from then on `takeCredit` is how a frame starts. */
	public var viewerPaces(get, never):Bool;

	function get_viewerPaces():Bool {
		inputLock.acquire();
		var seen = creditsSeen;
		inputLock.release();
		return seen;
	}

	/** Waits up to `seconds` for permission to draw a frame and spends it; false when none came, so the caller can look at its own events and try again. */
	public function takeCredit(seconds:Float):Bool {
		if (!creditWait.wait(seconds)) return false;
		inputLock.acquire();
		credits--;
		spent++;
		inputLock.release();
		return true;
	}

	function readInputs():Void {
		var stdin = Sys.stdin();
		try while (true) {
			var record = SurfaceProtocol.read(stdin);
			if (record.kind == SurfaceProtocol.CREDIT) {
				inputLock.acquire();
				creditsSeen = true;
				// A viewer that is ahead does not bank frames: at most two wait.
				var grant = credits < 2;
				if (grant) credits++;
				inputLock.release();
				if (grant) creditWait.release();
				continue;
			}
			if (record.kind != SurfaceProtocol.INPUT) continue;
			var input = SurfaceProtocol.parseInput(record.payload);
			inputLock.acquire();
			queued.push(input);
			inputLock.release();
		} catch (_:Dynamic) {
			viewerGone = true;
		}
	}

	function send():Void {
		var out = Sys.stdout(), previous:Null<Bytes> = null, seq = 0;
		while (true) {
			ready.wait();
			lock.acquire();
			var next = pending, done = closing;
			pending = null;
			lock.release();
			inputLock.acquire();
			var acks = spent;
			spent = 0;
			inputLock.release();
			for (_ in 0...acks) SurfaceProtocol.writeTo(out, SurfaceProtocol.record(SurfaceProtocol.ACK, Bytes.alloc(0)));
			if (next == null) {
				if (done) {
					SurfaceProtocol.writeTo(out, SurfaceProtocol.record(SurfaceProtocol.EXIT, Bytes.alloc(0)));
					Sys.exit(0);
				}
				continue;
			}
			var t0 = haxe.Timer.stamp(), now = next.pixels, rect = changed(now, previous);
			var t1 = haxe.Timer.stamp();
			if (rect != null) {
				var data = rows(now, rect.x, rect.y, rect.w, rect.h), encoding = 0;
				if (deflate) {
					var packed:Bytes = try haxe.zip.Compress.run(data, 1) catch (_:Dynamic) null;
					if (packed != null && packed.length < data.length) {
						data = packed;
						encoding = 1;
					}
				}
				SurfaceProtocol.writeTo(out, SurfaceProtocol.frame({seq: ++seq, input: next.input, x: rect.x, y: rect.y, width: rect.w, height: rect.h, encoding: encoding, data: data}));
				recycle(previous);
				previous = now;
			} else recycle(now);
			var t2 = haxe.Timer.stamp();
			diffTime += t1 - t0;
			writeTime += t2 - t1;
			if (stats && ++sent % 60 == 0)
				Sys.stderr().writeString('stats: per sent frame ms diff ${fmt(diffTime / sent)} write ${fmt(writeTime / sent)}; sent $sent dropped $dropped\n');
			if (done) {
				lock.acquire();
				var more = pending != null;
				lock.release();
				if (!more) {
					SurfaceProtocol.writeTo(out, SurfaceProtocol.record(SurfaceProtocol.EXIT, Bytes.alloc(0)));
					Sys.exit(0);
				}
			}
		}
	}

	function recycle(b:Null<Bytes>):Void {
		if (b == null) return;
		lock.acquire();
		spare.push(b);
		lock.release();
	}

	static function fmt(seconds:Float):String
		return Std.string(Math.round(seconds * 10000) / 10);

	function rows(b:Bytes, x:Int, y:Int, w:Int, h:Int):Bytes {
		if (w == width) return b.sub(y * width * 4, h * width * 4);
		var out = Bytes.alloc(w * h * 4);
		for (r in 0...h) out.blit(r * w * 4, b, ((y + r) * width + x) * 4, w * 4);
		return out;
	}

	/** The rectangle that differs from the last picture sent, the whole picture for the first, or null when nothing changed. */
	function changed(now:Bytes, previous:Null<Bytes>):Null<{x:Int, y:Int, w:Int, h:Int}> {
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
}
