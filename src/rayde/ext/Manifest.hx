package rayde.ext;

import rayde.ext.OrderedJson.J;

/** A command an extension contributes: the id its script registers a handler for, the title shown for it, and its icon (an SVG file or the name of one of RayDE's), null when it has none. */
typedef ViewCommand = {id:String, title:String, icon:Null<String>};

/** When a menu item applies: the kind of thing it is opened on, the extensions of the files it takes, and a name pattern with `*`. Each condition given must hold. */
typedef MenuWhen = {kind:Null<String>, ext:Array<String>, name:Null<String>};

/** An item an extension adds to a menu: the command it runs, an optional title and icon of its own, and when it appears. */
typedef MenuItem = {command:String, title:Null<String>, icon:Null<String>, when:MenuWhen};

/** An item of a menu as it is shown: the command it runs, its title, and its icon, which is the item's own or else the command's. */
typedef MenuEntry = {command:String, title:String, icon:Null<String>};

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
 * `contributes` adds to the workbench: `commands` (each an `id`, a `title` and optionally an `icon`; the script
 * handles one with `registerCommand(id, handler)`) and `menus`, by location (`explorer/context`), each a list of
 * items naming a `command` and a `when`: `{"kind": "file", "ext": [".md"], "name": "README*"}`. A menu item runs its
 * command with `{path, kind}` of what the menu was opened on, and shows the command's `icon` unless it has one of
 * its own. An `icon` is an SVG file, relative to the config, or the name of one of RayDE's own.
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

	/** The commands the extension contributes. */
	public final commands:Array<ViewCommand> = [];

	/** The menu items the extension contributes, by the location of the menu. */
	public final menus:Map<String, Array<MenuItem>> = new Map();

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
		contributions(Reflect.field(json, "contributes"));
		if (viewIcon != null && !sys.FileSystem.exists(absolute(viewIcon)))
			problems.push('Icon ${viewIcon} not found.');
		if (!sys.FileSystem.exists(mainPath()))
			problems.push('Main script ${main} not found.');
	}

	function contributions(c:Dynamic):Void {
		if (c == null)
			return;
		if (Std.isOfType(c, String) || Std.isOfType(c, Array) || !Reflect.isObject(c)) {
			problems.push('"contributes" must be an object.');
			return;
		}
		var listed:Dynamic = Reflect.field(c, "commands");
		if (listed != null && !Std.isOfType(listed, Array))
			problems.push('"contributes.commands" must be an array.');
		else if (listed != null)
			for (x in (listed : Array<Dynamic>)) {
				var id = Std.isOfType(x, String) || x == null ? "" : text(x, "id", "");
				if (id == "") {
					problems.push("Each command needs an id.");
					continue;
				}
				if (Lambda.exists(commands, k -> k.id == id)) {
					problems.push('Duplicate command id "$id".');
					continue;
				}
				var icon = text(x, "icon", "");
				if (StringTools.endsWith(icon, ".svg") && !sys.FileSystem.exists(absolute(icon)))
					problems.push('Icon $icon of command "$id" not found.');
				commands.push({id: id, title: text(x, "title", id), icon: icon == "" ? null : icon});
			}
		var menuObject:Dynamic = Reflect.field(c, "menus");
		if (menuObject != null && (Std.isOfType(menuObject, Array) || Std.isOfType(menuObject, String) || !Reflect.isObject(menuObject)))
			problems.push('"contributes.menus" must be an object of locations.');
		else if (menuObject != null)
			for (location in Reflect.fields(menuObject)) {
				var items:Dynamic = Reflect.field(menuObject, location);
				if (!Std.isOfType(items, Array)) {
					problems.push('"contributes.menus.$location" must be an array.');
					continue;
				}
				var out = [];
				for (x in (items : Array<Dynamic>)) {
					var command = Std.isOfType(x, String) || x == null ? "" : text(x, "command", "");
					if (command == "") {
						problems.push('A menu item in $location needs a command.');
						continue;
					}
					if (!Lambda.exists(commands, k -> k.id == command))
						problems.push('Menu item in $location names unknown command "$command".');
					var icon = text(x, "icon", "");
					if (StringTools.endsWith(icon, ".svg") && !sys.FileSystem.exists(absolute(icon)))
						problems.push('Icon $icon of a menu item in $location not found.');
					var when:Dynamic = Reflect.field(x, "when");
					var kind = when == null ? "" : text(when, "kind", "");
					if (kind != "" && kind != "file" && kind != "folder")
						problems.push('Unknown "when.kind" "$kind"; expected file or folder.');
					out.push({
						command: command,
						title: Reflect.hasField(x, "title") ? text(x, "title", "") : null,
						icon: icon == "" ? null : icon,
						when: {
							kind: kind == "" ? null : kind,
							ext: when == null ? [] : [for (e in strings(when, "ext")) e.toLowerCase()],
							name: when == null || text(when, "name", "") == "" ? null : text(when, "name", "")
						}
					});
				}
				menus.set(location, out);
			}
	}

	/** Whether a menu item applies to `path`, which is a `kind` of file or folder. */
	public static function applies(when:MenuWhen, path:String, kind:String):Bool {
		if (when.kind != null && when.kind != kind)
			return false;
		var name = haxe.io.Path.withoutDirectory(haxe.io.Path.removeTrailingSlashes(path));
		if (when.ext.length > 0) {
			var dot = name.lastIndexOf(".");
			var ext = dot < 0 ? "" : name.substr(dot).toLowerCase();
			if (when.ext.indexOf(ext) < 0)
				return false;
		}
		if (when.name != null && !wildcard(when.name, name))
			return false;
		return true;
	}

	/** `*` matches any run of characters; the rest must match as written, without regard to case. */
	static function wildcard(pattern:String, name:String):Bool {
		var escaped = [for (part in pattern.split("*")) ~/[.+?^${}()|[\]\\]/g.replace(part, "\\$0")].join(".*");
		return new EReg("^" + escaped + "$", "i").match(name);
	}

	/** The items of the menu at `location` that apply to `path`, each with the command it runs and the title to show. */
	public function menuFor(location:String, path:String, kind:String):Array<MenuEntry> {
		var out = [];
		var items = menus.get(location);
		if (items == null)
			return out;
		for (i in items)
			if (applies(i.when, path, kind)) {
				var command = Lambda.find(commands, k -> k.id == i.command);
				out.push({
					command: i.command,
					title: i.title != null && i.title != "" ? i.title : command == null ? i.command : command.title,
					icon: i.icon != null ? i.icon : command == null ? null : command.icon
				});
			}
		return out;
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
		return iconFile(tool.icon);

	/** The SVG file an icon names, in full; null when it names one of RayDE's own, or none. */
	public function iconFile(icon:Null<String>):Null<String>
		return icon != null && StringTools.endsWith(icon, ".svg") ? absolute(icon) : null;

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
