package rayde.ext;

/** Script-only VMs stay embedded; native extensions use an individually supervised process. */
class ExtensionHost {
	public var state(default, null) = "idle";
	public var exitCode(default, null):Null<Int>;
	public var processId(default, null):Null<Int>;
	public final isolated:Bool;
	final root:Null<String>;
	final extension:String;
	var handle = -1;
	var diagnostics = "";
	var lines:Array<String> = [];
	var nextLine = 0;

	public function new(?root:String, isolated = false, extension = "") {
		this.root = root;
		this.isolated = isolated;
		this.extension = extension;
	}

	public function running():Bool
		return state == "running";

	public function pending():Bool return nextLine < lines.length || handle >= 0 && (isolated ? processPending(handle) : pendingNative(handle));
	public function canWake():Bool return handle >= 0 && (isolated ? processCanWake(handle) : canWakeNative(handle));

	public function start():Void {
		stop();
		var bytes = haxe.io.Bytes.ofString(isolated ? haxe.Json.stringify({binary:hostBinary(),root:root ?? "",extension:extension}) : root ?? "");
		handle = isolated ? processOpen(bytes.getData(),bytes.length) : openNative(bytes.getData(), bytes.length);
		if (handle < 0)
			throw "Cannot create the RayScript extension host";
		exitCode = null;
		processId = null;
		diagnostics = "";
		state = "running";
	}

	public function send(message:Dynamic):Bool {
		if (!running()) return false;
		if (!isolated && message.t == "closed") return closeViewNative(handle, Std.int(message.root)) != 0;
		var bytes = haxe.io.Bytes.ofString(haxe.Json.stringify(message));
		return isolated ? processSend(handle,bytes.getData(),bytes.length) : sendNative(handle, bytes.getData(), bytes.length) != 0;
	}

	/** Requests collection at a VM safepoint, without waiting on the UI thread. */
	public function collect():Bool
		return running() && (isolated ? send({t:"collect"}) : collectNative(handle) != 0);

	public function poll():Array<Dynamic> {
		var messages:Array<Dynamic> = [];
		if (handle < 0) return messages;
		// Read status first: a completed runtime has already published its final output.
		var ended = isolated ? processStatus(handle) : statusNative(handle);
		var timing = Timing.start();
		var fetched = nextLine == lines.length;
		var bytes = fetched ? (isolated ? processPoll(handle) : pollNative(handle)) : null;
		if (Timing.enabled) Timing.end(timing, "transport.poll");
		if (bytes != null) {
			timing = Timing.start();
			var length = bytes.getI32(0);
			var text = bytes.sub(4, length).toBytes(length).toString();
			lines = text.split("\n"); nextLine = 0;
			if (Timing.enabled) Timing.end(timing, "transport.copy", {bytes:length});
		}
		timing = Timing.start();
		var deadline = haxe.Timer.stamp() + .004;
		while (nextLine < lines.length) {
			var message:Dynamic = haxe.Json.parse(lines[nextLine++]);
			if (isolated && message.t == "ready") processId = message.pid;
			if (message.t == "error" && message.kind == "host") diagnostics = message.message;
			messages.push(message);
			if (haxe.Timer.stamp() >= deadline) break;
		}
		if (Timing.enabled) Timing.end(timing, "transport.decode", {messages:messages.length});
		if (ended != 0 && fetched && bytes == null && nextLine == lines.length) {
			exitCode = ended == 1 ? 0 : 1;
			state = "exited";
			if (isolated) processClose(handle); else closeNative(handle);
			handle = -1;
		}
		return messages;
	}

	public function errors():String
		return diagnostics;

	/** Requests cleanup without waiting; an isolated host is forcibly reaped if cleanup stalls. */
	public function stop():Void {
		if (handle >= 0) { if (isolated) processClose(handle); else closeNative(handle); }
		handle = -1;
		processId = null;
		lines = []; nextLine = 0;
		state = "idle";
	}

	static function hostBinary():String {
		// Resolve beside the program, never through a workspace-controlled PATH or current directory.
		var name = Sys.systemName() == "Windows" ? "rayde-extension-host.exe" : "rayde-extension-host";
		var program = haxe.io.Path.directory(sys.FileSystem.fullPath(Sys.programPath()));
		for (path in [program + "/" + name, program + "/../Resources/" + name])
			if (sys.FileSystem.exists(path) && !sys.FileSystem.isDirectory(path)) return sys.FileSystem.fullPath(path);
		throw "The packaged native extension host is missing: " + name;
	}

	@:hlNative("rayscript", "extension_open") static function processOpen(data:hl.Bytes, length:Int):Int return -1;
	@:hlNative("rayscript", "extension_send") static function processSend(handle:Int, data:hl.Bytes, length:Int):Bool return false;
	@:hlNative("rayscript", "extension_poll") static function processPoll(handle:Int):hl.Bytes return null;
	@:hlNative("rayscript", "extension_status") static function processStatus(handle:Int):Int return 1;
	@:hlNative("rayscript", "extension_pending") static function processPending(handle:Int):Bool return false;
	@:hlNative("rayscript", "extension_can_wake") static function processCanWake(handle:Int):Bool return false;
	@:hlNative("rayscript", "extension_close") static function processClose(handle:Int):Void {}

	@:hlNative("rayscript", "runtime_open") static function openNative(root:hl.Bytes, length:Int):Int return -1;
	@:hlNative("rayscript", "runtime_send") static function sendNative(handle:Int, data:hl.Bytes, length:Int):Int return 0;
	@:hlNative("rayscript", "runtime_close_view") static function closeViewNative(handle:Int, root:Int):Int return 0;
	@:hlNative("rayscript", "runtime_collect") static function collectNative(handle:Int):Int return 0;
	@:hlNative("rayscript", "runtime_poll") static function pollNative(handle:Int):hl.Bytes return null;
	@:hlNative("rayscript", "runtime_status") static function statusNative(handle:Int):Int return 1;
	@:hlNative("rayscript", "runtime_close") static function closeNative(handle:Int):Int return 0;
	@:hlNative("rayscript", "runtime_pending") static function pendingNative(handle:Int):Bool return false;
	@:hlNative("rayscript", "runtime_can_wake") static function canWakeNative(handle:Int):Bool return false;
}
