package rayde.workspace;

/** Programs run as processes of this one. */
class LocalLauncher implements Launcher {
	public function new() {}

	public function start(command:String, args:Array<String>):Program
		return new LocalProgram(new sys.io.Process(command, args));
}

private class LocalProgram implements Program {
	public var stdout(default, null):haxe.io.Input;
	public var stderr(default, null):haxe.io.Input;
	public var stdin(default, null):haxe.io.Output;
	final process:sys.io.Process;

	public function new(process:sys.io.Process) {
		this.process = process;
		stdout = process.stdout;
		stderr = process.stderr;
		stdin = process.stdin;
	}

	public function exitCode(block:Bool = true):Null<Int> return process.exitCode(block);
	public function kill():Void process.kill();
	public function close():Void process.close();
}
