import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.project.ProjectFile;
import rayde.run.Runner;

class BuildChecks {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }
	static function main():Void run();
	static function finish(job:Runner):Void {
		var deadline = haxe.Timer.stamp() + 20;
		while (job.active() && haxe.Timer.stamp() < deadline) { job.tick(); Sys.sleep(.005); }
		job.tick();
		if (job.active()) { job.stop(); throw "Build did not finish"; }
	}
	public static function run():Void {
		var root = Sys.getCwd() + "bin/build checks λ '-" + Std.random(0x3fffffff);
		sys.FileSystem.createDirectory(root + "/src"); sys.FileSystem.createDirectory(root + "/bin");
		var source = 'class Main { static function main() { #if sys sys.io.File.saveContent("ran.txt", "ran"); #end trace("PROGRAM_RAN"); } }\n';
		sys.io.File.saveContent(root + "/src/Main.hx", source);
		var file = root + "/build.hxml";
		sys.io.File.saveContent(file, "-cp src\n-main Main\n-js bin/app.js\n--next\n-cp src\n-main Main\n-hl bin/app.hl\n");
		var compiler = new CompilerServer(), runner = new Runner(Display.ofHxml(compiler, file));
		check(runner.canBuild(), "HXML project has no Build action");
		runner.build(); finish(runner);
		check(runner.state == "built" && runner.exitCode == 0, "Declared HXML build failed: " + runner.console);
		check(sys.FileSystem.exists(root + "/bin/app.js") && sys.FileSystem.exists(root + "/bin/app.hl"), "Build changed the declared targets or ignored --next");
		check(!sys.FileSystem.exists(root + "/ran.txt") && runner.console.indexOf("PROGRAM_RAN") < 0 && !sys.FileSystem.exists(runner.program()), "Build launched the program or replaced its output path");
		check(!compiler.running(), "Build started the language server");
		sys.io.File.saveContent(root + "/src/Main.hx", "class Main { static function main() { var broken:Int = 'text'; } }\n");
		runner.build(); finish(runner);
		check(runner.state == "failed" && runner.exitCode != 0 && runner.problems.length > 0 && runner.problems[0].message == "String should be Int", "Failed build lost its status or diagnostic: " + runner.console);
		sys.io.File.saveContent(root + "/src/Main.hx", source);
		runner.build(); finish(runner);
		check(runner.state == "built" && runner.problems.length == 0, "Successful rebuild retained old errors");
		defaults(root, compiler, source);
		var folder = new Runner(Display.ofProject(compiler, root));
		check(!folder.canBuild(), "Folder workspace inferred a build target");
		folder.build(); check(folder.state == "failed" && !folder.active(), "Unsupported workspace launched a build");
		if (Sys.systemName() != "Windows") processes(root);
		Sys.println("build: declared HXML targets, multiple compilations, no launch, diagnostics, rebuild, compiler selection, Rayzor routing and cancellation");
	}
	static function defaults(root:String, compiler:CompilerServer, source:String):Void {
		var file = root + "/default.hxml";
		sys.io.File.saveContent(file, "-cp src\n-main Main\n");
		sys.io.File.saveContent(root + "/src/Main.hx", 'class Main { static function main() { #if hl var broken:Int = "text"; #end } }\n');
		var run = new Runner(Display.ofHxml(compiler, file)); run.build(); finish(run);
		check(run.state == "failed" && run.problems.length > 0, "Targetless Build missed a HashLink-only error that Run would catch");
		sys.io.File.saveContent(file, "-cp src\n-main Main\n--no-output\n");
		run.build(); finish(run);
		check(run.state == "built" && run.console.indexOf("No target declared") < 0, "Build replaced deliberate --no-output checking");
		sys.io.File.saveContent(root + "/src/Main.hx", source);
		sys.io.File.saveContent(file, "-cp src\n-main Main\n");
		run.build(); finish(run);
		check(run.state == "built" && sys.FileSystem.exists(root + "/.rayde/run/build.hl") && run.console.indexOf("PROGRAM_RAN") < 0, "Targetless Build did not emit bytecode without launching it");
		sys.io.File.saveContent(root + "/nested.hxml", "-cp src\n-main Main\n-js bin/nested.js\n");
		sys.io.File.saveContent(file, "nested.hxml\n"); run.build(); finish(run);
		check(run.state == "built" && sys.FileSystem.exists(root + "/bin/nested.js") && run.console.indexOf("No target declared") < 0, "Nested HXML target was replaced");
		sys.io.File.saveContent(file, "-cp src\n-main Main\n--next\n-cp src\n-main Main\n"); run.build();
		check(run.state == "failed" && !run.active(), "Multiple targetless compilations incorrectly reported success");
	}
	static function processes(root:String):Void {
		var record = root + "/record", executable = root + "/compiler";
		sys.io.File.saveContent(executable, "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" > record\nsleep .1\n");
		Sys.command("chmod", ["+x", executable]);
		var compiler = new CompilerServer(executable), configured = new Runner(Display.ofHxml(compiler, root + "/build.hxml"));
		configured.build(); finish(configured);
		check(configured.state == "built" && sys.io.File.getContent(record) == root + "\n" + root + "/build.hxml\n", "Build ignored the configured Haxe compiler or project cwd");
		var entry = ProjectFile.create(root, "rayzor-app", "rayzor"), previous = Sys.getEnv("RAYZOR_LSP");
		Sys.putEnv("RAYZOR_LSP", executable);
		try {
			var rayzor = new Runner(Display.ofProject(compiler, entry)); rayzor.build(); finish(rayzor);
			check(rayzor.state == "built" && sys.io.File.getContent(haxe.io.Path.directory(entry) + "/record") == haxe.io.Path.directory(entry) + "\nbuild\n" && !compiler.running(), "Rayzor Build invoked the wrong compiler, command or cwd");
		} catch (error:Dynamic) { Sys.putEnv("RAYZOR_LSP", previous ?? ""); throw error; }
		Sys.putEnv("RAYZOR_LSP", previous ?? "");
		sys.io.File.saveContent(executable, "#!/bin/sh\nsleep 5\n");
		var start = haxe.Timer.stamp(); configured.build();
		check(haxe.Timer.stamp() - start < .5 && configured.active(), "Build blocked the calling thread");
		configured.stop(); check(configured.state == "idle" && !configured.active(), "Stop did not cancel Build");
	}
}
