package rayde.ext;

/** Workspace services answered by the editor and capability checked by the connection. */
typedef WorkspaceServices = {
	readFile:String->Null<String>,
	?readBytes:String->Null<String>,
	?imageBytes:String->Null<haxe.io.Bytes>,
	activeFile:Void->Null<String>,
	root:Void->String,
	openFile:String->Void,
	writeFile:(String, String) -> Void,
	?notify:(String, String, String, String)->Void,
	?focusView:(String, Int)->Void,
	?openExternal:String->Void,
	replay:String->Dynamic
};

/** A line emitted by an extension or its host, optionally linked to source. */
typedef HostEntry = {kind:String, text:String, time:Float, ?file:String, ?line:Int, ?col:Int};

/** A host connection with no dependency on the editor's view or development tools. */
class Connection {
	public static final builtin:Map<String, Array<String>> = ["rayde.workspace" => ["readFile", "readBytes", "activeFile", "root", "openFile", "writeFile"], "rayde.settings" => ["get"], "rayde.window" => ["notify", "focusView", "openExternal"]];

	public var state(default, null) = "stopped";
	public var manifest(default, null):Null<Manifest>;
	public var file(default, null):String;
	public var services:Null<WorkspaceServices>;
	public var onMessage:Null<Dynamic->Void>;
	public var onBatch:Null<Void->Void>;
	public var onState:Null<String->Void>;
	public var onEntry:Null<(String, HostEntry) -> Void>;
	public var onWake:Null<Void->Void>;
	public var onStart:Null<Void->Void>;
	public var nativeAllowed:Manifest->Bool = m -> NativeTrust.allApproved(m);
	public var useMocks = false;

	public var source:Void->String;

	var host:Null<ExtensionHost>;
	var mocks:Dynamic = {};
	final subscribed = new Map<String, Bool>();
	final registered = new Map<String, Bool>();
	var queued:Array<{id:String, args:Dynamic, deadline:Float}> = [];
	final pending = new Map<String, {name:String, data:Dynamic, at:Float}>();
	var replies:Array<{message:Dynamic, at:Float}> = [];
	var messages:Array<Dynamic> = [];
	var nextMessage = 0;

	public function new(file:String, source:Void->String, ?manifest:Manifest) {
		this.file = file;
		this.source = source;
		this.manifest = manifest;
	}

	public function useManifest(m:Manifest):Void {
		var grantsChanged = manifest != null && haxe.Json.stringify(manifest.natives) != haxe.Json.stringify(m.natives);
		manifest = m;
		file = m.mainPath();
		var denied = m.problems.length > 0 || !nativeAllowed(m);
		if (running() && (grantsChanged || m.natives.length > 0 && denied)) {
			stop();
			setState(denied ? "blocked" : "stopped");
		}
	}

	public function mocksPath():String
		return manifest == null ? haxe.io.Path.join([haxe.io.Path.directory(file), "studio.mocks.json"]) : manifest.mocksPath();

	function setState(value:String):Void {
		state = value;
		if (onState != null)
			onState(value);
	}

	public function note(list:String, kind:String, text:String, ?at:{file:String, line:Int, col:Int}):Void {
		if (onEntry != null)
			onEntry(list, {
				kind: kind,
				text: text,
				time: haxe.Timer.stamp(),
				file: at == null ? null : at.file,
				line: at == null ? null : at.line,
				col: at == null ? null : at.col
			});
	}

	public function running():Bool
		return host != null && host.running();

	public function start():Void {
		stop();
		if (manifest != null && manifest.natives.length > 0 && (manifest.problems.length > 0 || !nativeAllowed(manifest))) {
			note("console", "error", manifest.problems.length > 0 ? manifest.problems[0] : "Native approval required in Settings > Extensions.");
			setState("blocked");
			return;
		}
		mocks = {};
		if (useMocks && sys.FileSystem.exists(mocksPath()))
			try
				mocks = haxe.Json.parse(sys.io.File.getContent(mocksPath()))
			catch (e:Dynamic)
				note("console", "error", 'Cannot read mocks file: $e');
		try {
			host = new ExtensionHost(manifest == null ? haxe.io.Path.directory(file) : manifest.importRoot());
			host.start();
			setState("running");
			if (manifest != null && manifest.natives.length > 0)
				send({t: "natives", root: manifest.root, capabilities: manifest.capabilities, libraries: manifest.natives});
			var modules = new Map<String, Array<String>>();
			for (module => names in builtin)
				modules.set(module, names.copy());
			for (module in Reflect.fields(mocks)) {
				var names = modules.exists(module) ? modules.get(module) : [];
				for (fn in Reflect.fields(Reflect.field(mocks, module)))
					if (names.indexOf(fn) < 0)
						names.push(fn);
				modules.set(module, names);
			}
			for (module => names in modules)
				send({t: "module", path: module, functions: names});
			if (onStart != null)
				onStart();
			send({t: "run", name: file, source: source()});
			note("activity", "info", "Started");
		} catch (e:Dynamic) {
			if (host != null)
				host.stop();
			host = null;
			note("console", "error", 'Cannot start extension: $e');
			setState("exited");
		}
	}

