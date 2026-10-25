package rayde.workspace.session;

import haxe.io.Bytes;

/**
 * Messages as frames on a byte stream: four bytes of length, big-endian, then UTF-8 text.
 * A page's sockets are WebSockets whose messages are queued and read by byte count, so the frames carry the boundaries.
 */
class FramedChannel implements Channel {
	static inline var MAX_MESSAGE = 16 * 1024 * 1024;

	final socket:sys.net.Socket;
	var open = true;

	public function new(socket:sys.net.Socket) {
		this.socket = socket;
		socket.input.bigEndian = true;
	}

	public static function connect(host:String, port:Int):FramedChannel {
		var socket = new sys.net.Socket();
		socket.connect(new sys.net.Host(host), port);
		return new FramedChannel(socket);
	}

	public function sendText(text:String):Void {
		var body = Bytes.ofString(text), frame = Bytes.alloc(4 + body.length);
		frame.set(0, body.length >>> 24);
		frame.set(1, (body.length >>> 16) & 0xff);
		frame.set(2, (body.length >>> 8) & 0xff);
		frame.set(3, body.length & 0xff);
		frame.blit(4, body, 0, body.length);
		// One write, so a host that sends each write as a message sends the frame whole.
		socket.output.write(frame);
		socket.output.flush();
	}

	public function receive(seconds:Float):Null<String> {
		if (!open) throw "The session connection is closed.";
		if (sys.net.Socket.select([socket], null, null, seconds).read.length == 0) return null;
		try {
			var length = socket.input.readInt32();
			if (length < 0 || length > MAX_MESSAGE) throw "A message from the session is too large.";
			return length == 0 ? "" : socket.input.read(length).toString();
		} catch (_:haxe.io.Eof) {
			open = false;
			throw "The session closed the connection.";
		}
	}

	public function close():Void {
		open = false;
		try socket.close() catch (_:Dynamic) {}
	}
}
