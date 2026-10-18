package rayde.ext;

import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Signal;
import rayde.lang.Display.Diagnostic;

/** One line of the Console or the Activity list. `kind` is log, error, info, event, call, answer or ops. */
typedef Entry = {kind:String, text:String, time:Float, ?file:String, ?line:Int, ?col:Int};

/** What an extension can ask of the workbench, through the `rayde.workspace` module; the workbench provides it. */
typedef Services = {
	/** The text of a file, as the editor holds it when it is open; null when there is no such file. */
	readFile:String->Null<String>,
	activeFile:Void->Null<String>,
	root:Void->String,
	openFile:String->Void,
	writeFile:(String, String) -> Void,
	/** The current state a hook reports, sent to an extension when it starts listening for it; null when the hook has none. */
	replay:String->Dynamic
};

/** A view the extension presented as a tab: the root it mounted, and the title it gave. */
typedef TabView = {root:Int, title:String};

/** A place the view is drawn: its container, and the root it shows; null for the main view, which shows every root that is not a tab. */
private typedef Surface = {container:Node, root:Null<Int>, attached:Array<Int>};

/**
 * An extension being developed: its host process, the Preview its view is drawn in, and what it said and
 * did. `reload` starts the extension afresh from the source as the editor holds it, `edited` does so
 * a moment after typing stops, and `tick` moves everything along. The remote modules an extension imports
 * are answered from a mocks file, so it can run with no editor behind it.
 */
class Studio {
	/** stopped, running, exited, or unavailable (no rayscript-host to run it). */
	public final state = Signal.make("stopped");

	public final console = Signal.make(([] : Array<Entry>));
	public final activity = Signal.make(([] : Array<Entry>));

	/** Whether typing reloads the extension on its own, a moment after it stops. */
	public final live = Signal.make(true);

	/** True while the view shown is the last that ran and the source as it is now does not: it has a mistake in it. */
	public final stale = Signal.make(false);

	/** The heading of the view: the config's title, which the extension can change. */
	public final title:Signal<String>;

	/** Changes with the Preview's tree, for the Elements panel. */
	public final elements = Signal.make(0);

	/** The views the extension presented as tabs, in the order it mounted them. */
	public var tabViews(default, null):Array<TabView> = [];

	/** Called when the extension's tabs change: one mounted, unmounted or retitled. */
	public var onTabs:Null<Array<TabView>->Void>;

	/** What the extension may ask of the workbench; set by whoever shows it. */
	public var services:Null<Services>;

	/** The functions of the modules RayDE answers itself, by module. */
	public static final builtin:Map<String, Array<String>> = ["rayde.workspace" => ["readFile", "activeFile", "root", "openFile", "writeFile"]];

	/** The syntax or compile errors of the last run of the source, where the editor can put them. */
	public var problems(default, null):Array<Diagnostic> = [];

	/** Called when `problems` is replaced. */
	public var onProblems:Null<Array<Diagnostic>->Void>;

	/** Called when the console gets an error, with its kind (syntax, compile, runtime or view), so a panel can come into view. */
	public var onError:Null<String->Void>;

	public var file(default, null):String;

	/** What the extension's view is, as nodes of the tree. It outlives the pages that show it: `detach` takes it out of one, `attach` puts it in the next. */
	public var preview(default, null):Null<Preview>;

	final binary:Null<String>;
	final dir:String;
	var root:String;
	/** The config of the extension, when it was opened from one. */
	public var manifest(default, null):Null<Manifest>;
	final source:Void->String;
	var host:Null<ExtensionHost>;
	final tree:LayoutTree;
	final surfaces:Array<Surface> = [];

	/** The hooks the running extension listens for. */
	final subscribed = new Map<String, Bool>();

	final pending = new Map<String, Dynamic>();
	var mocks:Dynamic = {};
	var mocksFile:String;
	var changedAt = -1.;
	var lastActive = 0.;
	var scheduled = false;

