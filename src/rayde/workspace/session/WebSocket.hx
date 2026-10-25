package rayde.workspace.session;

import haxe.crypto.Base64;
import haxe.crypto.Sha1;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/** A WebSocket client over a plain socket, for talking to a session from a program that is not in a page. Text messages only. */
class WebSocket {
	static inline var GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
	/** The largest message accepted, in bytes. */
	static inline var MAX_MESSAGE = 16 * 1024 * 1024;

	final socket:sys.net.Socket;
	var open = true;

	function new(socket:sys.net.Socket) {
		this.socket = socket;
		socket.input.bigEndian = true;
		socket.output.bigEndian = true;
	}

	public static function connect(host:String, port:Int, path:String):WebSocket {
		var socket = new sys.net.Socket();
		socket.connect(new sys.net.Host(host), port);
		var key = Base64.encode(Bytes.ofString([for (_ in 0...16) String.fromCharCode(33 + Std.random(90))].join("")));
		socket.output.writeString('GET $path HTTP/1.1\r\nHost: $host:$port\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n\r\n');
		socket.output.flush();
		// One byte at a time, so nothing after the headers is taken from the first message.
		var head = new StringBuf(), text = "";
		while (!StringTools.endsWith(text, "\r\n\r\n")) {
			head.addChar(socket.input.readByte());
			text = head.toString();
			if (text.length > 16384) throw "The server's answer is not an HTTP response.";
		}
		var lines = text.split("\r\n");
		if (lines[0].indexOf(" 101 ") < 0) throw "The server did not open a WebSocket: " + lines[0];
		var accepted = Base64.encode(Sha1.make(Bytes.ofString(key + GUID)));
		var ok = false;
		for (line in lines) if (StringTools.startsWith(line.toLowerCase(), "sec-websocket-accept:") && StringTools.trim(line.substr(line.indexOf(":") + 1)) == accepted) ok = true;
		if (!ok) throw "The server's WebSocket answer is not for this request.";
		return new WebSocket(socket);
	}

	public function sendText(text:String):Void send(1, Bytes.ofString(text));

	function send(opcode:Int, payload:Bytes):Void {
		var out = socket.output;
		out.writeByte(0x80 | opcode);
		if (payload.length < 126) out.writeByte(0x80 | payload.length);
		else if (payload.length < 65536) { out.writeByte(0x80 | 126); out.writeUInt16(payload.length); }
		else { out.writeByte(0x80 | 127); out.writeInt32(0); out.writeInt32(payload.length); }
		var mask = Bytes.alloc(4);
		for (i in 0...4) mask.set(i, Std.random(256));
		out.write(mask);
		var masked = Bytes.alloc(payload.length);
		for (i in 0...payload.length) masked.set(i, payload.get(i) ^ mask.get(i & 3));
		out.write(masked);
		out.flush();
	}

	/** The next text message, waiting up to `seconds` for one to start; null when none does. Throws when the connection has closed. */
	public function receive(seconds:Float):Null<String> {
		if (!open) throw "The session connection is closed.";
		var message = new BytesBuffer(), started = false;
		while (true) {
			if (!started && sys.net.Socket.select([socket], null, null, seconds).read.length == 0) return null;
			started = true;
			var input = socket.input, first = input.readByte(), second = input.readByte();
			var length = second & 0x7f;
			if (length == 126) length = input.readUInt16();
			else if (length == 127) {
				if (input.readInt32() != 0) throw "A message from the session is too large.";
				length = input.readInt32();
			}
			if (length < 0 || length > MAX_MESSAGE) throw "A message from the session is too large.";
			var mask = (second & 0x80) != 0 ? input.read(4) : null;
			var data = length == 0 ? Bytes.alloc(0) : input.read(length);
			if (mask != null) for (i in 0...data.length) data.set(i, data.get(i) ^ mask.get(i & 3));
			switch first & 0x0f {
				case 1, 0:
					message.add(data);
					if (message.length > MAX_MESSAGE) throw "A message from the session is too large.";
					if (first & 0x80 != 0) return message.getBytes().toString();
				case 8:
					open = false;
					try socket.close() catch (_:Dynamic) {}
					throw "The session closed the connection.";
				case 9: send(10, data);
				default:
			}
		}
	}

	public function close():Void {
		if (!open) return;
		open = false;
		try {
			send(8, Bytes.alloc(0));
			socket.close();
		} catch (_:Dynamic) {}
	}
}
