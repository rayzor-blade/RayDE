package rayde.lang;

import rayde.workspace.Procs;
import rayde.workspace.Program;

/**
 * A Haxe compilation server kept running for a project, and the requests sent
 * to it. The server keeps what it has typed between requests, so asking again
 * after an edit costs only what changed.
 *
 * Keep one server for each project: the server caches typed modules by name,
 * so two projects that each have a module `Main` would be given each other's.
 *
 * Its protocol is the one `haxe --connect` speaks: one connection per request,
 * the compiler's arguments one per line, then a NUL byte; the reply is what the
 * compiler printed, and the server closes the connection when done.
 */
class CompilerServer {
	public final haxe:String;
	public var port(default, null) = 0;

	var process:Null<Program>;

	/** A server run with `haxe`, the compiler on `PATH` unless named. Nothing starts until the first request. */
	public function new(haxe = "haxe")
		this.haxe = haxe;

	/** Whether the server process is running. */
	public function running():Bool
		return process != null && process.exitCode(false) == null;

	/** The compiler socket is local to the editor process; remote workspaces use stdio language servers. */
	public function canConnect():Bool {
		#if wasm
		return false;
		#else
		return !Std.isOfType(Procs.current,rayde.workspace.session.SessionLauncher);
		#end
	}

	/** Starts the server when it is not running, so its port is known. */
	public function ensure():Void
		if (!running())
			start();

	/** What the compiler printed for `args`, run in `cwd`; starts the server first when it is not running. */
	public function request(cwd:String, args:Array<String>):String {
		if (!running())
			start();
		try
			return exchange(cwd, args)
		catch (e:Dynamic) {
			// A server that died since the last request is started again once.
			stop();
			start();
			return exchange(cwd, args);
		}
	}

	function exchange(cwd:String, args:Array<String>):String {
		var socket = new sys.net.Socket();
		socket.connect(new sys.net.Host("127.0.0.1"), port);
		try {
			socket.output.writeString(["--cwd", cwd].concat(args).join("\n") + "\n\x00");
			socket.output.flush();
			var reply = socket.input.readAll().toString();
			socket.close();
			return reply;
		} catch (e:Dynamic) {
			socket.close();
			throw e;
		}
	}

	/** Starts the server on the first free port from 7600 and waits until it accepts connections. */
	public function start():Void {
		if (!canConnect()) throw "Use a workspace language server for code inspection in a remote session.";
		stop();
		for (candidate in 7600...7700) {
			if (taken(candidate))
				continue;
			var p = Procs.start(haxe, ["--server-listen", Std.string(candidate)]);
			for (_ in 0...200) {
				if (p.exitCode(false) != null)
					break;
				if (taken(candidate)) {
					process = p;
					port = candidate;
					return;
				}
				Sys.sleep(.025);
			}
			p.kill();
			p.close();
		}
		throw 'no compilation server could start with $haxe';
	}

	public function stop():Void {
		if (process == null)
			return;
		process.kill();
		process.close();
		process = null;
	}

	static function taken(port:Int):Bool {
		var probe = new sys.net.Socket();
		try {
			probe.connect(new sys.net.Host("127.0.0.1"), port);
			probe.close();
			return true;
		} catch (_:Dynamic) {
			probe.close();
			return false;
		}
	}
}
