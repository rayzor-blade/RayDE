package rayde.files;

import haxe.io.Path;
import sys.FileSystem;

using StringTools;

private typedef Rule = {base:String, pattern:EReg, anchored:Bool, directory:Bool, negated:Bool};
private typedef Parsed = {stamp:String, rules:Array<Rule>, generation:Int};

/**
 * Whether git ignores a path, from the repository's `.git/info/exclude` and the `.gitignore` of each folder above it.
 * The last pattern that matches decides, and nothing inside an ignored folder can be brought back. Whether a file
 * is tracked is not considered, and neither are the user's global excludes. A `.git` folder always counts as ignored.
 */
class GitIgnore {
	final root:String;
	final parsed = new Map<String, Parsed>();
	final answers = new Map<String, Bool>();
	var repository:Null<String>;
	var searched = false;
	var generation = 0;

	public function new(root:String) this.root = Path.removeTrailingSlashes(Path.normalize(root));

	/** The folder that holds `.git`, at or above the project; null outside a repository. */
	function top():Null<String> {
		if (searched) return repository;
		searched = true;
		var dir = root;
		while (true) {
			if (FileSystem.exists(dir + "/.git")) return repository = dir;
			var up = Path.directory(dir);
			if (up == dir || up == "") return null;
			dir = up;
		}
	}

	/** Reads the ignore files again the next time a path is asked about; call it when files may have changed. */
	public function refresh():Void {
		generation++;
		answers.clear();
	}

	public function ignored(path:String):Bool {
		var known = answers.get(path);
		if (known != null) return known;
		var result = decide(path);
		answers.set(path, result);
		return result;
	}

	function decide(path:String):Bool {
		var base = top();
		if (base == null) return false;
		var full = Path.removeTrailingSlashes(Path.normalize(path));
		if (full == base || !full.startsWith(base + "/")) return false;
		var parts = full.substr(base.length + 1).split("/"), at = "";
		for (i in 0...parts.length) {
			at = at == "" ? parts[i] : at + "/" + parts[i];
			if (parts[i] == ".git") return true;
			var directory = i < parts.length - 1 || FileSystem.isDirectory(full);
			if (matches(base, at, directory)) return true;
		}
		return false;
	}

	function matches(base:String, rel:String, directory:Bool):Bool {
		var files = [base + "/.git/info/exclude", base + "/.gitignore"], bases = ["", ""];
		var folders = rel.split("/");
		folders.pop();
		var at = "";
		for (folder in folders) {
			at = at == "" ? folder : at + "/" + folder;
			files.push(base + "/" + at + "/.gitignore");
			bases.push(at);
		}
		var result = false;
		for (i in 0...files.length) {
			var scope = bases[i], local = scope == "" ? rel : rel.substr(scope.length + 1);
			for (rule in rulesOf(files[i], scope)) {
				if (rule.directory && !directory) continue;
				if (rule.pattern.match(rule.anchored ? local : local.substr(local.lastIndexOf("/") + 1))) result = !rule.negated;
			}
		}
		return result;
	}

	function rulesOf(file:String, scope:String):Array<Rule> {
		var known = parsed.get(file);
		if (known != null && known.generation == generation) return known.rules;
		if (!FileSystem.exists(file) || FileSystem.isDirectory(file)) {
			parsed.set(file, {stamp: "", rules: [], generation: generation});
			return [];
		}
		var stat = FileSystem.stat(file), stamp = Std.string(stat.mtime.getTime()) + ":" + stat.size;
		if (known != null && known.stamp == stamp) {
			known.generation = generation;
			return known.rules;
		}
		var rules = [];
		for (line in sys.io.File.getContent(file).split("\n")) {
			var rule = parse(line, scope);
			if (rule != null) rules.push(rule);
		}
		parsed.set(file, {stamp: stamp, rules: rules, generation: generation});
		return rules;
	}

	static function parse(line:String, scope:String):Null<Rule> {
		if (line.endsWith("\r")) line = line.substr(0, line.length - 1);
		while (line.length > 0 && line.endsWith(" ") && !line.endsWith("\\ ")) line = line.substr(0, line.length - 1);
		if (line == "" || line.startsWith("#")) return null;
		var negated = line.startsWith("!");
		if (negated) line = line.substr(1);
		var directory = line.endsWith("/");
		if (directory) line = line.substr(0, line.length - 1);
		if (line == "") return null;
		var anchored = line.indexOf("/") >= 0;
		if (line.startsWith("/")) line = line.substr(1);
		return {base: scope, pattern: new EReg("^" + glob(line) + "$", ""), anchored: anchored, directory: directory, negated: negated};
	}

	/** A gitignore glob as a regular expression over a `/` separated path. */
	static function glob(pattern:String):String {
		var out = new StringBuf(), i = 0, n = pattern.length;
		while (i < n) {
			var c = pattern.charAt(i);
			switch c {
				case "*":
					if (pattern.charAt(i + 1) == "*") {
						var before = i == 0 || pattern.charAt(i - 1) == "/", after = i + 2 >= n || pattern.charAt(i + 2) == "/";
						if (before && after) {
							if (i + 2 >= n) out.add(".*");
							else { out.add("(?:.*/)?"); i++; }
							i += 2;
							continue;
						}
						i++;
					}
					out.add("[^/]*");
				case "?": out.add("[^/]");
				case "[":
					var close = pattern.indexOf("]", i + 2);
					if (close < 0) out.add("\\[");
					else {
						var set = pattern.substring(i + 1, close);
						if (set.startsWith("!")) set = "^" + set.substr(1);
						out.add("[" + set.replace("\\", "\\\\") + "]");
						i = close;
					}
				case "\\":
					i++;
					if (i < n) out.add(escape(pattern.charAt(i)));
				default: out.add(escape(c));
			}
			i++;
		}
		return out.toString();
	}

	static function escape(c:String):String
		return "\\^$.|+(){}/".indexOf(c) >= 0 ? "\\" + c : c;
}
