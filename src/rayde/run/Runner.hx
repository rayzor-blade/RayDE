package rayde.run;

import rayde.lang.CompilerServer;
import rayde.lang.Display;

/** Build preserves the project's targets; Run uses its runtime. Jobs own their processes on a worker. */
class Runner {
	/** idle, building, running, built, finished or failed. */
	public var state(default, null) = "idle";

	/** What the build and the program have printed, newest last, bounded. */
	public var console(default, null) = "";

	/** The errors and warnings of the last build. */
	public var problems(default, null):Array<Diagnostic> = [];

	public var exitCode(default, null):Null<Int>;

	/** Counts every change to the above, for whatever shows them. */
	public var revision(default, null) = 0;

	final display:Display;
	final ash:String;
	final hashlink:String;
	final out:String;
	var job:Null<Job>;
	var building = false;
	var buildOnly = false;
	var runtime = "ash";

	public function new(display:Display, ?ash:String) {
		this.display = display;
		this.ash = ash != null ? ash : Sys.getEnv("ASH") != null ? Sys.getEnv("ASH") : "ash";
		hashlink = Sys.getEnv("HL") ?? "hl";
		out = haxe.io.Path.join([display.cwd, ".rayde", "run"]);
	}

	public function program():String
		return haxe.io.Path.join([out, "program.hl"]);

	public function active():Bool
		return state == "building" || state == "running";

	public function canBuild():Bool
		return display.hxml != null || display.project != null && display.project.runtime == "rayzor";

	/** Compiles the selected project as declared, without adding a target or launching its output. */
	public function build():Void {
		stop();
		console = ""; problems = []; exitCode = null;
		building = true; buildOnly = true;
		if (!canBuild()) {
			state = "failed"; append("Open an HXML or Rayzor project to build.\n"); return;
		}
		var rayzor = display.project != null && display.project.runtime == "rayzor";
		state = "building";
		append(rayzor ? "Building with Rayzor…\n" : "Building with Haxe…\n");
		job = new Job(rayzor ? rayde.lang.RayzorBinary.find() ?? "rayzor" : display.server.haxe,
			rayzor ? ["build"] : [display.hxml], haxe.io.Path.join([out, "build.log"]), null, display.cwd, true);
		job.start();
	}

	/** Builds, and when that made a program, runs it. */
	public function start():Void {
		stop();
		buildOnly = false;
		console = "";
		problems = [];
		exitCode = null;
		runtime = display.project == null ? rayde.project.ProjectRunner.resolve(display.cwd) : display.project.runtime;
		if (display.project != null && !display.project.runnable) {
			state = "failed"; append("This project has no application entry point. Open a runnable build to use Run.\n"); return;
		}
		if (display.project != null && display.project.runtime == "rayzor") {
			sys.FileSystem.createDirectory(out);
			building = false; state = "running"; append("Running with Rayzor…\n");
			job = new Job(rayde.lang.RayzorBinary.find() ?? "rayzor", ["run"], haxe.io.Path.join([out, "run.log"]), null, display.cwd, true);
			job.start(); return;
		}
		display.server.ensure();
		if (sys.FileSystem.exists(program()))
			sys.FileSystem.deleteFile(program());
		sys.FileSystem.createDirectory(out);
		building = true;
		state = "building";
		append("Building…\n");
		job = new Job(display.server.haxe, ["--connect", Std.string(display.server.port), "--cwd", display.cwd].concat(bytecodeArgs(display.args)).concat(["-hl", program()]), haxe.io.Path.join([out, "build.log"]), null, null, true);
		job.start();
	}

	public function stop():Void {
		if (job != null)
			job.stop();
		job = null;
		if (active()) {
			state = "idle";
			append("Stopped.\n");
		}
	}

	/** Moves a build or run along; call it every frame. */
	public function tick():Void {
		if (job == null)
			return;
		var text = job.read();
		if (text != "")
			append(text);
		if (job.running())
			return;
		append(job.read());
		var code = job.exit;
		job = null;
		if (building) {
			building = false;
			problems = CompilerOutput.parse(console, display.cwd);
			revision++;
			if (buildOnly) {
				exitCode = code;
				state = code == 0 ? "built" : "failed";
				append(code == 0 ? "Build succeeded.\n" : "Build failed with " + code + ".\n");
				return;
			}
			if (code != 0 || !sys.FileSystem.exists(program())) {
				state = "failed";
				append("The build did not make a program.\n");
				return;
			}
			append("Running…\n");
			state = "running";
			job = new Job(runtime == "hashlink" ? hashlink : ash, runtime == "hashlink" ? [program()] : ["--preset", "application", program()], haxe.io.Path.join([out, "run.log"]), null, display.cwd, true);
			job.start();
			return;
		}
		exitCode = code;
		state = "finished";
		append("Exited with " + code + ".\n");
	}

	function append(text:String):Void {
		if (text == "")
			return;
		revision++;
		var all = console + text, lines = all.split("\n");
		console = lines.length > 2000 ? lines.slice(lines.length - 2000).join("\n") : all;
	}

	/** Run writes bytecode to its own output, keeping the project's editor/compiler arguments intact. */
	static function bytecodeArgs(args:Array<String>):Array<String> {
		var out:Array<String> = [], at = 0;
		while (at < args.length) {
			if ((args[at] == "-hl" || args[at] == "--hl") && at + 1 < args.length) at += 2;
			else out.push(args[at++]);
		}
		return out;
	}
}
