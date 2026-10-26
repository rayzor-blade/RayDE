package rayde.workspace.session;

import haxe.crypto.Base64;
import haxe.io.Bytes;
import haxe.io.Eof;

/** Programs that run in the session, beside the workspace's files. */
class SessionLauncher implements Launcher {
	public final client:SessionClient;
	final running = new Map<Int, SessionProgram>();
	final early = new Map<Int, Array<Dynamic>>();
	final mutex = new sys.thread.Mutex();
	var starting = 0;
	var earlyBytes = 0;
	var earlyOverflow = false;

	public function new(client:SessionClient) {
		this.client = client;
		client.subscribePrograms(event -> {
			mutex.acquire();
			if (event.ev == "session.disconnected") {
				for (program in running) program.receive({ev:"proc.exit",code:255});
				running.clear();
				early.clear(); earlyBytes = 0; earlyOverflow = false;
			} else {
				var program = event.pid == null ? null : running.get(event.pid);
				if (program != null) program.receive(event);
				else if (starting > 0 && event.pid != null && (event.ev == "proc.out" || event.ev == "proc.exit")) {
					var size = event.data == null ? 0 : (event.data:String).length;
					if (earlyBytes + size > 32 * 1024 * 1024) earlyOverflow = true;
					else {
						if (!early.exists(event.pid)) early.set(event.pid, []);
						early.get(event.pid).push(event); earlyBytes += size;
					}
				}
			}
			mutex.release();
		});
	}

	public function start(command:String, args:Array<String>):Program {
		return startAsync(command, args).await();
	}

	public function startAsync(command:String, args:Array<String>):ash.Future<SessionProgram> {
		return startConfigured(command,args);
	}

	/** Program paths and environment belong to the session host, never the browser machine. */
	public function startConfigured(command:String, args:Array<String>, ?cwd:String, ?env:Dynamic):ash.Future<SessionProgram> {
		var future = new ash.Future<SessionProgram>();
		if (!client.exec) { future.reject("This session does not run programs."); return future; }
		var directory = "";
		if (cwd != null && cwd != "") {
			var root = haxe.io.Path.normalize(client.root), path = haxe.io.Path.normalize(cwd);
			if (!rayde.files.FileOps.inside(root,path)) { future.reject("The program directory is outside this workspace session."); return future; }
			directory = path == root ? "" : rayde.files.FileOps.relative(root,path);
		}
		mutex.acquire(); starting++; mutex.release();
		var generation = client.connectionEpoch();
		client.requestAsync("proc.spawn", {command:command, args:args, cwd:directory, env:env, sessionGeneration:generation}).then(reply -> {
			var pid:Int = reply.pid;
			var program:SessionProgram = null;
			program = new SessionProgram(client, pid, () -> { mutex.acquire(); if (running.get(pid) == program) running.remove(pid); mutex.release(); },generation);
			mutex.acquire();
			if (generation != client.connectionEpoch() || !client.isOnline()) {
				finishStart(); mutex.release(); program.close(); future.reject("The session changed while starting the program."); return;
			}
			running.set(pid, program);
			if (client.isClosed()) program.receive({ev:"proc.exit",code:255});
			var waiting = early.get(pid); early.remove(pid);
			if (waiting != null) for (event in waiting) {
				if (event.data != null) earlyBytes -= (event.data:String).length;
				program.receive(event);
			}
			var overflow = earlyOverflow;
			finishStart(); mutex.release();
			if (overflow) { program.killAsync(); program.close(); future.reject("The program's initial output exceeded the session buffer."); }
			else future.resolve(program);
		}, error -> {
			mutex.acquire(); finishStart(); mutex.release(); future.reject(error);
		});
		return future;
	}

	function finishStart():Void {
		if (--starting == 0) { early.clear(); earlyBytes = 0; earlyOverflow = false; }
	}
}

class SessionProgram implements Program {
	public var stdout(default, null):haxe.io.Input;
	public var stderr(default, null):haxe.io.Input;
	public var stdin(default, null):haxe.io.Output;
	final client:SessionClient;
	final pid:Int;
	final out = new Pipe();
	final err = new Pipe();
	var code:Null<Int>;
	var closed = false;
	final mutex = new sys.thread.Mutex();
	var changed = new ash.Future<Bool>();
	final release:Void->Void;
	final generation:Int;

	public function new(client:SessionClient, pid:Int, release:Void->Void, generation:Int) {
		this.client = client;
		this.pid = pid;
		this.release = release;
		this.generation = generation;
		stdout = new PipeInput(out, () -> wait(out), mutex);
		stderr = new PipeInput(err, () -> wait(err), mutex);
		stdin = new SessionInput(client, pid,generation);
	}

