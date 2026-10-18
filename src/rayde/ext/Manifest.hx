package rayde.ext;

import rayde.ext.OrderedJson.J;

/** A button in the header of an extension's view. `icon` is an SVG file or the name of an icon of RayDE's, null when it has none. */
typedef ViewTool = {id:String, title:String, icon:Null<String>};

/**
 * An extension's config file, `<name>.rayext`: JSON that names the extension and says where its code is.
 * It is to an extension what a `.hxml` is to a Haxe project: RayDE opens it, and the folder it is in is the
 * project. Only `name` and `main` matter to the Studio so far; the rest is for when extensions are installed.
 *
 *     {
 *       "name": "Notes",
 *       "version": "0.1.0",
 *       "description": "A notes panel",
 *       "main": "ext/main.rays",
 *       "sources": ["ext"],
 *       "mocks": "ext/studio.mocks.json",
 *       "capabilities": ["workspace.read"],
 *       "view": {"title": "Notes", "icon": "ext/notes.svg", "location": "sidebar"}
 *     }
 *
 * `main` is the script that starts the extension (`main.rays` unless named). `sources` are the folders its
 * scripts are in, where `import a.b.C` looks for `a/b/C.rays` (the first one); by default the folder of
 * `main`. `mocks` is the file that answers the extension's remote calls while it is developed, by default
 * `studio.mocks.json` beside `main`. A path is relative to the config file.
 *
 * `view` says how the extension shows itself: its `title`, an SVG file for its `icon`, its `tools` and its `location`:
 * `sidebar` (the default: its icon joins the activity bar and its view takes the Explorer's place when the
 * icon is chosen), `secondary` (the side bar on the right), `panel` (a tab of the bottom panel) or `editor`
 * (a tab among the open files).
 *
 * `tools` are the buttons in the view's header, beside its title: each has an `id`, a `title` (its tooltip) and an
 * `icon`, an SVG file or the name of one of RayDE's own (`add`, `refresh`, `search`...). Choosing one tells the
 * extension, which answers it with `onTool("id", handler)`. The extension can change the title with `setTitle(text)`.
 */
class Manifest {
	/** The file's extension, with its dot. */
	public static inline var EXTENSION = ".rayext";

	/** Where a view can be shown. */
	public static final LOCATIONS = ["sidebar", "secondary", "panel", "editor"];

	public final file:String;

	/** The folder the config file is in. */
	public final root:String;

	public final name:String;
	public final version:String;
	public final description:String;
	public final main:String;
	public final sources:Array<String>;
	public final mocks:String;
	public final capabilities:Array<String>;

	/** The name the view goes by: its tab, its heading. */
	public final viewTitle:String;

	/** The SVG file of the view's icon, as written; null when it has none. */
	public final viewIcon:Null<String>;

	public final location:String;

	/** The buttons of the view's header. */
	public final tools:Array<ViewTool> = [];

	/** What is wrong with the file, as sentences; the fields above are filled in with their defaults where they were wrong or missing. */
	public final problems:Array<String> = [];

