package rayde.ext;

/** An embedded extension VM. All VM access is serialized on its owning runtime thread. */
class ExtensionHost {
	public var state(default, null) = "idle";
	public var exitCode(default, null):Null<Int>;
	final root:Null<String>;
	var handle = -1;
	var diagnostics = "";

	public function new(?root:String) {
		this.root = root;
	}

	public function running():Bool
		return state == "running";

	public function start():Void {
		stop();
		var bytes = haxe.io.Bytes.ofString(root == null ? "" : root);
		handle = openNative(bytes.getData(), bytes.length);
		if (handle < 0)
			throw "Cannot create the embedded RayScript runtime";
		exitCode = null;
		diagnostics = "";
		state = "running";
	}

	public function send(message:Dynamic):Bool {
		if (!running()) return false;
		if (message.t == "closed") return closeViewNative(handle, Std.int(message.root)) != 0;
		var bytes = haxe.io.Bytes.ofString(haxe.Json.stringify(message));
		return sendNative(handle, bytes.getData(), bytes.length) != 0;
	}

	/** Requests collection at a VM safepoint, without waiting on the UI thread. */
	public function collect():Bool
		return running() && collectNative(handle) != 0;

	public function poll():Array<Dynamic> {
		var messages:Array<Dynamic> = [];
		if (handle < 0) return messages;
		// Read status first: a completed runtime has already published its final output.
		var ended = statusNative(handle);
		var bytes = pollNative(handle);
		if (bytes != null) {
			var length = bytes.getI32(0);
			var text = bytes.sub(4, length).toBytes(length).toString();
			for (line in text.split("\n")) {
				var message:Dynamic = haxe.Json.parse(line);
				if (message.t == "error" && message.kind == "host") diagnostics = message.message;
				messages.push(message);
			}
		}
		if (ended != 0) {
			exitCode = ended == 1 ? 0 : 1;
			state = "exited";
			closeNative(handle);
			handle = -1;
		}
		return messages;
	}

	public function errors():String
		return diagnostics;

	/** Unmounts views and drops the VM and its fibers on their owning thread. */
	public function stop():Void {
		if (handle >= 0) closeNative(handle);
		handle = -1;
		state = "idle";
	}

	@:hlNative("rayscript", "runtime_open") static function openNative(root:hl.Bytes, length:Int):Int return -1;
	@:hlNative("rayscript", "runtime_send") static function sendNative(handle:Int, data:hl.Bytes, length:Int):Int return 0;
	@:hlNative("rayscript", "runtime_close_view") static function closeViewNative(handle:Int, root:Int):Int return 0;
	@:hlNative("rayscript", "runtime_collect") static function collectNative(handle:Int):Int return 0;
	@:hlNative("rayscript", "runtime_poll") static function pollNative(handle:Int):hl.Bytes return null;
	@:hlNative("rayscript", "runtime_status") static function statusNative(handle:Int):Int return 1;
	@:hlNative("rayscript", "runtime_close") static function closeNative(handle:Int):Int return 0;
}
