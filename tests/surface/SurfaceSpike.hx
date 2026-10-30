import haxe.io.Bytes;
import rayde.preview.SurfaceProtocol;
import rayde.workspace.Launcher;
import rayde.workspace.LocalLauncher;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.SessionLauncher;

/**
 * Measures the surface protocol: a synthetic producer sends frames of three kinds of content, raw and deflated, to a viewer through a local
 * process and through a session, at 30 frames a second. Prints bytes and the bit rate they imply, the viewer's decode cost, and how long an
 * input takes to show in a frame. Run with: ash --preset application bin/surface-spike.hl
 */
class SurfaceSpike {
	static inline var WIDTH = 1280;
	static inline var HEIGHT = 720;
	static inline var FRAMES = 90;
	static inline var FPS = 30;

	static function main() {
		var producer = sys.FileSystem.fullPath("bin/surface-producer.hl"), ash = Sys.getEnv("ASH_BIN") ?? "ash";
		Sys.println('surface protocol spike: ${WIDTH}x$HEIGHT RGBA, $FRAMES frames paced at $FPS fps, producer is a synthetic software scene');
		Sys.println(pad("transport", 10) + pad("scene", 7) + pad("encoding", 9) + pad("KB/frame", 10) + pad("Mbit/s", 9) + pad("fps", 7) + pad("decode ms", 11) + pad("input ms", 9));

		for (transport in ["local", "session"]) {
			var launcher:Launcher, client:Null<SessionClient> = null, server:Null<sys.io.Process> = null, path = producer;
			if (transport == "local") launcher = new LocalLauncher();
			else {
				var binary = sys.FileSystem.fullPath("native/session/target/debug/rayde-session");
				if (!sys.FileSystem.exists(binary)) { Sys.println("session: skipped, native/session is not built"); continue; }
				var root = sys.FileSystem.fullPath("bin") + "/surface-spike-" + Std.random(0x3fffffff), port = 20000 + Std.random(20000);
				sys.FileSystem.createDirectory(root);
				sys.io.File.copy(producer, root + "/producer.hl");
				path = root + "/producer.hl";
				server = new sys.io.Process(binary, ["--root", root, "--port", Std.string(port), "--token", "t", "--exec"]);
				for (_ in 0...100) try { client = SessionClient.connect("127.0.0.1", port, "t"); break; } catch (_:Dynamic) Sys.sleep(.05);
				launcher = new SessionLauncher(client);
			}
			for (scene in ["ui", "game", "noise"]) for (encoding in [0, 1]) measure(launcher, transport, ash, path, scene, encoding);
			if (client != null) client.close();
			if (server != null) { server.kill(); server.close(); }
		}
	}

	static function measure(launcher:Launcher, transport:String, ash:String, producer:String, scene:String, encoding:Int):Void {
		var program = launcher.start(ash, ["--preset", "application", producer, '$WIDTH', '$HEIGHT', '$FRAMES', scene, '$encoding', '$FPS']);
		var screen = Bytes.alloc(WIDTH * HEIGHT * 4), bytes = 0, frames = 0, decode = 0., started = -1., sentAt = -1., latency = -1.;
		try while (true) {
			var record = SurfaceProtocol.read(program.stdout);
			var now = haxe.Timer.stamp();
			if (started < 0) started = now;
			bytes += record.payload.length + 5;
			if (record.kind == SurfaceProtocol.EXIT) break;
			if (record.kind != SurfaceProtocol.FRAME) continue;
			var frame = SurfaceProtocol.parseFrame(record.payload);
			frames++;
			var t = haxe.Timer.stamp();
			var rect = SurfaceProtocol.pixels(frame);
			for (r in 0...frame.height) screen.blit(((frame.y + r) * WIDTH + frame.x) * 4, rect, r * frame.width * 4, frame.width * 4);
			decode += haxe.Timer.stamp() - t;
			if (frames == Std.int(FRAMES / 2) && sentAt < 0) {
				sentAt = haxe.Timer.stamp();
				program.stdin.write(SurfaceProtocol.input({id: 1, type: SurfaceProtocol.POINTER_DOWN, a: 400, b: 300, c: 0}));
				program.stdin.flush();
			}
			if (frame.input >= 1 && sentAt > 0 && latency < 0) latency = haxe.Timer.stamp() - sentAt;
		} catch (_:haxe.io.Eof) {}
		var seconds = Math.max(.001, haxe.Timer.stamp() - started);
		program.close();
		var perFrame = frames == 0 ? 0 : bytes / frames;
		Sys.println(pad(transport, 10) + pad(scene, 7) + pad(encoding == 1 ? "deflate" : "raw", 9) + pad(fixed(perFrame / 1024, 1), 10) + pad(fixed(perFrame * FPS * 8 / 1e6, 1), 9)
			+ pad(fixed(frames / seconds, 1), 7) + pad(fixed(frames == 0 ? 0 : decode * 1000 / frames, 2), 11) + pad(latency < 0 ? "-" : fixed(latency * 1000, 0), 9));
	}

	static function fixed(v:Float, digits:Int):String {
		var p = Math.pow(10, digits), s = Std.string(Math.round(v * p) / p);
		if (digits > 0 && s.indexOf(".") < 0) s += ".0";
		return s;
	}

	static function pad(s:String, n:Int):String {
		while (s.length < n) s += " ";
		return s;
	}
}