	/** Set by a reload: the view stays until the new version has started, so a typing mistake does not blank it. */
	var replacing = false;

	/** Counts what the Console shows. */
	static inline var MAX_ENTRIES = 1000;

	/** `file` is the script that is the extension's main, `source` gives it as the editor holds it; `dir` holds the host's logs; the view's nodes are made in `tree`. */
	public function new(file:String, dir:String, source:Void->String, tree:LayoutTree, ?manifest:Manifest, ?binary:String) {
		this.file = file;
		this.dir = dir;
		this.source = source;
		this.tree = tree;
		this.manifest = manifest;
		title = Signal.make(manifest != null ? manifest.viewTitle : "Preview");
		Utilities.install();
		preview = new Preview(tree, send);
		this.binary = binary != null ? binary : HostBinary.find();
		root = manifest != null ? manifest.importRoot() : haxe.io.Path.directory(file);
		mocksFile = manifest != null ? manifest.mocksPath() : haxe.io.Path.join([root, "studio.mocks.json"]);
		if (this.binary == null)
			state.set("unavailable");
	}

	/** The config changed: the view's heading, where scripts are imported from and the mocks file are what it says now. */
	public function useManifest(m:Manifest):Void {
		manifest = m;
		root = m.importRoot();
		mocksFile = m.mocksPath();
		title.set(m.viewTitle);
	}

	public function mocksPath():String
		return mocksFile;

	/**
	 * Draws the view in `container`, a node of the tree: the main view, or only the root `root` for a tab.
	 * A page built to replace one that showed the same thing takes its place.
	 */
	public function attach(container:Node, ?root:Int):Void {
		for (s in surfaces.copy())
			if (s.root == root && s.container.id != container.id)
				release(s);
		if (!Lambda.exists(surfaces, s -> s.container.id == container.id))
			surfaces.push({container: container, root: root, attached: []});
		if (preview != null)
			preview.show();
		adopt();
	}

	/** Lets go of a surface: what is drawn goes from it and from the tree, and the model of the view stays. */
	function release(s:Surface):Void {
		tree.detachChildren(s.container.id);
		surfaces.remove(s);
		if (surfaces.length == 0 && preview != null)
			preview.hide();
	}

	/**
	 * Takes the view out of `from`, a page that is about to go; the extension and its view go on, and
	 * are drawn again by the next page. A page built to replace it may have the view already.
	 */
	public function detach(from:Node):Void {
		for (s in surfaces.copy())
			if (s.container.id == from.id)
				release(s);
	}

	/** Ends the extension and takes its view down, for good. */
	public function dispose():Void {
		stop();
		for (s in surfaces.copy())
			release(s);
		if (preview != null)
			preview.clear();
		preview = null;
	}

	function note(list:Signal<Array<Entry>>, kind:String, text:String, ?at:{file:String, line:Int, col:Int}):Void {
		var all = list.get().copy();
		all.push({kind: kind, text: text, time: haxe.Timer.stamp(), file: at == null ? null : at.file, line: at == null ? null : at.line, col: at == null ? null : at.col});
		if (all.length > MAX_ENTRIES)
			all = all.slice(all.length - MAX_ENTRIES);
		list.set(all);
	}

	public function clearConsole():Void
		console.set([]);

	/** Runs the extension afresh: a new process, the Preview emptied, the mocked modules registered, the source run. */
	public function reload():Void {
		changedAt = -1;
		if (binary == null)
			return;
		stop();
		replacing = true;
		title.set(manifest != null ? manifest.viewTitle : "Preview");
		problems = [];
		if (onProblems != null)
			onProblems(problems);
		readMocks();
		subscribed.clear();
		pending.clear();
		host = new ExtensionHost(binary, dir, root);
		host.start();
		state.set("running");
		// What RayDE answers itself and what the mocks file adds, a mock answering in place of the real one.
		var modules = new Map<String, Array<String>>();
		for (module => names in builtin)
			modules.set(module, names.copy());
		for (module in Reflect.fields(mocks)) {
			var names = modules.exists(module) ? modules.get(module) : [];
			for (f in Reflect.fields(Reflect.field(mocks, module)))
				if (names.indexOf(f) < 0)
					names.push(f);
			modules.set(module, names);
		}
		for (module => names in modules)
			host.send({t: "module", path: module, functions: names});
		host.send({t: "run", name: file, source: source()});
		note(activity, "info", "Reloaded");
		activeNow();
	}

