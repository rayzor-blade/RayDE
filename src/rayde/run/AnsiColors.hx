package rayde.run;

/** Indexed and RGB colors shared by terminal screens and formatted Output. */
class AnsiColors {
	public static final dark = [
		0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5, 0x666666, 0xf14c4c, 0x23d18b, 0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db,
		0xe5e5e5
	];
	public static final light = [
		0x000000, 0xcd3131, 0x00bc00, 0x949800, 0x0451a5, 0xbc05bc, 0x0598bc, 0x555555, 0x666666, 0xcd3131, 0x14ce14, 0xb5ba00, 0x0451a5, 0xbc05bc, 0x0598bc,
		0xa5a5a5
	];

	public static function resolve(code:Int, fallback:Int, isDark:Bool):Int {
		if (code == 0) return fallback;
		var kind = code >>> 24, v = code & 0xffffff;
		if (kind == 2) return v;
		if (v < 16) return (isDark ? dark : light)[v];
		if (v < 232) {
			var i = v - 16, level = (n:Int) -> n == 0 ? 0 : 55 + n * 40;
			return level(Std.int(i / 36)) << 16 | level(Std.int(i / 6) % 6) << 8 | level(i % 6);
		}
		var gray = 8 + (v - 232) * 10;
		return gray << 16 | gray << 8 | gray;
	}

	public static function css(code:Int):Null<String> {
		if (code == 0) return null;
		if (code >>> 24 == 1 && (code & 0xffffff) < 16) return "var(--rayde-ansi-" + (code & 0xffffff) + ")";
		return "#" + StringTools.hex(resolve(code, 0, true), 6);
	}
}