	public function stop():Void {
		if (host != null)
			host.stop();
		host = null;
		subscribed.clear();
		registered.clear();
		queued = [];
		pending.clear();
		replies = [];
		messages = []; nextMessage = 0;
		setState("stopped");
	}

	public function collect():Void {
		if (host != null) host.collect();
	}

	public function send(message:Dynamic):Bool {
		if (host == null)
			return false;
		var sent = host.send(message);
		if (onWake != null)
			onWake();
		return sent;
	}

	public function tick():Void {
		if (host == null)
			return;
		var now = haxe.Timer.stamp();
		for (key in [for (k in pending.keys()) k]) {
			var p = pending.get(key);
			if (p.at <= now) {
				pending.remove(key);
				deliver(p.name, p.data);
			}
		}
		var due = replies;
		replies = [];
		for (p in due)
			if (p.at <= now)
				reply(p.message)
			else
				replies.push(p);
		var expired = [for (q in queued) if (q.deadline <= now) q];
		for (q in expired) {
			queued.remove(q);
			note("console", "error", 'Command ${q.id} was not registered before its activation timed out.');
		}
		var current = host;
		if (nextMessage == messages.length) { messages = current.poll(); nextMessage = 0; }
		var deadline = haxe.Timer.stamp() + .004;
		while (nextMessage < messages.length) {
			var m = messages[nextMessage++];
			var timing = Timing.start();
			switch (m.t : String) {
				case "registered":
					var id = Std.string(m.id);
					registered.set(id, true);
					for (q in queued.copy())
						if (q.id == id) {
							queued.remove(q);
							command(q.id, q.args);
						}
				case "error":
					failed(m);
					if (m.kind == "native") {
						stop();
						setState("blocked");
					}
				case "subscribe":
					var name = Std.string(m.hook);
					if (!Hooks.knownEvent(name))
						note("console", "error", 'Unknown hook "$name"; expected ${Hooks.eventNames().join(", ")}.');
					else {
						subscribed.set(name, true);
						var replay = services == null ? null : services.replay(name);
						if (replay != null)
							hook(name, replay);
					}
				case "call":
					if (m.fn == "rayde.window.focusView" && onBatch != null) onBatch();
					answer(m);
				case "log":
					note("console", "log", m.message);
				case _:
			}
			if (onMessage != null)
				onMessage(m);
			if (Timing.enabled) Timing.end(timing, "message." + Std.string(m.t), {extension:manifest == null ? file : manifest.id});
			if (host != current || haxe.Timer.stamp() >= deadline) break;
		}
		if (onBatch != null) onBatch();
		if (nextMessage < messages.length && onWake != null) onWake();
		if (host == current && current.state == "exited" && nextMessage == messages.length) {
			var err = StringTools.trim(current.errors());
			note("console", "error", 'Extension host exited with code ${current.exitCode}.' + (err == "" ? "" : "\n" + err));
			host = null;
			setState("exited");
		}
	}

	public function listening():Array<String>
		return [for (name in subscribed.keys()) name];

	public function hook(name:String, data:Dynamic, ?delay:Float):Void {
		if (!running() || !subscribed.exists(name))
			return;
		if (delay == null)
			deliver(name, data);
		else {
			var key = name + (data != null && Reflect.hasField(data, "path") ? ":" + data.path : "");
			pending.set(key, {name: name, data: data, at: haxe.Timer.stamp() + delay});
			if (onWake != null)
				onWake();
		}
	}

	function deliver(name:String, data:Dynamic):Void {
		send({t: "hook", name: name, data: data});
		note("activity", "event", 'hook $name' + (data == null ? "" : " " + haxe.Json.stringify(data)));
	}

	public function command(id:String, args:Dynamic):Void {
		if (!running()) {
			note("console", "error", 'Cannot run command $id: the extension is not running.');
			return;
		}
		if (!registered.exists(id)) {
			queued.push({id: id, args: args, deadline: haxe.Timer.stamp() + 5});
			if (onWake != null)
				onWake();
			return;
		}
		send({t: "command", id: id, args: args});
		note("activity", "event", 'command $id' + (args == null ? "" : " " + haxe.Json.stringify(args)));
	}

	function failed(message:Dynamic):Void {
		var items:Array<Dynamic> = message.items == null ? [] : message.items;
		var first = items.length == 0 ? null : items[0];
		note("console", "error", StringTools.trim(Std.string(message.message).split("\n")[0]), first == null
			|| first.line == null ? null : place(first));
		if (message.kind == "runtime")
			for (i in 1...items.length) {
				var item = items[i],
					functionName:Dynamic = Reflect.field(item, "function");
				if (item.line != null)
					note("console", "info",
						"  at "
						+ (functionName == null ? "" : functionName + " ")
						+ haxe.io.Path.withoutDirectory(item.file)
						+ ":"
						+ item.line
						+ ":"
						+ item.col,
						place(item));
			}
	}