	/** The source changed in the editor: with `live` on, reloads once it has been still for a moment. */
	public function edited():Void {
		if (live.get())
			changedAt = haxe.Timer.stamp();
		activeNow();
	}

	public function stop():Void {
		if (host != null)
			host.stop();
		host = null;
		if (state.get() != "unavailable")
			state.set("stopped");
	}

	public function running():Bool
		return host != null && host.running();

	/** The buttons the extension's config puts in its header. */
	public function tools():Array<rayde.ext.Manifest.ViewTool>
		return manifest == null ? [] : manifest.tools;

	/** A tool of the header was chosen: tells the extension. */
	public function tool(id:String):Void {
		if (host == null)
			return;
		host.send({t: "tool", id: id});
		note(activity, "event", 'tool $id');
		activeNow();
	}

	/** Sends an event for an element of the view, as a person using the Preview does. */
	public function send(node:Int, event:String, payload:Dynamic):Void {
		if (host == null)
			return;
		host.send({t: "event", node: node, event: event, payload: payload});
		note(activity, "event", '$event on #$node' + (payload == null ? "" : " " + haxe.Json.stringify(payload)));
		activeNow();
	}

	function readMocks():Void {
		mocks = {};
		if (!sys.FileSystem.exists(mocksFile))
			return;
		try
			mocks = haxe.Json.parse(sys.io.File.getContent(mocksFile))
		catch (e:Dynamic)
			note(console, "error", 'Cannot read mocks file ${haxe.io.Path.withoutDirectory(mocksFile)}: $e');
	}

	/** Polls faster for a while after something happened, so a click and its answer feel immediate. */
	function activeNow():Void {
		lastActive = haxe.Timer.stamp();
		schedule(.016);
	}

	function schedule(delay:Float):Void {
		if (scheduled)
			return;
		scheduled = true;
		ashui.animation.AnimationScheduler.main.after(delay, () -> {
			scheduled = false;
			tick();
			if (host != null && host.running() || changedAt >= 0)
				schedule(haxe.Timer.stamp() - lastActive < 1 ? .016 : .1);
		});
	}

	/** Moves the extension along: reads what the host said, and reloads after typing has stopped. */
	public function tick():Void {
		if (changedAt >= 0 && haxe.Timer.stamp() - changedAt > .4)
			reload();
		if (host == null)
			return;
		var messages = host.poll();
		for (m in messages) {
			handle(m);
			lastActive = haxe.Timer.stamp();
		}
		if (host.state == "exited") {
			var err = StringTools.trim(host.errors());
			note(console, "error", 'Extension host exited with code ${host.exitCode}.' + (err == "" ? "" : "\n" + err));
			host = null;
			state.set("exited");
		}
	}

	function handle(m:Dynamic):Void {
		switch (m.t : String) {
			case "started":
				replace();
			case "ops":
				if (preview != null) {
					preview.apply(m.ops);
					adopt();
					refreshTabs();
					elements.set(elements.get() + 1);
				}
				note(activity, "ops", (m.ops : Array<Dynamic>).length + (m.ops.length == 1 ? " operation" : " operations"));
			case "view":
				if (m.title != null)
					title.set(Std.string(m.title));
			case "subscribe":
				var name = Std.string(m.hook);
				subscribed.set(name, true);
				// What a hook reports about the present is told once, so an extension that starts late is not behind.
				var now = services == null ? null : services.replay(name);
				if (now != null)
					hook(name, now);
			case "log":
				note(console, "log", m.message);
			case "call":
				answer(m);
			case "error":
				failed(m);
			case _:
		}
	}

