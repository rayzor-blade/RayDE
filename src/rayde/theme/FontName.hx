package rayde.theme;

import haxe.io.Bytes;

/**
 * The family names a font file carries, read from the `name` table of a TrueType or OpenType file (the first font of a
 * collection). The faces ashui registers are found by these names, so a theme that says a file is "Inter" can be told
 * when it is not. WOFF2 is compressed, so its names are not read: `of` gives null for it.
 */
class FontName {
	/** Whether the file is a kind ashui registers: `.ttf`, `.otf`, `.ttc` or `.woff2`. */
	public static function isFontFile(path:String):Bool
		return Lambda.exists([".ttf", ".otf", ".ttc", ".woff2"], e -> StringTools.endsWith(path.toLowerCase(), e));

	/** The family names in `bytes` (the family and the typographic family), or null when they cannot be read. */
	public static function of(bytes:Bytes):Null<Array<String>> {
		try
			return read(bytes)
		catch (_:Dynamic)
			return null;
	}

	static function read(b:Bytes):Null<Array<String>> {
		if (b.length < 12)
			return null;
		var tag = b.getString(0, 4), start = 0;
		if (tag == "ttcf")
			start = u32(b, 12);
		else if (tag != "OTTO" && tag != "true" && u32(b, 0) != 0x00010000)
			return null;
		var tables = u16(b, start + 4), name = -1;
		for (i in 0...tables) {
			var at = start + 12 + i * 16;
			if (b.getString(at, 4) == "name")
				name = u32(b, at + 8);
		}
		if (name < 0)
			return null;
		var count = u16(b, name + 2), strings = name + u16(b, name + 4);
		var found = new Map<Int, String>();
		for (i in 0...count) {
			var at = name + 6 + i * 12;
			var platform = u16(b, at), id = u16(b, at + 6), length = u16(b, at + 8), offset = u16(b, at + 10);
			if (id != 1 && id != 16)
				continue;
			var text = platform == 3 || platform == 0 ? utf16(b, strings + offset, length) : platform == 1 ? b.getString(strings + offset, length) : null;
			if (text != null && (platform == 3 || !found.exists(id)))
				found.set(id, text);
		}
		var out = [];
		for (id in [16, 1])
			if (found.exists(id) && out.indexOf(found.get(id)) < 0)
				out.push(found.get(id));
		return out.length == 0 ? null : out;
	}

	/** Font files are big-endian; `Bytes.getInt32` is little-endian. */
	static function u32(b:Bytes, at:Int):Int
		return (b.get(at) << 24) | (b.get(at + 1) << 16) | (b.get(at + 2) << 8) | b.get(at + 3);

	static function u16(b:Bytes, at:Int):Int
		return (b.get(at) << 8) | b.get(at + 1);

	static function utf16(b:Bytes, at:Int, length:Int):String {
		var s = new StringBuf();
		var i = 0;
		while (i + 1 < length) {
			s.addChar(u16(b, at + i));
			i += 2;
		}
		return s.toString();
	}
}
