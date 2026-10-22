package rayde.run;

/**
 * A command run in the background, its output going to a log file that is read
 * from as it grows, so polling never waits on the process. The command replaces
 * the shell that starts it, so stopping the job stops the command itself. It has
 * input from a file when provided; otherwise a program that asks a question gets EOF.
 */
class Job {
	public final log:String;

	/** The command's exit code once it has ended, null while it runs. */
	public var exit(default, null):Null<Int>;

	final line:String;
	var process:Null<sys.io.Process>;
	var offset = 0;
	final background:Bool;
	var worker:Null<OutputJob>;

	public function new(command:String, args:Array<String>, log:String, ?input:String, ?cwd:String, background = false) {
		this.background = background;
		this.log = log;
		line = (cwd == null ? "" : "cd " + quote(cwd) + " && ") + "exec " + [command].concat(args).map(quote).join(" ") + " < " + (input == null ? "/dev/null" : quote(input)) + " > " + quote(log) + " 2>&1";
	}

	public function start():Void {
		if (background) {
			if (worker != null) worker.stop();
			exit = null;
			worker = new OutputJob(line, log);
			return;
		}
		sys.FileSystem.createDirectory(haxe.io.Path.directory(log));
		sys.io.File.saveContent(log, "");
		offset = 0;
		exit = null;
		process = new sys.io.Process("/bin/sh", ["-c", line]);
	}

	/** Whether the command is still running. */
	public function running():Bool {
		if (background) {
			exit = worker == null ? null : worker.exitCode();
			return worker != null && exit == null;
		}
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
		if (background) return worker == null ? "" : worker.read();
		if (!sys.FileSystem.exists(log))
			return "";
		var input = sys.io.File.read(log, true);
		input.seek(offset, SeekBegin);
		var bytes = input.readAll();
		input.close();
		offset += bytes.length;
		return bytes.toString();
	}

	public function stop():Void {
		if (background) {
			if (worker != null) worker.stop();
			return;
		}
		if (process != null && exit == null) {
			process.kill();
			running();
		}
	}

	static function quote(s:String):String
		return "'" + StringTools.replace(s, "'", "'\\''") + "'";
}


/** The worker owns the process and file cursor; the UI takes a bounded, already-decoded chunk. */
private class OutputJob {
	final mutex = new sys.thread.Mutex();
	var cancelled = false;
	var code:Null<Int>;
	var pending = "";

	public function new(line:String, log:String) {
		sys.thread.Thread.create(() -> run(line, log));
	}

	public function stop():Void {
		mutex.acquire(); cancelled = true; mutex.release();
	}

	function stopped():Bool {
		mutex.acquire(); var stop = cancelled; mutex.release(); return stop;
	}

	public function exitCode():Null<Int> {
		mutex.acquire(); var result = code; mutex.release(); return result;
	}

	public function read():String {
		mutex.acquire(); var text = pending; pending = ""; mutex.release(); return text;
	}

	function append(text:String):Void {
		if (text == "") return;
		mutex.acquire(); var previous = pending; pending = ""; mutex.release();
		var lines = (previous + text).split("\n");
		var next = lines.length > 2000 ? lines.slice(lines.length - 2000).join("\n") : previous + text;
		mutex.acquire(); pending = next; mutex.release();
	}

	function run(line:String, log:String):Void {
		var job:Job = null, result = 1;
		try {
			// Job supplies redirection and quoting; this shell executes the prepared command line.
			job = new Job("/bin/sh", ["-c", line], log);
			if (!stopped()) {
				job.start();
				while (!stopped()) {
					append(job.read());
					if (!job.running()) { append(job.read()); result = job.exit; break; }
					Sys.sleep(.03);
				}
			}
		} catch (failure:Dynamic) append("Error: " + Std.string(failure) + "\n");
		if (job != null) job.stop();
		mutex.acquire(); code = result; mutex.release();
	}
}
