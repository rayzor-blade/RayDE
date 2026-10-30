package rayde.preview;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import haxe.io.Input;
import haxe.io.Output;

/** How one frame of a headless app's picture reaches RayDE: the rectangle that changed, as raw or deflated RGBA. */
typedef SurfaceFrame = {
	seq:Int,
	/** The last input the app had applied when it drew this frame, so a viewer can time its own input. */
	input:Int,
	x:Int, y:Int, width:Int, height:Int,
	/** 0 for raw RGBA rows, 1 for the same bytes deflated. */
	encoding:Int,
	data:Bytes
};

/** What a viewer sends the app: a pointer or key event, numbered. */
typedef SurfaceInput = {id:Int, type:Int, a:Int, b:Int, c:Int};

/**
 * The surface protocol between a producer (a shim inside a headless app) and RayDE, as records on the app's stdio.
 * A record is four bytes of length (big-endian) for what follows, one byte of kind and the payload.
 * Producer to viewer: HELLO (width, height), FRAME, LOG (text) and EXIT. Viewer to producer: INPUT.
 */
class SurfaceProtocol {
	public static inline var HELLO = 1;
	public static inline var FRAME = 2;
	public static inline var LOG = 3;
	public static inline var EXIT = 4;
	public static inline var INPUT = 5;

	/** Input types for `SurfaceInput.type`: pointer down, up and move carry x in `a`, y in `b` and the button in `c`. */
	public static inline var POINTER_DOWN = 1;
	public static inline var POINTER_UP = 2;
	public static inline var POINTER_MOVE = 3;
	public static inline var KEY_DOWN = 4;
	public static inline var KEY_UP = 5;
	/** Typed text: `a` is the code point. Wheel: `a` and `b` are the horizontal and vertical delta in tenths of a pixel. Focus: `a` is 1 gained, 0 lost. */
	public static inline var TEXT = 6;
	public static inline var WHEEL = 7;
	public static inline var FOCUS = 8;

	/** Bits of `c` on key input: repeat, then the held modifiers. */
	public static inline var REPEAT = 1;
	public static inline var SHIFT = 2;
	public static inline var CONTROL = 4;
	public static inline var ALT = 8;
	public static inline var META = 16;

	/** The largest record accepted, in bytes. */
	public static inline var MAX_RECORD = 64 * 1024 * 1024;

	public static function record(kind:Int, payload:Bytes):Bytes {
		var out = new BytesOutput();
		out.bigEndian = true;
		out.writeInt32(payload.length + 1);
		out.writeByte(kind);
		out.write(payload);
		return out.getBytes();
	}

	/** The next record, blocking until it has arrived. Throws `haxe.io.Eof` at the end of the stream. */
	public static function read(input:Input):{kind:Int, payload:Bytes} {
		input.bigEndian = true;
		var length = input.readInt32();
		if (length < 1 || length > MAX_RECORD) throw "Not a surface record.";
		var kind = input.readByte();
		return {kind: kind, payload: length == 1 ? Bytes.alloc(0) : input.read(length - 1)};
	}

	public static function hello(width:Int, height:Int):Bytes {
		var out = new BytesOutput();
		out.bigEndian = true;
		out.writeUInt16(width);
		out.writeUInt16(height);
		return record(HELLO, out.getBytes());
	}

	public static function parseHello(payload:Bytes):{width:Int, height:Int} {
		var input = new BytesInput(payload);
		input.bigEndian = true;
		return {width: input.readUInt16(), height: input.readUInt16()};
	}

	public static function frame(f:SurfaceFrame):Bytes {
		var out = new BytesOutput();
		out.bigEndian = true;
		out.writeInt32(f.seq);
		out.writeInt32(f.input);
		out.writeUInt16(f.x);
		out.writeUInt16(f.y);
		out.writeUInt16(f.width);
		out.writeUInt16(f.height);
		out.writeByte(f.encoding);
		out.writeInt32(f.data.length);
		out.write(f.data);
		return record(FRAME, out.getBytes());
	}

	public static function parseFrame(payload:Bytes):SurfaceFrame {
		var input = new BytesInput(payload);
		input.bigEndian = true;
		var seq = input.readInt32(), last = input.readInt32(), x = input.readUInt16(), y = input.readUInt16(), w = input.readUInt16(), h = input.readUInt16();
		var encoding = input.readByte(), length = input.readInt32();
		return {seq: seq, input: last, x: x, y: y, width: w, height: h, encoding: encoding, data: input.read(length)};
	}

	/** The rectangle's pixels as raw RGBA rows, whatever the frame's encoding. */
	public static function pixels(f:SurfaceFrame):Bytes
		return f.encoding == 1 ? haxe.zip.Uncompress.run(f.data) : f.data;

	public static function input(i:SurfaceInput):Bytes {
		var out = new BytesOutput();
		out.bigEndian = true;
		out.writeInt32(i.id);
		out.writeByte(i.type);
		out.writeInt32(i.a);
		out.writeInt32(i.b);
		out.writeInt32(i.c);
		return record(INPUT, out.getBytes());
	}

	public static function parseInput(payload:Bytes):SurfaceInput {
		var input = new BytesInput(payload);
		input.bigEndian = true;
		return {id: input.readInt32(), type: input.readByte(), a: input.readInt32(), b: input.readInt32(), c: input.readInt32()};
	}

	public static function writeTo(out:Output, bytes:Bytes):Void {
		out.write(bytes);
		out.flush();
	}
}
