package rayde.workspace;

/** Where programs cannot run: a page with no session. A program started here has already ended, as one that is not installed has: exit 127 and a sentence on stderr. */
class NoLauncher implements Launcher {
	public function new() {}

	public function start(command:String, args:Array<String>):Program
		return new Ended(127, "", "Cannot run " + command + ": programs run in a session, and this page has none.\n");
}

private class Ended implements Program {
	public var stdout(default, null):haxe.io.Input;
	public var stderr(default, null):haxe.io.Input;
	public var stdin(default, null):haxe.io.Output = new haxe.io.BytesOutput();
	final code:Int;

	public function new(code:Int, out:String, err:String) {
		this.code = code;
		stdout = new haxe.io.BytesInput(haxe.io.Bytes.ofString(out));
		stderr = new haxe.io.BytesInput(haxe.io.Bytes.ofString(err));
	}

	public function exitCode(block:Bool = true):Null<Int> return code;
	public function kill():Void {}
	public function close():Void {}
}
