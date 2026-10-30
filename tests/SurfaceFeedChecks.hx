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
	static function pump(name:String, producer:String, arguments:Array<String>, flags:Array<String>, ?launcher:rayde.workspace.Launcher):Void {
		var ash = Sys.getEnv("ASH") ?? "ash";
		if (!sys.FileSystem.exists(producer)) {
			Sys.println('Surface pump ($name): skipped, $producer is not built');
			return;
		}
		var pump = new rayde.preview.SurfacePump((launcher ?? new rayde.workspace.LocalLauncher()).start(ash, flags.concat([producer]).concat(arguments)));
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
		Sys.println('Surface pump ($name): ${pump.feed.frames} frames, input applied: ${pump.feed.appliedInput >= 1}');
	}

	/** The same pump over a real rayde-session, the process that runs beside a hosted workspace: the app's stdio crosses the session's relay. */
	static function session():Void {
		var binary = sys.FileSystem.fullPath("native/session/target/debug/rayde-session"), synthetic = sys.FileSystem.fullPath("bin/surface-producer.hl");
		if (!sys.FileSystem.exists(binary) || !sys.FileSystem.exists(synthetic)) {
			Sys.println("Surface pump (session): skipped, native/session or the producer is not built");
			return;
		}
		var root = sys.FileSystem.fullPath("bin") + "/surface-session-" + Std.random(0x3fffffff), port = 20000 + Std.random(20000);
		sys.FileSystem.createDirectory(root);
		sys.io.File.copy(synthetic, root + "/producer.hl");
		var server = new sys.io.Process(binary, ["--root", root, "--port", Std.string(port), "--token", "t", "--exec"]), client:Null<rayde.workspace.session.SessionClient> = null;
		try {
			for (_ in 0...100) try { client = rayde.workspace.session.SessionClient.connect("127.0.0.1", port, "t"); break; } catch (_:Dynamic) Sys.sleep(.05);
			check(client != null, "The session did not start");
			var launcher = new rayde.workspace.session.SessionLauncher(client);
			pump("synthetic through a session", root + "/producer.hl", ["320", "180", "40", "ui", "0", "60"], ["--preset", "application"], launcher);
			var heaps = Sys.getEnv("RAYDE_HEAPS_DIR");
			if (heaps != null) {
				for (file in sys.FileSystem.readDirectory(heaps)) if (!sys.FileSystem.isDirectory(heaps + "/" + file)) sys.io.File.copy(heaps + "/" + file, root + "/" + file);
				var here = Sys.getCwd();
				Sys.setCwd(root);
				try pump("heaps through a session", root + "/heaps-producer.hl", ["640", "360", "90"], ["--mode", "hybrid"], launcher) catch (e:Dynamic) { Sys.setCwd(here); throw e; }
				Sys.setCwd(here);
			}
		} catch (e:Dynamic) {
			if (client != null) client.close();
			server.kill();
			server.close();
			throw e;
		}
		client.close();
		server.kill();
		server.close();
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
		pump("synthetic", sys.FileSystem.fullPath("bin/surface-producer.hl"), ["320", "180", "40", "ui", "0", "60"], ["--preset", "application"]);
		// A real Heaps app, when RAYDE_HEAPS_DIR holds its .hl beside the SDL libraries it loads (they are found from the working directory).
		var heaps = Sys.getEnv("RAYDE_HEAPS_DIR");
		if (heaps != null) {
			var here = Sys.getCwd();
			Sys.setCwd(heaps);
			try pump("heaps", heaps + "/heaps-producer.hl", ["640", "360", "90"], ["--mode", "hybrid"]) catch (e:Dynamic) { Sys.setCwd(here); throw e; }
			Sys.setCwd(here);
		}
		session();
		Sys.println("Surface feed: frames land where they say, a late viewer sees the newest picture, bad frames are refused, pointer mapping follows Contain");
	}
}
