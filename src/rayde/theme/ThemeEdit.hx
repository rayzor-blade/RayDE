package rayde.theme;

import rayde.ext.OrderedJson;
import rayde.ext.OrderedJson.J;

/**
 * Edits to the text of a `.raytheme` file. A value that is in the file is replaced where it stands, so the rest of the
 * text keeps its layout; a new entry is added by writing the file again through `OrderedJson`, which keeps the order of
 * the keys and lays objects out one entry to a line. Every function takes the text and gives the new text, and throws
 * a sentence when the text is not a JSON object.
 */
class ThemeEdit {
	/** Sets the entry at `path` (`dark.colors.primary`) to `value`; the objects on the way are made when missing. */
	public static function set(text:String, path:String, value:J):String {
		var span = JsonLocator.find(text, path);
		if (span != null)
			return text.substr(0, span.valueStart) + OrderedJson.stringify(value, "  ") + text.substr(span.valueEnd);
		var json = object(text);
		var steps = path.split(".");
		var at = json;
		for (i in 0...steps.length - 1) {
			var next = OrderedJson.get(at, steps[i]);
			if (next == null || !next.match(Obj(_))) {
				next = Obj([]);
				OrderedJson.set(at, steps[i], next);
			}
			at = next;
		}
		OrderedJson.set(at, steps[steps.length - 1], value);
		return OrderedJson.stringify(json) + "\n";
	}

	public static function setText(text:String, path:String, value:String):String
		return set(text, path, Str(value));

	public static function setNumber(text:String, path:String, value:Float):String
		return set(text, path, Num(Std.string(value)));

	/** Takes the entry at `path` away, and the objects it leaves empty. */
	public static function remove(text:String, path:String):String {
		if (JsonLocator.find(text, path) == null)
			return text;
		var json = object(text);
		var steps = path.split(".");
		var chain = [json];
		for (i in 0...steps.length - 1) {
			var next = OrderedJson.get(chain[i], steps[i]);
			if (next == null)
				return text;
			chain.push(next);
		}
		OrderedJson.set(chain[chain.length - 1], steps[steps.length - 1], null);
		var i = chain.length - 1;
		while (i > 0 && chain[i].match(Obj([]))) {
			OrderedJson.set(chain[i - 1], steps[i - 1], null);
			i--;
		}
		return OrderedJson.stringify(json) + "\n";
	}

	/** Adds the stylesheet `file` to `css`, which becomes a list when it was one text or one entry. */
	public static function addCss(text:String, file:String):String {
		var json = object(text);
		var items = switch OrderedJson.get(json, "css") {
			case null: [];
			case Arr(list): list;
			case other: [other];
		}
		var entry = Obj([{key: "file", value: Str(file)}]);
		if (!Lambda.exists(items, i -> OrderedJson.text(OrderedJson.get(i, "file")) == file))
			items.push(entry);
		OrderedJson.set(json, "css", Arr(items));
		return OrderedJson.stringify(json) + "\n";
	}

	/** Adds `file` to the family `family` in `fonts`, which is added when there is none. */
	public static function addFont(text:String, family:String, file:String):String {
		var json = object(text);
		var fonts = OrderedJson.get(json, "fonts");
		var list = switch fonts {
			case Arr(items): items;
			case _: [];
		}
		var entry:Null<J> = null;
		for (item in list)
			if (OrderedJson.text(OrderedJson.get(item, "family")) == family)
				entry = item;
		if (entry == null) {
			entry = Obj([{key: "family", value: Str(family)}, {key: "files", value: Arr([])}]);
			list.push(entry);
		}
		switch OrderedJson.get(entry, "files") {
			case Arr(files):
				if (!Lambda.exists(files, f -> OrderedJson.text(f) == file))
					files.push(Str(file));
			case _:
				OrderedJson.set(entry, "files", Arr([Str(file)]));
		}
		OrderedJson.set(json, "fonts", Arr(list));
		return OrderedJson.stringify(json) + "\n";
	}

	/** Takes `file` out of its family in `fonts`, and the family when it has no file left. */
	public static function removeFont(text:String, file:String):String {
		var json = object(text);
		switch OrderedJson.get(json, "fonts") {
			case Arr(list):
				var kept = [];
				for (item in list) {
					switch OrderedJson.get(item, "files") {
						case Arr(files):
							var left = [for (f in files) if (OrderedJson.text(f) != file) f];
							if (left.length == 0)
								continue;
							OrderedJson.set(item, "files", Arr(left));
						case _:
					}
					kept.push(item);
				}
				OrderedJson.set(json, "fonts", kept.length == 0 ? null : Arr(kept));
			case _:
		}
		return OrderedJson.stringify(json) + "\n";
	}

	static function object(text:String):J {
		var json = StringTools.trim(text) == "" ? Obj([]) : OrderedJson.parse(text);
		if (!json.match(Obj(_)))
			throw "The theme must be a JSON object.";
		return json;
	}
}
