package rayde.ext;

import rayde.workspace.Fs;
import ashui.css.Css;
import ashui.css.Stylesheet;

private typedef Entry = {sheet:Null<Stylesheet>, stamp:String, users:Int};
private typedef Rule = {head:String, body:Null<String>, children:Null<Array<Rule>>};
private typedef Scoped = {source:String, problems:Array<String>, valid:Bool};

/** Local CSS overrides for an extension's chrome and content, owned by its mounted views. */
class ExtensionStyles {
	public static inline var LIMIT = 262144;
	public static inline var ATTRIBUTE = "data-extension";
	static inline var SCOPE = "data-extension-style";
	static final localEntries = new ashui.core.UiContext.Local<Map<String, Entry>>(() -> new Map());
	static var entries(get, never):Map<String, Entry>;

	static function get_entries():Map<String, Entry>
		return localEntries.value;

	/** The extra attribute distinguishes workspace overrides with the same extension id. */
	public static function base(id:String, ?token:String):String
		return '#rayde [$ATTRIBUTE="${escape(id)}"]' + (token == null ? "" : '[$SCOPE="$token"]');

	static function escape(value:String):String
		return value.split("\\").join("\\\\").split('"').join('\\"');

	static function key(m:Manifest):String
		return fullPath(m.file) ?? haxe.io.Path.normalize(Fs.absolutePath(m.file));

	static function token(m:Manifest):String
		return haxe.crypto.Sha256.encode(key(m));

	public static function mark(element:ashui.layout.Element, m:Null<Manifest>):Void {
		if (m == null || m.styles.length == 0)
			return;
		var identity = ashui.css.Identity.of(element.tree, element.node.id);
		identity.setAttribute(ATTRIBUTE, m.id);
		identity.setAttribute(SCOPE, token(m));
	}

	/** Acquires the sheets and returns a disposer tied to this manifest and UI context. */
	public static function use(m:Null<Manifest>, report:String->Void):Void->Void {
		if (m == null || m.styles.length == 0)
			return () -> {};
		var cache = entries, id = key(m), context = ashui.core.UiContext.current;
		var entry = cache.get(id);
		if (entry == null)
			cache.set(id, entry = {sheet: null, stamp: "", users: 0});
		entry.users++;
		refresh(m, report);
		var released = false;
		return () -> {
			if (released)
				return;
			released = true;
			context.run(() -> {
				if (--entry.users > 0)
					return;
				if (entry.sheet != null)
					Css.remove(entry.sheet);
				cache.remove(id);
			});
		};
	}

	/** Reload is content-based so same-size edits in one filesystem timestamp are visible. */
	public static function refresh(m:Manifest, report:String->Void):Void {
		var entry = entries.get(key(m));
		if (entry == null)
			return;
		var problems:Array<String> = [],
			texts:Array<String> = [],
			readable = true;
		var root = fullPath(m.root);
		for (path in m.styles) {
			try {
				var file = fullPath(haxe.io.Path.join([m.root, path]));
				if (root == null || file == null || !StringTools.startsWith(file, root + "/") || Fs.isDirectory(file))
					throw "It must be a file inside the extension folder.";
				if (Fs.stat(file).size > LIMIT)
					throw 'It exceeds ${LIMIT >> 10} KiB.';
				var bytes = Fs.getBytes(file);
				if (bytes.length > LIMIT)
					throw 'It exceeds ${LIMIT >> 10} KiB.';
				texts.push(bytes.toString());
			} catch (error:Dynamic) {
				readable = false;
				problems.push('Cannot read style "$path": ' + Std.string(error));
			}
		}
		var source = texts.join("\n"),
			stamp = haxe.crypto.Sha256.encode(haxe.Json.stringify({
				id: m.id,
				styles: m.styles,
				source: source,
				problems: problems
			}));
		if (stamp == entry.stamp)
			return;
		entry.stamp = stamp;
		if (readable) {
			var scoped = transform(source, m.id, token(m), m.styles.join(", "));
			problems = problems.concat(scoped.problems);
			if (scoped.valid)
				try {
					var next = Stylesheet.parse(scoped.source, "extension " + m.id + " styles");
					var malformed = Lambda.exists(next.diagnostics, d -> d.severity == Error);
					if (!malformed) {
						if (entry.sheet == null)
							Css.add(next);
						else
							Css.replace(entry.sheet, next);
						entry.sheet = next;
					}
					for (d in next.diagnostics)
						problems.push('${d.line}:${d.column}: ${d.message}');
				} catch (error:Dynamic)
					problems.push("Cannot load extension styles: " + Std.string(error));
		}
		for (problem in problems)
			report(problem);
	}

