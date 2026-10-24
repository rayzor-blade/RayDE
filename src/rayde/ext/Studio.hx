package rayde.ext;

import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Signal;
import rayde.lang.Display.Diagnostic;

/** One line of the Console or the Activity list. `kind` is log, error, info, event, call, answer or ops. */
typedef Entry = rayde.ext.Connection.HostEntry;

/** What an extension can ask of the workbench, through the `rayde.workspace` module; the workbench provides it. */
typedef Services = rayde.ext.Connection.WorkspaceServices;

/** A view the extension presented as a tab: the root it mounted, and the title it gave. */
typedef TabView = {root:Int, title:String};

/**
 * A place a view is drawn: its container, and what it shows: one root, for a tab; the roots mounted for one declared
 * view, for a part of the layout; or, with neither, every root that is not a tab, as a script run on its own has.
 */
private typedef Surface = {container:Node, root:Null<Int>, view:Null<String>, attached:Array<Int>};

/**
 * An extension being developed: its host, the Preview its view is drawn in, and what it said and
 * did. `reload` starts the extension afresh from the source as the editor holds it, `edited` does so
 * a moment after typing stops, and `tick` moves everything along. The remote modules an extension imports
 * are answered from a mocks file, so it can run with no editor behind it.
 */
class Studio {
	/** stopped, running, or exited. */
	public final state = Signal.make("stopped");

	public final console = Signal.make(([] : Array<Entry>));
	public final activity = Signal.make(([] : Array<Entry>));

	/** Whether typing reloads the extension on its own, a moment after it stops. */
	public final live = Signal.make(true);

	/** True while the view shown is the last that ran and the source as it is now does not: it has a mistake in it. */
	public final stale = Signal.make(false);
	/** Empty when ready; otherwise the startup or command preparation being awaited. */
	public final progress = Signal.make("");
	public final failure = Signal.make("");

	/** The heading of the view: the config's title, which the extension can change. */
	public final title:Signal<String>;

	/** Changes with the Preview's tree, for the Elements panel. */
	public final elements = Signal.make(0);

	/** The extension's breakpoints, and where it is stopped. */
	public final debug = new Debugger();

	/** Which part of the extension's panel is in view: console, activity, elements or debug. */
	public final panel = Signal.make("console");

	/** The views the extension presented as tabs, in the order it mounted them. */
	public var tabViews(default, null):Array<TabView> = [];

	/** Called when the extension's tabs change: one mounted, unmounted or retitled. */
	public var onTabs:Null<Array<TabView>->Void>;

	/** What the extension may ask of the workbench; set by whoever shows it. */
	public var services(get, set):Null<Services>;
	function get_services():Null<Services> return connection.services;
	function set_services(value:Null<Services>):Null<Services> return connection.services = value;

	public final connection:Connection;
	public var development = true;
	public var managed = false;

	/** The functions of the modules RayDE answers itself, by module. */
	public static final builtin = Connection.builtin;

	/** The syntax or compile errors of the last run of the source, where the editor can put them. */
	public var problems(default, null):Array<Diagnostic> = [];

	/** Called when `problems` is replaced. */
	public var onProblems:Null<Array<Diagnostic>->Void>;

	/** Called when the console gets an error, with its kind (syntax, compile, runtime or view), so a panel can come into view. */
	public var onError:Null<String->Void>;

	public var file(default, null):String;

	/** What the extension's view is, as nodes of the tree. It outlives the pages that show it: `detach` takes it out of one, `attach` puts it in the next. */
	public var preview(default, null):Null<Preview>;

	/** The config of the extension, when it was opened from one. */
	public var manifest(default, null):Null<Manifest>;
	final tree:LayoutTree;
	final surfaces:Array<Surface> = [];
	final surfaceRevision = Signal.make(0);
	// Attaching a surface must not subscribe its parent to this revision.
	var surfaceSerial = 0;

	/** The names of mounted views the config gives no place, said once each. */
	final unhosted:Array<String> = [];

	var changedAt = -1.;
	var lastActive = 0.;
	var scheduled = false;
	var scheduledAt = 0.;
	var pollTimer:ashui.animation.AnimationScheduler.Timer;
	var receive:LayoutTree->Void;

	/** Whether the Studio has been taken down, and so starts nothing. */
	var disposed = false;

