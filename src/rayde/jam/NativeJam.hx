package rayde.jam;

/** Owned messages cross the native boundary; network work never enters the UI thread. */
class NativeJam {
	public static function document(text:String):Int {
		var bytes = haxe.io.Bytes.ofString(text), id = docOpen(bytes.getData(),bytes.length);
		if (id < 0) throw "Cannot create Jam document (maximum 1 MiB)";
		return id;
	}
	public static function call(id:Int,message:Dynamic):Dynamic {
		var bytes = haxe.io.Bytes.ofString(haxe.Json.stringify(message)), result = unpack(docCall(id,bytes.getData(),bytes.length));
		if (result == null) throw "Jam document operation failed";
		if (result.error != null) throw Std.string(result.error);
		return result;
	}
	public static function open(config:Dynamic):Int {
		var bytes = haxe.io.Bytes.ofString(haxe.Json.stringify(config)), id = sessionOpen(bytes.getData(),bytes.length);
		if (id < 0) throw "Cannot start local Jam; check the invitation and document size";
		return id;
	}
	public static function send(id:Int,message:Dynamic):Bool {
		var bytes = haxe.io.Bytes.ofString(haxe.Json.stringify(message));
		return sessionSend(id,bytes.getData(),bytes.length);
	}
	public static function poll(id:Int):Null<Array<Dynamic>> return unpack(sessionPoll(id));
	static function unpack(bytes:hl.Bytes):Dynamic return bytes == null ? null : haxe.Json.parse(bytes.sub(4,bytes.getI32(0)).toBytes(bytes.getI32(0)).toString());
	@:hlNative("rayscript","jam_document_open") static function docOpen(data:hl.Bytes,length:Int):Int return -1;
	@:hlNative("rayscript","jam_document_call") static function docCall(id:Int,data:hl.Bytes,length:Int):hl.Bytes return null;
	@:hlNative("rayscript","jam_document_close") public static function closeDocument(id:Int):Void {}
	@:hlNative("rayscript","jam_session_open") static function sessionOpen(data:hl.Bytes,length:Int):Int return -1;
	@:hlNative("rayscript","jam_session_send") static function sessionSend(id:Int,data:hl.Bytes,length:Int):Bool return false;
	@:hlNative("rayscript","jam_session_poll") static function sessionPoll(id:Int):hl.Bytes return null;
	@:hlNative("rayscript","jam_session_pending") public static function pending(id:Int):Bool return false;
	@:hlNative("rayscript","jam_session_can_wake") public static function canWake(id:Int):Bool return false;
	@:hlNative("rayscript","jam_session_close") public static function closeSession(id:Int):Void {}
}
