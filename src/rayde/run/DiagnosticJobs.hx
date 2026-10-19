package rayde.run;

import rayde.lang.Display;

private typedef Request = {file:String, text:String, args:Array<String>, serial:Int};
typedef DiagnosticResult = {file:String, text:String, serial:Int, problems:Array<Diagnostic>};

/** One background compiler at a time, independent of the interactive display server's module cache. */
class DiagnosticJobs {
	final display:Display;
	final queue:Array<Request> = [];
	final latest = new Map<String, Int>();
	final config:String;
	final log:String;
	var serial = 0;
	var job:Null<Job>;
	var current:Request;

	public function new(display:Display) {
		this.display = display;
		var base = display.cwd + "/.rayde/diagnostics/" + Std.string(haxe.Timer.stamp()).split(".").join("-");
		config = base + ".hxml"; log = base + ".log";
	}

	public function request(file:String, text:String):Void {
		var request = {file:file, text:text, args:display.args.copy(), serial:++serial};
		latest.set(file, serial);
		for (old in queue.copy()) if (old.file == file) queue.remove(old);
		queue.push(request);
	}

	public function busy():Bool return job != null || queue.length > 0;

	public function tick():Array<DiagnosticResult> {
		var results:Array<DiagnosticResult> = [];
		if (job != null && !job.running()) {
			if (latest.get(current.file) == current.serial) {
				var found = parse(job.read());
				if (found != null) results.push({file:current.file, text:current.text, serial:current.serial, problems:found});
			}
			job = null;
		}
		if (job == null && queue.length > 0) {
			current = queue.shift();
			var request = haxe.Json.stringify({jsonrpc:"2.0", id:current.serial, method:"display/diagnostics", params:{file:current.file, contents:current.text}});
			sys.FileSystem.createDirectory(haxe.io.Path.directory(config));
			// An hxml keeps large buffers out of the operating system's command-line size limit.
			sys.io.File.saveContent(config, ["--cwd", display.cwd].concat(current.args).concat(["--no-output", "--display", request]).join("\n") + "\n");
			job = new Job(display.server.haxe, [config], log);
			job.start();
		}
		return results;
	}

	public function cancel(file:String):Void {
		latest.remove(file);
		for (request in queue.copy()) if (request.file == file) queue.remove(request);
	}

	public function dispose():Void {
		queue.resize(0); latest.clear();
		if (job != null) job.stop();
		job = null;
		for (path in [config, log]) if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
	}

	static function parse(reply:String):Null<Array<Diagnostic>> {
		try {
			var at = reply.indexOf("{"), json:Dynamic = haxe.Json.parse(at < 0 ? reply : reply.substr(at));
			if (json.error != null || json.result == null || json.result.result == null) return null;
			var files:Array<Dynamic> = json.result.result, out:Array<Diagnostic> = [];
			for (file in files) {
				var list:Array<Dynamic> = file.diagnostics;
				for (d in list) out.push({file:file.file, range:d.range, severity:d.severity, message:Std.string(d.args)});
			}
			return out;
		} catch (_:Dynamic) return null;
	}
}