	/** The new version of the extension has started: what the old one drew goes, and the new one draws. */
	function replace():Void {
		if (!replacing)
			return;
		replacing = false;
		stale.set(false);
		if (preview != null)
			preview.clear();
		for (s in surfaces)
			s.attached = [];
		refreshTabs();
		elements.set(elements.get() + 1);
	}

	static function isTab(name:String):Bool
		return StringTools.startsWith(name, "tab:");

	/** Puts each root the extension has mounted in the surface that shows it. */
	function adopt():Void {
		if (preview == null)
			return;
		preview.findRoots();
		for (s in surfaces)
			for (r in preview.roots) {
				var wanted = s.root == null ? !isTab(r.name) : r.id == s.root;
				if (wanted && s.attached.indexOf(r.id) < 0 && r.node != null) {
					s.attached.push(r.id);
					tree.addChild(s.container.id, r.node.id);
				}
			}
	}

	/** The views mounted as tabs now: when they are not what `tabs` says, it says it. */
	function refreshTabs():Void {
		if (preview == null)
			return;
		preview.findRoots();
		var now = [for (r in preview.roots) if (isTab(r.name)) {root: r.id, title: r.name.substr(4)}];
		var same = now.length == tabViews.length;
		if (same)
			for (i in 0...now.length)
				if (now[i].root != tabViews[i].root || now[i].title != tabViews[i].title)
					same = false;
		if (same)
			return;
		tabViews = now;
		if (onTabs != null)
			onTabs(now);
	}

	/** A tab of the extension was closed in the editor: the extension is told, and unmounts the view. */
	public function closeTab(root:Int):Void {
		if (preview != null)
			preview.removeRoot(root);
		refreshTabs();
		if (host != null)
			host.send({t: "closed", root: root});
	}

	/** Tells the extension of something that happened in the editor, if it listens for it. `key` makes a later call replace an earlier one still waiting. */
	public function hook(name:String, data:Dynamic, ?delay:Float):Void {
		if (host == null || !subscribed.exists(name))
			return;
		if (delay == null) {
			deliver(name, data);
			return;
		}
		var key = name + (data != null && Reflect.hasField(data, "path") ? ":" + data.path : "");
		var waiting = pending.exists(key);
		pending.set(key, data);
		if (!waiting)
			ashui.animation.AnimationScheduler.main.after(delay, () -> {
				var d = pending.get(key);
				pending.remove(key);
				deliver(name, d);
			});
	}

	function deliver(name:String, data:Dynamic):Void {
		if (host == null)
			return;
		host.send({t: "hook", name: name, data: data});
		note(activity, "event", 'hook $name' + (data == null ? "" : " " + haxe.Json.stringify(data)));
		activeNow();
	}

	/** Runs a command the extension registered, with `args`. */
	public function command(id:String, args:Dynamic):Void {
		if (host == null) {
			note(console, "error", 'Cannot run command $id: the extension is not running.');
			return;
		}
		host.send({t: "command", id: id, args: args});
		note(activity, "event", 'command $id' + (args == null ? "" : " " + haxe.Json.stringify(args)));
		activeNow();
	}

	function failed(m:Dynamic):Void {
		var items:Array<Dynamic> = m.items == null ? [] : m.items;
		var kind:String = m.kind;
		if (kind == "syntax" || kind == "compile") {
			if (replacing)
				stale.set(preview != null && preview.count() > 0);
			problems = [
				for (i in items)
					{
						file: i.file,
						range: {start: {line: Std.int(i.line) - 1, character: Std.int(i.col) - 1}, end: {line: Std.int(i.endLine) - 1, character: Std.int(i.endCol) - 1}},
						severity: 1,
						message: i.message
					}
			];
			if (onProblems != null)
				onProblems(problems);
		}
		var first = items.length > 0 ? items[0] : null;
		if (onError != null)
			onError(kind);
		note(console, "error", firstLine(m.message), first == null || first.line == null ? null : place(first));
		for (i in 1...items.length) {
			var it = items[i];
			var function_:Null<String> = Reflect.field(it, "function");
			if (kind == "runtime" && it.line != null)
				note(console, "info", "  at " + (function_ == null ? "" : function_ + " ") + haxe.io.Path.withoutDirectory(it.file) + ":" + it.line + ":" + it.col, place(it));
		}
	}

