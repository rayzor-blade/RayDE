class Util {
	/** `text` written `times` times over. */
	public static function repeat(text:String, times:Int):String {
		var out = "";
		for (_ in 0...times)
			out += text;
		return out;
	}
}
