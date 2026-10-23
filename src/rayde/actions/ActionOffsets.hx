package rayde.actions;

/** RayScript indexes Unicode scalars; native editors may index UTF-16. Convert only requested boundaries. */
class ActionOffsets {
	public static function convert(text:String, positions:Array<Int>, toEditor:Bool):Map<Int, Int> {
		var sorted = positions.copy(); sorted.sort((a,b) -> a - b);
		var out = new Map<Int,Int>(), at = 0, scalar = 0;
		for (position in sorted) {
			if (position < 0) throw "Code-action offsets must be non-negative";
			while ((toEditor ? scalar : at) < position && at < text.length) {
				var code = text.charCodeAt(at++);
				if (code >= 0xD800 && code <= 0xDBFF && at < text.length && text.charCodeAt(at) >= 0xDC00 && text.charCodeAt(at) <= 0xDFFF) at++;
				scalar++;
			}
			if ((toEditor ? scalar : at) != position) throw "Code-action offset is outside the document or splits a Unicode character";
			out.set(position,toEditor ? at : scalar);
		}
		return out;
	}
}
