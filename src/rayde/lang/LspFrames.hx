package rayde.lang;

import haxe.io.Bytes;

/** Streaming Content-Length frames. Sizes and offsets count UTF-8 bytes, not editor UTF-16 units. */
class LspFrames {
	public static inline var MAX_MESSAGE = 16 * 1024 * 1024;
	final header = Bytes.alloc(8192);
	var headerUsed = 0;
	var body:Null<Bytes>;
	var used = 0;
	final receive:(Dynamic, Int)->Void;

	public function new(receive:(Dynamic, Int)->Void) this.receive = receive;

	public static function frame(message:Dynamic):Bytes {
		var body = Bytes.ofString(haxe.Json.stringify(message));
		if (body.length > MAX_MESSAGE) throw "Language server message exceeds its size limit.";
		var header = Bytes.ofString('Content-Length: ${body.length}\r\n\r\n');
		var out = Bytes.alloc(header.length + body.length);
		out.blit(0,header,0,header.length); out.blit(header.length,body,0,body.length);
		return out;
	}

	public function push(bytes:Bytes, length:Int):Void {
		var at = 0;
		while (at < length) {
			if (body == null) {
				if (headerUsed == header.length) throw "Language server headers exceed their size limit.";
				header.set(headerUsed++,bytes.get(at++));
				if (headerUsed >= 2 && header.get(headerUsed-1) == 10 && (header.get(headerUsed-2) == 10 ||
					headerUsed >= 4 && header.get(headerUsed-2) == 13 && header.get(headerUsed-3) == 10 && header.get(headerUsed-4) == 13)) {
					var size:Null<Int> = null;
					for (line in header.sub(0,headerUsed).toString().split("\n")) {
						var colon = line.indexOf(":");
						if (colon >= 0 && StringTools.trim(line.substr(0,colon)).toLowerCase() == "content-length") {
							var value = StringTools.trim(line.substr(colon+1));
							if (size != null || value.length > 8 || !~/^[0-9]+$/.match(value)) throw "Invalid language server Content-Length.";
							size = Std.parseInt(value);
						}
					}
					if (size == null || size <= 0 || size > MAX_MESSAGE) throw "Invalid language server Content-Length.";
					body = Bytes.alloc(size); used = 0; headerUsed = 0;
				}
			} else {
				var count = Std.int(Math.min(length-at,body.length-used));
				body.blit(used,bytes,at,count); used += count; at += count;
				if (used == body.length) {
					var data = body; body = null; used = 0;
					var message:Dynamic = haxe.Json.parse(data.toString());
					if (message == null || !Reflect.isObject(message) || Std.isOfType(message,Array)) throw "Invalid language server JSON message.";
					receive(message,data.length);
				}
			}
		}
	}
	public function finish():Void if (headerUsed != 0 || body != null) throw "The language server ended an incomplete message.";
}