	static function place(item:Dynamic):{file:String, line:Int, col:Int}
		return {file: item.file, line: Std.int(item.line), col: Std.int(item.col)};

	/** The message, without the picture ariadne draws under it. */
	static function firstLine(message:String):String {
		var lines = message.split("\n");
		return StringTools.trim(lines[0]);
	}

	function answer(call:Dynamic):Void {
		var name:String = call.fn, at = name.lastIndexOf(".");
		var module = name.substr(0, at), fn = name.substr(at + 1);
		note(activity, "call", name + "(" + [for (a in (call.args : Array<Dynamic>)) haxe.Json.stringify(a)].join(", ") + ")");
		var group = Reflect.field(mocks, module);
		if (group == null || !Reflect.hasField(group, fn)) {
			if (builtin.exists(module) && builtin.get(module).indexOf(fn) >= 0) {
				reply(service(call, fn));
				return;
			}
			reply({t: "reject", id: call.id, message: 'No mock for $name; add it to ${haxe.io.Path.withoutDirectory(mocksFile)}'});
			return;
		}
		var value:Dynamic = Reflect.field(group, fn);
		var delay = 0;
		if (value != null && Reflect.hasField(value, "$after")) {
			delay = Std.int(Reflect.field(value, "$after"));
			value = Reflect.field(value, "$value");
		}
		var message:Dynamic = value != null && Reflect.hasField(value, "$error") ? {t: "reject", id: call.id, message: Std.string(Reflect.field(value, "$error"))} : {t: "resolve", id: call.id, value: value};
		if (delay > 0)
			ashui.animation.AnimationScheduler.main.after(delay / 1000, () -> reply(message));
		else
			reply(message);
	}

	/** The capability a call to `rayde.workspace` needs. */
	static function capability(fn:String):String
		return fn == "writeFile" ? "workspace.write" : "workspace.read";

	/** Answers a call to a module RayDE provides, if the extension has the capability and the workbench can. */
	function service(call:Dynamic, fn:String):Dynamic {
		var need = capability(fn);
		if (manifest != null && manifest.capabilities.indexOf(need) < 0)
			return {t: "reject", id: call.id, message: 'Capability $need is not granted; add it to "capabilities" in ${haxe.io.Path.withoutDirectory(manifest.file)}'};
		if (services == null)
			return {t: "reject", id: call.id, message: "The workbench provides no services here."};
		var args:Array<Dynamic> = call.args;
		try {
			var value:Dynamic = switch fn {
				case "readFile":
					var text = services.readFile(Std.string(args[0]));
					if (text == null)
						throw 'No such file: ${args[0]}';
					text;
				case "activeFile":
					services.activeFile();
				case "root":
					services.root();
				case "openFile":
					services.openFile(Std.string(args[0]));
					null;
				case _:
					services.writeFile(Std.string(args[0]), Std.string(args[1]));
					null;
			};
			return {t: "resolve", id: call.id, value: value};
		} catch (e:Dynamic)
			return {t: "reject", id: call.id, message: Std.string(e)};
	}

	function reply(message:Dynamic):Void {
		if (host == null)
			return;
		host.send(message);
		note(activity, "answer", (message.t == "resolve" ? "resolved " : "rejected ") + (message.t == "resolve" ? haxe.Json.stringify(message.value) : message.message));
		activeNow();
	}
}