	/** Set by a reload: the view stays until the new version has started, so a typing mistake does not blank it. */
	var replacing = false;
	var opsPending = false;

	/** Counts what the Console shows. */
	static inline var MAX_ENTRIES = 1000;

	/** `file` is the script that is the extension's main, `source` gives it as the editor holds it; the view's nodes are made in `tree`. */
	public function new(file:String, source:Void->String, tree:LayoutTree, ?manifest:Manifest, ?connection:Connection) {
		this.file = file;
		this.tree = tree;
		this.manifest = manifest;
		title = Signal.make(manifest != null ? manifest.viewTitle : "Preview");
		Utilities.install();
		preview = new Preview(tree, send, readImage, manifest != null && manifest.capabilities.indexOf("net.profiles") >= 0);
		this.connection = connection == null ? new Connection(file, source, manifest) : connection;
		preview.onProblem = message -> this.connection.note("console", "error", message);
		if (connection == null) this.connection.useMocks = true;
		this.connection.onMessage = handle;
		this.connection.onBatch = flushOps;
		this.connection.onEntry = (list, entry) -> note(list == "console" ? console : activity, entry.kind, entry.text,
			entry.line == null ? null : {file: entry.file, line: entry.line, col: entry.col});
		this.connection.onState = value -> {
			state.set(value);
			if (value != "running") debug.disconnect();
			if (value == "exited" || value == "blocked") { opsPending = false; clearView(); }
		};
		this.connection.onStart = () -> {
			replacing = true;
			failure.set("");
			debug.connect(m -> this.connection.send(m));
		};
		this.connection.onProgress = () -> progress.set(this.connection.progress());
		progress.set(this.connection.progress());
		this.connection.onWake = activeNow;
		receive = current -> {
			if (current != tree || disposed || !this.connection.hasEvents()) return;
			if (pollTimer != null) pollTimer.cancel();
			pollTimer = null; scheduled = false;
			tick(); scheduleNext();
		};
		LayoutTree.flushHooks.push(receive);
		state.set(this.connection.state);
	}

	/** The config changed: the view's heading, where scripts are imported from and the mocks file are what it says now. */
	public function useManifest(m:Manifest):Void {
		manifest = m;
		file = m.mainPath();
		connection.useManifest(m);
		title.set(m.viewTitle);
	}

	public function mocksPath():String
		return connection.mocksPath();

	function readImage(base:String, href:String):{bytes:haxe.io.Bytes, svg:Bool} {
		if (manifest == null || manifest.capabilities.indexOf("workspace.read") < 0) throw "Capability workspace.read is not granted";
		if (services == null) throw "Workspace images are unavailable";
		if (href.indexOf(":") >= 0 || StringTools.startsWith(href, "//")) throw "Preview images must be local files";
		var name = StringTools.urlDecode(href.split("#")[0].split("?")[0]);
		var path = haxe.io.Path.isAbsolute(name) ? name : haxe.io.Path.join([haxe.io.Path.directory(base), name]);
		var bytes = services.imageBytes != null ? services.imageBytes(path) : services.readBytes == null ? null : haxe.crypto.Base64.decode(services.readBytes(path));
		if (bytes == null) throw 'No such image: $href';
		return {bytes:bytes, svg:StringTools.endsWith(path.toLowerCase(), ".svg")};
	}

	/**
	 * Draws the view in `container`, a node of the tree: the main view, or only the root `root` for a tab.
	 * A page built to replace one that showed the same thing takes its place.
	 */
	public function attach(container:Node, ?root:Int, ?view:String):Void {
		for (s in surfaces.copy())
			if (s.root == root && s.view == view && s.container.id != container.id)
				release(s);
		if (!Lambda.exists(surfaces, s -> s.container.id == container.id))
			surfaces.push({container: container, root: root, view: view, attached: []});
		if (preview != null) {
			preview.setVisibleRoots(visibleRoots());
			preview.show();
		}
		adopt();
		surfaceRevision.set(++surfaceSerial);
		if (root == null && view != null) hook("view.visibility", {id:view, visible:true});
	}

