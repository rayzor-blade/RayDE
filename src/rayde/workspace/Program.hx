package rayde.workspace;

/** A program that is running, shaped as `sys.io.Process` is: reads block until there is something to read. */
interface Program {
	var stdout(default, null):haxe.io.Input;
	var stderr(default, null):haxe.io.Input;
	var stdin(default, null):haxe.io.Output;
	/** The exit code once the program has ended; with `block` false, null while it runs. */
	function exitCode(block:Bool = true):Null<Int>;
	function kill():Void;
	function close():Void;
}
