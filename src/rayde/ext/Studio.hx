package rayde.ext;

import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Signal;
import rayde.lang.Display.Diagnostic;

/** One line of the Console or the Activity list. `kind` is log, error, info, event, call, answer or ops. */
typedef Entry = {kind:String, text:String, time:Float, ?file:String, ?line:Int, ?col:Int};

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
	var container:Null<Node>;
	var mocks:Dynamic = {};
	var mocksFile:String;
	var changedAt = -1.;
	var lastActive = 0.;
	var scheduled = false;
	var attached:Array<Int> = [];

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

	/** Shows the Preview in `container`, a node of the tree. */
	public function attach(container:Node):Void {
		if (this.container != null && this.container.id != container.id)
			release();
		this.container = container;
		if (preview != null)
			preview.show();
		adopt();
	}

	/** Lets go of the container: what is drawn goes from it and from the tree, and the model of the view stays. */
	function release():Void {
		if (container != null)
			tree.detachChildren(container.id);
		if (preview != null)
			preview.hide();
		container = null;
		attached = [];
	}

	/**
	 * Takes the Preview out of `from`, a page that is about to go; the extension and its view go on, and
	 * are drawn again by the next page. A page built to replace it may have the view already.
	 */
	public function detach(from:Node):Void {
		if (container == null || container.id != from.id)
			return;
		release();
	}

	/** Ends the extension and takes its view down, for good. */
	public function dispose():Void {
		stop();
		release();
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
		host = new ExtensionHost(binary, dir, root);
		host.start();
		state.set("running");
		for (module in Reflect.fields(mocks))
			host.send({t: "module", path: module, functions: Reflect.fields(Reflect.field(mocks, module))});
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
			note(console, "error", 'The mocks file ${haxe.io.Path.withoutDirectory(mocksFile)} cannot be read: $e');
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
			note(console, "error", 'The extension host stopped (exit ${host.exitCode}).' + (err == "" ? "" : "\n" + err));
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
					elements.set(elements.get() + 1);
				}
				note(activity, "ops", (m.ops : Array<Dynamic>).length + (m.ops.length == 1 ? " operation" : " operations"));
			case "view":
				if (m.title != null)
					title.set(Std.string(m.title));
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
		attached = [];
		elements.set(elements.get() + 1);
	}

	/** Puts the roots the extension has mounted in the container. */
	function adopt():Void {
		if (preview == null || container == null)
			return;
		preview.findRoots();
		for (r in preview.roots)
			if (attached.indexOf(r.id) < 0) {
				attached.push(r.id);
				if (r.node != null)
					tree.addChild(container.id, r.node.id);
			}
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
			reply({t: "reject", id: call.id, message: 'no mock for $name: add it to ${haxe.io.Path.withoutDirectory(mocksFile)}'});
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

	function reply(message:Dynamic):Void {
		if (host == null)
			return;
		host.send(message);
		note(activity, "answer", (message.t == "resolve" ? "resolved " : "rejected ") + (message.t == "resolve" ? haxe.Json.stringify(message.value) : message.message));
		activeNow();
	}
}
