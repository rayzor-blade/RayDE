import rayde.project.ProjectFile;
import rayde.project.ProjectRunner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.run.Runner;
import rayde.settings.Store;

class ProjectRunnerChecks {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }
	static function main():Void run();
	public static function run():Void {
		check(ProjectRunner.defaultHashlink("Mac", true) == "ash", "Apple Silicon did not default to Ash");
		for (system in ["Windows", "Linux", "BSD"]) check(ProjectRunner.defaultHashlink(system, true) == "hashlink", "Non-macOS platform did not keep HashLink");
		check(ProjectRunner.defaultHashlink("Mac", false) == "hashlink", "Intel macOS did not keep HashLink");
		var root = Sys.getCwd() + "bin/runner-checks-" + Std.random(0x3fffffff);
		sys.FileSystem.createDirectory(root);
		for (kind in ["ash", "ashui", "hashlink"]) {
			var file = ProjectFile.create(root, kind, kind), project = ProjectFile.read(file);
			check(project.runtime == (kind == "hashlink" ? ProjectRunner.defaultHashlink() : "ash"), "Starter selected the wrong runner: " + kind);
		}
		var file = ProjectFile.create(root, "override", "hashlink"), folder = haxe.io.Path.directory(file);
		Store.save(folder, "run", {runner:"hashlink", keep:"preserved"});
		check(ProjectFile.read(file).runtime == "hashlink", "Explicit HashLink override was ignored");
		Store.save(folder, "run", {runner:"ash"});
		check(ProjectFile.read(file).runtime == "ash", "Explicit Ash override was ignored");
		var files = [".rayde/settings.json" => '{"appearance":{"scheme":"dark"},"run":{"keep":true}}'];
		ProjectRunner.configure(files, "ash"); var data:Dynamic = haxe.Json.parse(files.get(".rayde/settings.json"));
		check(data.appearance.scheme == "dark" && data.run.keep && data.run.runner == "ash", "Runner configuration overwrote unrelated settings");
		if (Sys.systemName() == "Windows") return;
		var record = root + "/record", fake = root + "/runner", oldAsh = Sys.getEnv("ASH"), oldHl = Sys.getEnv("HL");
		sys.io.File.saveContent(fake, "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" > '" + record + "'\n");
		Sys.command("chmod", ["+x", fake]); Sys.putEnv("ASH", fake); Sys.putEnv("HL", fake);
		var compiler = new CompilerServer();
		try {
			for (runtime in ["ash", "hashlink"]) {
				Store.save(folder, "run", {runner:runtime});
				var runner = new Runner(Display.ofProject(compiler, file)); runner.start();
				var end = haxe.Timer.stamp() + 15;
				while (runner.active() && haxe.Timer.stamp() < end) { runner.tick(); Sys.sleep(.005); }
				check(runner.state == "finished" && runner.exitCode == 0, "Configured runner failed: " + runner.console);
				var expected = folder + "\n" + (runtime == "ash" ? "--preset\napplication\n" : "") + runner.program() + "\n";
				check(sys.io.File.getContent(record) == expected, "Runner executable received the wrong arguments or working directory");
			}
		} catch (error:Dynamic) { compiler.stop(); Sys.putEnv("ASH", oldAsh ?? ""); Sys.putEnv("HL", oldHl ?? ""); throw error; }
		compiler.stop(); Sys.putEnv("ASH", oldAsh ?? ""); Sys.putEnv("HL", oldHl ?? "");
		Sys.println("project runners: platform defaults, starter defaults, settings overrides and actual Ash/HashLink process routing");
	}
}