	public function receive(event:Dynamic):Void {
		mutex.acquire();
		if (closed) { mutex.release(); return; }
		var overflow = false;
		switch (event.ev : String) {
			case "proc.out": overflow = !(event.stream == "stderr" ? err : out).add(Base64.decode(event.data));
			case "proc.exit":
				code = event.code != null ? event.code : 128 + (event.signal != null ? event.signal : 1);
				out.end(); err.end();
			default:
		}
		if (overflow) {
			code = 255; out.end(); err.end();
		}
		var ready = changed; changed = new ash.Future<Bool>(); mutex.release(); ready.resolve(true);
		if (overflow) killAsync();
	}

	function wait(?pipe:Pipe):Void {
		mutex.acquire();
		if (code != null || pipe != null && pipe.chunks.length > 0) { mutex.release(); return; }
		var ready = changed; mutex.release(); ready.await();
	}

	public function exitCode(block:Bool = true):Null<Int> {
		while (true) {
			mutex.acquire(); var value = code; mutex.release();
			if (value != null || !block) return value;
			wait();
		}
	}

	public function killAsync():ash.Future<Dynamic>
		return client.requestAsync("proc.kill", {pid:pid, signal:"KILL", sessionGeneration:generation});

	public function kill():Void { try killAsync().await() catch (_:Dynamic) {} }

	public function writeAsync(text:String):ash.Future<Dynamic>
		return client.requestAsync("proc.write", {pid:pid, data:Base64.encode(Bytes.ofString(text)), sessionGeneration:generation});

	public function close():Void {
		mutex.acquire();
		if (closed) { mutex.release(); return; }
		closed = true; code = code ?? 255; out.clear(); err.clear(); out.end(); err.end();
		var ready = changed; mutex.release(); ready.resolve(true); release();
	}
	public function hasOutput():Bool {
		mutex.acquire(); var found = out.chunks.length > 0 || err.chunks.length > 0; mutex.release(); return found;
	}
	public function takeOutput(error = false):Bytes {
		mutex.acquire();
		var pipe = error ? err : out, bytes = new haxe.io.BytesBuffer();
		for (i => chunk in pipe.chunks) bytes.addBytes(chunk, i == 0 ? pipe.position : 0, chunk.length - (i == 0 ? pipe.position : 0));
		pipe.clear(); mutex.release();
		return bytes.getBytes();
	}
}

private class Pipe {
	public final chunks:Array<Bytes> = [];
	public var position = 0;
	public var ended = false;
	var size = 0;

	public function new() {}

	public function add(bytes:Bytes):Bool {
		if (size + bytes.length > 32 * 1024 * 1024) return false;
		chunks.push(bytes); size += bytes.length; return true;
	}
	public function consumed(length:Int):Void size -= length;
	public function clear():Void { chunks.resize(0); position = 0; size = 0; }
	public function end():Void ended = true;
}

private class PipeInput extends haxe.io.Input {
	final pipe:Pipe;
	final wait:Void->Void;
	final mutex:sys.thread.Mutex;

	public function new(pipe:Pipe, wait:Void->Void, mutex:sys.thread.Mutex) {
		this.pipe = pipe;
		this.wait = wait;
		this.mutex = mutex;
	}

	override public function readBytes(into:Bytes, pos:Int, len:Int):Int {
		if (len == 0) return 0;
		while (true) {
			mutex.acquire();
			if (pipe.chunks.length > 0) break;
			var ended = pipe.ended; mutex.release();
			if (ended) throw new Eof();
			wait();
		}
		var chunk = pipe.chunks[0], count = Std.int(Math.min(len, chunk.length - pipe.position));
		into.blit(pos, chunk, pipe.position, count);
		pipe.position += count; pipe.consumed(count);
		if (pipe.position >= chunk.length) {
			pipe.chunks.shift();
			pipe.position = 0;
		}
		mutex.release(); return count;
	}

	override public function readByte():Int {
		var one = Bytes.alloc(1);
		readBytes(one, 0, 1);
		return one.get(0);
	}
}

private class SessionInput extends haxe.io.Output {
	final client:SessionClient;
	final pid:Int;
	final generation:Int;

	public function new(client:SessionClient, pid:Int, generation:Int) {
		this.client = client;
		this.pid = pid;
		this.generation = generation;
	}

	override public function writeBytes(from:Bytes, pos:Int, len:Int):Int {
		client.request("proc.write", {pid: pid, data: Base64.encode(from.sub(pos, len)), sessionGeneration:generation});
		return len;
	}

	override public function writeByte(c:Int):Void {
		var one = Bytes.alloc(1);
		one.set(0, c);
		writeBytes(one, 0, 1);
	}

	override public function close():Void client.request("proc.close-input", {pid: pid, sessionGeneration:generation});
}
