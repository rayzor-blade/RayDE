package rayde.sync;

/** The upload client in `rayscript.hdll`: an upload runs on its own thread and the UI polls its events. */
class NativeSync {
	public static function start(config:Dynamic):Int {
		var bytes = haxe.io.Bytes.ofString(haxe.Json.stringify(config)), id = pushStart(bytes.getData(), bytes.length);
		if (id < 0) throw "Cannot start the upload; check the folder and gateway";
		return id;
	}
	public static function poll(id:Int):Null<Array<Dynamic>> return unpack(pushPoll(id));
	static function unpack(bytes:hl.Bytes):Dynamic return bytes == null ? null : haxe.Json.parse(bytes.sub(4, bytes.getI32(0)).toBytes(bytes.getI32(0)).toString());
	@:hlNative("rayscript", "sync_push_start") static function pushStart(data:hl.Bytes, length:Int):Int return -1;
	@:hlNative("rayscript", "sync_push_poll") static function pushPoll(id:Int):hl.Bytes return null;
	@:hlNative("rayscript", "sync_push_pending") public static function pending(id:Int):Bool return false;
	@:hlNative("rayscript", "sync_push_cancel") public static function cancel(id:Int):Void {}
	@:hlNative("rayscript", "sync_push_close") public static function close(id:Int):Void {}
}