	static function fullPath(path:String):Null<String> {
		try
			return haxe.io.Path.removeTrailingSlashes(haxe.io.Path.normalize(Fs.fullPath(path)))
		catch (_:Dynamic)
			return null;
	}

	/** Prefixes selectors, namespaces animations, and drops external-resource declarations. */
	public static function scope(css:String, id:String, problems:Array<String>, ?file:String):String {
		var result = transform(css, id, null, file);
		for (problem in result.problems)
			problems.push(problem);
		return result.source;
	}

	static function transform(css:String, id:String, token:Null<String>, file:Null<String>):Scoped {
		var result:Scoped = {source: "", problems: [], valid: true};
		var where = file == null ? "" : file + ": ";
		var rules = parse(stripComments(css, result, where), result, where, 0),
			names = new Map<String, String>();
		var prefix = "rayde-ext-" + haxe.crypto.Sha256.encode(id + (token ?? "")).substr(0, 16) + "-";
		function collect(list:Array<Rule>):Void {
			for (rule in list) {
				if (isKeyframes(rule.head)) {
					var name = frameName(rule.head);
					if (name == null || animationKeywords.indexOf(name.toLowerCase()) >= 0)
						result.problems.push(where + "Keyframes need a non-keyword CSS identifier.");
					else
						names.set(name, prefix + name);
				} else if (rule.children != null)
					collect(rule.children);
			}
		}
		collect(rules);
		function render(list:Array<Rule>):String {
			var out = new StringBuf();
			for (rule in list) {
				if (rule.body == null) {
					if (StringTools.startsWith(rule.head, "@"))
						result.problems.push(where + rule.head.split(" ")[0] + " is not allowed.");
					continue;
				}
				if (isGroup(rule.head))
					out.add(rule.head + " {\n" + render(rule.children) + "}\n");
				else if (isKeyframes(rule.head)) {
					var name = frameName(rule.head);
					if (name == null || !names.exists(name))
						continue;
					out.add("@keyframes " + names.get(name) + " {\n");
					for (frame in rule.children)
						if (frame.body != null && !StringTools.startsWith(frame.head, "@"))
							out.add(frame.head + " {" + declarations(frame.body, names, result.problems, where) + "}\n");
					out.add("}\n");
				} else if (StringTools.startsWith(rule.head, "@"))
					result.problems.push(where + rule.head.split(" ")[0] + " is not allowed.");
				else {
					var selectors:Array<String> = [];
					for (selector in splitTop(rule.head, ",")) {
						var scoped = scopeSelector(StringTools.trim(selector), id, token);
						if (scoped == null)
							result.problems.push(where + "A :view selector cannot reach siblings outside its view.");
						else if (scoped != "")
							selectors.push(scoped);
					}
					if (selectors.length > 0)
						out.add(selectors.join(", ") + " {" + declarations(rule.body, names, result.problems, where) + "}\n");
				}
			}
			return out.toString();
		}
		result.source = render(rules);
		return result;
	}

	static final animationKeywords = [
		"none",
		"initial",
		"inherit",
		"unset",
		"revert",
		"linear",
		"ease",
		"ease-in",
		"ease-out",
		"ease-in-out",
		"step-start",
		"step-end",
		"infinite",
		"normal",
		"reverse",
		"alternate",
		"alternate-reverse",
		"forwards",
		"backwards",
		"both",
		"running",
		"paused"
	];

