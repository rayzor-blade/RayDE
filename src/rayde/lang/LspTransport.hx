package rayde.lang;

/** Nonblocking caller API; process launch, framed pipe I/O and reaping run on native workers. */
class LspTransport {
	var handle = -1;
	var session:Null<SessionLspTransport>;

	public function new(config:Dynamic) {
		var launcher = rayde.workspace.Procs.current;
		if (Std.isOfType(launcher,rayde.workspace.session.SessionLauncher)) {
			session = new SessionLspTransport(cast launcher,config);
			return;
		}
		#if wasm
		throw "Connect to a workspace session with execution enabled to start a language server.";
		#else
		var bytes = haxe.io.Bytes.ofString(haxe.Json.stringify(config));
		handle = openNative(bytes.getData(), bytes.length);
		if (handle < 0) throw "Cannot start language server transport";
		#end
	}

	public function send(message:Dynamic):Bool {
		if (session != null) return session.send(message);
		if (handle < 0) return false;
		var bytes = haxe.io.Bytes.ofString(haxe.Json.stringify(message));
		return sendNative(handle, bytes.getData(), bytes.length);
	}

	public function poll():Null<Array<Dynamic>> {
		if (session != null) return session.poll();
		var bytes = handle < 0 ? null : pollNative(handle);
		return bytes == null ? null : haxe.Json.parse(bytes.sub(4, bytes.getI32(0)).toBytes(bytes.getI32(0)).toString());
	}

	public function close():Void {
		if (session != null) { session.close(); session = null; }
		if (handle >= 0) closeNative(handle);
		handle = -1;
	}

	public function pending():Bool return session != null ? session.pending() : handle >= 0 && pendingNative(handle);
	public function canWake():Bool return session != null ? session.canWake() : handle >= 0 && canWakeNative(handle);
	public function connected():Bool return session == null || session.connected();
	public static function available():Bool {
		var launcher = rayde.workspace.Procs.current;
		return !Std.isOfType(launcher,rayde.workspace.session.SessionLauncher) || (cast launcher:rayde.workspace.session.SessionLauncher).client.isOnline();
	}

	@:hlNative("rayscript", "lsp_open") static function openNative(data:hl.Bytes, length:Int):Int return -1;
	@:hlNative("rayscript", "lsp_send") static function sendNative(handle:Int, data:hl.Bytes, length:Int):Bool return false;
	@:hlNative("rayscript", "lsp_poll") static function pollNative(handle:Int):hl.Bytes return null;
	@:hlNative("rayscript", "lsp_close") static function closeNative(handle:Int):Void {}
	@:hlNative("rayscript", "lsp_pending") static function pendingNative(handle:Int):Bool return false;
	@:hlNative("rayscript", "lsp_can_wake") static function canWakeNative(handle:Int):Bool return false;
}
