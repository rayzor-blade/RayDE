package rayde.run;

/**
 * A command run in the background, its output going to a log file that is read
 * from as it grows, so polling never waits on the process. The command replaces
 * the shell that starts it, so stopping the job stops the command itself. It has
 * no input: a program that asks a question gets the end of the file.
 */
class Job {
	public final log:String;

	/** The command's exit code once it has ended, null while it runs. */
	public var exit(default, null):Null<Int>;

	final line:String;
	var process:Null<sys.io.Process>;
	var offset = 0;

	public function new(command:String, args:Array<String>, log:String) {
		this.log = log;
		line = "exec " + [command].concat(args).map(quote).join(" ") + " < /dev/null > " + quote(log) + " 2>&1";
	}

	public function start():Void {
		sys.FileSystem.createDirectory(haxe.io.Path.directory(log));
		sys.io.File.saveContent(log, "");
		offset = 0;
		exit = null;
		process = new sys.io.Process("/bin/sh", ["-c", line]);
	}

	/** Whether the command is still running. */
	public function running():Bool {
		if (process == null || exit != null)
			return false;
		var code = process.exitCode(false);
		if (code == null)
			return true;
		exit = code;
		process.close();
		return false;
	}

	/** What the command has printed since the last call. */
	public function read():String {
		if (!sys.FileSystem.exists(log))
			return "";
		var input = sys.io.File.read(log, true);
		input.seek(offset, SeekBegin);
		var text = input.readAll().toString();
		input.close();
		offset += haxe.io.Bytes.ofString(text).length;
		return text;
	}

	public function stop():Void {
		if (process != null && exit == null) {
			process.kill();
			running();
		}
	}

	static function quote(s:String):String
		return "'" + StringTools.replace(s, "'", "'\\''") + "'";
}
