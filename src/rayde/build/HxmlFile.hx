package rayde.build;

import rayde.workspace.Fs;

using StringTools;

/** One line of a build file as it is written, and what it says when it is an argument. */
private typedef Line = {text:String, flag:Null<String>, value:Null<String>};

/**
 * A build file open for editing. Lines are kept as they were written, so
 * comments, blank lines, order and any argument this model does not know all
 * survive an edit; an edit changes, adds or removes only the lines it names.
 * Only the first compilation is edited, the lines before a `--next`.
 *
 * Flags are known by one name each: `-cp`, `-lib`, `-D`, `--main`, `--debug`
 * and `--dce`, `--hl` for a target, whichever of the compiler's spellings the
 * file uses.
 */
class HxmlFile {
	/** The compilers' targets a build can name, with the one that takes no output last. */
	public static final targets = ["hl", "js", "cpp", "cppia", "neko", "lua", "php", "python", "java", "jvm", "cs", "swf", "interp"];

	/** The flags the form manages; every other argument is listed apart and kept as written. */
	public static final managed = ["-cp", "-lib", "-D", "--main", "--debug", "--dce", "--no-traces", "--no-inline"].concat([for (t in targets) "--" + t]);

	static final names = ["main" => "--main", "m" => "--main", "class-path" => "-cp", "cp" => "-cp", "library" => "-lib", "lib" => "-lib", "define" => "-D", "D" => "-D"];
	static final longs = ["debug", "dce", "no-traces", "no-inline", "next", "each", "macro", "w", "xml", "dll-import"].concat(targets);

	public final path:String;

	var lines:Array<Line> = [];

	public function new(path:String, text:String) {
		this.path = path;
		for (raw in text.split("\n"))
			lines.push(parseLine(raw));
	}

	public static function read(path:String):HxmlFile
		return new HxmlFile(path, Fs.getContent(path));

	static function parseLine(raw:String):Line {
		var line = raw.trim();
		if (line == "" || line.startsWith("#") || !line.startsWith("-"))
			return {text: raw, flag: null, value: null};
		var space = line.indexOf(" "), tab = line.indexOf("\t");
		if (space < 0 || tab >= 0 && tab < space)
			space = tab;
		var word = space < 0 ? line : line.substr(0, space);
		var value = space < 0 ? null : unquote(line.substr(space + 1).trim());
		return {text: raw, flag: canonical(word), value: value};
	}

	/** The one name this model uses for the flag written as `word`, whichever of the compiler's spellings it is. */
	static function canonical(word:String):String {
		var bare = word.startsWith("--") ? word.substr(2) : word.substr(1);
		if (names.exists(bare))
			return names.get(bare);
		if (longs.indexOf(bare) >= 0)
			return "--" + bare;
		return word;
	}

	static function unquote(s:String):String
		return s.length >= 2 && (s.startsWith('"') && s.endsWith('"') || s.startsWith("'") && s.endsWith("'")) ? s.substr(1, s.length - 2) : s;

	static function quote(s:String):String
		return s.indexOf(" ") >= 0 ? '"' + s + '"' : s;

	static function write(flag:String, value:Null<String>):String
		return value == null ? flag : flag + " " + quote(value);

	/** Where the first compilation ends: the line of the first `--next`, or the end of the file. */
	function end():Int {
		for (i => l in lines)
			if (l.flag == "--next")
				return i;
		return lines.length;
	}

	/** Whether the file holds more than one compilation, of which only the first is edited. */
	public function multiple():Bool
		return end() < lines.length;

	/** The values of every line with `flag`, in order. */
	public function values(flag:String):Array<String>
		return [for (i in 0...end()) if (lines[i].flag == flag) lines[i].value == null ? "" : lines[i].value];

	public function value(flag:String):Null<String> {
		for (i in 0...end())
			if (lines[i].flag == flag)
				return lines[i].value;
		return null;
	}

	public function has(flag:String):Bool {
		for (i in 0...end())
			if (lines[i].flag == flag)
				return true;
		return false;
	}

	/** Where a new line goes: after the last argument of the first compilation, before any blank lines that end it. */
	function insertion():Int {
		var at = end();
		while (at > 0 && lines[at - 1].text.trim() == "")
			at--;
		return at;
	}

	function put(flag:String, value:Null<String>):Void {
		var text = write(flag, value);
		lines.insert(insertion(), {text: text, flag: flag, value: value});
	}

	/** Adds a line with `flag` and `value`, unless there already is one just like it. */
	public function add(flag:String, ?value:String):Void {
		for (i in 0...end())
			if (lines[i].flag == flag && lines[i].value == value)
				return;
		put(flag, value);
	}

	/** Makes `value` the only one for `flag`: the first line is rewritten and the others go; none when `value` is null. */
	public function set(flag:String, value:Null<String>):Void {
		var found = -1, i = 0;
		while (i < end()) {
			if (lines[i].flag == flag) {
				if (found < 0 && value != null) {
					found = i;
					lines[i] = {text: write(flag, value), flag: flag, value: value};
				} else {
					lines.splice(i, 1);
					continue;
				}
			}
			i++;
		}
		if (found < 0 && value != null)
			put(flag, value);
	}

	/** Turns a flag that takes no value on or off. */
	public function setSwitch(flag:String, on:Bool):Void {
		if (on)
			add(flag);
		else
			set(flag, null);
	}

	/** Removes the first line with `flag` and `value`. */
	public function remove(flag:String, ?value:String):Void {
		for (i in 0...end())
			if (lines[i].flag == flag && lines[i].value == value) {
				lines.splice(i, 1);
				return;
			}
	}

	/** The target the build names and where it writes, or null for neither. */
	public function target():Null<{kind:String, output:Null<String>}> {
		for (i in 0...end())
			if (lines[i].flag != null && lines[i].flag.startsWith("--") && targets.indexOf(lines[i].flag.substr(2)) >= 0)
				return {kind: lines[i].flag.substr(2), output: lines[i].value};
		return null;
	}

	/** Makes the build's target `kind` writing to `output`, replacing whichever it named. */
	public function setTarget(kind:String, output:Null<String>):Void {
		for (t in targets)
			if (t != kind)
				set("--" + t, null);
		set("--" + kind, kind == "interp" ? null : output);
	}

	/** The arguments of the first compilation that the form does not manage, with their lines, for listing and removing. */
	public function others():Array<{index:Int, text:String}> {
		var out = [];
		for (i in 0...end()) {
			var l = lines[i], t = l.text.trim();
			if (t == "" || t.startsWith("#"))
				continue;
			if (l.flag == null || managed.indexOf(l.flag) < 0)
				out.push({index: i, text: t});
		}
		return out;
	}

	public function removeLine(index:Int):Void
		if (index >= 0 && index < lines.length)
			lines.splice(index, 1);

	public function text():String
		return [for (l in lines) l.text].join("\n");

	public function save():Void
		Fs.saveContent(path, text());
}
