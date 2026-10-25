package rayde.project;

/** What `caribou project --json` says about a `.cbproj`: Caribou's own reading of its project file. A workspace lists its members. */
typedef CaribouInfo = {
	dir:String,
	name:String,
	/** `language:module`, or null when there is no entry (a workspace, or a library). */
	entry:Null<String>,
	languages:Array<String>,
	/** The folder Caribou runs Haxe from. Its source roots are relative to it, and must stay so: Caribou declares guest-language classes only for relative class paths. */
	cwd:String,
	/** The exact argument list Caribou runs Haxe with, in the form `Hxml.read` gives. */
	args:Array<String>,
	/** What Caribou rejects or ignores in the file, each as a sentence. */
	problems:Array<String>,
	workspace:Bool,
	members:Array<CaribouInfo>
};

/**
 * A Caribou project is read by Caribou. RayDE does not re-derive its rules (source roots, namespaces, plugin libraries,
 * the arguments Haxe is run with); it asks `caribou project <file> --json`, which runs nothing and builds nothing, and reads the answer.
 */
class CaribouProject {
	/** The `caribou` executable: `CARIBOU`, the one packaged beside RayDE, one on PATH, or a sibling development build. */
	public static function binary():Null<String> {
		var named = Sys.getEnv("CARIBOU");
		if (named != null && named != "") return named;
		var name = Sys.systemName() == "Windows" ? "caribou.exe" : "caribou";
		var program = haxe.io.Path.directory(Sys.programPath());
		function existing(paths:Array<String>):Null<String> {
			for (path in paths) if (sys.FileSystem.exists(path) && !sys.FileSystem.isDirectory(path)) return sys.FileSystem.fullPath(path);
			return null;
		}
		var bundled = existing([program + "/" + name, program + "/../Resources/" + name]);
		if (bundled != null) return bundled;
		var path = Sys.getEnv("PATH");
		if (path != null) {
			var installed = existing([for (dir in path.split(Sys.systemName() == "Windows" ? ";" : ":")) if (dir != "") dir + "/" + name]);
			if (installed != null) return installed;
		}
		return existing([for (root in [program + "/../../caribou", Sys.getCwd() + "/../caribou"]) for (profile in ["release", "debug"]) root + "/target/" + profile + "/" + name]);
	}

	/** Asks Caribou for the project in `file`; throws a sentence when it cannot. */
	public static function resolve(file:String):CaribouInfo {
		var caribou = binary();
		if (caribou == null) throw "Caribou is not installed. Build ../caribou, put caribou on PATH, or set CARIBOU.";
		var process:sys.io.Process;
		try process = new sys.io.Process(caribou, ["project", file, "--json"]) catch (e:Dynamic) throw "Could not start " + caribou + ": " + Std.string(e);
		var out = process.stdout.readAll().toString(), err = process.stderr.readAll().toString(), code = process.exitCode();
		process.close();
		if (code != 0) {
			var why = StringTools.trim(err) != "" ? StringTools.trim(err) : "exit " + code;
			throw "caribou project failed: " + (why.indexOf("\n") >= 0 ? why.substr(0, why.indexOf("\n")) : why);
		}
		return parse(out);
	}

	/** Reads the JSON `caribou project --json` prints. */
	public static function parse(text:String):CaribouInfo {
		var data:Dynamic;
		try data = haxe.Json.parse(text) catch (e:Dynamic) throw "caribou project printed something that is not JSON.";
		if (data == null || !Reflect.isObject(data)) throw "caribou project printed no project.";
		if (data.workspace != null) {
			var members:Array<Dynamic> = Std.isOfType(data.members, Array) ? data.members : [];
			var info = read(data.workspace);
			info.workspace = true;
			info.members = [for (member in members) read(member)];
			return info;
		}
		return read(data);
	}

	static function read(data:Dynamic):CaribouInfo {
		var dir = text(data.dir), entry:Dynamic = data.entry, compiler:Dynamic = data.haxe;
		var args = compiler != null && Std.isOfType(compiler.args, Array) ? [for (a in (compiler.args:Array<Dynamic>)) Std.string(a)] : [];
		var problems = Std.isOfType(data.problems, Array) ? [for (p in (data.problems:Array<Dynamic>)) problem(p)] : [];
		return {
			dir: dir,
			name: text(data.name) == "" ? haxe.io.Path.withoutDirectory(haxe.io.Path.removeTrailingSlashes(dir)) : text(data.name),
			entry: entry == null ? null : Std.isOfType(entry, String) ? entry : text(entry.language) + ":" + text(entry.module),
			languages: Std.isOfType(data.languages, Array) ? [for (l in (data.languages:Array<Dynamic>)) Std.string(l)] : [],
			cwd: compiler != null && compiler.cwd != null ? Std.string(compiler.cwd) : dir, args: args, problems: problems, workspace: false, members: []
		};
	}

	static function text(value:Dynamic):String
		return value == null ? "" : Std.string(value);

	static function problem(p:Dynamic):String {
		if (Std.isOfType(p, String)) return p;
		var message = text(p.message), key = text(p.key);
		return key == "" ? message : key + ": " + message;
	}
}
