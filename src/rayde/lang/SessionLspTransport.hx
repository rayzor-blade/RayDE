package rayde.lang;

import haxe.io.Bytes;
import rayde.workspace.session.SessionLauncher;
import rayde.workspace.session.SessionLauncher.SessionProgram;

/** Remote stdio uses the same session as files. Workers own framing and pipe I/O; polling transfers completed events only. */
class SessionLspTransport {
	final mailbox:LspMailbox;
	final launcher:SessionLauncher;

	public function new(launcher:SessionLauncher, config:Dynamic) {
		if (config == null || !Std.isOfType(config.command,String) || config.command == "") throw "Language server command is missing.";
		this.launcher = launcher;
		var client = launcher.client;
		mailbox = new LspMailbox(() -> { if (client.onWake != null) client.onWake(); });
		var box = mailbox;
		sys.thread.Thread.create(() -> start(launcher,config,box));
	}
	public function send(message:Dynamic):Bool {
		try return mailbox.send(LspFrames.frame(message)) catch (_:Dynamic) return false;
	}
	public function poll():Null<Array<Dynamic>> return mailbox.take();
	public function pending():Bool return mailbox.pending();
	public function canWake():Bool return launcher.client.onWake != null;
	public function connected():Bool return launcher.client.isOnline();
	public function close():Void mailbox.close();

	static function start(launcher:SessionLauncher, config:Dynamic, box:LspMailbox):Void {
		try {
			var args:Array<String> = config.args == null ? [] : cast config.args;
			var program = launcher.startConfigured(config.command,args,config.cwd,config.env).await();
			if (!box.attach(program)) { program.killAsync(); program.close(); return; }
			box.push({t:"connected"},32);
			sys.thread.Thread.create(() -> write(program,box));
			sys.thread.Thread.create(() -> stderr(program,box));
			stdout(program,box);
		} catch (error:Dynamic) box.fail(Std.string(error));
	}
	static function write(program:SessionProgram, box:LspMailbox):Void {
		try while (true) {
			var bytes = box.next(); if (bytes == null) return;
			var at = 0;
			while (at < bytes.length) at += program.stdin.writeBytes(bytes,at,Std.int(Math.min(256*1024,bytes.length-at)));
			box.written(bytes.length);
		} catch (error:Dynamic) box.fail('Language server input failed: $error');
	}
	static function stdout(program:SessionProgram, box:LspMailbox):Void {
		var frames = new LspFrames((body, size) -> { if (!box.push({t:"message",body:body},size)) throw "Language server output queue is full."; });
		var bytes = Bytes.alloc(16384);
		try {
			while (true) {
				var count = program.stdout.readBytes(bytes,0,bytes.length);
				if (count > 0) frames.push(bytes,count);
			}
		} catch (_:haxe.io.Eof) {
			try frames.finish() catch (error:Dynamic) { box.fail(Std.string(error)); return; }
			box.fail("Language server exited (" + program.exitCode(false) + ")");
		} catch (error:Dynamic) box.fail('Language server output failed: $error');
	}
	static function stderr(program:SessionProgram, box:LspMailbox):Void {
		var lines = new LspLines(), bytes = Bytes.alloc(16384);
		try while (true) {
			var count = program.stderr.readBytes(bytes,0,bytes.length);
			for (line in lines.push(bytes,count)) if (!box.push({t:"stderr",message:line},line.length*2)) { box.fail("Language server log queue is full."); return; }
		} catch (_:haxe.io.Eof) {
			var last = lines.finish(); if (last != "") box.push({t:"stderr",message:last},last.length*2);
		} catch (error:Dynamic) box.fail('Language server log failed: $error');
	}
}

private class LspMailbox {
	static inline var LIMIT = 32 * 1024 * 1024;
	final mutex = new sys.thread.Mutex();
	final wake = new sys.thread.Lock();
	final notify:Void->Void;
	var outgoing:Array<Bytes> = [];
	var incoming:Array<Dynamic> = [];
	var outputBytes = 0;
	var inputBytes = 0;
	var stopped = false;
	var program:Null<SessionProgram>;
	public function new(notify:Void->Void) this.notify = notify;
	public function attach(process:SessionProgram):Bool {
		mutex.acquire(); var accept = !stopped; if (accept) program = process; mutex.release(); return accept;
	}
	public function send(bytes:Bytes):Bool {
		mutex.acquire();
		if (stopped || outgoing.length >= 1024 || inputBytes + bytes.length > LIMIT) { mutex.release(); return false; }
		var empty = outgoing.length == 0;
		outgoing.push(bytes); inputBytes += bytes.length;
		mutex.release(); if (empty) wake.release(); return true;
	}
	public function next():Null<Bytes> {
		while (true) {
			mutex.acquire(); var stop = stopped, bytes = stop ? null : outgoing.shift(); mutex.release();
			if (stop || bytes != null) return bytes;
			wake.wait();
		}
	}
	public function written(size:Int):Void { mutex.acquire(); if (!stopped) inputBytes -= size; mutex.release(); }
	public function push(event:Dynamic, size:Int):Bool {
		mutex.acquire();
		if (stopped || incoming.length >= 2048 || outputBytes + size > LIMIT) { mutex.release(); return false; }
		var empty = incoming.length == 0;
		incoming.push(event); outputBytes += size;
		mutex.release(); if (empty) notify(); return true;
	}
	public function pending():Bool { mutex.acquire(); var present = incoming.length > 0; mutex.release(); return present; }
	public function take():Null<Array<Dynamic>> {
		mutex.acquire(); var events = incoming; incoming = []; outputBytes = 0; mutex.release();
		return events.length == 0 ? null : events;
	}
	public function fail(message:String):Void {
		stop(message);
	}
	public function close():Void stop(null);
	function stop(message:Null<String>):Void {
		mutex.acquire();
		if (stopped) { if (message == null) { incoming = []; outputBytes = 0; } mutex.release(); return; }
		stopped = true; outgoing = []; inputBytes = 0;
		if (message == null || incoming.length >= 2048 || outputBytes + message.length*2 > LIMIT) { incoming = []; outputBytes = 0; }
		if (message != null) { incoming.push({t:"error",message:message}); outputBytes += message.length*2; }
		var process = program; program = null;
		mutex.release(); wake.release();
		if (process != null) { process.killAsync(); process.close(); }
		if (message != null) notify();
	}
}

/** Complete UTF-8 log lines; bounded long lines retain a partial escape or Unicode suffix. */
private class LspLines {
	var pending = Bytes.alloc(0);
	public function new() {}
	public function push(bytes:Bytes, count:Int):Array<String> {
		var joined = Bytes.alloc(pending.length+count); joined.blit(0,pending,0,pending.length); joined.blit(pending.length,bytes,0,count);
		var out = [], from = 0;
		for (at in 0...joined.length) if (joined.get(at) == 10) {
			var end = at > from && joined.get(at-1) == 13 ? at-1 : at;
			out.push(joined.sub(from,end-from).toString()); from = at+1;
		}
		while (joined.length-from > 65536) {
			var cut = from+65536;
			for (at in cut-256...cut) if (joined.get(at) == 27) cut = at;
			while (cut > from && joined.get(cut)&0xC0 == 0x80) cut--;
			out.push(joined.sub(from,cut-from).toString()); from = cut;
		}
		pending = joined.sub(from,joined.length-from); return out;
	}
	public function finish():String { var last = pending.toString(); pending = Bytes.alloc(0); return last; }
}
