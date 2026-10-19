package rayde.ext;

import rayde.ext.OrderedJson.J;

/** A view an extension declares: the id its script mounts it under, its title and icon, the part of the layout it goes in, and the buttons of its header. */
typedef ViewDecl = {id:String, title:String, icon:Null<String>, location:String, tools:Array<ViewTool>};

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

/** A library named by a native block; its path is relative to the manifest. */
typedef NativeLibrary = {name:String, path:String, sha256:String};

/**
 * An extension's config file, `<name>.rayext`: JSON that names the extension and says where its code is.
 * It is to an extension what a `.hxml` is to a Haxe project: RayDE opens it, and the folder it is in is the
 * project. The manager uses `id` and `activationEvents` to discover and start installed extensions.
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
 *     "views": [
 *       {"id": "main", "title": "Overview", "location": "sidebar"},
 *       {"id": "inspector", "title": "Inspector", "location": "secondary"}
 *     ]
 *
 * `main` is the script that starts the extension (`main.rays` unless named). `sources` are the folders its
 * scripts are in, where `import a.b.C` looks for `a/b/C.rays` (the first one); by default the folder of
 * `main`. `mocks` is the file that answers the extension's remote calls while it is developed, by default
 * `studio.mocks.json` beside `main`. A path is relative to the config file.
 *
 * An extension has a view only if it declares one; one that handles hooks and commands and presents tabs declares
 * none, and takes no place in the layout. `view` declares one (its id is `main`), `views` a list of them, each with
 * an `id`, and the script mounts a view under its id: `mount(view, 'inspector')`. A view says how it shows itself:
 * its `title`, an SVG file for its `icon`, its `tools` and its `location`: `sidebar` (the default: its icon joins the
 * activity bar and its view takes the Explorer's place when the icon is chosen), `secondary` (the side bar on the
 * right), `panel` (a tab of the bottom panel) or `editor` (a tab among the open files). A name that is no view's id
 * goes to the first view; `tab:<title>` opens a tab, which needs no declaration.
 *
 * `contributes` adds to the workbench: `commands` (each an `id`, a `title` and optionally an `icon`; the script
 * handles one with `registerCommand(id, handler)`) and `menus`, by location (`explorer/context`, `editor/title`), each a list of
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

	public final id:String;
	public final activationEvents:Null<Array<String>>;
	public final keybindings:Array<{command:String, key:String}> = [];
	public final configuration:Dynamic;
	public final name:String;
	public final version:String;
	public final description:String;
	public final main:String;
	public final sources:Array<String>;
	public final mocks:String;
	public final capabilities:Array<String>;
	public final natives:Array<NativeLibrary> = [];

	/**
	 * The views the extension declares, each in a part of the layout; none for an extension that only handles hooks and
	 * commands and presents tabs. `view` is the first of them, with the id `main`.
	 */
	public final views:Array<ViewDecl> = [];

	/** The name the first view goes by: its tab, its heading. */
	public var viewTitle(get, never):String;

	/** The SVG file of the first view's icon, as written; null when it has none. */
	public var viewIcon(get, never):Null<String>;

	/** Where the first view is shown. */
	public var location(get, never):String;

	/** The buttons of the first view's header. */
	public var tools(get, never):Array<ViewTool>;

	function get_viewTitle():String
		return views.length == 0 ? name : views[0].title;

	function get_viewIcon():Null<String>
		return views.length == 0 ? null : views[0].icon;

	function get_location():String
		return views.length == 0 ? "sidebar" : views[0].location;

	function get_tools():Array<ViewTool>
		return views.length == 0 ? [] : views[0].tools;

	/** The view with this id. */
	public function viewOf(id:String):Null<ViewDecl>
		return Lambda.find(views, v -> v.id == id);

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
		id = text(json, "id", fallback);
		if (!~/^[A-Za-z0-9_-]+$/.match(id)) problems.push("Extension id must contain letters, digits, underscores or hyphens.");
		activationEvents = Reflect.hasField(json, "activationEvents") ? strings(json, "activationEvents") : null;
		if (activationEvents != null)
			for (event in activationEvents)
				if (event != "onStartup" && !~/^(workspaceContains|onCommand|onView):.+$/.match(event)) problems.push('Unknown activation event "$event".');
		var contributes = Reflect.field(json, "contributes");
		configuration = contributes == null ? null : Reflect.field(contributes, "configuration");
		name = text(json, "name", fallback);
		version = text(json, "version", "");
		description = text(json, "description", "");
		main = text(json, "main", "main.rays");
		var folder = haxe.io.Path.directory(main);
		var listed = strings(json, "sources");
		sources = listed.length > 0 ? listed : [folder == "" ? "." : folder];
		mocks = text(json, "mocks", haxe.io.Path.join([folder, "studio.mocks.json"]));
		capabilities = strings(json, "capabilities");
		readNatives(json);
		var view:Dynamic = Reflect.field(json, "view");
		if (view != null && (Std.isOfType(view, String) || Std.isOfType(view, Array) || !Reflect.isObject(view)))
			problems.push('"view" must be an object.');
		else if (view != null)
			views.push(readView(view, "main"));
		var listed:Dynamic = Reflect.field(json, "views");
		if (listed != null && !Std.isOfType(listed, Array))
			problems.push('"views" must be an array.');
		else if (listed != null)
			for (v in (listed : Array<Dynamic>)) {
				if (v == null || Std.isOfType(v, String) || Std.isOfType(v, Array) || !Reflect.isObject(v)) {
					problems.push("Each view must be an object with an id.");
					continue;
				}
				var id = text(v, "id", "");
				if (id == "") {
					problems.push("View is missing an id.");
					continue;
				}
				if (id.indexOf(":") >= 0) {
					problems.push('View id "$id" must not contain ":".');
					continue;
				}
				if (viewOf(id) != null) {
					problems.push('Duplicate view id "$id".');
					continue;
				}
				views.push(readView(v, id));
			}
		var seen:Array<String> = [];
		for (v in views)
			for (t in v.tools) {
				if (seen.indexOf(t.id) >= 0)
					problems.push('Tool id "${t.id}" is declared by more than one view.');
				seen.push(t.id);
			}
		contributions(Reflect.field(json, "contributes"));
		if (!sys.FileSystem.exists(mainPath()))
			problems.push('Main script ${main} not found.');
	}

	function readNatives(json:Dynamic):Void {
		var value:Dynamic = Reflect.field(json, "natives");
		if (value != null) {
			if (!Reflect.isObject(value) || Std.isOfType(value, Array) || Std.isOfType(value, String)) {
				problems.push('"natives" must be an object.');
				return;
			}
			var names = Reflect.fields(value);
			names.sort(Reflect.compare);
			for (name in names) {
				var entry = Reflect.field(value, name);
				if (!~/^[A-Za-z_][A-Za-z0-9_-]*$/.match(name))
					problems.push('Invalid native library name "$name".');
				if (entry == null || !Reflect.isObject(entry) || Std.isOfType(entry, Array) || Std.isOfType(entry, String)) {
					problems.push('Native library "$name" must have a path and SHA-256 hash.');
					continue;
				}
				var path = text(entry, "path", ""), hash = text(entry, "sha256", "").toLowerCase();
				if (path == "" || haxe.io.Path.isAbsolute(path) || path.indexOf("\\") >= 0 || path.indexOf(":") >= 0
					|| Lambda.exists(path.split("/"), part -> part == "" || part == "." || part == ".."))
					problems.push('Native library "$name" requires a relative path without traversal.');
				if (!~/^[0-9a-f]{64}$/.match(hash))
					problems.push('Native library "$name" requires a SHA-256 hash.');
				if (capabilities.indexOf('native:$name') < 0)
					problems.push('Native library "$name" requires capability native:$name.');
				natives.push({name: name, path: path, sha256: hash});
			}
		}
		for (capability in capabilities)
			if (StringTools.startsWith(capability, "native:") && !Lambda.exists(natives, n -> n.name == capability.substr(7)))
				problems.push('Capability "$capability" has no native declaration.');
	}

	/** One view's declaration, with its tools; what is wrong with it goes to `problems`. */
	function readView(view:Dynamic, id:String):ViewDecl {
		var icon = text(view, "icon", "");
		if (icon != "" && StringTools.endsWith(icon, ".svg") && !sys.FileSystem.exists(absolute(icon)))
			problems.push(id == "main" ? 'Icon $icon not found.' : 'Icon $icon of view "$id" not found.');
		var where = text(view, "location", "sidebar");
		if (LOCATIONS.indexOf(where) < 0) {
			problems.push('Unknown view location "$where"; expected one of ${LOCATIONS.join(", ")}.');
			where = "sidebar";
		}
		var tools:Array<ViewTool> = [];
		var listed:Dynamic = Reflect.field(view, "tools");
		if (listed != null && !Std.isOfType(listed, Array))
			problems.push('"tools" must be an array.');
		else if (listed != null)
			for (t in (listed : Array<Dynamic>)) {
				if (t == null || Std.isOfType(t, String) || Std.isOfType(t, Array) || !Reflect.isObject(t)) {
					problems.push("Each tool must be an object with an id.");
					continue;
				}
				var tid = text(t, "id", "");
				if (tid == "") {
					problems.push("Tool is missing an id.");
					continue;
				}
				if (Lambda.exists(tools, x -> x.id == tid)) {
					problems.push('Duplicate tool id "$tid".');
					continue;
				}
				var toolIcon = text(t, "icon", "");
				if (StringTools.endsWith(toolIcon, ".svg") && !sys.FileSystem.exists(absolute(toolIcon)))
					problems.push('Icon $toolIcon of tool "$tid" not found.');
				tools.push({id: tid, title: text(t, "title", tid), icon: toolIcon == "" ? null : toolIcon});
			}
		return {id: id, title: text(view, "title", name), icon: icon == "" ? null : icon, location: where, tools: tools};
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
		var keys:Dynamic = Reflect.field(c, "keybindings");
		if (keys != null && !Std.isOfType(keys, Array)) problems.push('"contributes.keybindings" must be an array.');
		else if (keys != null) for (entry in (keys:Array<Dynamic>)) {
			var command = entry == null ? "" : text(entry, "command", ""), key = entry == null ? "" : text(entry, "key", "");
			if (!Lambda.exists(commands, c -> c.id == command) || key == "") problems.push("Each key binding needs a declared command and a key.");
			else keybindings.push({command: command, key: key});
		}
		var menuObject:Dynamic = Reflect.field(c, "menus");
		if (menuObject != null && (Std.isOfType(menuObject, Array) || Std.isOfType(menuObject, String) || !Reflect.isObject(menuObject)))
			problems.push('"contributes.menus" must be an object of locations.');
		else if (menuObject != null)
			for (location in Reflect.fields(menuObject)) {
				if (!Hooks.knownMenu(location))
					problems.push('Unknown menu location "$location"; expected ${Hooks.menuIds().join(" or ")}.');
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

	/** Sets `field` of the config file to `value`, or takes it out for null or empty text; inside the view `viewId` (`main` by default) when `inView`. */
	public static function setText(file:String, field:String, value:Null<String>, inView = false, viewId = "main"):Void
		update(file, json -> {
			var v = value == null || value == "" ? null : Str(value);
			if (!inView)
				return OrderedJson.set(json, field, v);
			var view = viewObject(json, viewId, v != null);
			if (view != null)
				OrderedJson.set(view, field, v);
		});

	/** Sets a field of the file to a list of text, or takes it out for an empty list. */
	public static function setList(file:String, field:String, values:Array<String>):Void
		update(file, json -> OrderedJson.set(json, field, values.length == 0 ? null : Arr([for (v in values) Str(v)])));

	/**
	 * The object that declares the view `id`: an entry of `views`, or `view` for `main` when there is no `views`. With
	 * `create`, a missing one is made; making a second view moves `view` into `views` as the entry `main`.
	 */
	static function viewObject(json:J, id:String, create:Bool):Null<J> {
		switch OrderedJson.get(json, "views") {
			case Arr(items):
				for (i in items)
					if (OrderedJson.text(OrderedJson.get(i, "id")) == id)
						return i;
				if (!create)
					return null;
				var made:J = Obj([{key: "id", value: Str(id)}]);
				items.push(made);
				return made;
			case _:
		}
		var single = OrderedJson.get(json, "view");
		var isObject = single != null && single.match(Obj(_));
		if (id == "main") {
			if (isObject)
				return single;
			if (!create)
				return null;
			var made:J = Obj([]);
			OrderedJson.set(json, "view", made);
			return made;
		}
		if (!create)
			return null;
		var list:Array<J> = [];
		if (isObject) {
			var moved:J = Obj([{key: "id", value: Str("main")}]);
			switch single {
				case Obj(entries):
					for (e in entries)
						OrderedJson.set(moved, e.key, e.value);
				case _:
			}
			list.push(moved);
			OrderedJson.set(json, "view", null);
		}
		var made:J = Obj([{key: "id", value: Str(id)}]);
		list.push(made);
		OrderedJson.set(json, "views", Arr(list));
		return made;
	}

	/** Declares a view, with the fields that are not the defaults; one with that id already is replaced where it is. */
	public static function addView(file:String, view:ViewDecl):Void
		update(file, json -> {
			var made = viewObject(json, view.id, true);
			if (made == null)
				return;
			if (view.title != "")
				OrderedJson.set(made, "title", Str(view.title));
			if (view.icon != null && view.icon != "")
				OrderedJson.set(made, "icon", Str(view.icon));
			if (view.location != "sidebar")
				OrderedJson.set(made, "location", Str(view.location));
		});

	/** Takes a view out, with its tools; `views` or `view` goes when that leaves none. */
	public static function removeView(file:String, id:String):Void
		update(file, json -> {
			switch OrderedJson.get(json, "views") {
				case Arr(items):
					var kept = [for (i in items) if (OrderedJson.text(OrderedJson.get(i, "id")) != id) i];
					OrderedJson.set(json, "views", kept.length == 0 ? null : Arr(kept));
				case _:
					if (id == "main")
						OrderedJson.set(json, "view", null);
			}
		});

	/** Adds a tool to the header of the view `viewId`, at the end; one with that id already is replaced where it is. */
	public static function addTool(file:String, tool:ViewTool, viewId = "main"):Void
		update(file, json -> {
			var view = viewObject(json, viewId, true);
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

	/** Takes the tool with this id out of the header of the view `viewId`, and the list of tools when that leaves it empty. */
	public static function removeTool(file:String, id:String, viewId = "main"):Void
		update(file, json -> {
			var view = viewObject(json, viewId, false);
			if (view == null)
				return;
			switch OrderedJson.get(view, "tools") {
				case Arr(items):
					var kept = [for (i in items) if (OrderedJson.text(OrderedJson.get(i, "id")) != id) i];
					OrderedJson.set(view, "tools", kept.length == 0 ? null : Arr(kept));
				case _:
			}
		});

	static function contributesOf(json:J):J {
		var c = OrderedJson.get(json, "contributes");
		if (c == null || !c.match(Obj(_))) {
			c = Obj([]);
			OrderedJson.set(json, "contributes", c);
		}
		return c;
	}

	/** Takes out of `contributes` what an edit left empty: lists, the menus object, and `contributes` itself. */
	static function tidy(json:J):Void {
		var c = OrderedJson.get(json, "contributes");
		if (c == null)
			return;
		var menus = OrderedJson.get(c, "menus");
		if (menus != null) {
			switch menus {
				case Obj(entries):
					for (e in entries.copy())
						switch e.value {
							case Arr(items) if (items.length == 0): OrderedJson.set(menus, e.key, null);
							case _:
						}
				case _:
			}
			switch menus {
				case Obj(entries) if (entries.length == 0): OrderedJson.set(c, "menus", null);
				case _:
			}
		}
		switch OrderedJson.get(c, "commands") {
			case Arr(items) if (items.length == 0): OrderedJson.set(c, "commands", null);
			case _:
		}
		switch c {
			case Obj(entries) if (entries.length == 0): OrderedJson.set(json, "contributes", null);
			case _:
		}
	}

	/** Adds a command to `contributes`, at the end; one with that id already is replaced where it is. */
	public static function addCommand(file:String, command:ViewCommand):Void
		update(file, json -> {
			var c = contributesOf(json);
			var entry:J = Obj([{key: "id", value: Str(command.id)}]);
			if (command.title != command.id && command.title != "")
				OrderedJson.set(entry, "title", Str(command.title));
			if (command.icon != null && command.icon != "")
				OrderedJson.set(entry, "icon", Str(command.icon));
			switch OrderedJson.get(c, "commands") {
				case Arr(items):
					for (i in 0...items.length)
						if (OrderedJson.text(OrderedJson.get(items[i], "id")) == command.id) {
							items[i] = entry;
							return;
						}
					items.push(entry);
				case _:
					OrderedJson.set(c, "commands", Arr([entry]));
			}
		});

	/** Takes a command out, and the menu items that name it. */
	public static function removeCommand(file:String, id:String):Void
		update(file, json -> {
			var c = OrderedJson.get(json, "contributes");
			if (c == null)
				return;
			switch OrderedJson.get(c, "commands") {
				case Arr(items):
					OrderedJson.set(c, "commands", Arr([for (i in items) if (OrderedJson.text(OrderedJson.get(i, "id")) != id) i]));
				case _:
			}
			switch OrderedJson.get(c, "menus") {
				case Obj(entries):
					for (e in entries)
						switch e.value {
							case Arr(items):
								e.value = Arr([for (i in items) if (OrderedJson.text(OrderedJson.get(i, "command")) != id) i]);
							case _:
						}
				case _:
			}
			tidy(json);
		});

	/** Adds an item to the menu at `location`, at the end. */
	public static function addMenuItem(file:String, location:String, item:MenuItem):Void
		update(file, json -> {
			var c = contributesOf(json);
			var entry:J = Obj([{key: "command", value: Str(item.command)}]);
			if (item.title != null && item.title != "")
				OrderedJson.set(entry, "title", Str(item.title));
			if (item.icon != null && item.icon != "")
				OrderedJson.set(entry, "icon", Str(item.icon));
			var when:J = Obj([]);
			if (item.when.kind != null)
				OrderedJson.set(when, "kind", Str(item.when.kind));
			if (item.when.ext.length > 0)
				OrderedJson.set(when, "ext", Arr([for (e in item.when.ext) Str(e)]));
			if (item.when.name != null)
				OrderedJson.set(when, "name", Str(item.when.name));
			switch when {
				case Obj(entries) if (entries.length > 0): OrderedJson.set(entry, "when", when);
				case _:
			}
			var menus = OrderedJson.get(c, "menus");
			if (menus == null || !menus.match(Obj(_))) {
				menus = Obj([]);
				OrderedJson.set(c, "menus", menus);
			}
			switch OrderedJson.get(menus, location) {
				case Arr(items): items.push(entry);
				case _: OrderedJson.set(menus, location, Arr([entry]));
			}
		});

	/** Takes the item at `index` out of the menu at `location`. */
	public static function removeMenuItem(file:String, location:String, index:Int):Void
		update(file, json -> {
			var c = OrderedJson.get(json, "contributes"), menus = c == null ? null : OrderedJson.get(c, "menus");
			if (menus == null)
				return;
			switch OrderedJson.get(menus, location) {
				case Arr(items) if (index >= 0 && index < items.length): items.splice(index, 1);
				case _:
			}
			tidy(json);
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
