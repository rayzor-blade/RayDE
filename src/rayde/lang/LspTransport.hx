package rayde.lang;

/** Nonblocking caller API; process launch, framed pipe I/O and reaping run on native workers. */
class LspTransport {
	var handle:Int;

	public function new(config:Dynamic) {
		var bytes = haxe.io.Bytes.ofString(haxe.Json.stringify(config));
		handle = openNative(bytes.getData(), bytes.length);
		if (handle < 0) throw "Cannot start language server transport";
	}

	public function send(message:Dynamic):Bool {
		if (handle < 0) return false;
		var bytes = haxe.io.Bytes.ofString(haxe.Json.stringify(message));
		return sendNative(handle, bytes.getData(), bytes.length);
	}

	public function poll():Array<Dynamic> {
		var bytes = handle < 0 ? null : pollNative(handle);
		return bytes == null ? [] : haxe.Json.parse(bytes.sub(4, bytes.getI32(0)).toBytes(bytes.getI32(0)).toString());
	}

	public function close():Void {
		if (handle >= 0) closeNative(handle);
		handle = -1;
	}

	@:hlNative("rayscript", "lsp_open") static function openNative(data:hl.Bytes, length:Int):Int return -1;
	@:hlNative("rayscript", "lsp_send") static function sendNative(handle:Int, data:hl.Bytes, length:Int):Bool return false;
	@:hlNative("rayscript", "lsp_poll") static function pollNative(handle:Int):hl.Bytes return null;
	@:hlNative("rayscript", "lsp_close") static function closeNative(handle:Int):Void {}
}