	function new(file:String, json:Dynamic) {
		this.file = file;
		root = haxe.io.Path.directory(file);
		var fallback = haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(file));
		name = text(json, "name", fallback);
		version = text(json, "version", "");
		description = text(json, "description", "");
		main = text(json, "main", "main.rays");
		var folder = haxe.io.Path.directory(main);
		var listed = strings(json, "sources");
		sources = listed.length > 0 ? listed : [folder == "" ? "." : folder];
		mocks = text(json, "mocks", haxe.io.Path.join([folder, "studio.mocks.json"]));
		capabilities = strings(json, "capabilities");
		var view:Dynamic = Reflect.field(json, "view");
		if (view != null && !Reflect.isObject(view)) {
			problems.push('"view" must be an object.');
			view = null;
		}
		viewTitle = view == null ? name : text(view, "title", name);
		var icon = view == null ? "" : text(view, "icon", "");
		viewIcon = icon == "" ? null : icon;
		var where = view == null ? "sidebar" : text(view, "location", "sidebar");
		if (LOCATIONS.indexOf(where) < 0) {
			problems.push('Unknown view location "$where"; expected one of ${LOCATIONS.join(", ")}.');
			where = "sidebar";
		}
		location = where;
		var listed:Dynamic = view == null ? null : Reflect.field(view, "tools");
		if (listed != null && !Std.isOfType(listed, Array))
			problems.push('"tools" must be an array.');
		else if (listed != null)
			for (t in (listed : Array<Dynamic>)) {
				if (t == null || Std.isOfType(t, String) || Std.isOfType(t, Array) || !Reflect.isObject(t)) {
					problems.push("Each tool must be an object with an id.");
					continue;
				}
				var id = text(t, "id", "");
				if (id == "") {
					problems.push("Tool is missing an id.");
					continue;
				}
				if (Lambda.exists(tools, x -> x.id == id)) {
					problems.push('Duplicate tool id "$id".');
					continue;
				}
				var icon = text(t, "icon", "");
				if (StringTools.endsWith(icon, ".svg") && !sys.FileSystem.exists(absolute(icon)))
					problems.push('Icon $icon of tool "$id" not found.');
				tools.push({id: id, title: text(t, "title", id), icon: icon == "" ? null : icon});
			}
		if (viewIcon != null && !sys.FileSystem.exists(absolute(viewIcon)))
			problems.push('Icon ${viewIcon} not found.');
		if (!sys.FileSystem.exists(mainPath()))
			problems.push('Main script ${main} not found.');
	}

	/** Reads the config file; one that cannot be read gives an extension with the defaults and the reason in `problems`. */
	public static function read(file:String):Manifest {
		var json:Dynamic = {};
		var why:Null<String> = null;
		try
			json = haxe.Json.parse(sys.io.File.getContent(file))
		catch (e:Dynamic)
			why = 'Invalid JSON: $e';
		if (why == null && (json == null || Std.isOfType(json, Array) || !Reflect.isObject(json))) {
			why = "The config must be a JSON object.";
			json = {};
		}
		var m = new Manifest(sys.FileSystem.fullPath(file), why == null ? json : {});
		if (why != null)
			m.problems.unshift(why);
		return m;
	}

	public static function isManifest(path:String):Bool
		return StringTools.endsWith(path, EXTENSION);

	function text(json:Dynamic, field:String, fallback:String):String {
		var v:Dynamic = Reflect.field(json, field);
		if (v == null)
			return fallback;
		if (!Std.isOfType(v, String)) {
			problems.push('"$field" must be a string.');
			return fallback;
		}
		return v == "" ? fallback : v;
	}

	function strings(json:Dynamic, field:String):Array<String> {
		var v:Dynamic = Reflect.field(json, field);
		if (v == null)
			return [];
		if (!Std.isOfType(v, Array) || !Lambda.foreach((v : Array<Dynamic>), x -> Std.isOfType(x, String))) {
			problems.push('"$field" must be an array of strings.');
			return [];
		}
		return v;
	}

	function absolute(path:String):String
		return haxe.io.Path.normalize(haxe.io.Path.isAbsolute(path) ? path : haxe.io.Path.join([root, path]));

	/** The main script, in full. */
	public function mainPath():String
		return absolute(main);

	/** The SVG file of a tool's icon, in full; null when the icon is the name of one of RayDE's. */
	public function toolIconPath(tool:ViewTool):Null<String>
		return tool.icon != null && StringTools.endsWith(tool.icon, ".svg") ? absolute(tool.icon) : null;

	/** The icon file, in full; null when the view names none. */
	public function iconPath():Null<String>
		return viewIcon == null ? null : absolute(viewIcon);

	/**
	 * Changes the config file's text: `edit` is given the file's JSON to change in place (an empty object when
	 * the file is missing or empty), and what it leaves is written back with its keys in their order. Keys
	 * this does not know are kept. Throws when the file is not JSON, so a form never overwrites what it cannot read.
	 */
	public static function update(file:String, edit:J->Void):Void {
		var text = sys.FileSystem.exists(file) ? sys.io.File.getContent(file) : "";
		var json = StringTools.trim(text) == "" ? Obj([]) : OrderedJson.parse(text);
		switch json {
			case Obj(_):
			case _: throw "The config must be a JSON object.";
		}
		edit(json);
		sys.io.File.saveContent(file, OrderedJson.stringify(json) + "\n");
	}

	/** Sets `field` of the config file to `value`, or takes it out for null or empty text; inside `view` when `inView`. */
	public static function setText(file:String, field:String, value:Null<String>, inView = false):Void
		update(file, json -> setIn(json, field, value == null || value == "" ? null : Str(value), inView));

	/** Sets a field of the file to a list of text, or takes it out for an empty list. */
	public static function setList(file:String, field:String, values:Array<String>):Void
		update(file, json -> OrderedJson.set(json, field, values.length == 0 ? null : Arr([for (v in values) Str(v)])));

	static function setIn(json:J, field:String, value:Null<J>, inView:Bool):Void {
		if (!inView)
			return OrderedJson.set(json, field, value);
		var view = OrderedJson.get(json, "view");
		if (view == null || !view.match(Obj(_))) {
			view = Obj([]);
			OrderedJson.set(json, "view", view);
		}
		OrderedJson.set(view, field, value);
		// A view with nothing left in it is not written.
		switch view {
			case Obj(entries) if (entries.length == 0): OrderedJson.set(json, "view", null);
			case _:
		}
	}

	/** Adds a tool to the view's header, at the end; one with that id already is replaced where it is. */
	public static function addTool(file:String, tool:ViewTool):Void
		update(file, json -> {
			var view = OrderedJson.get(json, "view");
			if (view == null || !view.match(Obj(_))) {
				view = Obj([]);
				OrderedJson.set(json, "view", view);
			}
			var entry:J = Obj([{key: "id", value: Str(tool.id)}]);
			if (tool.title != tool.id && tool.title != "")
				OrderedJson.set(entry, "title", Str(tool.title));
			if (tool.icon != null && tool.icon != "")
				OrderedJson.set(entry, "icon", Str(tool.icon));
			switch OrderedJson.get(view, "tools") {
				case Arr(items):
					for (i in 0...items.length)
						if (OrderedJson.text(OrderedJson.get(items[i], "id")) == tool.id) {
							items[i] = entry;
							return;
						}
					items.push(entry);
				case _:
					OrderedJson.set(view, "tools", Arr([entry]));
			}
		});

	/** Takes the tool with this id out of the view's header, and the list of tools or the view when that leaves them empty. */
	public static function removeTool(file:String, id:String):Void
		update(file, json -> {
			var view = OrderedJson.get(json, "view");
			if (view == null)
				return;
			switch OrderedJson.get(view, "tools") {
				case Arr(items):
					var kept = [for (i in items) if (OrderedJson.text(OrderedJson.get(i, "id")) != id) i];
					OrderedJson.set(view, "tools", kept.length == 0 ? null : Arr(kept));
				case _:
			}
			switch view {
				case Obj(entries) if (entries.length == 0): OrderedJson.set(json, "view", null);
				case _:
			}
		});

	/** Where the mocked answers are, in full. */
	public function mocksPath():String
		return absolute(mocks);

	/** The source folders that exist: the label as written, and the folder in full. */
	public function sourceDirs():Array<{label:String, dir:String}> {
		var out = [];
		for (s in sources) {
			var dir = absolute(s);
			if (sys.FileSystem.exists(dir) && sys.FileSystem.isDirectory(dir))
				out.push({label: s, dir: dir});
		}
		return out;
	}

	/** The folder `import a.b.C` looks in: the first source folder, or the project's own. */
	public function importRoot():String {
		var dirs = sourceDirs();
		return dirs.length > 0 ? dirs[0].dir : root;
	}
}
