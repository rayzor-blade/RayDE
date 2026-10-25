package rayde.history;

import rayde.workspace.Fs;
import haxe.io.Path;
import rayde.history.LineOwners.OwnedText;

typedef GitRevision = {id:String, label:String, author:String};
typedef GitFileHistory = {root:String, path:String, head:String, revisions:Array<GitRevision>, current:OwnedText};

/** Read-only Git work. Call on a worker; subprocess output is redirected, bounded and cancellable. */
class GitHistory {
	public static inline var MAX_BYTES = 8 * 1024 * 1024;
	static var serial = 0;
	static final mutex = new sys.thread.Mutex();

	public static function command(cwd:String, args:Array<String>, cancelled:Void->Bool):String {
		if (cancelled())
			throw "Cancelled";
		mutex.acquire();
		var number = ++serial;
		mutex.release();
		var tmp = Sys.getEnv("TMPDIR") ?? Sys.getEnv("TEMP") ?? "/tmp";
		var log = Path.join([tmp, "rayde-history-" + Std.string(Sys.time()) + "-" + number]);
		var windows = Sys.systemName() == "Windows";
		var quote = windows ? (s:String) -> haxe.SysTools.quoteWinArg(s, true) : (s:String) -> "'" + StringTools.replace(s, "'", "'\\''") + "'";
		var line = [
			"git",
			"--no-pager",
			"-c",
			"color.ui=false",
			"-c",
			"core.quotepath=false",
			"-C",
			cwd
		].concat(args).map(quote).join(" ") + " < " + (windows ? "NUL" : "/dev/null") + " > " + quote(log) + " 2>&1";
		var process:sys.io.Process = null, result = "", failure:Dynamic = null;
		try {
			process = new sys.io.Process(windows ? "cmd.exe" : "/bin/sh", windows ? ["/d", "/s", "/c", line] : ["-c", "exec " + line]);
			var until = haxe.Timer.stamp() + 12., code:Null<Int>;
			while ((code = process.exitCode(false)) == null) {
				if (cancelled() || haxe.Timer.stamp() > until)
					throw cancelled() ? "Cancelled" : "Git history timed out";
				if (Fs.exists(log) && Fs.stat(log).size > MAX_BYTES)
					throw "File history exceeds the preview size limit";
				Sys.sleep(.015);
			}
			if (Fs.exists(log)) {
				if (Fs.stat(log).size > MAX_BYTES)
					throw "File history exceeds the preview size limit";
				result = Fs.getContent(log);
			}
			if (code != 0)
				throw StringTools.trim(result);
		} catch (error:Dynamic)
			failure = error;
		if (process != null) {
			try {
				if (process.exitCode(false) == null)
					process.kill();
			} catch (_:Dynamic) {}
			try
				process.close()
			catch (_:Dynamic) {}
		}
		if (Fs.exists(log))
			try
				Fs.deleteFile(log)
			catch (_:Dynamic) {}
		if (failure != null)
			throw failure;
		return result;
	}

	public static function load(file:String, cancelled:Void->Bool):Null<GitFileHistory> {
		var cwd = Path.directory(file), root:String;
		try
			root = StringTools.trim(command(cwd, ["rev-parse", "--show-toplevel"], cancelled))
		catch (_:Dynamic)
			return null;
		var path = Path.normalize(file).substr(Path.normalize(root).length + 1);
		var head:String;
		try
			head = StringTools.trim(command(root, ["rev-parse", "HEAD"], cancelled))
		catch (_:Dynamic)
			return null;
		var revisions:Array<GitRevision> = [];
		for (line in command(root, ["log", "-40", "--format=%H%x09%an%x09%s", "--", path], cancelled).split("\n")) {
			var fields = line.split("\t");
			if (fields.length >= 3 && valid(fields[0]))
				revisions.push({id: fields[0], author: fields[1], label: fields[0].substr(0, 7) + " · " + fields.slice(2).join(" ").substr(0, 90)});
		}
		var current:OwnedText;
		try
			current = read(root, path, head, cancelled)
		catch (_:Dynamic)
			return null; // untracked or absent at HEAD
		return {
			root: root,
			path: path,
			head: head,
			revisions: revisions,
			current: current
		};
	}

	public static function valid(id:String):Bool
		return ~/^[a-fA-F0-9]{40,64}$/.match(id);

	public static function read(root:String, path:String, id:String, cancelled:Void->Bool):OwnedText {
		if (!valid(id))
			throw "Invalid Git revision";
		var text = command(root, ["show", id + ":" + path], cancelled);
		if (text.indexOf("\x00") >= 0)
			throw "This revision contains binary data";
		var blame = command(root, ["blame", "--line-porcelain", id, "--", path], cancelled);
		return {text: text, owners: parseBlame(blame, text.split("\n").length)};
	}

	public static function parseBlame(porcelain:String, count:Int):Array<Null<String>> {
		var owners:Array<Null<String>> = [for (_ in 0...count) null], author:Null<String> = null, at = -1;
		var header = ~/^[a-fA-F0-9]{40,64} [0-9]+ ([0-9]+)(?: [0-9]+)?$/;
		for (line in porcelain.split("\n")) {
			if (header.match(line)) {
				at = Std.parseInt(header.matched(1)) - 1;
				author = null;
			} else if (StringTools.startsWith(line, "author "))
				author = line.substr(7);
			else if (StringTools.startsWith(line, "\t") && at >= 0 && at < count)
				owners[at] = author;
		}
		return owners;
	}
}
