package rayde.ext;

import rayde.workspace.PageHost;
import rayde.workspace.Procs;
import rayde.workspace.session.SessionLauncher;
import rayde.workspace.session.SessionLauncher.SessionProgram;

/** One supervised extension process on the session machine; views and service calls stay in the page. */
class SessionExtensionHost {
	var process:Null<SessionProgram>;
	final opening:ash.Future<SessionProgram>;
	final queued:Array<Dynamic> = [];
	var writes:Array<ash.Future<Dynamic>> = [];
	var held = new haxe.io.BytesBuffer();
	var heldBytes = 0;
	public var exitCode(default, null):Null<Int>;
	public var processId(default, null):Null<Int>;
	public var ended(default, null) = false;

	public function new(root:Null<String>, extension:String) {
		var session = PageHost.session;
		if (session == null || !session.exec || session.extensionHost == null) throw "This workspace session has no extension host.";
		var args = ["--extension", extension];
		if (root != null) args = args.concat(["--root", remotePath(root)]);
		var launcher:SessionLauncher = cast Procs.current;
		opening = launcher.startAsync(session.extensionHost, args);
	}

	static function remotePath(path:String):String {
		var prefix = "/rayde/extensions/", session = PageHost.session;
		if (StringTools.startsWith(path, prefix)) {
			if (session.extensionsRoot == null) throw "This workspace session has no built-in extension installation.";
			return session.extensionsRoot + "/" + path.substr(prefix.length);
		}
		if (path == session.root || StringTools.startsWith(path, session.root + "/")) return path;
		throw "The extension is not installed in this workspace session.";
	}

	public function send(message:Dynamic):Bool {
		if (ended || queued.length + writes.length >= 256) return false;
		var value:Dynamic = haxe.Json.parse(haxe.Json.stringify(message));
		if (value.t == "run") value.name = remotePath(value.name);
		if (value.t == "natives") value.root = remotePath(value.root);
		if (process == null) queued.push(value);
		else writes.push(process.writeAsync(haxe.Json.stringify(value) + "\n"));
		return true;
	}

	public function pending():Bool {
		if (ended) return false;
		PageHost.session.drain();
		return process == null ? opening.isReady() : process.hasOutput() || process.exitCode(false) != null && !ended || Lambda.exists(writes, future -> future.isReady());
	}

	public function poll():Array<Dynamic> {
		var messages:Array<Dynamic> = [];
		if (ended) return messages;
		try {
			if (process == null && opening.isReady()) {
				process = opening.await();
				for (message in queued) writes.push(process.writeAsync(haxe.Json.stringify(message) + "\n"));
				queued.resize(0);
			}
			var remaining = [];
			for (future in writes) if (future.isReady()) future.await() else remaining.push(future);
			writes = remaining;
		} catch (error:Dynamic) {
			stop(); exitCode = 1;
			messages.push({t:"error",kind:"host",message:Std.string(error)});
		}
		if (process == null || ended) return messages;
		var bytes = process.takeOutput(), start = 0;
		try {
			for (i in 0...bytes.length) if (bytes.get(i) == 10) {
				append(bytes, start, i - start); start = i + 1;
				var text = held.getBytes().toString(); held = new haxe.io.BytesBuffer(); heldBytes = 0;
				if (text == "") continue;
				var message:Dynamic = haxe.Json.parse(text);
				if (message.t == "ready") processId = message.pid;
				messages.push(message);
			}
			append(bytes, start, bytes.length - start);
		} catch (error:Dynamic) {
			stop(); exitCode = 1; messages.push({t:"error",kind:"host",message:Std.string(error)}); return messages;
		}
		var errors = process.takeOutput(true).toString();
		if (errors != "") messages.push({t:"error",kind:"host",message:errors});
		var code = process.exitCode(false);
		if (code != null && !process.hasOutput()) { exitCode = code; ended = true; process.close(); }
		return messages;
	}

	function append(bytes:haxe.io.Bytes, start:Int, length:Int):Void {
		if (heldBytes + length > 16 * 1024 * 1024) throw "The extension output exceeded its message limit.";
		held.addBytes(bytes, start, length); heldBytes += length;
	}

	public function stop():Void {
		if (process != null) { if (!ended) process.killAsync(); process.close(); }
		else if (!ended) opening.then(program -> { program.killAsync(); program.close(); }, _ -> {});
		ended = true; held = new haxe.io.BytesBuffer(); heldBytes = 0; queued.resize(0); writes = [];
	}
}
