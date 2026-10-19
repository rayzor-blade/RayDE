import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.run.DiagnosticJobs;

class DiagnosticJobsChecks {
	public static function run():Void {
		var root = Sys.getCwd() + "bin/check-diagnostic-jobs", file = root + "/Main.hx";
		sys.FileSystem.createDirectory(root);
		var clean = "class Main { static function main() {} }";
		sys.io.File.saveContent(file, clean);
		var server = new CompilerServer(), display = new Display(server, root, ["-cp", root, "-main", "Main"]), jobs = new DiagnosticJobs(display);
		function finish():Array<rayde.run.DiagnosticJobs.DiagnosticResult> {
			var end = haxe.Timer.stamp() + 10, found = [];
			while (jobs.busy() && haxe.Timer.stamp() < end) { found = found.concat(jobs.tick()); Sys.sleep(.01); }
			if (jobs.busy()) throw "background diagnostics did not finish";
			return found;
		}
		try {
			jobs.request(file, "class Main { static function main() { missing; } }");
			jobs.tick();
			if (!jobs.busy()) throw "compiler did not start in the background";
			jobs.request(file, clean);
			var found = finish();
			if (found.length != 1 || found[0].text != clean || found[0].problems.length != 0) throw "superseded diagnostics were delivered";
			// The request file carries a buffer beyond the command-line argument limit.
			var text = clean + "\n/*" + StringTools.lpad("", "x", 300000) + "*/";
			jobs.request(file, text);
			found = finish();
			if (found.length != 1 || found[0].text != text || found[0].problems.length != 0) throw "large unsaved buffer was not checked";
			jobs.request(file, "class Main { static function main() { missing; } }");
			found = finish();
			if (found.length != 1 || found[0].problems.length == 0) throw "background compiler did not report an unsaved error";
			jobs.request(file, clean); jobs.tick(); jobs.cancel(file);
			if (finish().length != 0) throw "closed file received late diagnostics";
			if (server.running()) throw "background diagnostics started the interactive compilation server";
		} catch (failure:Dynamic) { jobs.dispose(); throw failure; }
		jobs.dispose();
		Sys.println("background diagnostics: unsaved buffers, superseded/cancelled results, large requests and compiler isolation");
	}
}
