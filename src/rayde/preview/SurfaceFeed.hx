package rayde.preview;

import ashui.types.PixelSurface;
import haxe.io.Bytes;

/**
 * Turns a producer's records into the picture to show. Frames are blitted into one shadow image and the changed rectangle is the union of
 * what arrived since the last `flush`, so a viewer that falls behind draws the latest picture once instead of every frame.
 */
class SurfaceFeed {
	public var width(default, null) = 0;
	public var height(default, null) = 0;
	/** The newest frame's number and the last input the app had applied by then. */
	public var seq(default, null) = -1;
	public var appliedInput(default, null) = 0;
	public var exited(default, null) = false;
	public var frames(default, null) = 0;
	public final log:Array<String> = [];

	var shadow:Null<Bytes>;
	var x0 = 0;
	var y0 = 0;
	var x1 = 0;
	var y1 = 0;

	public function new() {}

	public function dirty():Bool
		return x1 > x0 && y1 > y0;

	/** Applies one record from the producer. Returns false for a kind it does not know. */
	public function apply(kind:Int, payload:Bytes):Bool {
		switch kind {
			case SurfaceProtocol.HELLO:
				var size = SurfaceProtocol.parseHello(payload);
				if (size.width < 1 || size.height < 1) throw "The app announced an empty surface.";
				width = size.width;
				height = size.height;
				shadow = Bytes.alloc(width * height * 4);
				x0 = y0 = x1 = y1 = 0;
			case SurfaceProtocol.FRAME:
				if (shadow == null) throw "A frame arrived before the app announced its size.";
				var frame = SurfaceProtocol.parseFrame(payload);
				if (frame.x + frame.width > width || frame.y + frame.height > height) throw "A frame lies outside the surface.";
				var pixels = SurfaceProtocol.pixels(frame), row = frame.width * 4;
				if (pixels.length < row * frame.height) throw "A frame is shorter than its rectangle.";
				for (r in 0...frame.height) shadow.blit(((frame.y + r) * width + frame.x) * 4, pixels, r * row, row);
				cover(frame.x, frame.y, frame.x + frame.width, frame.y + frame.height);
				seq = frame.seq;
				appliedInput = frame.input;
				frames++;
			case SurfaceProtocol.LOG:
				log.push(payload.toString());
			case SurfaceProtocol.EXIT:
				exited = true;
			case _:
				return false;
		}
		return true;
	}

	/** Writes the changed rectangle into `surface`, which must be the size the app announced. Returns whether anything was written. */
	public function flush(surface:PixelSurface):Bool {
		if (!dirty() || shadow == null) return false;
		if (surface.width != width || surface.height != height) throw "The surface is not the size the app announced.";
		var row = (x1 - x0) * 4;
		for (r in y0...y1) surface.pixels.blit((r * width + x0) * 4, shadow, (r * width + x0) * 4, row);
		surface.touch(x0, y0, x1, y1);
		return true;
	}

	/** Forgets the changed rectangle after `flush`. */
	public function clean():Void
		x0 = y0 = x1 = y1 = 0;

	/** A whole-surface rectangle changed: after a new surface is made for a viewer. */
	public function invalidate():Void
		if (shadow != null) {
			x0 = y0 = 0;
			x1 = width;
			y1 = height;
		}

	function cover(ax:Int, ay:Int, bx:Int, by:Int):Void {
		if (!dirty()) {
			x0 = ax; y0 = ay; x1 = bx; y1 = by;
			return;
		}
		if (ax < x0) x0 = ax;
		if (ay < y0) y0 = ay;
		if (bx > x1) x1 = bx;
		if (by > y1) y1 = by;
	}
}
