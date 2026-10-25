package rayde.run;

import rayde.workspace.Fs;
import rayde.lang.Display;

/** A command to run in a terminal: what it is called, the shell command, and where it comes from. */
typedef Task = {label:String, command:String, detail:String};

/**
 * The tasks a project offers. Its own are in `.rayde/tasks.json`, `{"tasks": [{"label": ..., "command": ...}]}`,
 * each run in the project's folder; RayDE adds one to build each `.hxml` file at the project's root, and one to
 * run the project on ash in the terminal, where the program has a keyboard.
 */
class Tasks {
	public static function file(root:String):String
		return haxe.io.Path.join([root, ".rayde", "tasks.json"]);

	/** What a new tasks file starts as. */
	public static function template():String
		return '{\n\t"tasks": [\n\t\t{ "label": "Format source", "command": "haxelib run formatter -s src" }\n\t]\n}\n';

	/** The file made if there is none, and its path. */
	public static function ensure(root:String):String {
		var path = file(root);
		if (!Fs.exists(path)) {
			var dir = haxe.io.Path.directory(path);
			if (!Fs.exists(dir))
				Fs.createDirectory(dir);
			Fs.saveContent(path, template());
		}
		return path;
	}

	/** `text` as one word of a shell command. */
	public static function quote(text:String):String
		return Sys.systemName() == "Windows" ? '"' + text + '"' : "'" + StringTools.replace(text, "'", "'\\''") + "'";

	public static function list(display:Display):Array<Task> {
		var out:Array<Task> = [];
		try {
			if (Fs.exists(file(display.cwd))) {
				var json:Dynamic = haxe.Json.parse(Fs.getContent(file(display.cwd)));
				var tasks:Array<Dynamic> = json.tasks;
				if (tasks != null)
					for (t in tasks)
						if (t.label != null && t.command != null)
							out.push({label: Std.string(t.label), command: Std.string(t.command), detail: "tasks.json"});
			}
		} catch (_:Dynamic) {}
		if (display.hxml != null) {
			var name = haxe.io.Path.withoutDirectory(display.hxml);
			var ash = Sys.getEnv("ASH") != null && Sys.getEnv("ASH") != "" ? Sys.getEnv("ASH") : "ash";
			var program = haxe.io.Path.join([display.cwd, ".rayde", "run", "terminal.hl"]);
			out.push({
				label: "Run " + name + " on ash",
				command: "haxe " + quote(name) + " -hl " + quote(program) + " && " + quote(ash) + " --preset application " + quote(program),
				detail: "ash"
			});
		}
		for (entry in Fs.readDirectory(display.cwd)) {
			var path = haxe.io.Path.join([display.cwd, entry]);
			if (StringTools.endsWith(entry, ".hxml") && !Fs.isDirectory(path))
				out.push({label: "Build " + entry, command: "haxe " + quote(entry), detail: "haxe"});
		}
		return out;
	}
}