	/** Lets go of a surface: what is drawn goes from it and from the tree, and the model of the view stays. */
	function release(s:Surface):Void {
		tree.detachChildren(s.container.id);
		surfaces.remove(s);
		surfaceRevision.set(++surfaceSerial);
		if (s.root == null && s.view != null && !Lambda.exists(surfaces, other -> other.root == null && other.view == s.view))
			hook("view.visibility", {id:s.view, visible:false});
		if (surfaces.length == 0 && preview != null)
			preview.hide();
		else if (preview != null) preview.setVisibleRoots(visibleRoots());
		connection.collect();
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

	/** Takes down mounted views when an installed extension is disabled. */
	public function clearView():Void {
		if (preview != null) preview.clear();
		for (surface in surfaces) surface.attached = [];
		var hadTabs = tabViews.length > 0;
		tabViews = [];
		if (hadTabs && onTabs != null) onTabs([]);
		elements.set(elements.get() + 1);
	}

	/** Ends the extension and takes its view down, for good. */
	public function dispose():Void {
		// A reload that was waiting for typing to stop must not start the extension again.
		disposed = true;
		LayoutTree.flushHooks.remove(receive);
		if (pollTimer != null) pollTimer.cancel();
		pollTimer = null; scheduled = false;
		changedAt = -1;
		stop();
		for (s in surfaces.copy())
			release(s);
		if (preview != null)
			preview.clear();
		preview = null;
	}

	function note(list:Signal<Array<Entry>>, kind:String, text:String, ?at:{file:String, line:Int, col:Int}):Void {
		if (list == activity) text = ActivityLog.clip(text);
		var all = list.get().copy();
		all.push({kind: kind, text: text, time: haxe.Timer.stamp(), file: at == null ? null : at.file, line: at == null ? null : at.line, col: at == null ? null : at.col});
		if (all.length > MAX_ENTRIES)
			all = all.slice(all.length - MAX_ENTRIES);
		list.set(all);
	}

	public function clearConsole():Void
		console.set([]);

	/** Runs the extension afresh: a new VM, the Preview emptied, the mocked modules registered, the source run. */
	public function reload():Void {
		changedAt = -1;
		if (disposed) return;
		title.set(manifest != null ? manifest.viewTitle : "Preview");
		problems = [];
		if (onProblems != null) onProblems(problems);
		unhosted.resize(0);
		connection.start();
		activeNow();
	}

	/** The source changed in the editor: with `live` on, reloads once it has been still for a moment. */
	public function edited():Void {
		if (live.get())
			changedAt = haxe.Timer.stamp();
		activeNow();
	}

	public function stop():Void connection.stop();

	public function running():Bool return connection.running();

	/** Reads the view revision so a waiting surface follows asynchronously mounted roots. */
	public function hasView(?view:String):Bool {
		elements.get();
		return preview != null && Lambda.exists(preview.roots,r -> r.node != null && !isTab(r.name) && (view == null || viewFor(r.name) == view));
	}

	public function loadingMessage():String {
		var preparing = progress.get();
		if (preparing != "") return preparing;
		surfaceRevision.get(); elements.get();
		if (state.get() != "running" || failure.get() != "") return "";
		if (manifest != null && manifest.views.length == 0) return "";
		return Lambda.exists(surfaces,s -> s.root == null ? !hasView(s.view) : preview == null || !Lambda.exists(preview.roots,r -> r.id == s.root && r.node != null)) ? "Opening extension view…" : "";
	}

	/** The buttons the extension's config puts in its header. */
	public function tools(?view:String):Array<rayde.ext.Manifest.ViewTool> {
		if (manifest == null)
			return [];
		var v = view == null ? (manifest.views.length == 0 ? null : manifest.views[0]) : manifest.viewOf(view);
		return v == null ? [] : v.tools;
	}

	/** A tool of the header was chosen: tells the extension. */
	public function tool(id:String):Void {
		if (!connection.running())
			return;
		connection.send({t: "tool", id: id});
		note(activity, "event", 'tool $id');
		activeNow();
	}

	/** Sends an event for an element of the view, as a person using the Preview does. */
	public function send(node:Int, event:String, payload:Dynamic):Void {
		if (!connection.running())
			return;
		connection.send({t: "event", node: node, event: event, payload: payload});
		note(activity, "event", '$event on #$node' + (payload == null ? "" : " " + ActivityLog.describe(payload)));
		activeNow();
	}

	/** Polls faster for a while after something happened, so a click and its answer feel immediate. */
	function activeNow():Void {
		lastActive = haxe.Timer.stamp();
		schedule(.016);
	}

	function schedule(delay:Float):Void {
		var at = haxe.Timer.stamp() + delay;
		if (scheduled && scheduledAt <= at)
			return;
		if (pollTimer != null) pollTimer.cancel();
		scheduled = true;
		scheduledAt = at;
		pollTimer = ashui.animation.AnimationScheduler.main.after(delay, () -> {
			scheduled = false;
			pollTimer = null;
			tick();
			scheduleNext();
		});
	}

	function scheduleNext():Void {
		if (disposed) return;
		var delay = connection.pollDelay(), now = haxe.Timer.stamp();
		if (connection.running() && !connection.canWake()) {
			var quiet = now - lastActive, fallback = quiet < 1 ? .016 : quiet < 5 ? .1 : .5;
			if (delay == null || fallback < delay) delay = fallback;
		}
		if (changedAt >= 0) {
			var reload = Math.max(.001, .4 - (now - changedAt));
			if (delay == null || reload < delay) delay = reload;
		}
		if (delay != null) schedule(delay);
	}

	/** Moves the extension along: reads what the host said, and reloads after typing has stopped. */
	public function tick():Void {
		if (changedAt >= 0 && haxe.Timer.stamp() - changedAt > .4) reload();
		connection.tick();
	}

	function handle(m:Dynamic):Void {
		switch (m.t : String) {
			case "subscribe" if (m.hook == "view.visibility" && manifest != null):
				for (view in manifest.views) hook("view.visibility", {id:view.id, visible:Lambda.exists(surfaces, s -> s.root == null && s.view == view.id)});
			case "started":
				replace();
			case "ops":
				if (preview != null) {
					preview.apply(m.ops, false);
					opsPending = true;
				}
				note(activity, "ops", (m.ops : Array<Dynamic>).length + (m.ops.length == 1 ? " operation" : " operations"));
			case "view":
				if (m.title != null)
					title.set(Std.string(m.title));
			case "paused" | "resumed" | "variables" | "children" | "evaluated" | "breakpoints":
				if (m.t == "paused")
					note(activity, "event", "stopped: " + m.reason);
				debug.handle(m);
			case "error":
				failed(m);
			case _:
		}
	}

	function flushOps():Void {
		if (!opsPending || preview == null) return;
		opsPending = false;
		preview.commit();
		adopt(); refreshTabs();
		elements.set(elements.get() + 1);
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

	/**
	 * The declared view a root mounted under `name` belongs to: the view with that id, else the first. Null when the
	 * config declares none, or there is no config.
	 */
	function viewFor(name:String):Null<String> {
		if (manifest == null || manifest.views.length == 0)
			return null;
		var v = manifest.viewOf(name);
		return v != null ? v.id : manifest.views[0].id;
	}

	/** Puts each root the extension has mounted in the surface that shows it. */
	function visibleRoots():Array<Int> {
		preview.findRoots();
		return [for (r in preview.roots) if (Lambda.exists(surfaces, s -> s.root != null ? r.id == s.root : !isTab(r.name) && (s.view == null || viewFor(r.name) == s.view))) r.id];
	}

	function adopt():Void {
		if (preview == null)
			return;
		preview.findRoots();
		preview.setVisibleRoots(visibleRoots());
		for (r in preview.roots)
			if (manifest != null && manifest.views.length == 0 && !isTab(r.name) && unhosted.indexOf(r.name) < 0) {
				unhosted.push(r.name);
				note(console, "error", 'Mounted a view "${r.name}", but ${haxe.io.Path.withoutDirectory(manifest.file)} declares no view. Declare one under "views", or mount it as "tab:<title>".');
			}
		for (s in surfaces)
			for (r in preview.roots) {
				var wanted = s.root != null ? r.id == s.root : !isTab(r.name) && (s.view == null || viewFor(r.name) == s.view);
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
		if (connection.running())
			connection.send({t: "closed", root: root});
	}

	/** The hooks the running extension listens for. */
	public function listening():Array<String> return connection.listening();

	public function hook(name:String, data:Dynamic, ?delay:Float):Void connection.hook(name, data, delay);

	public function command(id:String, args:Dynamic):Void connection.command(id, args);

	function failed(m:Dynamic):Void {
		failure.set(Std.string(m.message));
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
		if (onError != null) onError(kind);
	}

}
