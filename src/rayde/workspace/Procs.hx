package rayde.workspace;

/** RayDE's calls to start programs, answered by the current `Launcher`. */
class Procs {
	/** Replaced at startup by a program that runs somewhere other than the machine its programs are on. */
	public static var current:Launcher = new LocalLauncher();

	public static inline function start(command:String, args:Array<String>):Program return current.start(command, args);

	/** Runs `command` to its end and returns what it printed and how it ended. */
	public static function run(command:String, args:Array<String>):{code:Int, out:String, err:String} {
		var program = current.start(command, args);
		try {
			var out = program.stdout.readAll().toString(), err = program.stderr.readAll().toString(), code = program.exitCode();
			program.close();
			return {code: code, out: out, err: err};
		} catch (e:Dynamic) {
			try program.close() catch (_:Dynamic) {}
			throw e;
		}
	}
}
