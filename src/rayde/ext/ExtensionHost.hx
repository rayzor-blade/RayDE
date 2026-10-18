package rayde.ext;

/**
 * One extension, running in its own rayscript-host process. The host speaks JSON lines: `send` writes a
 * message to its input, and `poll` reads what it has written since the last call. Nothing here waits.
 *
 * The program's output goes to a file that is read as it grows, as `Job` does, because reading a pipe
 * would stop the frame loop until the host wrote something. Its input is a pipe, which a message much
 * smaller than a pipe's buffer never blocks.
 */
class ExtensionHost {
	/** idle, running, or exited (with its exit code in `exitCode`). */
	public var state(default, null) = "idle";

	public var exitCode(default, null):Null<Int>;

	final binary:String;
	final dir:String;
	final root:Null<String>;
	var process:Null<sys.io.Process>;
	var offset = 0;
	var partial = "";

	/** `dir` holds the host's output and error logs; `root` is where it finds the script modules a script imports. */
	public function new(binary:String, dir:String, ?root:String) {
		this.binary = binary;
		this.dir = dir;
		this.root = root;
	}

	public function out():String
		return dir + "/host.out";

	public function errLog():String
		return dir + "/host.err";

	public function running():Bool
		return state == "running";

	public function start():Void {
		stop();
		sys.FileSystem.createDirectory(dir);
		sys.io.File.saveContent(out(), "");
		sys.io.File.saveContent(errLog(), "");
		offset = 0;
		partial = "";
		exitCode = null;
		var args = [binary].concat(root != null ? ["--root", root] : []);
		var line = "exec " + args.map(quote).join(" ") + " > " + quote(out()) + " 2> " + quote(errLog());
		process = new sys.io.Process("/bin/sh", ["-c", line]);
		state = "running";
	}

	/** Sends a message to the host: any value that makes JSON. False if the host is not there to take it. */
	public function send(message:Dynamic):Bool {
		if (process == null || state != "running")
			return false;
		try {
			process.stdin.writeString(haxe.Json.stringify(message) + "\n");
			process.stdin.flush();
			return true;
		} catch (e:Dynamic)
			return false;
	}

	/** The messages the host has written since the last call, in order. */
	public function poll():Array<Dynamic> {
		var messages:Array<Dynamic> = [];
		if (process == null)
			return messages;
		// Whether it has ended is asked first, so that what it wrote just before is still read.
		var ended = process.exitCode(false);
		var text = readNew();
		if (text != "") {
			var lines = (partial + text).split("\n");
			partial = lines.pop();
			for (l in lines)
				if (l != "")
					messages.push(try haxe.Json.parse(l) catch (e:Dynamic) ({t: "error", kind: "protocol", message: "the host wrote something that is not JSON: " + l} : Dynamic));
		}
		if (ended != null && state == "running") {
			state = "exited";
			exitCode = ended;
			process.close();
			process = null;
		}
		return messages;
	}

	/** What the host wrote to its error stream: free text, for when it fails to start or stops. */
	public function errors():String
		return sys.FileSystem.exists(errLog()) ? sys.io.File.getContent(errLog()) : "";

	/** Asks the host to end, and ends it. */
	public function stop():Void {
		if (process == null)
			return;
		if (state == "running") {
			send({t: "shutdown"});
			process.kill();
			process.exitCode(true);
		}
		process.close();
		process = null;
		state = "idle";
	}

	function readNew():String {
		if (!sys.FileSystem.exists(out()))
			return "";
		var input = sys.io.File.read(out(), true);
		input.seek(offset, SeekBegin);
		var text = input.readAll().toString();
		input.close();
		offset += haxe.io.Bytes.ofString(text).length;
		return text;
	}

	static function quote(s:String):String
		return "'" + StringTools.replace(s, "'", "'\\''") + "'";
}