	static function isGroup(head:String):Bool
		return ~/^@(media|supports|container|layer)\b/i.match(head);

	static function isKeyframes(head:String):Bool
		return ~/^@(-webkit-)?keyframes\b/i.match(head);

	static function frameName(head:String):Null<String> {
		var pattern = ~/^@(?:-webkit-)?keyframes\s+([-_A-Za-z][-_A-Za-z0-9]*)\s*$/i;
		return pattern.match(head) ? pattern.matched(1) : null;
	}

	static function parse(text:String, result:Scoped, where:String, depth:Int):Array<Rule> {
		var rules:Array<Rule> = [], i = 0;
		if (depth > 32) {
			result.valid = false;
			result.problems.push(where + "CSS nesting is too deep.");
			return rules;
		}
		while (i < text.length) {
			while (i < text.length && StringTools.isSpace(text, i))
				i++;
			if (i >= text.length)
				break;
			var start = i, level = 0;
			while (i < text.length) {
				var c = text.charAt(i);
				if (c == "\"" || c == "'")
					i = closing(text, i);
				else if (c == "\\")
					i++;
				else if (c == "(" || c == "[")
					level++;
				else if (c == ")" || c == "]")
					level--;
				else if (level == 0 && (c == "{" || c == ";"))
					break;
				i++;
			}
			var head = StringTools.trim(text.substring(start, i));
			if (i >= text.length) {
				result.valid = false;
				result.problems.push(where + "Expected a CSS rule block.");
				break;
			}
			if (text.charAt(i) == ";") {
				rules.push({head: head, body: null, children: null});
				i++;
				continue;
			}
			start = ++i;
			level = 1;
			while (i < text.length && level > 0) {
				var c = text.charAt(i);
				if (c == "\"" || c == "'")
					i = closing(text, i);
				else if (c == "\\")
					i++;
				else if (c == "{")
					level++;
				else if (c == "}")
					level--;
				if (level > 0)
					i++;
			}
			if (level != 0) {
				result.valid = false;
				result.problems.push(where + "Unclosed CSS block.");
				break;
			}
			var body = text.substring(start, i++);
			rules.push({
				head: head,
				body: body,
				children: isGroup(head) || isKeyframes(head) ? parse(body, result, where, depth + 1) : null});
		}
		return rules;
	}

	static function closing(text:String, at:Int):Int {
		var quote = text.charAt(at), i = at + 1;
		while (i < text.length && text.charAt(i) != quote)
			i += text.charAt(i) == "\\" ? 2 : 1;
		return i;
	}

	static function stripComments(text:String, result:Scoped, where:String):String {
		var out = new StringBuf(), i = 0;
		while (i < text.length) {
			var c = text.charAt(i);
			if (c == "\"" || c == "'") {
				var end = closing(text, i);
				out.add(text.substring(i, end + 1));
				i = end + 1;
			} else if (c == "/" && text.charAt(i + 1) == "*") {
				var end = text.indexOf("*/", i + 2);
				if (end < 0) {
					result.valid = false;
					result.problems.push(where + "Unclosed CSS comment.");
				}
				out.add(" ");
				i = end < 0 ? text.length : end + 2;
			} else {
				out.add(c);
				i++;
			}
		}
		return out.toString();
	}

	static function splitTop(text:String, separator:String):Array<String> {
		var out:Array<String> = [], start = 0, depth = 0, i = 0;
		while (i < text.length) {
			var c = text.charAt(i);
			if (c == "\"" || c == "'")
				i = closing(text, i);
			else if (c == "\\")
				i++;
			else if (c == "(" || c == "[")
				depth++;
			else if (c == ")" || c == "]")
				depth--;
			else if (depth == 0 && c == separator) {
				out.push(text.substring(start, i));
				start = i + 1;
			}
			i++;
		}
		out.push(text.substr(start));
		return out;
	}

