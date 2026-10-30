package rayde.preview;

import ashui.types.PixelSurface;
import rayde.workspace.Program;
import sys.thread.Mutex;
import sys.thread.Thread;

/**
 * Runs a headless app's surface protocol on background threads: records in, applied to a `SurfaceFeed`, and numbered input out.
 * The UI thread calls `poll` once a frame and `send` for each input; it never blocks on the app.
 */
class SurfacePump {
	public final feed = new SurfaceFeed();
	/** Why the stream ended, when it ended badly: a malformed record or a read failure. Null while running or after a clean exit. */
	public var failure(default, null):Null<String>;
	public var inputs(default, null) = 0;

	final program:Program;
	final lock = new Mutex();
	final wire = new Mutex();
	var stopped = false;
	var ended = false;
	var logged = 0;

	public function new(program:Program) {
		this.program = program;
		Thread.create(readRecords);
		Thread.create(readErrors);
	}

	/** Whether the app has announced its size. */
	public function ready():Bool {
		lock.acquire();
		var r = feed.width > 0;
		lock.release();
		return r;
	}

	public function size():{width:Int, height:Int} {
		lock.acquire();
		var s = {width: feed.width, height: feed.height};
		lock.release();
		return s;
	}

	/** The stream is over: the app exited, was stopped or sent something unreadable. */
	public function finished():Bool {
		lock.acquire();
		var r = ended || feed.exited;
		lock.release();
		return r;
	}

	/** Copies the newest picture into `surface`; returns whether it changed. Also returns false before the app has announced its size. */
	public function poll(surface:PixelSurface):Bool {
		lock.acquire();
		try {
			var wrote = feed.flush(surface);
			if (wrote) feed.clean();
			lock.release();
			return wrote;
		} catch (error:Dynamic) {
			lock.release();
			throw error;
		}
	}

	/** Makes the whole picture count as changed, for a new surface that has not been drawn yet. */
	public function invalidate():Void {
		lock.acquire();
		feed.invalidate();
		lock.release();
	}

	/** Lines the app wrote to its log or stderr since the last call. */
	public function takeLog():Array<String> {
		lock.acquire();
		var lines = feed.log.slice(logged);
		logged = feed.log.length;
		lock.release();
		return lines;
	}

	/** Sends an input numbered in order; the frame that shows it carries the number back as `feed.appliedInput`. */
	public function send(type:Int, a = 0, b = 0, c = 0):Int {
		wire.acquire();
		var id = ++inputs;
		try {
			if (!stopped) SurfaceProtocol.writeTo(program.stdin, SurfaceProtocol.input({id: id, type: type, a: a, b: b, c: c}));
		} catch (_:Dynamic) {
			stopped = true;
		}
		wire.release();
		return id;
	}

	/** Stops the app and releases its pipes. Safe to call again. */
	public function stop():Void {
		wire.acquire();
		var again = stopped;
		stopped = true;
		wire.release();
		lock.acquire();
		var done = ended;
		ended = true;
		lock.release();
		if (again && done) return;
		try program.kill() catch (_:Dynamic) {}
		try program.close() catch (_:Dynamic) {}
	}

	function readRecords():Void {
		try while (true) {
			var record = SurfaceProtocol.read(program.stdout);
			var prepared = SurfaceFeed.prepare(record.kind, record.payload);
			if (prepared == null) continue;
			lock.acquire();
			try feed.commit(prepared) catch (error:Dynamic) {
				failure = Std.string(error);
				lock.release();
				break;
			}
			var exit = feed.exited;
			lock.release();
			if (exit) break;
		} catch (_:haxe.io.Eof) {} catch (error:Dynamic) {
			lock.acquire();
			if (!ended) failure = Std.string(error);
			lock.release();
		}
		lock.acquire();
		ended = true;
		lock.release();
	}

	function readErrors():Void {
		try while (true) {
			var line = program.stderr.readLine();
			lock.acquire();
			feed.log.push(line);
			lock.release();
		} catch (_:Dynamic) {}
	}
}
