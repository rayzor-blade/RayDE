package rayde.ui;

/** Extra codecs decode on one native worker; closing a view drops queued input and its eventual result. */
class RasterDecode {
	public static function start(bytes:haxe.io.Bytes, avif:Bool, done:(Null<haxe.io.Bytes>, Null<String>)->Void):Void->Void {
		var handle = openNative(bytes.getData(), bytes.length, avif), alive = true;
		var timer:ashui.animation.AnimationScheduler.Timer = null;
		function cancel():Void {
			alive = false;
			if (timer != null) timer.cancel();
			if (handle >= 0) closeNative(handle);
			handle = -1;
		}
		if (handle < 0) { done(null, "Unable to start image decoder"); return cancel; }
		var poll:Void->Void = null;
		poll = () -> {
			timer = null;
			if (!alive) return;
			var result = pollNative(handle);
			if (result == null) { timer = ashui.animation.AnimationScheduler.main.after(.016, poll); return; }
			var status = result.getI32(0), length = result.getI32(4);
			cancel();
			if (length < 0) { done(null, "Invalid image response"); return; }
			var payload = result.sub(8, length).toBytes(length);
			if (status == 1) done(payload, null); else done(null, payload.toString());
		};
		timer = ashui.animation.AnimationScheduler.main.after(.016, poll);
		return cancel;
	}

	@:hlNative("rayscript", "image_open") static function openNative(bytes:hl.Bytes, length:Int, avif:Bool):Int return -1;
	@:hlNative("rayscript", "image_poll") static function pollNative(handle:Int):hl.Bytes return null;
	@:hlNative("rayscript", "image_close") static function closeNative(handle:Int):Void {}
}
