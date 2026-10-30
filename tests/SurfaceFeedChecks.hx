import ashui.types.PixelSurface;
import haxe.io.Bytes;
import rayde.preview.SurfaceFeed;
import rayde.preview.SurfaceProtocol;
import rayde.ui.SurfaceView;

class SurfaceFeedChecks {
	static function check(ok:Bool, message:String):Void if (!ok) throw message;

	static function rect(seq:Int, x:Int, y:Int, w:Int, h:Int, fill:Int, encoding = 0):Bytes {
		var raw = Bytes.alloc(w * h * 4);
		for (i in 0...w * h) raw.set(i * 4, fill);
		var data = encoding == 1 ? haxe.zip.Compress.run(raw, 1) : raw;
		return SurfaceProtocol.frame({seq: seq, input: seq * 10, x: x, y: y, width: w, height: h, encoding: encoding, data: data});
	}

	static function feed(f:SurfaceFeed, record:Bytes):Void {
		var kind = record.get(4), payload = record.sub(5, record.length - 5);
		check(f.apply(kind, payload), "A known record was refused");
	}

	/** Runs the synthetic producer when it has been built, as a real app would run, and drives it through the pump. */
	static function pump():Void {
		var producer = sys.FileSystem.fullPath("bin/surface-producer.hl"), ash = Sys.getEnv("ASH") ?? "ash";
		if (!sys.FileSystem.exists(producer)) {
			Sys.println("Surface pump: skipped, bin/surface-producer.hl is not built");
			return;
		}
		var pump = new rayde.preview.SurfacePump(new rayde.workspace.LocalLauncher().start(ash, ["--preset", "application", producer, "320", "180", "40", "ui", "0", "60"]));
		var waited = 0;
		while (!pump.ready() && waited++ < 400) Sys.sleep(.025);
		check(pump.ready(), "The app never announced its size");
		var size = pump.size(), surface = new PixelSurface(size.width, size.height), drawn = false;
		pump.send(SurfaceProtocol.POINTER_DOWN, 100, 100, 0);
		waited = 0;
		while (!pump.finished() && waited++ < 400) {
			if (pump.poll(surface)) drawn = true;
			Sys.sleep(.025);
		}
		if (pump.poll(surface)) drawn = true;
		check(drawn, "No frame reached the surface");
		check(pump.failure == null, "The stream failed: " + pump.failure);
		check(pump.feed.appliedInput >= 1, "The app never applied the input");
		pump.stop();
		pump.stop();
	}

	static function main():Void {
		var f = new SurfaceFeed(), surface = new PixelSurface(8, 6);
		feed(f, SurfaceProtocol.hello(8, 6));
		check(!f.dirty() && !f.flush(surface), "Nothing was drawn yet but the feed was dirty");

		feed(f, rect(1, 1, 1, 2, 2, 200));
		feed(f, rect(2, 5, 3, 2, 2, 90, 1));
		check(f.dirty() && f.seq == 2 && f.appliedInput == 20, "The newest frame was not tracked");
		check(f.flush(surface), "A dirty feed wrote nothing");
		f.clean();
		check(surface.pixels.get((1 * 8 + 1) * 4) == 200 && surface.pixels.get((4 * 8 + 6) * 4) == 90, "A rectangle landed in the wrong place");
		check(surface.pixels.get(0) == 0 && surface.pixels.get((5 * 8 + 0) * 4) == 0, "Pixels outside every rectangle changed");
		check(!f.flush(surface), "A clean feed wrote again");

		// A viewer that fell behind sees the latest picture where two frames overlapped.
		feed(f, rect(3, 0, 0, 4, 4, 10));
		feed(f, rect(4, 2, 2, 4, 4, 20));
		f.flush(surface);
		f.clean();
		check(surface.pixels.get(0) == 10 && surface.pixels.get((3 * 8 + 3) * 4) == 20 && surface.pixels.get((5 * 8 + 5) * 4) == 20, "Overlapping frames did not keep the newer one");

		var threw = false;
		try feed(f, rect(5, 6, 4, 4, 4, 1)) catch (_:Dynamic) threw = true;
		check(threw, "A frame outside the surface was accepted");
		check(!f.apply(99, Bytes.alloc(0)), "An unknown record was accepted");
		f.apply(SurfaceProtocol.LOG, Bytes.ofString("hello"));
		f.apply(SurfaceProtocol.EXIT, Bytes.alloc(0));
		check(f.log[0] == "hello" && f.exited, "Log and exit were not recorded");

		var m = SurfaceView.map(0, 0, 200, 100, 100, 100);
		check(m.x == 0 && m.y == 0, "A point left of the picture was not clamped");
		m = SurfaceView.map(100, 50, 200, 100, 100, 100);
		check(m.x == 50 && m.y == 50, "Letterboxed centre maps to the picture centre");
		pump();
		Sys.println("Surface feed: frames land where they say, a late viewer sees the newest picture, bad frames are refused, pointer mapping follows Contain");
	}
}
