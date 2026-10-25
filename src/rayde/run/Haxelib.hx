package rayde.run;

import rayde.workspace.Procs;

using StringTools;

/** A library haxelib has, and the version it uses. */
typedef Lib = {name:String, version:String};

/**
 * haxelib as the Libraries page uses it: what is installed, asked for once and again after a change, and
 * installing, updating and removing as jobs that run in the background. `RAYDE_HAXELIB` names another
 * command in its place, which a test points at a stand-in.
 */
class Haxelib {
	static var cache:Null<Array<Lib>> = null;
	static var pending:Null<ash.Future<Array<Lib>>>;
	static var generation = 0;
	static final mutex = new sys.thread.Mutex();

	public static function command():String {
		var named = Sys.getEnv("RAYDE_HAXELIB");
		return named == null || named == "" ? "haxelib" : named;
	}

	/** The libraries haxelib has, each with the version it uses. */
	public static function installed():Array<Lib> return installedAsync().await();

	/** Concurrent readers share one background query; rendering need not wait for haxelib. */
	public static function installedAsync():ash.Future<Array<Lib>> {
		mutex.acquire();
		if (cache != null) { var ready = new ash.Future<Array<Lib>>(); ready.resolve(cache); mutex.release(); return ready; }
		if (pending != null) { var known = pending; mutex.release(); return known; }
		var future = pending = new ash.Future<Array<Lib>>(), version = generation;
		mutex.release();
		sys.thread.Thread.create(() -> {
			var libraries = try parse(output(["list"])) catch (_:Dynamic) [];
			mutex.acquire();
			if (generation == version) { cache = libraries; pending = null; }
			mutex.release(); future.resolve(libraries);
		});
		return future;
	}

	/** Forgets the previous query; an older in-flight reply cannot replace a fresh catalog. */
	public static function refresh():Void {
		mutex.acquire(); generation++; cache = null; pending = null; mutex.release();
	}

	/** The libraries `haxelib list` printed: a name, a colon, then versions with the one in use in brackets. */
	public static function parse(text:String):Array<Lib> {
		var libs = [];
		for (line in text.split("\n")) {
			var colon = line.indexOf(":");
			if (colon <= 0 || line.substr(0, colon).indexOf(" ") >= 0)
				continue;
			var open = line.indexOf("["), close = line.indexOf("]");
			var version = open > colon && close > open ? line.substring(open + 1, close) : "";
			libs.push({name: line.substr(0, colon), version: version.startsWith("dev:") ? "dev" : version});
		}
		return libs;
	}

	static function output(args:Array<String>):String {
		var p = Procs.start(command(), args);
		var text = p.stdout.readAll().toString();
		p.close();
		return text;
	}

	/** A job that installs `name`, at `version` when one is given. It is not started. */
	public static function install(root:String, name:String, version:String):Job
		return job(root, ["--always", "install", name].concat(version == "" ? [] : [version]));

	public static function update(root:String, name:String):Job
		return job(root, ["--always", "update", name]);

	public static function remove(root:String, name:String):Job
		return job(root, ["remove", name]);

	static function job(root:String, args:Array<String>):Job
		return new Job(command(), args, haxe.io.Path.join([root, ".rayde", "run", "haxelib.log"]));
}