	static function scopeSelector(selector:String, id:String, token:Null<String>):Null<String> {
		if (selector == "")
			return "";
		if (["+", "~", "|"].indexOf(selector.charAt(0)) >= 0)
			return null;
		var head = ~/^(:view|:root|html|body)(?![A-Za-z0-9_-])/;
		if (!head.match(selector))
			return base(id, token) + " " + selector;
		var suffix = selector.substr(head.matched(1).length), i = 0, depth = 0;
		while (i < suffix.length) {
			var c = suffix.charAt(i);
			if (c == "\"" || c == "'")
				i = closing(suffix, i);
			else if (c == "\\")
				i++;
			else if (c == "(" || c == "[")
				depth++;
			else if (c == ")" || c == "]")
				depth--;
			else if (depth == 0 && (StringTools.isSpace(suffix, i) || c == ">" || c == "+" || c == "~" || c == "|"))
				break;
			i++;
		}
		while (i < suffix.length && StringTools.isSpace(suffix, i))
			i++;
		if (["+", "~", "|"].indexOf(suffix.charAt(i)) >= 0)
			return null;
		return base(id, token) + suffix;
	}

	static function declarations(body:String, names:Map<String, String>, problems:Array<String>, where:String):String {
		// Nested selectors can use & to leave a :view root through a sibling combinator.
		var i = 0;
		while (i < body.length) {
			var c = body.charAt(i);
			if (c == "\"" || c == "'")
				i = closing(body, i);
			else if (c == "\\")
				i++;
			else if (c == "{" || c == "}") {
				problems.push(where + "Nested style rules are not supported; write full selectors.");
				return "";
			}
			i++;
		}
		var out:Array<String> = [];
		for (part in splitTop(body, ";")) {
			var colon = part.indexOf(":");
			if (colon < 0) {
				out.push(part);
				continue;
			}
			var property = StringTools.trim(part.substr(0, colon)).toLowerCase();
			var animation = ["animation", "animation-name", "-webkit-animation", "-webkit-animation-name"].indexOf(property) >= 0;
			var value = rewriteValue(part.substr(colon + 1), names, animation);
			if (value == null)
				problems.push(where + "url() is not allowed.");
			else
				out.push(part.substr(0, colon + 1) + value);
		}
		return out.join(";");
	}

	static function nameChar(code:Int):Bool
		return code >= 128 || code >= 48 && code <= 57 || code >= 65 && code <= 90 || code >= 97 && code <= 122 || code == 45 || code == 95;

	static function rewriteValue(text:String, names:Map<String, String>, animation:Bool):Null<String> {
		var out = new StringBuf(), i = 0, depth = 0;
		while (i < text.length) {
			var c = text.charAt(i);
			if (c == "\"" || c == "'") {
				var end = closing(text, i);
				out.add(text.substring(i, end + 1));
				i = end + 1;
			} else if (nameChar(text.charCodeAt(i)) || c == "\\") {
				var start = i, name = new StringBuf();
				while (i < text.length && (nameChar(text.charCodeAt(i)) || text.charAt(i) == "\\")) {
					if (text.charAt(i) != "\\")
						name.add(text.charAt(i++));
					else {
						i++;
						var from = i;
						while (i < text.length && i - from < 6 && "0123456789abcdefABCDEF".indexOf(text.charAt(i)) >= 0)
							i++;
						if (i > from) {
							name.add(String.fromCharCode(Std.parseInt("0x" + text.substring(from, i))));
							if (i < text.length && StringTools.isSpace(text, i))
								i++;
						} else if (i < text.length)
							name.add(text.charAt(i++));
					}
				}
				var word = name.toString(), after = i;
				while (after < text.length && StringTools.isSpace(text, after))
					after++;
				if (word.toLowerCase() == "url" && text.charAt(after) == "(")
					return null;
				out.add(animation
					&& depth == 0
					&& text.charAt(after) != "("
					&& names.exists(word) ? names.get(word) : text.substring(start, i));
			} else {
				if (c == "(")
					depth++;
				else if (c == ")")
					depth--;
				out.add(c);
				i++;
			}
		}
		return out.toString();
	}
}
