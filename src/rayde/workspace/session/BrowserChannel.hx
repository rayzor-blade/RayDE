package rayde.workspace.session;

#if wasm
import haxe.io.Bytes;

/** Whole frames over bounded rings. The session receiver awaits Ash futures instead of polling. */
class BrowserChannel implements Channel {
	final channel:ash.channel.Channel;

	var current:Null<Bytes>;
	var offset = 0;
	final header = Bytes.alloc(4);
	var headerUsed = 0;
	var payload:Null<Bytes>;
	var used = 0;
	static inline var MAX = 16 * 1024 * 1024;

	public function new() {
		channel = ash.channel.Channel.open("rayde_session");
	}

	public function sendText(text:String):Void {
		var bytes = Bytes.ofString(text);
		if (bytes.length > MAX) throw "The session message is too large.";
		var framed = Bytes.alloc(4 + bytes.length);
		framed.set(0, bytes.length >>> 24); framed.set(1, bytes.length >>> 16); framed.set(2, bytes.length >>> 8); framed.set(3, bytes.length);
		framed.blit(4, bytes, 0, bytes.length);
		var at = 0;
		while (at < framed.length) {
			var count = Std.int(Math.min(16384, framed.length - at));
			channel.send(framed.sub(at, count)); at += count;
		}
	}

	public function receive(seconds:Float):Null<String> {
		while (true) {
			if (current == null) { current = channel.recv(); offset = 0; }
			if (current != null) {
				if (headerUsed < 4) {
					var count = Std.int(Math.min(4 - headerUsed, current.length - offset));
					header.blit(headerUsed, current, offset, count); headerUsed += count; offset += count;
					if (headerUsed == 4) {
						var expected = header.get(0) << 24 | header.get(1) << 16 | header.get(2) << 8 | header.get(3);
						if (expected < 0 || expected > MAX) { close(); throw "The session message is too large."; }
						payload = Bytes.alloc(expected); used = 0;
					}
				}
				if (payload != null) {
					var count = Std.int(Math.min(payload.length - used, current.length - offset));
					payload.blit(used, current, offset, count); used += count; offset += count;
					if (used == payload.length) {
						var text = payload.toString(); payload = null; headerUsed = 0;
						if (offset == current.length) current = null;
						return text;
					}
				}
				if (offset == current.length) current = null;
				continue;
			}
		}
		return null;
	}

	public function close():Void channel.close();
}
#end
