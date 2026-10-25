package rayde.run;

import rayde.workspace.Fs;
import rayde.lang.Display;

private typedef Request = {file:String, text:String, args:Array<String>, serial:Int, cwd:String, haxe:String, base:String, payload:Dynamic};
typedef DiagnosticResult = {file:String, text:String, serial:Int, problems:Array<Diagnostic>, lsp:Bool};

/** A dedicated worker owns compiler I/O and diagnostic decoding; tick only transfers completed data. */
class DiagnosticJobs {
	final display:Display;
	final worker = new Worker<Request, DiagnosticResult>(compile);
	final base:String;
	var serial = 0;

	public function new(display:Display) {
		this.display = display;
		base = display.cwd + "/.rayde/diagnostics/" + Std.string(haxe.Timer.stamp()).split(".").join("-");
	}

	public function request(file:String, text:String):Void {
		worker.submit(file, {file:file, text:text, args:display.args.copy(), serial:++serial,
			cwd:display.cwd, haxe:display.server.haxe, base:base, payload:null});
	}

	public function publish(file:String, text:String, payload:Dynamic):Void {
		worker.submit(file, {file:file, text:text, args:[], serial:++serial,
			cwd:display.cwd, haxe:"", base:base, payload:payload});
	}

	public function busy():Bool return worker.busy();

	public function tick():Array<DiagnosticResult> {
		return [for (result in worker.poll()) if (result.value != null) result.value];
	}

	public function cancel(file:String):Void worker.cancel(file);
	public function dispose():Void worker.dispose();

	static function compile(request:Request, cancelled:Void->Bool):Null<DiagnosticResult> {
		if (cancelled()) return null;
		if (request.payload != null) return {file:request.file, text:request.text, serial:request.serial,
			problems:rayde.lang.LspProtocol.diagnostics(request.payload), lsp:true};
		var config = request.base + ".hxml", log = request.base + ".log", job:Job = null;
		var result:DiagnosticResult = null;
		try {
			var rpc = haxe.Json.stringify({jsonrpc:"2.0", id:request.serial, method:"display/diagnostics", params:{file:request.file, contents:request.text}});
			Fs.createDirectory(haxe.io.Path.directory(config));
			// An hxml keeps unsaved buffers out of the command-line size limit.
			Fs.saveContent(config, ["--cwd", request.cwd].concat(request.args).concat(["--no-output", "--display", rpc]).join("\n") + "\n");
			job = new Job(request.haxe, [config], log);
			job.start();
			while (!cancelled() && job.running()) Sys.sleep(.02);
			if (!cancelled()) {
				var found = parse(job.read());
				if (found != null) result = {file:request.file, text:request.text, serial:request.serial, problems:found, lsp:false};
			}
		} catch (failure:Dynamic) {
			result = {file:request.file, text:request.text, serial:request.serial,
				problems:[{file:request.file, range:null, severity:1, message:"Diagnostic worker: " + Std.string(failure)}], lsp:false};
		}
		if (job != null) job.stop();
		for (path in [config, log]) if (Fs.exists(path)) Fs.deleteFile(path);
		return result;
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
