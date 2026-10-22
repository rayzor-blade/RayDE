package rayde.run;

import rayde.lang.CompilerServer;
import rayde.lang.Display;

/**
 * Builds a project through its compilation server and runs it on ash, an
 * `ash --preset application` run of the program the build made. A build is
 * `haxe --connect` against the server the language layer already keeps warm,
 * so it only types what changed. Nothing here waits: `tick`, from the
 * frame loop, moves a run along and gathers what the build and the program
 * printed.
 */
class Runner {
	/** idle, building, running, finished (with its exit code in `exitCode`) or failed (the build did not make a program). */
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
	final out:String;
	var job:Null<Job>;
	var building = false;

	public function new(display:Display, ?ash:String) {
		this.display = display;
		this.ash = ash != null ? ash : Sys.getEnv("ASH") != null ? Sys.getEnv("ASH") : "ash";
		out = haxe.io.Path.join([display.cwd, ".rayde", "run"]);
	}

	public function program():String
		return haxe.io.Path.join([out, "program.hl"]);

	public function active():Bool
		return state == "building" || state == "running";

	/** Builds, and when that made a program, runs it. */
	public function start():Void {
		stop();
		console = "";
		problems = [];
		exitCode = null;
		display.server.ensure();
		if (sys.FileSystem.exists(program()))
			sys.FileSystem.deleteFile(program());
		sys.FileSystem.createDirectory(out);
		building = true;
		state = "building";
		append("Building…\n");
		job = new Job("haxe", ["--connect", Std.string(display.server.port), "--cwd", display.cwd].concat(display.args).concat(["-hl", program()]), haxe.io.Path.join([out, "build.log"]), null, null, true);
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
			if (code != 0 || !sys.FileSystem.exists(program())) {
				state = "failed";
				append("The build did not make a program.\n");
				return;
			}
			append("Running…\n");
			state = "running";
			job = new Job(ash, ["--preset", "application", program()], haxe.io.Path.join([out, "run.log"]), null, null, true);
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
}
