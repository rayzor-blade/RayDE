package rayde.workspace.session;

import haxe.crypto.Base64;
import haxe.io.Bytes;
import haxe.io.Eof;

/** Programs that run in the session, beside the workspace's files. */
class SessionLauncher implements Launcher {
	final client:SessionClient;
	final running = new Map<Int, SessionProgram>();

	public function new(client:SessionClient) {
		this.client = client;
		client.onEvent = event -> {
			var program = event.pid == null ? null : running.get(event.pid);
			if (program != null) program.receive(event);
		};
	}

	public function start(command:String, args:Array<String>):Program {
		if (!client.exec) throw "This session does not run programs.";
		var pid:Int = client.request("proc.spawn", {command: command, args: args}).pid;
		var program = new SessionProgram(client, pid);
		running.set(pid, program);
		return program;
	}
}

private class SessionProgram implements Program {
	public var stdout(default, null):haxe.io.Input;
	public var stderr(default, null):haxe.io.Input;
	public var stdin(default, null):haxe.io.Output;
	final client:SessionClient;
	final pid:Int;
	final out = new Pipe();
	final err = new Pipe();
	var code:Null<Int>;

	public function new(client:SessionClient, pid:Int) {
		this.client = client;
		this.pid = pid;
		stdout = new PipeInput(out, wait);
		stderr = new PipeInput(err, wait);
		stdin = new SessionInput(client, pid);
	}

	public function receive(event:Dynamic):Void {
		switch (event.ev : String) {
			case "proc.out": (event.stream == "stderr" ? err : out).add(Base64.decode(event.data));
			case "proc.exit":
				// A program killed by a signal has no code; it ends unsuccessfully.
				code = event.code != null ? event.code : 128 + (event.signal != null ? event.signal : 1);
				out.end();
				err.end();
			default:
		}
	}

	/** Reads from the session until something arrives for this program. */
	function wait():Void client.pump(.5);

	public function exitCode(block:Bool = true):Null<Int> {
		if (block) while (code == null) client.pump(.5);
		else client.drain();
		return code;
	}

	public function kill():Void {
		if (code == null) try client.request("proc.kill", {pid: pid, signal: "KILL"}) catch (_:Dynamic) {}
	}

	public function close():Void {}
}

private class Pipe {
	public final chunks:Array<Bytes> = [];
	public var position = 0;
	public var ended = false;

	public function new() {}

	public function add(bytes:Bytes):Void chunks.push(bytes);
	public function end():Void ended = true;
}

private class PipeInput extends haxe.io.Input {
	final pipe:Pipe;
	final wait:Void->Void;

	public function new(pipe:Pipe, wait:Void->Void) {
		this.pipe = pipe;
		this.wait = wait;
	}

	override public function readBytes(into:Bytes, pos:Int, len:Int):Int {
		while (pipe.chunks.length == 0) {
			if (pipe.ended) throw new Eof();
			wait();
		}
		var chunk = pipe.chunks[0], count = Std.int(Math.min(len, chunk.length - pipe.position));
		into.blit(pos, chunk, pipe.position, count);
		pipe.position += count;
		if (pipe.position >= chunk.length) {
			pipe.chunks.shift();
			pipe.position = 0;
		}
		return count;
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

	public function new(client:SessionClient, pid:Int) {
		this.client = client;
		this.pid = pid;
	}

	override public function writeBytes(from:Bytes, pos:Int, len:Int):Int {
		client.request("proc.write", {pid: pid, data: Base64.encode(from.sub(pos, len))});
		return len;
	}

	override public function writeByte(c:Int):Void {
		var one = Bytes.alloc(1);
		one.set(0, c);
		writeBytes(one, 0, 1);
	}

	override public function close():Void client.request("proc.close-input", {pid: pid});
}