	static function place(item:Dynamic):{file:String, line:Int, col:Int}
		return {file: item.file, line: Std.int(item.line), col: Std.int(item.col)};

	function answer(call:Dynamic):Void {
		var name:String = call.fn,
			at = name.lastIndexOf("."),
			module = name.substr(0, at),
			fn = name.substr(at + 1);
		note("activity", "call", name + "(" + [for (a in (call.args : Array<Dynamic>)) haxe.Json.stringify(a)].join(", ") + ")");
		var group = Reflect.field(mocks, module);
		if (group == null || !Reflect.hasField(group, fn)) {
			reply(builtin.exists(module)
				&& builtin.get(module).indexOf(fn) >= 0 ? service(call, fn, module) : {t: "reject", id: call.id, message: 'No service for $name'});
			return;
		}
		var value:Dynamic = Reflect.field(group, fn), delay = 0;
		if (value != null && Reflect.hasField(value, "$after")) {
			delay = Std.int(Reflect.field(value, "$after"));
			value = Reflect.field(value, "$value");
		}
		var message:Dynamic = value != null
			&& Reflect.hasField(value,
				"$error") ? {t: "reject", id: call.id, message: Std.string(Reflect.field(value, "$error"))} : {t: "resolve", id: call.id, value: value};
		if (delay > 0)
			replies.push({message: message, at: haxe.Timer.stamp() + delay / 1000});
		else
			reply(message);
	}

	function service(call:Dynamic, fn:String, module:String):Dynamic {
		var need = fn == "writeFile" ? "workspace.write" : "workspace.read";
		if (module == "rayde.workspace" && manifest != null && manifest.capabilities.indexOf(need) < 0)
			return {
				t: "reject",
				id: call.id,
				message: 'Capability $need is not granted; add it to "capabilities" in ${haxe.io.Path.withoutDirectory(manifest.file)}'
			};
		if (services == null)
			return {t: "reject", id: call.id, message: "The workbench provides no services here."};
		var args:Array<Dynamic> = call.args;
		try {
			var value:Dynamic = switch fn {
				case "focusView" if (module == "rayde.window"):
					if (services.focusView != null) services.focusView(file, Std.int(args[0]));
					null;
				case "openExternal" if (module == "rayde.window"):
					if (manifest != null && manifest.capabilities.indexOf("window.openExternal") < 0) throw "Capability window.openExternal is not granted";
					var url = Std.string(args[0]);
					if (!~/^(https?:\/\/|mailto:)/i.match(url)) throw "External links require http, https or mailto";
					if (services.openExternal == null) throw "External links are unavailable";
					services.openExternal(url);
					null;
				case "notify" if (module == "rayde.window"):
					var message = Std.string(args[0]), kind = args.length > 1 ? Std.string(args[1]) : "info";
					if (["info", "success", "warning", "error"].indexOf(kind) < 0) throw "Unknown notification kind";
					note("console", kind, message);
					if (services.notify != null) services.notify(manifest == null ? "" : manifest.id, manifest == null ? "Extension" : manifest.name, message, kind);
					null;
				case "get" if (module == "rayde.settings"):
					if (manifest == null) throw "Extension settings require a manifest";
					var key = Std.string(args[0]), section = "extension." + manifest.id;
					var workspace = rayde.settings.Store.section(services.root(), section);
					var user = rayde.settings.Store.section(rayde.settings.Extensions.home(), section);
					var fallback:Dynamic = args.length > 1 ? args[1] : null;
					var groups:Array<Dynamic> = manifest.configuration == null ? [] : Std.isOfType(manifest.configuration, Array) ? manifest.configuration : [manifest.configuration];
					for (group in groups) {
						var definition = group == null || group.properties == null ? null : Reflect.field(group.properties, key);
						if (definition != null && Reflect.hasField(definition, "default")) fallback = Reflect.field(definition, "default");
					}
					Reflect.hasField(workspace, key) ? Reflect.field(workspace, key) : Reflect.hasField(user, key) ? Reflect.field(user, key) : fallback;
				case "readFile":
					var text = services.readFile(Std.string(args[0]));
					if (text == null)
						throw 'No such file: ${args[0]}';
					text;
				case "readBytes":
					var bytes = services.readBytes == null ? null : services.readBytes(Std.string(args[0]));
					if (bytes == null) throw 'No such image: ${args[0]}';
					bytes;
				case "activeFile": services.activeFile();
				case "root": services.root();
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
		send(message);
		note("activity", "answer",
			(message.t == "resolve" ? "resolved " : "rejected ") + (message.t == "resolve" ? haxe.Json.stringify(message.value) : message.message));
	}
}
