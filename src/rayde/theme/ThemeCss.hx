package rayde.theme;

/**
 * Puts a theme's stylesheet under the theme: each selector of each rule gets `scope` in front of it, so the rules apply
 * while the theme is in use and not after another is chosen. `:root` and `#rayde` stand for the scope itself, which is
 * where custom properties go. Rules inside `@media` and `@supports` are scoped too; `@keyframes`, `@font-face` and other
 * at-rules are kept as they are.
 */
class ThemeCss {
	public static function scope(css:String, scope:String):String
		return rules(css, scope);

	static function rules(css:String, scope:String):String {
		var out = new StringBuf();
		var i = 0, n = css.length, start = 0;
		while (i < n) {
			var c = css.charAt(i);
			if (c == "/" && css.charAt(i + 1) == "*") {
				var end = css.indexOf("*/", i + 2);
				i = end < 0 ? n : end + 2;
				continue;
			}
			if (c == "\"" || c == "'") {
				i = skipString(css, i);
				continue;
			}
			if (c == ";" ) {
				// A statement with no block, such as @import or @charset.
				out.add(css.substring(start, i + 1));
				i++;
				start = i;
				continue;
			}
			if (c != "{") {
				i++;
				continue;
			}
			var prelude = StringTools.trim(stripComments(css.substring(start, i)));
			var close = matching(css, i);
			var body = css.substring(i + 1, close);
			if (StringTools.startsWith(prelude, "@")) {
				var inner = ~/^@(media|supports|container|layer)\b/.match(prelude);
				out.add(prelude + " {" + (inner ? rules(body, scope) : body) + "}\n");
			} else
				out.add(selectors(prelude, scope) + " {" + body + "}\n");
			i = close + 1;
			start = i;
		}
		var rest = StringTools.trim(stripComments(css.substring(start)));
		if (rest != "")
			out.add(rest);
		return out.toString();
	}

	static function skipString(css:String, at:Int):Int {
		var quote = css.charAt(at), i = at + 1;
		while (i < css.length && css.charAt(i) != quote)
			i += css.charAt(i) == "\\" ? 2 : 1;
		return i + 1;
	}

	/** The position of the brace that closes the one at `open`. */
	static function matching(css:String, open:Int):Int {
		var depth = 0, i = open;
		while (i < css.length) {
			var c = css.charAt(i);
			if (c == "/" && css.charAt(i + 1) == "*") {
				var end = css.indexOf("*/", i + 2);
				i = end < 0 ? css.length : end + 2;
				continue;
			}
			if (c == "\"" || c == "'") {
				i = skipString(css, i);
				continue;
			}
			if (c == "{")
				depth++;
			else if (c == "}") {
				depth--;
				if (depth == 0)
					return i;
			}
			i++;
		}
		return css.length;
	}

	static function stripComments(text:String):String
		return ~/\/\*[\s\S]*?\*\//g.replace(text, "");

	/** `prelude` is a comma-separated list of selectors; each is placed under `scope`. */
	static function selectors(prelude:String, scope:String):String {
		var parts = [], depth = 0, from = 0;
		for (i in 0...prelude.length) {
			var c = prelude.charAt(i);
			if (c == "(" || c == "[")
				depth++;
			else if (c == ")" || c == "]")
				depth--;
			else if (c == "," && depth == 0) {
				parts.push(prelude.substring(from, i));
				from = i + 1;
			}
		}
		parts.push(prelude.substring(from));
		var out = [];
		for (p in parts) {
			var sel = StringTools.trim(p);
			if (sel == "")
				continue;
			if (sel == ":root" || sel == "#rayde" || sel == "html" || sel == "body")
				out.push(scope);
			else if (StringTools.startsWith(sel, ":root ") || StringTools.startsWith(sel, "#rayde "))
				out.push(scope + sel.substr(sel.indexOf(" ")));
			else
				out.push(scope + " " + sel);
		}
		return out.join(",\n");
	}
}
